import Foundation

public enum OAuthTokenRefreshError: LocalizedError, Sendable, Equatable {
    /// No credential is stored for this provider at all — the caller should
    /// fall through to the next source in the credential chain rather than
    /// show this as an error.
    case notLoggedIn
    /// The authorization server rejected the refresh token outright
    /// (`invalid_grant`); it will never accept this refresh token again.
    case invalidGrant(String?)
    case network(String)
    case server(statusCode: Int, message: String?)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return QuotaL10n.string("token.notSignedIn", "Not signed in. Sign in to your account in QuotaGlance first.")
        case .invalidGrant(let message):
            return message.map { QuotaL10n.string("token.expired.reason", "Your sign-in has expired: \($0)") }
                ?? QuotaL10n.string("token.expired", "Your sign-in has expired. Please sign in again.")
        case .network(let reason):
            return QuotaL10n.string("token.transportFailed", "The request to refresh your sign-in failed: \(reason)")
        case .server(let statusCode, let message):
            return message.map {
                QuotaL10n.string("token.httpStatus.reason", "Could not refresh your sign-in (HTTP \(String(statusCode))): \($0)")
            } ?? QuotaL10n.string("token.httpStatus", "Could not refresh your sign-in (HTTP \(String(statusCode))).")
        case .invalidResponse(let reason):
            return QuotaL10n.string("token.invalidResponse", "The sign-in refresh response was invalid: \(reason)")
        }
    }
}

/// What a provider's token endpoint returned for a refresh request. Servers
/// are not required to rotate the refresh token on every call, so
/// `refreshToken` is optional — when absent, `OAuthTokenRefresher` keeps the
/// previous one. `scopes` follows the same "nil means unchanged" rule.
public struct OAuthRefreshResult: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]?
    /// Same "nil means unchanged" rule as `scopes` — a refresh response only
    /// carries this when it also returned a fresh id_token to re-derive it
    /// from.
    public let accountID: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String]?,
        accountID: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.accountID = accountID
    }
}

