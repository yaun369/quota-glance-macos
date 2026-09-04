#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class CodexOAuthLoginServiceTests: XCTestCase {
    override func tearDown() {
        CodexOAuthURLProtocolStub.handler = nil
        super.tearDown()
    }

    // MARK: - makeAuthorizeURL

    func testMakeAuthorizeURLIncludesEveryParameterCodexCLIItselfSends() {
        let pkce = PKCESession(codeVerifier: "verifier-value", state: "state-value")

        let url = CodexOAuthLoginService.makeAuthorizeURL(
            pkce: pkce,
            redirectURI: "http://localhost:1455/auth/callback"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(query["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(query["scope"], "openid profile email offline_access api.connectors.read api.connectors.invoke")
        XCTAssertEqual(query["code_challenge"], PKCEChallenge.codeChallenge(forVerifier: "verifier-value"))
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["id_token_add_organizations"], "true")
        XCTAssertEqual(query["codex_cli_simplified_flow"], "true")
        XCTAssertEqual(query["state"], "state-value")
        XCTAssertEqual(query["originator"], "codex_cli_rs")
    }

    // MARK: - extractAuthorizationCode

    func testExtractAuthorizationCodeReturnsCodeWhenStateMatches() throws {
        let code = try CodexOAuthLoginService.extractAuthorizationCode(
            from: ["code": "auth-code-1", "state": "expected-state"],
            expectedState: "expected-state"
        )

        XCTAssertEqual(code, "auth-code-1")
    }

    func testExtractAuthorizationCodeThrowsOnStateMismatch() {
        XCTAssertThrowsError(try CodexOAuthLoginService.extractAuthorizationCode(
            from: ["code": "auth-code-1", "state": "wrong-state"],
            expectedState: "expected-state"
        )) { error in
            XCTAssertEqual(error as? CodexOAuthLoginError, .stateMismatch)
        }
    }

    func testExtractAuthorizationCodeSurfacesAuthorizationServerError() {
        XCTAssertThrowsError(try CodexOAuthLoginService.extractAuthorizationCode(
            from: ["error": "access_denied", "error_description": "user declined", "state": "expected-state"],
            expectedState: "expected-state"
        )) { error in
            XCTAssertEqual(error as? CodexOAuthLoginError, .authorizationDenied("user declined"))
        }
    }

    func testExtractAuthorizationCodeThrowsWhenCodeIsMissing() {
        XCTAssertThrowsError(try CodexOAuthLoginService.extractAuthorizationCode(
            from: ["state": "expected-state"],
            expectedState: "expected-state"
        )) { error in
            XCTAssertEqual(error as? CodexOAuthLoginError, .missingAuthorizationCode)
        }
    }

    // MARK: - accountInfo(fromIDToken:)

    func testAccountInfoExtractsAccountIDAndEmail() throws {
        let idToken = JWTPayloadTests.makeJWT(payload: [
            "email": "person@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-123"],
        ])

        let info = try CodexOAuthLoginService.accountInfo(fromIDToken: idToken)

        XCTAssertEqual(info.accountID, "acct-123")
        XCTAssertEqual(info.email, "person@example.com")
    }

    func testAccountInfoThrowsWhenAccountIDClaimIsMissing() {
        let idToken = JWTPayloadTests.makeJWT(payload: ["email": "person@example.com"])

        XCTAssertThrowsError(try CodexOAuthLoginService.accountInfo(fromIDToken: idToken)) { error in
            XCTAssertEqual(error as? CodexOAuthLoginError, .missingAccountID)
        }
    }

    // MARK: - login(openBrowser:)

    func testLoginReportsAuthorizationCodeBeforeStartingTokenExchange() async throws {
        let callbackReported = CodexCallbackFlag()
        let idToken = JWTPayloadTests.makeJWT(payload: [
            "email": "person@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-123"],
        ])
        CodexOAuthURLProtocolStub.handler = { request in
            XCTAssertTrue(callbackReported.value)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data("""
            { "id_token": "\(idToken)", "access_token": "access-1", "refresh_token": "refresh-1" }
            """.utf8))
        }

        let credential = try await makeService().login(
            openBrowser: { authorizeURL in Self.sendSuccessfulCallback(for: authorizeURL) },
            onAuthorizationCodeReceived: { callbackReported.set() },
            callbackTimeout: 5
        )

        XCTAssertEqual(credential.accountID, "acct-123")
    }

    // MARK: - refresh(refreshToken:)

    func testRefreshSendsJSONRequestAndMapsSuccessfulResponse() async throws {
        let accessToken = JWTPayloadTests.makeJWT(payload: ["exp": 1_780_000_000])
        CodexOAuthURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url, CodexOAuthLoginService.tokenEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let body = Data("""
            { "access_token": "\(accessToken)", "refresh_token": "new-refresh" }
            """.utf8)
            return (response, body)
        }

        let service = makeService()
        let result = try await service.refresh(refreshToken: "old-refresh")

        XCTAssertEqual(result.accessToken, accessToken)
        XCTAssertEqual(result.refreshToken, "new-refresh")
        XCTAssertEqual(result.expiresAt, Date(timeIntervalSince1970: 1_780_000_000))
    }

    func testRefreshRequestBodyContainsClientIdGrantTypeAndRefreshToken() async throws {
        var capturedBody: [String: String]?
        CodexOAuthURLProtocolStub.handler = { request in
            if let bodyData = request.httpBody ?? Self.readBodyStream(request) {
                capturedBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data("{\"access_token\":\"a\",\"refresh_token\":\"b\"}".utf8))
        }

        _ = try? await makeService().refresh(refreshToken: "old-refresh")

        XCTAssertEqual(capturedBody?["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(capturedBody?["grant_type"], "refresh_token")
        XCTAssertEqual(capturedBody?["refresh_token"], "old-refresh")
    }

    func testRefreshMapsUnauthorizedToInvalidGrant() async {
        CodexOAuthURLProtocolStub.handler = { request in
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
        CodexOAuthURLProtocolStub.handler = { request in
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

    func testRefreshKeepsOldRefreshTokenAbsentAsNilWhenServerOmitsIt() async throws {
        CodexOAuthURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data("{\"access_token\":\"new-access\"}".utf8))
        }

        let result = try await makeService().refresh(refreshToken: "old-refresh")

        XCTAssertEqual(result.accessToken, "new-access")
        XCTAssertNil(result.refreshToken)
    }

    // MARK: - Helpers

    private func makeService() -> CodexOAuthLoginService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexOAuthURLProtocolStub.self]
        return CodexOAuthLoginService(session: URLSession(configuration: configuration))
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

private final class CodexCallbackFlag: @unchecked Sendable {
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

private final class CodexOAuthURLProtocolStub: URLProtocol, @unchecked Sendable {
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
