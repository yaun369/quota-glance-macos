import Foundation

/// An OAuth token QuotaPulse obtained itself by logging the user in
/// directly, as opposed to one borrowed from Claude Code's or Codex's own
/// credential storage. Kept in QuotaPulse's own Keychain item
/// (`OAuthTokenStore`) so it can be refreshed and rotated without ever
/// touching a credential another app manages.
public struct OAuthCredential: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public let version: Int
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let accountLabel: String?
    /// The provider's own machine-readable account identifier — e.g.
    /// Codex's `chatgpt_account_id`, sent back as the `ChatGPT-Account-Id`
    /// header on every usage request. `nil` for providers with no such
    /// concept (Claude's usage endpoint identifies the account from the
    /// access token alone). Distinct from `accountLabel`, which is only
    /// ever a display string.
    public let accountID: String?
    public let obtainedAt: Date

    public init(
        version: Int = OAuthCredential.currentVersion,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        accountLabel: String?,
        accountID: String? = nil,
        obtainedAt: Date
    ) {
        self.version = version
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.accountLabel = accountLabel
        self.accountID = accountID
        self.obtainedAt = obtainedAt
    }

    enum CodingKeys: String, CodingKey {
        case version
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scopes
        case accountLabel = "account_label"
        case accountID = "account_id"
        case obtainedAt = "obtained_at"
    }

    /// True once fewer than `leeway` seconds remain before expiry (or the
    /// token has already expired). This is the point at which
    /// `OAuthTokenRefresher` proactively refreshes rather than waiting for
    /// the API to reject the access token with 401.
    public func isExpiring(now: Date, leeway: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }
}