/// Keeps a QuotaPulse-issued OAuth credential valid for one provider:
/// refreshes proactively before it expires, coalesces concurrent callers
/// into a single in-flight refresh request, and persists a rotated refresh
/// token atomically so a second caller can never replay one the server has
/// already invalidated.
///
/// The stored credential is cached in memory after the first read, so the
/// app's poll loop does not touch the Keychain again until something
/// actually changes. For the cache to stay truthful, every mutation must
/// flow through this actor — `storeCredential` after an interactive login,
/// `clearCredential` on sign-out — never through a separately constructed
/// `OAuthTokenStore`.
///
/// The actual HTTP call to a provider's token endpoint is injected as
/// `performRefresh` — this type only owns the generic policy (when to
/// refresh, how to coalesce, what to do with the result), not any
/// provider-specific request shape.
public actor OAuthTokenRefresher {
    private let provider: Provider
    private let store: OAuthTokenStore
    private let refreshLeeway: TimeInterval
    private let now: @Sendable () -> Date
    private let performRefresh: @Sendable (String) async throws -> OAuthRefreshResult

    private var inFlight: Task<OAuthCredential, Error>?

    /// `.known(nil)` ("checked, nothing stored") is meaningfully different
    /// from `.unknown` ("never checked"): the former answers without a
    /// Keychain read, the latter triggers one.
    private enum CachedCredential {
        case unknown
        case known(OAuthCredential?)
    }
    private var cached: CachedCredential = .unknown

    public init(
        provider: Provider,
        store: OAuthTokenStore,
        refreshLeeway: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() },
        performRefresh: @escaping @Sendable (String) async throws -> OAuthRefreshResult
    ) {
        self.provider = provider
        self.store = store
        self.refreshLeeway = refreshLeeway
        self.now = now
        self.performRefresh = performRefresh
    }

    /// Returns a credential guaranteed not to be within `refreshLeeway` of
    /// expiry, refreshing first if needed. Returns `nil` when nothing is
    /// stored at all, so callers can fall through to the next credential
    /// source instead of treating "never logged in" as a refresh failure.
    public func validCredential() async throws -> OAuthCredential? {
        guard let stored = try storedCredential() else { return nil }
        guard stored.isExpiring(now: now(), leeway: refreshLeeway) else { return stored }
        // No refresh token to spend: hand back the (possibly already
        // expired) access token and let the caller's request fail with 401,
        // which is a clearer signal than this method throwing.
        guard stored.refreshToken != nil else { return stored }
        return try await refresh(current: stored)
    }

    /// The stored credential as-is, without any refresh attempt — for
    /// display state like the "已连接 person@example.com" label. Reads the
    /// Keychain at most once for the lifetime of this actor.
    public func storedCredential() throws -> OAuthCredential? {
        switch cached {
        case .known(let credential):
            return credential
        case .unknown:
            let stored = try store.load(provider)
            cached = .known(stored)
            return stored
        }
    }

    /// Persists a credential obtained by an interactive login and primes
    /// the cache, so the next `validCredential()` answers without touching
    /// the Keychain.
    public func storeCredential(_ credential: OAuthCredential) throws {
        try store.save(credential, for: provider)
        cached = .known(credential)
    }

    /// Forces a refresh regardless of the stored expiry. Used after the API
    /// itself has rejected the current access token with 401, in case the
    /// clock-based check in `validCredential()` was optimistic (clock skew,
    /// server-side early revocation, etc).
    public func forceRefresh() async throws -> OAuthCredential {
        guard let stored = try storedCredential() else {
            throw OAuthTokenRefreshError.notLoggedIn
        }
        return try await refresh(current: stored)
    }

    /// Local sign-out: removes the stored credential. Does not attempt to
    /// contact the provider — neither Claude nor Codex offers a documented
    /// public revoke endpoint for this token type.
    public func clearCredential() throws {
        try store.delete(provider)
        cached = .known(nil)
    }

    private func refresh(current: OAuthCredential) async throws -> OAuthCredential {
        if let inFlight { return try await inFlight.value }

        let task = Task<OAuthCredential, Error> {
            guard let refreshToken = current.refreshToken else {
                throw OAuthTokenRefreshError.notLoggedIn
            }
            do {
                let result = try await performRefresh(refreshToken)
                let updated = OAuthCredential(
                    accessToken: result.accessToken,
                    refreshToken: result.refreshToken ?? current.refreshToken,
                    expiresAt: result.expiresAt,
                    scopes: result.scopes ?? current.scopes,
                    accountLabel: current.accountLabel,
                    accountID: result.accountID ?? current.accountID,
                    obtainedAt: now()
                )
                try store.save(updated, for: provider)
                cached = .known(updated)
                return updated
            } catch {
                // A rejected refresh token will never be accepted again;
                // holding onto it would just fail identically on every
                // subsequent attempt. Network/server errors, by contrast,
                // leave the stored credential untouched so the next attempt
                // can simply retry.
                if case OAuthTokenRefreshError.invalidGrant = error {
                    // "Rejected" can also mean another process already spent
                    // this refresh token and saved the rotated successor
                    // (the server invalidates the old one the moment a
                    // rotation succeeds). Re-read the store — bypassing the
                    // cache — before concluding the login itself is dead.
                    // Compared by token strings, not whole-credential
                    // equality: `Date`s lose sub-millisecond precision on
                    // their JSON round trip, which would make the unchanged
                    // stored copy look "newer" than the cached one.
                    if let latest = try? store.load(provider),
                       latest.accessToken != current.accessToken
                        || latest.refreshToken != current.refreshToken {
                        cached = .known(latest)
                        return latest
                    }
                    try? store.delete(provider)
                    cached = .known(nil)
                }
                throw error
            }
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
