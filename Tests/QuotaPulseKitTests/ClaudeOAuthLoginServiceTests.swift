#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class ClaudeOAuthLoginServiceTests: XCTestCase {
    override func tearDown() {
        ClaudeLoginURLProtocolStub.handler = nil
        super.tearDown()
    }

    // MARK: - makeAuthorizeURL

    func testMakeAuthorizeURLIncludesEveryParameterTheRealCLISends() {
        let pkce = PKCESession(codeVerifier: "verifier-value", state: "state-value")

        let url = ClaudeOAuthLoginService.makeAuthorizeURL(
            pkce: pkce,
            redirectURI: "http://localhost:54545/callback"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "claude.ai")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(query["code"], "true")
        XCTAssertEqual(query["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["redirect_uri"], "http://localhost:54545/callback")
        // `URLComponents` keeps `+` literal, so fold it back to spaces
        // before comparing. The literal pins the CLI's exact default scope
        // list — the authorize server rejects unregistered combinations.
        XCTAssertEqual(
            query["scope"]?.replacingOccurrences(of: "+", with: " "),
            "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
        )
        XCTAssertEqual(query["code_challenge"], PKCEChallenge.codeChallenge(forVerifier: "verifier-value"))
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "state-value")
    }

    /// The authorize endpoint rejects the request as "Invalid request
    /// format" when `redirect_uri` keeps bare `:` and `/`, or when spaces
    /// are `%20` instead of `+` — exactly what `URLComponents.queryItems`
    /// produces. Pin the raw query string so a refactor back to
    /// `URLComponents` fails loudly here instead of in the browser.
    func testMakeAuthorizeURLFullyPercentEncodesTheRawQuery() {
        let pkce = PKCESession(codeVerifier: "verifier-value", state: "state-value")

        let url = ClaudeOAuthLoginService.makeAuthorizeURL(
            pkce: pkce,
            redirectURI: "http://localhost:54545/callback"
        )
        let rawQuery = url.absoluteString.split(separator: "?", maxSplits: 1)[1]

        XCTAssertTrue(rawQuery.contains("redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback"))
        XCTAssertTrue(rawQuery.contains(
            "scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference+user%3Asessions%3Aclaude_code"
                + "+user%3Amcp_servers+user%3Afile_upload"
        ))
        XCTAssertFalse(rawQuery.contains("%20"))
    }

    // MARK: - extractAuthorizationCode

    func testExtractAuthorizationCodeReturnsCodeWhenStateMatches() throws {
        let code = try ClaudeOAuthLoginService.extractAuthorizationCode(
            from: ["code": "auth-code-1", "state": "expected-state"],
            expectedState: "expected-state"
        )

        XCTAssertEqual(code, "auth-code-1")
    }

    func testExtractAuthorizationCodeThrowsOnStateMismatch() {
        XCTAssertThrowsError(try ClaudeOAuthLoginService.extractAuthorizationCode(
            from: ["code": "auth-code-1", "state": "wrong-state"],
            expectedState: "expected-state"
        )) { error in
            XCTAssertEqual(error as? ClaudeOAuthLoginError, .stateMismatch)
        }
    }

    func testExtractAuthorizationCodeSurfacesAuthorizationServerError() {
        XCTAssertThrowsError(try ClaudeOAuthLoginService.extractAuthorizationCode(
            from: ["error": "access_denied", "error_description": "user declined", "state": "expected-state"],
            expectedState: "expected-state"
        )) { error in
            XCTAssertEqual(error as? ClaudeOAuthLoginError, .authorizationDenied("user declined"))
        }
    }

    // MARK: - loginViaLoopback(openBrowser:)

    func testLoginReportsAuthorizationCodeBeforeStartingTokenExchange() async throws {
        let callbackReported = ClaudeCallbackFlag()
        ClaudeLoginURLProtocolStub.handler = { request in
            XCTAssertTrue(callbackReported.value)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data("""
            {
              "access_token": "access-1", "refresh_token": "refresh-1", "expires_in": 3600,
              "account": { "uuid": "acct-uuid-1", "email_address": "person@example.com" }
            }
            """.utf8))
        }

        let credential = try await makeService().loginViaLoopback(
            openBrowser: { authorizeURL in Self.sendSuccessfulCallback(for: authorizeURL) },
            onAuthorizationCodeReceived: { callbackReported.set() },
            callbackTimeout: 5
        )

        XCTAssertEqual(credential.accountID, "acct-uuid-1")
    }

    // MARK: - exchangeCode

    func testExchangeCodeSendsJSONBodyAndMapsCredential() async throws {
        ClaudeLoginURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url, ClaudeOAuthLoginService.tokenEndpoint)
            let body = try XCTUnwrap(request.httpBody ?? Self.readBodyStream(request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
            XCTAssertEqual(json?["code"], "auth-code-1")
            XCTAssertEqual(json?["grant_type"], "authorization_code")
            XCTAssertEqual(json?["redirect_uri"], "http://localhost:54545/callback")
            XCTAssertEqual(json?["code_verifier"], "verifier-value")
            XCTAssertEqual(json?["state"], "state-value")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            // Verbatim the shape `formatTokens` reads in the Claude Code
            // v2.1.218 binary — the identity lives under `account`, and there
            // is no top-level `email` key.
            let data = Data("""
            {
              "access_token": "access-1",
              "refresh_token": "refresh-1",
              "expires_in": 3600,
              "scope": "user:profile user:inference",
              "account": { "uuid": "acct-uuid-1", "email_address": "person@example.com" },
              "organization": { "uuid": "org-uuid-1" }
            }
            """.utf8)
            return (response, data)
        }

        let credential = try await makeService().exchangeCode(
            code: "auth-code-1",
            codeVerifier: "verifier-value",
            redirectURI: "http://localhost:54545/callback",
            state: "state-value"
        )

        XCTAssertEqual(credential.accessToken, "access-1")
        XCTAssertEqual(credential.refreshToken, "refresh-1")
        XCTAssertEqual(credential.accountLabel, "person@example.com")
        XCTAssertEqual(credential.accountID, "acct-uuid-1")
        XCTAssertEqual(credential.scopes, ["user:profile", "user:inference"])
    }

    /// Regression guard for the bug that made a completed login still read
    /// "账号未连接": the label must come from `account.email_address`, so a
    /// response carrying only the pre-fix top-level `email` must NOT produce
    /// a label.
    func testExchangeCodeIgnoresTopLevelEmailKey() async throws {
        ClaudeLoginURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let data = Data("""
            { "access_token": "access-1", "refresh_token": "refresh-1", "expires_in": 3600, "email": "person@example.com" }
            """.utf8)
            return (response, data)
        }

        let credential = try await makeService().exchangeCode(
            code: "auth-code-1",
            codeVerifier: "verifier-value",
            redirectURI: "http://localhost:54545/callback",
            state: "state-value"
        )

        XCTAssertNil(credential.accountLabel)
    }

    /// The account uuid stands in when the response has an account object
    /// with no email, rather than leaving the UI showing "not connected".
    func testExchangeCodeFallsBackToAccountUUIDWhenEmailMissing() async throws {
        ClaudeLoginURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let data = Data("""
            { "access_token": "a", "refresh_token": "r", "expires_in": 3600,
              "account": { "uuid": "acct-uuid-1" } }
            """.utf8)
            return (response, data)
        }

        let credential = try await makeService().exchangeCode(
            code: "auth-code-1",
            codeVerifier: "verifier-value",
            redirectURI: "http://localhost:54545/callback",
            state: "state-value"
        )

        XCTAssertEqual(credential.accountLabel, "acct-uuid-1")
    }

    func testExchangeCodeMapsNon200ToTokenExchangeFailed() async {
        ClaudeLoginURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 400,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data("{\"error\":\"invalid_grant\"}".utf8))
        }

        do {
            _ = try await makeService().exchangeCode(
                code: "auth-code-1",
                codeVerifier: "verifier-value",
                redirectURI: "http://localhost:54545/callback",
                state: "state-value"
            )
            XCTFail("expected tokenExchangeFailed")
        } catch ClaudeOAuthLoginError.tokenExchangeFailed(let message) {
            XCTAssertEqual(message, "invalid_grant")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - refresh(refreshToken:)

    func testRefreshSendsJSONRequestAndMapsSuccessfulResponse() async throws {
        ClaudeLoginURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url, ClaudeOAuthLoginService.tokenEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let data = Data("""
            { "access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 1800 }
            """.utf8)
            return (response, data)
        }

        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let service = makeService(now: now)
        let result = try await service.refresh(refreshToken: "old-refresh")

        XCTAssertEqual(result.accessToken, "new-access")
        XCTAssertEqual(result.refreshToken, "new-refresh")
        XCTAssertEqual(result.expiresAt, now.addingTimeInterval(1_800))
    }

    func testRefreshRequestBodyContainsGrantTypeRefreshTokenAndClientId() async throws {
        var capturedBody: [String: String]?
        ClaudeLoginURLProtocolStub.handler = { request in
            if let bodyData = request.httpBody ?? Self.readBodyStream(request) {
                capturedBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data("{\"access_token\":\"a\",\"expires_in\":60}".utf8))
        }

        _ = try? await makeService().refresh(refreshToken: "old-refresh")

        XCTAssertEqual(capturedBody?["grant_type"], "refresh_token")
        XCTAssertEqual(capturedBody?["refresh_token"], "old-refresh")
        XCTAssertEqual(capturedBody?["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        // Refresh carries the binary's `ntt` set, which is the authorize
        // scope minus `org:create_api_key` — not the same string.
        XCTAssertEqual(
            capturedBody?["scope"],
            "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
        )
        XCTAssertNotEqual(capturedBody?["scope"], ClaudeOAuthLoginService.scope)
    }

    func testRefreshMapsUnauthorizedToInvalidGrant() async {
        ClaudeLoginURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data("{\"error\":\"invalid_grant\"}".utf8))
        }

        do {
            _ = try await makeService().refresh(refreshToken: "old-refresh")
            XCTFail("expected invalidGrant")
        } catch OAuthTokenRefreshError.invalidGrant(let message) {
            XCTAssertEqual(message, "invalid_grant")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRefreshMapsServerErrorStatusToServerCase() async {
        ClaudeLoginURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await makeService().refresh(refreshToken: "old-refresh")
            XCTFail("expected server error")
        } catch OAuthTokenRefreshError.server(let statusCode, _) {
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRefreshKeepsRefreshTokenNilWhenServerOmitsIt() async throws {
        ClaudeLoginURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data("{\"access_token\":\"new-access\",\"expires_in\":60}".utf8))
        }

        let result = try await makeService().refresh(refreshToken: "old-refresh")

        XCTAssertEqual(result.accessToken, "new-access")
        XCTAssertNil(result.refreshToken)
    }

    // MARK: - Helpers

    private func makeService(now: Date = Date(timeIntervalSince1970: 1_780_000_000)) -> ClaudeOAuthLoginService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeLoginURLProtocolStub.self]
        return ClaudeOAuthLoginService(session: URLSession(configuration: configuration), now: { now })
    }

    private static func readBodyStream(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func sendSuccessfulCallback(for authorizeURL: URL) {
        let authorize = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (authorize?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard var callback = URLComponents(string: query["redirect_uri"] ?? "") else { return }
        callback.queryItems = [
            URLQueryItem(name: "code", value: "auth-code-1"),
            URLQueryItem(name: "state", value: query["state"]),
        ]
        guard let callbackURL = callback.url else { return }
        Task { _ = try? await URLSession.shared.data(from: callbackURL) }
    }
}

private final class ClaudeCallbackFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private final class ClaudeLoginURLProtocolStub: URLProtocol, @unchecked Sendable {
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
