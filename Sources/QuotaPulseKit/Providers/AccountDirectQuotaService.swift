import Foundation

/// Failures of the account-direct path that the app layer shows as-is.
/// Exists because the usage clients' own error text assumes the macOS
/// credential chain (`ClaudeOAuthUsageError.unauthorized` says "请运行
/// Claude Code 并重新登录") — on a platform where this service is the only
/// source, the actionable remedy is always "重新登录" inside this app.
public enum AccountDirectQuotaError: LocalizedError, Sendable, Equatable {
    /// The stored credential can no longer produce an accepted access token:
    /// the refresh token was rejected, or a force-refreshed access token
    /// still came back 401/insufficient. Re-login overwrites the credential.
    case loginExpired
    /// The stored Codex credential lacks the ChatGPT account ID the usage
    /// endpoint requires. Unreachable through a normal login (the login
    /// service fails without an account ID); defensive for hand-migrated or
    /// corrupted credentials.
    case incompleteCredential

    public var errorDescription: String? {
        switch self {
        case .loginExpired:
            return QuotaL10n.string("accountDirect.credentialExpired", "Your sign-in has expired. Please sign in again.")
        case .incompleteCredential:
            return QuotaL10n.string(
                "accountDirect.credentialIncomplete",
                "Your sign-in details are incomplete. Sign out and sign in again."
            )
        }
    }
}

/// The "账号直连" collection path as a self-contained, cross-platform unit:
/// credential lifecycle + proactive refresh + request throttling + one
/// forced-refresh retry on 401.
///
/// This is the *only* collection channel on iOS, which is why it exists
/// separately from the macOS providers: `CodexQuotaProvider` and
/// `ClaudeQuotaProvider` interleave account-direct with desktop-only
/// fallbacks (`codex app-server` subprocesses, Claude Code's status line and
/// credential file), and their failure/fallback timing is load-bearing —
/// they deliberately do not reuse this class.
///
/// All credential reads and writes flow through one `OAuthTokenRefresher`
/// so its in-memory cache stays truthful; the app layer must never
/// construct its own `OAuthTokenStore` (same doctrine as the macOS
/// providers' credential lifecycle).
public final class AccountDirectQuotaService: Sendable {
    public let provider: Provider

    private let refresher: OAuthTokenRefresher
    private let fetchUsage: @Sendable (OAuthCredential, Bool) async throws -> QuotaSnapshot
    private let isUnauthorized: @Sendable (Error) -> Bool

    /// Production entry point for Codex: the same collaborators
    /// `CodexQuotaProvider`'s production initializer wires for its
    /// account-direct tier (Keychain item `QuotaPulse-OAuth-Codex`, 120s
    /// background reuse, shared rate-limit/5xx backoff policy).
    public static func codex() -> AccountDirectQuotaService {
        let loginService = CodexOAuthLoginService()
        let refresher = OAuthTokenRefresher(
            provider: .codex,
            store: OAuthTokenStore(),
            performRefresh: { token in try await loginService.refresh(refreshToken: token) }
        )
        let usageClient = CodexUsageClient()
        let coordinator = UsageRequestCoordinator<QuotaSnapshot, String>(
            minimumBackgroundInterval: 120,
            classifyFailure: { error, now in CodexUsageError.requestBlockDecision(for: error, now: now) }
        )
        return AccountDirectQuotaService(
            provider: .codex,
            refresher: refresher,
            fetchUsage: { credential, userInitiated in
                let accountID = try Self.requireAccountID(credential)
                return try await coordinator.fetch(key: "codex", userInitiated: userInitiated) {
                    try await usageClient.fetchSnapshot(
                        accessToken: credential.accessToken,
                        accountID: accountID
                    )
                }
            },
            isUnauthorized: { ($0 as? CodexUsageError) == .unauthorized }
        )
    }

