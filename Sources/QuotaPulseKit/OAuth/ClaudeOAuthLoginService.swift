import Foundation

public enum ClaudeOAuthLoginError: LocalizedError, Sendable, Equatable {
    case portUnavailable
    case cancelled
    case timedOut
    case stateMismatch
    case authorizationDenied(String?)
    case missingAuthorizationCode
    case tokenExchangeFailed(String)
    case network(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .portUnavailable:
            return QuotaL10n.string("login.portBusy.claude", "Port 54545 is already in use. Close whatever is using it and try again.")
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
        case .network(let reason):
            return QuotaL10n.string("login.transportFailed", "The sign-in request failed: \(reason)")
        case .invalidResponse(let reason):
            return QuotaL10n.string("login.invalidResponse", "The sign-in response was invalid: \(reason)")
        }
    }
}

/// Logs a user into their Claude account using the same authorization-code
/// + PKCE flow, client id, and token endpoint as the real `claude` CLI —
/// cross-checked against three independent from-scratch reimplementations
/// (one from 2026-07-16, including a mitmproxy capture of real traffic)
/// rather than assumed, since this endpoint has moved domains and grown its
/// scope list over time and guessing would silently drift out of date.
public struct ClaudeOAuthLoginService: Sendable {
    public static let issuer = "https://claude.ai"
    public static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let loopbackPort: UInt16 = 54545
    public static let loopbackCallbackPath = "/callback"
    /// Verbatim the default scope list from `buildAuthUrl` in the Claude
    /// Code v2.1.218 binary: the console pair (`org:create_api_key
    /// user:profile`) unioned with the claude.ai set, sent unchanged to
    /// both authorize hosts. The authorize server only grants registered
    /// scope sets, never subsets — asking for `user:profile` alone (all
    /// this app actually needs) renders the consent page fine but fails
    /// the Authorize click with "Invalid request format".
    public static let scope = "org:create_api_key user:profile user:inference " +
        "user:sessions:claude_code user:mcp_servers user:file_upload"
    /// The scope list a *refresh* sends — the binary's `ntt`, which is
    /// `scope` minus `org:create_api_key`. Not interchangeable with `scope`
    /// above: authorize wants the union (`OCi = Mo([...Njm, ...ntt])`),
    /// refresh wants this one, and the token endpoint validates the field
    /// rather than ignoring it, so omitting it entirely is not safe either.
    public static let refreshScope = "user:profile user:inference " +
        "user:sessions:claude_code user:mcp_servers user:file_upload"

    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session ?? Self.makeEphemeralSession()
        self.now = now
    }

    // MARK: - Loopback flow

    /// Runs the fully-automatic flow: binds `localhost:54545`, opens the
    /// authorize page via `openBrowser`, waits for the redirect, and
    /// exchanges the resulting code. Throws `.portUnavailable` if the port
    /// can't be bound — there is no known fallback port for this client, so
    /// the user has to free the port and retry.
    public func loginViaLoopback(
        openBrowser: @Sendable (URL) -> Void,
        callbackTimeout: TimeInterval = 300
    ) async throws -> OAuthCredential {
        let pkce = PKCESession()
        let server = LoopbackCallbackServer(port: Self.loopbackPort, callbackPath: Self.loopbackCallbackPath)
        defer { server.cancel() }

        let port: UInt16
        do {
            port = try await server.start()
        } catch LoopbackCallbackServerError.portUnavailable {
            throw ClaudeOAuthLoginError.portUnavailable
        }
        let redirectURI = "http://localhost:\(port)\(Self.loopbackCallbackPath)"
        openBrowser(Self.makeAuthorizeURL(pkce: pkce, redirectURI: redirectURI))

        let query: [String: String]
        do {
            query = try await server.waitForCallback(timeout: callbackTimeout)
        } catch LoopbackCallbackServerError.timedOut {
            throw ClaudeOAuthLoginError.timedOut
        } catch LoopbackCallbackServerError.cancelled {
            throw ClaudeOAuthLoginError.cancelled
        } catch {
            throw ClaudeOAuthLoginError.network(error.localizedDescription)
        }

        let code = try Self.extractAuthorizationCode(from: query, expectedState: pkce.state)
        return try await exchangeCode(
            code: code,
            codeVerifier: pkce.codeVerifier,
            redirectURI: redirectURI,
            state: pkce.state
        )
    }

    // MARK: - Refresh

    /// The `performRefresh` closure `OAuthTokenRefresher` expects.
    public func refresh(refreshToken: String) async throws -> OAuthRefreshResult {
        var request = URLRequest(
            url: Self.tokenEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RefreshRequestBody(
            grantType: "refresh_token",
            refreshToken: refreshToken,
            clientId: Self.clientID,
            scope: Self.refreshScope
        ))

        let (data, response) = try await Self.perform(request, session: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthTokenRefreshError.invalidResponse(QuotaL10n.string("reason.missingHTTPResponse", "no HTTP response"))
        }

        switch httpResponse.statusCode {
        case 200:
            let decoded: TokenResponseBody
            do {
                decoded = try JSONDecoder().decode(TokenResponseBody.self, from: data)
            } catch {
                throw OAuthTokenRefreshError.invalidResponse(error.localizedDescription)
            }
            return OAuthRefreshResult(
                accessToken: decoded.accessToken,
                refreshToken: decoded.refreshToken,
                expiresAt: now().addingTimeInterval(decoded.expiresIn),
                scopes: Self.scopeList(from: decoded.scope),
                accountID: decoded.account?.uuid
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

    // MARK: - Shared steps

    static func makeAuthorizeURL(pkce: PKCESession, redirectURI: String) -> URL {
        // Mirrors `buildAuthUrl` in the Claude Code v2.1.218 binary: the
        // same parameters in its exact `URLSearchParams.append` order,
        // `code=true` included even for the loopback flow, and form-style
        // encoding — every reserved character percent-escaped (so
        // `redirect_uri`'s `:` and `/` become `%3A`/`%2F`) and spaces as
        // `+`, not `%20`. `URLComponents.queryItems` produces neither (it
        // leaves `:` and `/` bare and uses `%20`) and the authorize
        // endpoint answers "Invalid request format" to that, so the query
        // is assembled by hand here.
        let pairs: [(String, String)] = [
            ("code", "true"),
            ("client_id", clientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", scope),
            ("code_challenge", pkce.codeChallenge),
            ("code_challenge_method", "S256"),
            ("state", pkce.state),
        ]
        let query = pairs
            .map { "\(formURLEncode($0.0))=\(formURLEncode($0.1))" }
            .joined(separator: "&")
        // Guaranteed non-nil: the base is a fixed literal and the query is
        // fully percent-encoded above.
        return URL(string: authorizeEndpoint.absoluteString + "?" + query)!
    }

    /// Go `url.Values.Encode()`-compatible escaping: everything outside the
    /// RFC 3986 unreserved set is percent-encoded, except space → `+`.
    private static func formURLEncode(_ value: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let escaped = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
        return escaped.replacingOccurrences(of: "%20", with: "+")
    }

    static func extractAuthorizationCode(
        from query: [String: String],
        expectedState: String
    ) throws -> String {
        guard query["state"] == expectedState else {
            throw ClaudeOAuthLoginError.stateMismatch
        }
        if let error = query["error"], !error.isEmpty {
            throw ClaudeOAuthLoginError.authorizationDenied(query["error_description"])
        }
        guard let code = query["code"], !code.isEmpty else {
            throw ClaudeOAuthLoginError.missingAuthorizationCode
        }
        return code
    }

    func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        state: String
    ) async throws -> OAuthCredential {
        var request = URLRequest(
            url: Self.tokenEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(ExchangeRequestBody(
            code: code,
            state: state,
            grantType: "authorization_code",
            clientId: Self.clientID,
            redirectUri: redirectURI,
            codeVerifier: codeVerifier
        ))

        let (data, response) = try await Self.perform(request, session: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeOAuthLoginError.invalidResponse(QuotaL10n.string("reason.missingHTTPResponse", "no HTTP response"))
        }
        guard httpResponse.statusCode == 200 else {
            let message = Self.errorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw ClaudeOAuthLoginError.tokenExchangeFailed(message)
        }
        let tokens: TokenResponseBody
        do {
            tokens = try JSONDecoder().decode(TokenResponseBody.self, from: data)
        } catch {
            throw ClaudeOAuthLoginError.invalidResponse(error.localizedDescription)
        }
        return Self.credential(from: tokens, now: now())
    }

    private static func credential(from tokens: TokenResponseBody, now: Date) -> OAuthCredential {
        // The account uuid stands in when the response carries an account
        // object without an email, so a connected account still reads as
        // connected rather than silently falling back to "not connected".
        let label = tokens.account?.emailAddress ?? tokens.account?.uuid
        return OAuthCredential(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: now.addingTimeInterval(tokens.expiresIn),
            scopes: Self.scopeList(from: tokens.scope) ?? scope.split(separator: " ").map(String.init),
            accountLabel: label,
            accountID: tokens.account?.uuid,
            obtainedAt: now
        )
    }

    /// The granted scope list as the server reported it. Falls back to the
    /// requested list when absent, since the endpoint only grants registered
    /// scope sets whole.
    private static func scopeList(from scope: String?) -> [String]? {
        guard let scope else { return nil }
        let parts = scope.split(separator: " ").map(String.init)
        return parts.isEmpty ? nil : parts
    }

    // MARK: - HTTP plumbing

    private static func perform(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ClaudeOAuthLoginError.network(error.localizedDescription)
        }
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
            delegate: ClaudeOAuthLoginRedirectBlocker(),
            delegateQueue: nil
        )
    }

    private struct ExchangeRequestBody: Encodable {
        let code: String
        let state: String
        let grantType: String
        let clientId: String
        let redirectUri: String
        let codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case code
            case state
            case grantType = "grant_type"
            case clientId = "client_id"
            case redirectUri = "redirect_uri"
            case codeVerifier = "code_verifier"
        }
    }

    private struct RefreshRequestBody: Encodable {
        let grantType: String
        let refreshToken: String
        let clientId: String
        let scope: String

        enum CodingKeys: String, CodingKey {
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
            case clientId = "client_id"
            case scope
        }
    }

    /// Shaped after `formatTokens` in the Claude Code v2.1.218 binary, which
    /// reads the signed-in identity as `account.email_address` /
    /// `account.uuid`. There is no top-level `email` on this response — an
    /// earlier guess at one decoded to `nil` on every real login, which left
    /// the account row reading "账号未连接" even though the token itself had
    /// been obtained and stored correctly.
    private struct TokenResponseBody: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
        let scope: String?
        let account: Account?

        struct Account: Decodable {
            let uuid: String?
            let emailAddress: String?

            enum CodingKeys: String, CodingKey {
                case uuid
                case emailAddress = "email_address"
            }
        }

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case account
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
/// `ClaudeOAuthRedirectBlocker` (the existing one guarding the usage
/// endpoint) and `CodexOAuthLoginService`'s equivalent.
private final class ClaudeOAuthLoginRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
