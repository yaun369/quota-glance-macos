#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class CodexUsageClientTests: XCTestCase {
    override func tearDown() {
        CodexUsageURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testFetchUsesExpectedEndpointHeadersAndMapsUsage() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        CodexUsageURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let data = Data("""
            {
              "plan_type": "plus",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": { "used_percent": 37, "limit_window_seconds": 18000, "reset_after_seconds": 2532613, "reset_at": \(now.timeIntervalSince1970 + 2_532_613) },
                "secondary_window": { "used_percent": 12, "limit_window_seconds": 604800, "reset_after_seconds": 86400, "reset_at": \(now.timeIntervalSince1970 + 86_400) }
              },
              "credits": { "has_credits": false, "unlimited": false, "balance": null }
            }
            """.utf8)
            return (response, data)
        }

        let client = makeClient(now: now)
        let snapshot = try await client.fetchSnapshot(accessToken: "secret-test-token", accountID: "acct-123")

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.session.usedPercent, 37)
        XCTAssertEqual(snapshot.weekly.usedPercent, 12)
        XCTAssertEqual(snapshot.capturedAt, now)
        XCTAssertNotNil(snapshot.session.resetAt)
        XCTAssertNotNil(snapshot.weekly.resetAt)
    }

    func testUnknownWindowDurationFallsBackToPrimarySecondaryPosition() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = try makeClient(now: now).decodeSnapshot(Data("""
        {
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": { "used_percent": 15, "limit_window_seconds": 999, "reset_after_seconds": 10, "reset_at": \(now.timeIntervalSince1970 + 10_000) },
            "secondary_window": { "used_percent": 55, "limit_window_seconds": 888, "reset_after_seconds": 10, "reset_at": \(now.timeIntervalSince1970 + 20_000) }
          }
        }
        """.utf8))

        XCTAssertEqual(snapshot.session.usedPercent, 15)
        XCTAssertEqual(snapshot.weekly.usedPercent, 55)
    }

    func testNullSecondaryWindowDoesNotOverwriteParsedPrimary() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = try makeClient(now: now).decodeSnapshot(Data("""
        {
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": { "used_percent": 40, "limit_window_seconds": 18000, "reset_after_seconds": 10, "reset_at": \(now.timeIntervalSince1970 + 10_000) },
            "secondary_window": null
          }
        }
        """.utf8))

        XCTAssertEqual(snapshot.session.usedPercent, 40)
        XCTAssertNil(snapshot.weekly.usedPercent)
    }

    func testRejectsOutOfRangeUsedPercent() {
        let client = makeClient(now: Date())
        XCTAssertThrowsError(try client.decodeSnapshot(Data("""
        { "rate_limit": { "allowed": true, "limit_reached": false, "primary_window": { "used_percent": 150, "limit_window_seconds": 18000, "reset_after_seconds": 10, "reset_at": 9999999999 } } }
        """.utf8))) { error in
            guard case CodexUsageError.invalidResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMissingBothWindowsThrowsInvalidResponse() {
        let client = makeClient(now: Date())
        XCTAssertThrowsError(try client.decodeSnapshot(Data("""
        { "rate_limit": { "allowed": true, "limit_reached": false } }
        """.utf8))) { error in
            guard case CodexUsageError.invalidResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testExpiredWindowIsDroppedRatherThanShownAsFresh() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = try makeClient(now: now).decodeSnapshot(Data("""
        {
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": { "used_percent": 60, "limit_window_seconds": 18000, "reset_after_seconds": 10, "reset_at": \(now.timeIntervalSince1970 - 100) },
            "secondary_window": { "used_percent": 20, "limit_window_seconds": 604800, "reset_after_seconds": 10, "reset_at": \(now.timeIntervalSince1970 + 100_000) }
          }
        }
        """.utf8))

        XCTAssertNil(snapshot.session.usedPercent)
        XCTAssertEqual(snapshot.weekly.usedPercent, 20)
    }

    func testUnauthorizedThrows() async {
        CodexUsageURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await makeClient(now: Date()).fetchSnapshot(accessToken: "token", accountID: "acct-123")
            XCTFail("expected unauthorized")
        } catch CodexUsageError.unauthorized {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRateLimitIncludesRetryAfter() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        CodexUsageURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "42"]
            )!
            return (response, Data())
        }

        do {
            _ = try await makeClient(now: now).fetchSnapshot(accessToken: "token", accountID: "acct-123")
            XCTFail("expected rate limit")
        } catch CodexUsageError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, now.addingTimeInterval(42))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testServerFailureIncludesRetryAfter() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        CodexUsageURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "30"]
            )!
            return (response, Data("{\"error\":{\"message\":\"busy\"}}".utf8))
        }

        do {
            _ = try await makeClient(now: now).fetchSnapshot(accessToken: "token", accountID: "acct-123")
            XCTFail("expected server failure")
        } catch CodexUsageError.server(let statusCode, let message, let retryAfter) {
            XCTAssertEqual(statusCode, 503)
            XCTAssertEqual(message, "busy")
            XCTAssertEqual(retryAfter, now.addingTimeInterval(30))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeClient(now: Date) -> CodexUsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexUsageURLProtocolStub.self]
        return CodexUsageClient(
            session: URLSession(configuration: configuration),
            now: { now }
        )
    }
}

private final class CodexUsageURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
#endif
