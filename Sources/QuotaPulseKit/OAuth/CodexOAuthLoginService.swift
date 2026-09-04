import Foundation

/// The ChatGPT account identity extracted from an id_token, surfaced to the
/// login UI ("已连接：<email>") independently of the `OAuthCredential`
/// that gets persisted.
public struct CodexAccountInfo: Sendable, Equatable {
    public let accountID: String
    public let email: String?
}

public enum CodexOAuthLoginError: LocalizedError, Sendable, Equatable {
    case portUnavailable
    case cancelled
    case timedOut
    case stateMismatch
    case authorizationDenied(String?)
    case missingAuthorizationCode
    case tokenExchangeFailed(String)
    case missingAccountID
    case network(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .portUnavailable:
            return QuotaL10n.string(
                "login.portsBusy.codex",
                "Ports 1455 and 1457 are both in use. Close whatever is using them — another QuotaGlance instance or codex login — and try again."
            )
        case .cancelled:
            return QuotaL10n.string("login.cancelled", "Sign-in cancelled.")
        case .timedOut:
            return QuotaL10n.string("login.timedOut", "Timed out waiting for sign-in authorization. Please try again.")
        case .stateMismatch:
            return QuotaL10n.string("login.stateMismatch", "The sign-in callback failed validation. Please start the sign-in again.")
        case .authorizationDenied(let description):
            return description.map { QuotaL10n.string("login.denied.reason", "Sign-in denied: \($0)") }
                ?? QuotaL10n.string("login.denied", "Sign-in denied.")
        case .missingAuthorizationCode:
            return QuotaL10n.string("login.missingCode", "The sign-in callback is missing its authorization code. Please try again.")
        case .tokenExchangeFailed(let reason):
            return QuotaL10n.string("login.exchangeFailed", "Sign-in failed: \(reason)")
        case .missingAccountID:
            return QuotaL10n.string("login.missingAccount", "The sign-in response has incomplete account details. Please try again.")
        case .network(let reason):
            return QuotaL10n.string("login.transportFailed", "The sign-in request failed: \(reason)")
        case .invalidResponse(let reason):
            return QuotaL10n.string("login.invalidResponse", "The sign-in response was invalid: \(reason)")
        }
    }
}

