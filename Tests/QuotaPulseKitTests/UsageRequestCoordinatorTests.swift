#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class UsageRequestCoordinatorTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_779_999_030)

    func testCachesSeparatelyForEachKey() async throws {
        let recorder = CallRecorder()
        let coordinator = UsageRequestCoordinator<Int, String>(
            minimumBackgroundInterval: 120,
            now: { [fixedNow] in fixedNow }
        )

        let firstA = try await coordinator.fetch(key: "a", userInitiated: false) {
            await recorder.record(key: "a")
            return 11
        }
        let cachedA = try await coordinator.fetch(key: "a", userInitiated: false) {
            await recorder.record(key: "a")
            return 999
        }
        let firstB = try await coordinator.fetch(key: "b", userInitiated: false) {
            await recorder.record(key: "b")
            return 22
        }

        XCTAssertEqual(firstA, 11)
        XCTAssertEqual(cachedA, 11)
        XCTAssertEqual(firstB, 22)
        let calls = await recorder.keys
        XCTAssertEqual(calls, ["a", "b"])
    }

    func testUserInitiatedCallBypassesCacheEvenWithinBackgroundInterval() async throws {
        let recorder = CallRecorder()
        let coordinator = UsageRequestCoordinator<Int, String>(
            minimumBackgroundInterval: 120,
            now: { [fixedNow] in fixedNow }
        )

        _ = try await coordinator.fetch(key: "a", userInitiated: false) {
            await recorder.record(key: "a")
            return 11
        }
        let second = try await coordinator.fetch(key: "a", userInitiated: true) {
            await recorder.record(key: "a")
            return 22
        }

        XCTAssertEqual(second, 22)
        let calls = await recorder.keys
        XCTAssertEqual(calls, ["a", "a"])
    }

    func testBackgroundCallAfterIntervalElapsesFetchesAgain() async throws {
        let clock = MutableClock(fixedNow)
        let recorder = CallRecorder()
        let coordinator = UsageRequestCoordinator<Int, String>(
            minimumBackgroundInterval: 120,
            now: { clock.date }
        )

        _ = try await coordinator.fetch(key: "a", userInitiated: false) {
            await recorder.record(key: "a")
            return 11
        }
        clock.date = clock.date.addingTimeInterval(121)
        let second = try await coordinator.fetch(key: "a", userInitiated: false) {
            await recorder.record(key: "a")
            return 22
        }

        XCTAssertEqual(second, 22)
        let calls = await recorder.keys
        XCTAssertEqual(calls, ["a", "a"])
    }

    func testConcurrentCallsForTheSameKeyShareOneInFlightTask() async throws {
        let recorder = BlockingRecorder()
        let coordinator = UsageRequestCoordinator<Int, String>(
            minimumBackgroundInterval: 120,
            now: { [fixedNow] in fixedNow }
        )

        async let first = coordinator.fetch(key: "a", userInitiated: false) {
            try await recorder.run()
        }
        async let second = coordinator.fetch(key: "a", userInitiated: false) {
            try await recorder.run()
        }
        await recorder.release()

        let (firstValue, secondValue) = try await (first, second)

        XCTAssertEqual(firstValue, 42)
        XCTAssertEqual(secondValue, 42)
        let count = await recorder.callCount
        XCTAssertEqual(count, 1)
    }

    func testConcurrentCallsForDifferentKeysDoNotShareAnInFlightTask() async throws {
        let recorder = BlockingRecorder()
        let coordinator = UsageRequestCoordinator<Int, String>(
            minimumBackgroundInterval: 120,
            now: { [fixedNow] in fixedNow }
        )

        async let first = coordinator.fetch(key: "a", userInitiated: false) {
            try await recorder.run()
        }
        async let second = coordinator.fetch(key: "b", userInitiated: false) {
            try await recorder.run()
        }
        await recorder.release()

        _ = try await (first, second)

        let count = await recorder.callCount
        XCTAssertEqual(count, 2)
    }

    func testFailureWithNoBackoffClassificationRetriesImmediately() async throws {
        let recorder = CallRecorder()
        let coordinator = UsageRequestCoordinator<Int, String>(
            minimumBackgroundInterval: 120,
            now: { [fixedNow] in fixedNow }
            // default classifyFailure never blocks
        )

        do {
            _ = try await coordinator.fetch(key: "a", userInitiated: false) {
                await recorder.record(key: "a")
                throw SampleError.boom
            }
            XCTFail("expected failure")
        } catch SampleError.boom {
            // expected
        }

        let second = try await coordinator.fetch(key: "a", userInitiated: false) {
            await recorder.record(key: "a")
            return 5
        }

        XCTAssertEqual(second, 5)
        let calls = await recorder.keys
        XCTAssertEqual(calls, ["a", "a"])
    }

    func testClassifiedFailureBlocksSubsequentCallsUntilTheWindowPasses() async throws {
        let clock = MutableClock(fixedNow)
        let recorder = CallRecorder()
        let coordinator = UsageRequestCoordinator<Int, String>(
            minimumBackgroundInterval: 120,
            now: { clock.date },
            classifyFailure: { _, now in (now.addingTimeInterval(30), SampleError.blocked) }
        )

        do {
            _ = try await coordinator.fetch(key: "a", userInitiated: true) {
                await recorder.record(key: "a")
                throw SampleError.boom
            }
            XCTFail("expected failure")
        } catch SampleError.boom {
            // expected
        }

        do {
            _ = try await coordinator.fetch(key: "a", userInitiated: true) {
                await recorder.record(key: "a")
                return 5
            }
            XCTFail("expected blocked error")
        } catch SampleError.blocked {
            // expected: blocked window has not elapsed
        }

        clock.date = clock.date.addingTimeInterval(31)
        let afterWindow = try await coordinator.fetch(key: "a", userInitiated: true) {
            await recorder.record(key: "a")
            return 5
        }

        XCTAssertEqual(afterWindow, 5)
        let calls = await recorder.keys
        XCTAssertEqual(calls, ["a", "a"])
    }

    func testSuccessAfterFailureClearsAnyBlock() async throws {
        let clock = MutableClock(fixedNow)
        let shouldFail = MutableFlag(true)
        let coordinator = UsageRequestCoordinator<Int, String>(
            minimumBackgroundInterval: 120,
            now: { clock.date },
            classifyFailure: { _, now in (now.addingTimeInterval(30), SampleError.blocked) }
        )

        do {
            _ = try await coordinator.fetch(key: "a", userInitiated: true) {
                if shouldFail.value { throw SampleError.boom }
                return 1
            }
            XCTFail("expected failure")
        } catch SampleError.boom {
            shouldFail.value = false
        }

        clock.date = clock.date.addingTimeInterval(31)
        let recovered = try await coordinator.fetch(key: "a", userInitiated: true) { 7 }
        XCTAssertEqual(recovered, 7)

        // Immediately after a success, a fresh failure should be free to
        // install its own block rather than being shadowed by a stale one.
        do {
            _ = try await coordinator.fetch(key: "a", userInitiated: true) {
                throw SampleError.boom
            }
            XCTFail("expected failure")
        } catch SampleError.boom {
            // expected
        }
        do {
            _ = try await coordinator.fetch(key: "a", userInitiated: true) { 9 }
            XCTFail("expected blocked error")
        } catch SampleError.blocked {
            // expected
        }
    }
}

private enum SampleError: Error, Equatable {
    case boom
    case blocked
}

/// A reference-type box lets `now:` closures observe a later mutation
/// without capturing a `var` directly, which the Swift 6 concurrency
/// checker flags even though every mutation here happens strictly before
/// the next `await`.
private final class MutableClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private final class MutableFlag: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

private actor CallRecorder {
    private(set) var keys: [String] = []

    func record(key: String) {
        keys.append(key)
    }
}

/// Blocks the first call on a continuation until `release()` is called, so a
/// test can assert two concurrent calls for the same key coalesce into
/// exactly one in-flight task.
private actor BlockingRecorder {
    private(set) var callCount = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run() async throws -> Int {
        callCount += 1
        if !released {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return 42
    }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}
#endif
