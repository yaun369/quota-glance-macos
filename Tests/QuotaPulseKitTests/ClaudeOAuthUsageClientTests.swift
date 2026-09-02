#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class ClaudeOAuthUsageClientTests: XCTestCase {
    override func tearDown() {
        OAuthURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testFetchUsesExpectedEndpointHeadersAndMapsUsage() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        OAuthURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let data = Data("""
            {
              "five_hour": {
                "utilization": 15,
                "resets_at": "2026-07-21T06:29:59.851544+00:00"
              },
              "seven_day": {
                "utilization": 8,
                "resets_at": "2026-07-26T01:59:59Z"
              },
              "extra_usage": { "is_enabled": false },
              "unknown_future_field": true
            }
            """.utf8)
            return (response, data)
        }

        let client = makeClient(now: now)
        let snapshot = try await client.fetchSnapshot(accessToken: "secret-test-token")

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.session.usedPercent, 15)
        XCTAssertEqual(snapshot.weekly.usedPercent, 8)
        XCTAssertEqual(snapshot.capturedAt, now)
        XCTAssertNotNil(snapshot.session.resetAt)
        XCTAssertNotNil(snapshot.weekly.resetAt)
    }

    func testUsesLimitsArrayWhenTopLevelWindowsAreMissing() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let client = makeClient(now: now)
        let snapshot = try client.decodeSnapshot(Data("""
        {
          "limits": [
            {
              "kind": "session",
              "group": "session",
              "percent": 21,
              "resets_at": "2026-07-21T06:29:59Z",
              "scope": null
            },
            {
              "kind": "weekly_all",
              "group": "weekly",
              "percent": 37,
              "resets_at": "2026-07-26T01:59:59Z",
              "scope": null
            }
          ]
        }
        """.utf8))

        XCTAssertEqual(snapshot.session.usedPercent, 21)
        XCTAssertEqual(snapshot.weekly.usedPercent, 37)
    }

    func testLimitsFallbackSkipsNilScopedAndExpiredEntries() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = try makeClient(now: now).decodeSnapshot(Data("""
        {
          "five_hour": {},
          "seven_day": {},
          "limits": [
            { "kind": "session", "percent": null, "scope": null },
            {
              "kind": "session",
              "percent": 90,
              "resets_at": "2026-07-21T06:29:59Z",
              "scope": { "model": "claude-opus" }
            },
            {
              "kind": "session",
              "percent": 88,
              "resets_at": "2026-01-01T00:00:00Z",
              "scope": null
            },
            {
              "kind": "session",
              "percent": 19,
              "resets_at": "2026-07-21T06:29:59Z",
              "scope": {}
            },
            {
              "kind": "weekly_all",
              "percent": 33,
              "resets_at": "2026-07-26T01:59:59Z",
              "scope": null
            }
          ]
        }
        """.utf8))

        XCTAssertEqual(snapshot.session.usedPercent, 19)
        XCTAssertEqual(snapshot.weekly.usedPercent, 33)
    }

    func testTopLevelZeroUtilizationDoesNotFallBackToLimits() throws {
        let snapshot = try makeClient(now: Date(timeIntervalSince1970: 1_780_000_000))
            .decodeSnapshot(Data("""
            {
              "five_hour": { "utilization": 0, "resets_at": "2026-07-21T06:29:59Z" },
              "limits": [
                { "kind": "session", "percent": 77, "resets_at": "2026-07-21T06:29:59Z" }
              ]
            }
            """.utf8))

        XCTAssertEqual(snapshot.session.usedPercent, 0)
    }

    func testExpiredWindowIsNotMarkedAsFresh() throws {
        let snapshot = try makeClient(now: Date(timeIntervalSince1970: 1_780_000_000))
            .decodeSnapshot(Data("""
            {
              "five_hour": { "utilization": 60, "resets_at": "2026-01-01T00:00:00Z" },
              "seven_day": { "utilization": 20, "resets_at": "2026-12-01T00:00:00Z" }
            }
            """.utf8))

        XCTAssertNil(snapshot.session.usedPercent)
        XCTAssertEqual(snapshot.weekly.usedPercent, 20)
    }

    func testRejectsOutOfRangeUtilization() {
        let client = makeClient(now: Date())
        XCTAssertThrowsError(try client.decodeSnapshot(Data("""
        { "five_hour": { "utilization": 101, "resets_at": null } }
        """.utf8))) { error in
            guard case ClaudeOAuthUsageError.invalidResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRateLimitIncludesRetryAfter() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        OAuthURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "42"]
            )!
            return (response, Data())
        }

        do {
            _ = try await makeClient(now: now).fetchSnapshot(accessToken: "secret-test-token")
            XCTFail("expected rate limit")
        } catch ClaudeOAuthUsageError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, now.addingTimeInterval(42))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testServerFailureIncludesRetryAfter() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        OAuthURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "30"]
            )!
            return (response, Data("{\"error\":{\"message\":\"busy\"}}".utf8))
        }

        do {
            _ = try await makeClient(now: now).fetchSnapshot(accessToken: "secret-test-token")
            XCTFail("expected server failure")
        } catch ClaudeOAuthUsageError.server(let statusCode, let message, let retryAfter) {
            XCTAssertEqual(statusCode, 503)
            XCTAssertEqual(message, "busy")
            XCTAssertEqual(retryAfter, now.addingTimeInterval(30))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeClient(now: Date) -> ClaudeOAuthUsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthURLProtocolStub.self]
        return ClaudeOAuthUsageClient(
            session: URLSession(configuration: configuration),
            now: { now }
        )
    }
}

private final class OAuthURLProtocolStub: URLProtocol, @unchecked Sendable {
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