/// Logs a user into their ChatGPT account using the same authorization-code
/// + PKCE flow, client id, and token endpoint as the real `codex` CLI (see
/// `codex-rs/login/src/server.rs` and `codex-rs/login/src/auth/manager.rs`)
/// — verified against that source rather than assumed, since the exact
/// query parameters, request bodies, and content types differ enough
/// between the code-exchange and refresh calls that guessing would silently
/// fail against the real server.
public struct CodexOAuthLoginService: Sendable {
    public static let issuer = "https://auth.openai.com"
    public static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    public static let authorizeEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let primaryPort: UInt16 = 1455
    public static let fallbackPort: UInt16 = 1457
    public static let callbackPath = "/auth/callback"
    /// Matches `build_authorize_url` in codex-rs exactly, including the two
    /// `api.connectors.*` scopes that are easy to assume away as unrelated
    /// to usage reading but are part of every real codex CLI authorize
    /// request.
    public static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    /// Not a secret — a self-reported client identifier codex's backend
    /// logs for analytics. Reusing the CLI's own value rather than
    /// inventing a new one maximizes the odds it's already an accepted
    /// value server-side.
    public static let originator = "codex_cli_rs"

    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session ?? Self.makeEphemeralSession()
        self.now = now
    }

    /// Runs the full interactive flow: binds a loopback server (1455, or
    /// 1457 if that's taken — the same fallback codex itself uses), opens
    /// the authorize page via `openBrowser`, waits for the redirect, and
    /// exchanges the resulting code for tokens.
    public func login(
        openBrowser: @Sendable (URL) -> Void,
        onAuthorizationCodeReceived: @Sendable () async -> Void = {},
        callbackTimeout: TimeInterval = 300
    ) async throws -> OAuthCredential {
        let pkce = PKCESession()
        let (server, port) = try await Self.startServer()
        defer { server.cancel() }

        let redirectURI = "http://localhost:\(port)\(Self.callbackPath)"
        openBrowser(Self.makeAuthorizeURL(pkce: pkce, redirectURI: redirectURI))

        let query: [String: String]
        do {
            query = try await server.waitForCallback(timeout: callbackTimeout)
        } catch LoopbackCallbackServerError.timedOut {
            throw CodexOAuthLoginError.timedOut
        } catch LoopbackCallbackServerError.cancelled {
            throw CodexOAuthLoginError.cancelled
        } catch {
            throw CodexOAuthLoginError.network(error.localizedDescription)
        }

        let code = try Self.extractAuthorizationCode(from: query, expectedState: pkce.state)
        await onAuthorizationCodeReceived()
        let tokens = try await exchangeCode(code: code, codeVerifier: pkce.codeVerifier, redirectURI: redirectURI)
        return try Self.credential(from: tokens, now: now())
    }

    /// The `performRefresh` closure `OAuthTokenRefresher` expects.
    public func refresh(refreshToken: String) async throws -> OAuthRefreshResult {
        var request = URLRequest(
            url: Self.tokenEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        // Deliberately JSON here, unlike the form-urlencoded code exchange
        // below — codex's refresh endpoint only accepts the former.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RefreshRequestBody(
            clientId: Self.clientID,
            grantType: "refresh_token",
            refreshToken: refreshToken
        ))

        let (data, response) = try await Self.perform(request, session: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthTokenRefreshError.invalidResponse(QuotaL10n.string("reason.missingHTTPResponse", "no HTTP response"))
        }

        switch httpResponse.statusCode {
        case 200:
            let decoded: RefreshResponseBody
            do {
                decoded = try JSONDecoder().decode(RefreshResponseBody.self, from: data)
            } catch {
                throw OAuthTokenRefreshError.invalidResponse(error.localizedDescription)
            }
            guard let accessToken = decoded.accessToken else {
                throw OAuthTokenRefreshError.invalidResponse(QuotaL10n.string("reason.missingAccessToken", "the response has no access_token"))
            }
            let expiresAt = try? JWTPayload.expirationDate(fromAccessToken: accessToken)
            let accountID = decoded.idToken.flatMap { try? Self.accountInfo(fromIDToken: $0).accountID }
            return OAuthRefreshResult(
                accessToken: accessToken,
                refreshToken: decoded.refreshToken,
                expiresAt: expiresAt,
                scopes: nil,
                accountID: accountID
            )
        case 401, 400:
            throw OAuthTokenRefreshError.invalidGrant(Self.errorMessage(from: data))
        default:
            throw OAuthTokenRefreshError.server(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }
    }

    // MARK: - Steps

    private static func startServer() async throws -> (LoopbackCallbackServer, UInt16) {
        let primary = LoopbackCallbackServer(port: primaryPort, callbackPath: callbackPath)
        do {
            return (primary, try await primary.start())
        } catch LoopbackCallbackServerError.portUnavailable {
            let fallback = LoopbackCallbackServer(port: fallbackPort, callbackPath: callbackPath)
            do {
                return (fallback, try await fallback.start())
            } catch {
                throw CodexOAuthLoginError.portUnavailable
            }
        }
    }

    static func makeAuthorizeURL(pkce: PKCESession, redirectURI: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "originator", value: originator),
        ]
        // Guaranteed non-nil: every query value above is either a fixed
        // literal or base64url output, none of which URLComponents can fail
        // to encode.
        return components.url!
    }

    static func extractAuthorizationCode(
        from query: [String: String],
        expectedState: String
    ) throws -> String {
        guard query["state"] == expectedState else {
            throw CodexOAuthLoginError.stateMismatch
        }
        if let error = query["error"], !error.isEmpty {
            throw CodexOAuthLoginError.authorizationDenied(query["error_description"])
        }
        guard let code = query["code"], !code.isEmpty else {
            throw CodexOAuthLoginError.missingAuthorizationCode
        }
        return code
    }

    private func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> TokenExchangeResponse {
        var request = URLRequest(
            url: Self.tokenEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=authorization_code",
            "code=\(Self.formEncode(code))",
            "redirect_uri=\(Self.formEncode(redirectURI))",
            "client_id=\(Self.formEncode(Self.clientID))",
            "code_verifier=\(Self.formEncode(codeVerifier))",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await Self.perform(request, session: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexOAuthLoginError.invalidResponse(QuotaL10n.string("reason.missingHTTPResponse", "no HTTP response"))
        }
        guard httpResponse.statusCode == 200 else {
            let message = Self.errorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw CodexOAuthLoginError.tokenExchangeFailed(message)
        }
        do {
            return try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
        } catch {
            throw CodexOAuthLoginError.invalidResponse(error.localizedDescription)
        }
    }

    static func accountInfo(fromIDToken idToken: String) throws -> CodexAccountInfo {
        let payload = try JWTPayload.decode(idToken)
        guard let accountID = payload["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue,
              !accountID.isEmpty else {
            throw CodexOAuthLoginError.missingAccountID
        }
        return CodexAccountInfo(accountID: accountID, email: payload["email"]?.stringValue)
    }

    private static func credential(from tokens: TokenExchangeResponse, now: Date) throws -> OAuthCredential {
        let account = try accountInfo(fromIDToken: tokens.idToken)
        let expiresAt = try? JWTPayload.expirationDate(fromAccessToken: tokens.accessToken)
        return OAuthCredential(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: expiresAt,
            scopes: scope.split(separator: " ").map(String.init),
            accountLabel: account.email ?? account.accountID,
            accountID: account.accountID,
            obtainedAt: now
        )
    }

    // MARK: - HTTP plumbing

    private static func perform(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw CodexOAuthLoginError.network(error.localizedDescription)
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(TokenErrorEnvelope.self, from: data) else {
            return nil
        }
        let message = envelope.errorDescription ?? envelope.error
        guard let message, !message.isEmpty else { return nil }
        return message.count > 240 ? String(message.prefix(240)) + "…" : message
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: CodexOAuthRedirectBlocker(),
            delegateQueue: nil
        )
    }

    private struct TokenExchangeResponse: Decodable {
        let idToken: String
        let accessToken: String
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private struct RefreshRequestBody: Encodable {
        let clientId: String
        let grantType: String
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
        }
    }

    private struct RefreshResponseBody: Decodable {
        let idToken: String?
        let accessToken: String?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private struct TokenErrorEnvelope: Decodable {
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}

/// The token endpoint is fixed, so refusing redirects avoids ever
/// forwarding a client credential or authorization code across an
/// unexpected redirect boundary — same rationale as
/// `ClaudeOAuthRedirectBlocker`.
private final class CodexOAuthRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
