#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class LoopbackCallbackServerTests: XCTestCase {
    /// Some sandboxed/firewalled environments (observed in this project's CI)
    /// let `NWListener` bind an ephemeral port but reject every explicit,
    /// non-zero port with `EINVAL` — a machine-level network policy, not a
    /// bug in this class (a raw BSD `bind()` to the same port succeeds
    /// there). Probed once and reused so the two fixed-port tests skip
    /// cleanly instead of failing on such machines, while every other test
    /// here — which only needs an ephemeral port — still runs everywhere.
    private static let canBindFixedPort = Task<Bool, Never> {
        let probePort: UInt16 = 39_599
        let server = LoopbackCallbackServer(port: probePort)
        defer { server.cancel() }
        return (try? await server.start()) != nil
    }

    func testDeliversQueryItemsFromTheRedirectRequest() async throws {
        let server = LoopbackCallbackServer(port: nil, callbackPath: "/callback")
        defer { server.cancel() }
        let port = try await server.start()

        async let callback = server.waitForCallback(timeout: 5)
        let response = try await Self.get(
            "http://127.0.0.1:\(port)/callback?code=auth-code-1&state=state-1"
        )

        let query = try await callback
        XCTAssertEqual(query["code"], "auth-code-1")
        XCTAssertEqual(query["state"], "state-1")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.body.contains("登录成功"))
    }

    func testStartOnAFixedPortBindsExactlyThatPort() async throws {
        let canBind = await Self.canBindFixedPort.value
        try XCTSkipUnless(canBind, "This environment does not allow NWListener to bind an explicit port.")
        let fixedPort: UInt16 = 39_213
        let server = LoopbackCallbackServer(port: fixedPort)
        defer { server.cancel() }

        let boundPort = try await server.start()

        XCTAssertEqual(boundPort, fixedPort)
    }

    func testStartOnAPortAlreadyInUseThrowsPortUnavailable() async throws {
        let canBind = await Self.canBindFixedPort.value
        try XCTSkipUnless(canBind, "This environment does not allow NWListener to bind an explicit port.")
        let fixedPort: UInt16 = 39_214
        let serverA = LoopbackCallbackServer(port: fixedPort)
        defer { serverA.cancel() }
        _ = try await serverA.start()

        let serverB = LoopbackCallbackServer(port: fixedPort)
        defer { serverB.cancel() }
        do {
            _ = try await serverB.start()
            XCTFail("expected portUnavailable")
        } catch LoopbackCallbackServerError.portUnavailable(let port) {
            XCTAssertEqual(port, fixedPort)
        }
    }

    func testWaitForCallbackTimesOutWhenNoRequestArrives() async throws {
        let server = LoopbackCallbackServer(port: nil)
        defer { server.cancel() }
        _ = try await server.start()

        do {
            _ = try await server.waitForCallback(timeout: 0.2)
            XCTFail("expected a timeout")
        } catch LoopbackCallbackServerError.timedOut {
            // expected
        }
    }

    func testWaitForCallbackBeforeStartThrowsNotStarted() async throws {
        let server = LoopbackCallbackServer(port: nil)
        defer { server.cancel() }

        do {
            _ = try await server.waitForCallback(timeout: 1)
            XCTFail("expected notStarted")
        } catch LoopbackCallbackServerError.notStarted {
            // expected
        }
    }

    func testCancelStopsAPendingWait() async throws {
        let server = LoopbackCallbackServer(port: nil)
        defer { server.cancel() }
        _ = try await server.start()

        async let callback = server.waitForCallback(timeout: 5)
        // Give waitForCallback's continuation a moment to actually register
        // before cancelling, so this exercises the "cancel while waiting"
        // path rather than "cancel before waiting".
        try await Task.sleep(nanoseconds: 20_000_000)
        server.cancel()

        do {
            _ = try await callback
            XCTFail("expected cancellation")
        } catch LoopbackCallbackServerError.cancelled {
            // expected
        }
    }

    func testCancellingTheCallingTaskStopsAPendingWaitWithoutCallingCancelDirectly() async throws {
        let server = LoopbackCallbackServer(port: nil)
        defer { server.cancel() }
        _ = try await server.start()

        let waiter = Task {
            try await server.waitForCallback(timeout: 5)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("expected cancellation")
        } catch LoopbackCallbackServerError.cancelled {
            // expected
        }
    }

    func testCancellingTheCallingTaskBeforeItStartsWaitingStillCompletesWithCancelled() async throws {
        let server = LoopbackCallbackServer(port: nil)
        defer { server.cancel() }
        _ = try await server.start()

        let waiter = Task {
            try await server.waitForCallback(timeout: 5)
        }
        // No sleep: the cancellation can land before `waitForCallback` has
        // even registered its continuation, exercising the `pendingResult`
        // buffering path rather than the "already waiting" path above.
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("expected cancellation")
        } catch LoopbackCallbackServerError.cancelled {
            // expected
        }
    }

    func testRequestToAnUnrelatedPathDoesNotCompleteTheWaitAndTheRealCallbackStillArrives() async throws {
        let server = LoopbackCallbackServer(port: nil, callbackPath: "/callback")
        defer { server.cancel() }
        let port = try await server.start()

        async let callback = server.waitForCallback(timeout: 5)

        let probe = try await Self.get("http://127.0.0.1:\(port)/favicon.ico")
        XCTAssertEqual(probe.statusCode, 404)

        let real = try await Self.get("http://127.0.0.1:\(port)/callback?code=auth-code-2&state=state-2")
        XCTAssertEqual(real.statusCode, 200)

        let query = try await callback
        XCTAssertEqual(query["code"], "auth-code-2")
    }

    func testResultThatArrivesBeforeWaitForCallbackIsCalledIsBuffered() async throws {
        let server = LoopbackCallbackServer(port: nil, callbackPath: "/callback")
        defer { server.cancel() }
        let port = try await server.start()

        _ = try await Self.get("http://127.0.0.1:\(port)/callback?code=auth-code-3&state=state-3")

        let query = try await server.waitForCallback(timeout: 5)
        XCTAssertEqual(query["code"], "auth-code-3")
    }

    // MARK: - Helpers

    private struct HTTPResponseSummary {
        let statusCode: Int
        let body: String
    }

    /// A dedicated, non-persistent session rather than `.shared`: these
    /// tests make several short-lived requests to a series of one-shot
    /// servers on different ports within a single test run, and the shared
    /// session's connection cache has no reason to know any of them are
    /// gone the instant each server finishes.
    private static func get(_ urlString: String) async throws -> HTTPResponseSummary {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(from: URL(string: urlString)!)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        return HTTPResponseSummary(
            statusCode: httpResponse.statusCode,
            body: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
#endif