    /// Production entry point for Claude: the same collaborators
    /// `ClaudeQuotaProvider`'s production initializer wires for its
    /// self-issued-token tier (Keychain item `QuotaPulse-OAuth-Claude`,
    /// token-fingerprint-keyed 120s coordinator).
    public static func claude() -> AccountDirectQuotaService {
        let loginService = ClaudeOAuthLoginService()
        let refresher = OAuthTokenRefresher(
            provider: .claude,
            store: OAuthTokenStore(),
            performRefresh: { token in try await loginService.refresh(refreshToken: token) }
        )
        let coordinator = ClaudeOAuthRequestCoordinator(
            client: ClaudeOAuthUsageClient(),
            minimumBackgroundInterval: 120,
            now: { Date() }
        )
        return AccountDirectQuotaService(
            provider: .claude,
            refresher: refresher,
            fetchUsage: { credential, userInitiated in
                do {
                    return try await coordinator.fetch(
                        accessToken: credential.accessToken,
                        userInitiated: userInitiated
                    )
                } catch ClaudeOAuthUsageError.forbidden {
                    // This app issues its own Claude tokens with the full
                    // registered scope set, so `forbidden` means the grant
                    // itself has degraded — and the raw error's remedy text
                    // points at Claude Code, which doesn't exist on the
                    // platforms this service serves. A fresh login is the
                    // accurate fix either way.
                    throw AccountDirectQuotaError.loginExpired
                }
            },
            isUnauthorized: { ($0 as? ClaudeOAuthUsageError) == .unauthorized }
        )
    }

    /// The Codex usage endpoint needs the ChatGPT account ID alongside the
    /// bearer token. Internal rather than private so the guard's contract is
    /// testable without a network-backed factory instance.
    static func requireAccountID(_ credential: OAuthCredential) throws -> String {
        guard let accountID = credential.accountID else {
            throw AccountDirectQuotaError.incompleteCredential
        }
        return accountID
    }

    /// Test-only entry point: the refresher and both policy closures are
    /// injected so no test touches a real Keychain or the network.
    init(
        provider: Provider,
        refresher: OAuthTokenRefresher,
        fetchUsage: @escaping @Sendable (OAuthCredential, Bool) async throws -> QuotaSnapshot,
        isUnauthorized: @escaping @Sendable (Error) -> Bool
    ) {
        self.provider = provider
        self.refresher = refresher
        self.fetchUsage = fetchUsage
        self.isUnauthorized = isUnauthorized
    }

    /// Fetches a fresh snapshot with the stored login.
    ///
    /// Returns `nil` when no credential is stored at all — "never logged
    /// in" is a state for the caller to render (fall back to synced data),
    /// not an error. Throws when a stored login exists but this fetch
    /// failed; `AccountDirectQuotaError.loginExpired` specifically means
    /// re-login is required.
    ///
    /// On 401 the access token is force-refreshed and the request retried
    /// exactly once. For Codex this deliberately diverges from
    /// `CodexQuotaProvider`, which treats 401 as a hard failure and falls
    /// back to `codex app-server` — here there is no fallback tier, so the
    /// forced refresh is the only self-heal available. Do not "fix" the
    /// divergence in either direction.
    public func fetchSnapshot(userInitiated: Bool) async throws -> QuotaSnapshot? {
        let stored: OAuthCredential?
        do {
            stored = try await refresher.validCredential()
        } catch OAuthTokenRefreshError.invalidGrant {
            // The refresher already dropped the rejected credential; the
            // next call will return nil (signed out).
            throw AccountDirectQuotaError.loginExpired
        }
        guard let credential = stored else { return nil }

        do {
            return try await fetchUsage(credential, userInitiated)
        } catch let error where isUnauthorized(error) {
            let refreshed: OAuthCredential
            do {
                refreshed = try await refresher.forceRefresh()
            } catch OAuthTokenRefreshError.invalidGrant, OAuthTokenRefreshError.notLoggedIn {
                throw AccountDirectQuotaError.loginExpired
            }
            do {
                return try await fetchUsage(refreshed, userInitiated)
            } catch let retryError where isUnauthorized(retryError) {
                // Two rejections around a successful refresh: the server is
                // refusing this grant, not this access token. The credential
                // is left in place — a re-login simply overwrites it.
                throw AccountDirectQuotaError.loginExpired
            }
        }
    }

    // MARK: - Credential lifecycle

    /// Persists a credential from a completed interactive login, through the
    /// same cached refresher the fetch path reads.
    public func storeCredential(_ credential: OAuthCredential) async throws {
        try await refresher.storeCredential(credential)
    }

    /// Local sign-out: removes the stored credential, after which
    /// `fetchSnapshot` returns `nil`.
    public func signOut() async throws {
        try await refresher.clearCredential()
    }

    /// Display label of the connected account ("person@example.com"), or
    /// `nil` when no login is stored. Never refreshes, prompts, or touches
    /// the network.
    public func storedAccountLabel() async -> String? {
        guard let credential = try? await refresher.storedCredential() else { return nil }
        return credential.accountLabel
    }

    /// Whether a login is stored, without refreshing or touching the network.
    public func hasStoredCredential() async -> Bool {
        (try? await refresher.storedCredential()) != nil
    }
}
