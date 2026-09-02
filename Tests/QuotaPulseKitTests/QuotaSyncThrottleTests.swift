import XCTest
@testable import QuotaPulseKit

final class QuotaSyncThrottleTests: XCTestCase {
    private func snapshot(sessionUsed: Double?, sessionResetAt: Date? = nil, weeklyUsed: Double? = nil) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .codex,
            session: QuotaWindow(usedPercent: sessionUsed, resetAt: sessionResetAt),
            weekly: QuotaWindow(usedPercent: weeklyUsed, resetAt: nil)
        )
    }

    func testFirstEverSnapshotAlwaysSyncs() {
        let next = snapshot(sessionUsed: 10)
        XCTAssertTrue(QuotaSyncThrottle.shouldSync(previous: nil, next: next, lastSyncedAt: nil))
    }

    func testNeverSyncedBeforeAlwaysSyncs() {
        let previous = snapshot(sessionUsed: 10)
        let next = snapshot(sessionUsed: 10)
        XCTAssertTrue(QuotaSyncThrottle.shouldSync(previous: previous, next: next, lastSyncedAt: nil))
    }

    func testBelowDeltaAndBeforeIntervalDoesNotSync() {
        let now = Date(timeIntervalSince1970: 10_000)
        let previous = snapshot(sessionUsed: 10)
        let next = snapshot(sessionUsed: 10.4)
        let shouldSync = QuotaSyncThrottle.shouldSync(
            previous: previous,
            next: next,
            lastSyncedAt: now.addingTimeInterval(-60),
            now: now
        )
        XCTAssertFalse(shouldSync)
    }

    func testPercentChangeAboveDeltaSyncs() {
        let now = Date(timeIntervalSince1970: 10_000)
        let previous = snapshot(sessionUsed: 10)
        let next = snapshot(sessionUsed: 11.2)
        let shouldSync = QuotaSyncThrottle.shouldSync(
            previous: previous,
            next: next,
            lastSyncedAt: now.addingTimeInterval(-60),
            now: now
        )
        XCTAssertTrue(shouldSync)
    }

    func testResetAtChangeSyncs() {
        let now = Date(timeIntervalSince1970: 10_000)
        let previous = snapshot(sessionUsed: 10, sessionResetAt: Date(timeIntervalSince1970: 100))
        let next = snapshot(sessionUsed: 10, sessionResetAt: Date(timeIntervalSince1970: 200))
        let shouldSync = QuotaSyncThrottle.shouldSync(
            previous: previous,
            next: next,
            lastSyncedAt: now.addingTimeInterval(-60),
            now: now
        )
        XCTAssertTrue(shouldSync)
    }

    func testElapsedMinimumIntervalSyncsEvenWithoutChange() {
        let now = Date(timeIntervalSince1970: 10_000)
        let previous = snapshot(sessionUsed: 10)
        let next = snapshot(sessionUsed: 10)
        let shouldSync = QuotaSyncThrottle.shouldSync(
            previous: previous,
            next: next,
            lastSyncedAt: now.addingTimeInterval(-301),
            now: now
        )
        XCTAssertTrue(shouldSync)
    }

    func testCrossingAlertThresholdSyncsImmediately() {
        let now = Date(timeIntervalSince1970: 10_000)
        // remaining crosses the default "light" threshold (30%) downward
        let previous = snapshot(sessionUsed: 69)
        let next = snapshot(sessionUsed: 71)
        let shouldSync = QuotaSyncThrottle.shouldSync(
            previous: previous,
            next: next,
            lastSyncedAt: now.addingTimeInterval(-10),
            now: now,
            thresholds: .default
        )
        XCTAssertTrue(shouldSync)
    }
}
