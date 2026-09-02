import Foundation
import LocalAuthentication
import Security

public enum OAuthTokenStoreError: LocalizedError, Sendable, Equatable {
    case encodingFailed(String)
    case decodingFailed(String)
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let reason):
            return QuotaL10n.string("token.saveFailed", "Could not save your sign-in: \(reason)")
        case .decodingFailed(let reason):
            return QuotaL10n.string("token.loadFailed", "Could not read your saved sign-in: \(reason)")
        case .keychainFailure(let status) where status == errSecMissingEntitlement:
            // The one status a user can hit without anything being broken:
            // an unsigned build has no code-signing identity, so it has no
            // data-protection keychain to write to. Reading already treats
            // this as "not signed in" (see `load`), but saving cannot — the
            // sign-in genuinely has nowhere to go, and the raw number tells
            // the reader nothing about why a browser that just said
            // "登录成功" is followed by a failure in the app.
            return QuotaL10n.string(
                "token.keychainUnavailableForBuild",
                "This build cannot use the keychain, so the sign-in was not saved. An unsigned build has no keychain of its own — sign in from a signed build of QuotaGlance (status \(String(status)))."
            )
        case .keychainFailure(let status):
            return QuotaL10n.string("token.keychainFailed", "Keychain access failed (status \(String(status))).")
        }
    }
}

/// Reads and writes QuotaPulse's own OAuth credentials — one item per
/// provider, entirely separate from Claude Code's `Claude Code-credentials`
/// item or Codex's on-disk auth file. Because this app owns these items
/// outright, it is free to add, update and delete them without the
/// read-only caution `ClaudeOAuthCredentialsLoader` has to take with a
/// credential another app manages.
///
/// Items live in the *data-protection* keychain
/// (`kSecUseDataProtectionKeychain`), where access is granted by the app's
/// code-signing identity (its keychain access group) instead of the legacy
/// per-item ACL. That distinction is what guarantees this store can never
/// summon the "码量 wants to use your confidential information" dialog: the
/// legacy ACL re-prompts whenever the item's recorded trusted application
/// stops matching the running binary (a rebuild, a rename, an item created
/// by a test runner), while the data-protection keychain has no such dialog
/// at all — access either succeeds silently or fails programmatically.
///
/// Items created by versions of this app that still used the legacy
/// keychain are migrated on first read, strictly without UI: a legacy item
/// that would need the authorization dialog to hand over its secret is
/// deleted and treated as "not logged in" (one fresh login recreates it in
/// the data-protection keychain), never prompted for.
///
/// Items are `AfterFirstUnlockThisDeviceOnly`: readable in the background
/// (no login-session requirement) but never included in an iCloud Keychain
/// or device-migration backup. A QuotaPulse-issued token must stay on the
/// machine that obtained it.
public struct OAuthTokenStore: Sendable {
    static let defaultAccount = "oauth-credential"

    private let serviceName: @Sendable (Provider) -> String
    private let account: String
    private let accessGroup: String?
    private let secItem: SecItemCalls

    public init(accessGroup: String? = nil) {
        self.init(
            serviceName: { provider in
                switch provider {
                case .claude: return "QuotaPulse-OAuth-Claude"
                case .codex: return "QuotaPulse-OAuth-Codex"
                }
            },
            accessGroup: accessGroup
        )
    }

    /// Test-only entry point: overriding the service name (and optionally
    /// the account label) keeps tests from ever targeting the real
    /// `QuotaPulse-OAuth-*` items, and `secItem` replaces the Security
    /// framework itself so no test touches any real keychain at all.
    init(
        serviceName: @escaping @Sendable (Provider) -> String,
        account: String = OAuthTokenStore.defaultAccount,
        accessGroup: String? = nil,
        secItem: SecItemCalls = .system
    ) {
        self.serviceName = serviceName
        self.account = account
        self.accessGroup = accessGroup
        self.secItem = secItem
    }

    public func load(_ provider: Provider) throws -> OAuthCredential? {
        var query = dataProtectionQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = secItem.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw OAuthTokenStoreError.decodingFailed("keychain item did not contain Data")
            }
            do {
                return try JSONDecoder.quotaPulse.decode(OAuthCredential.self, from: data)
            } catch {
                throw OAuthTokenStoreError.decodingFailed(error.localizedDescription)
            }
        case errSecItemNotFound:
            return try migrateLegacyItem(for: provider)
        case errSecMissingEntitlement:
            // A process without an application identifier (`swift run
            // quota-cli`, any unsigned dev binary) has no data-protection
            // keychain at all — and therefore can never have stored a
            // credential either, so "not logged in" is accurate and the
            // caller's fallback chain proceeds. Deliberately no legacy
            // fallback here: such a process must not consume (or clean up)
            // an item it could never re-create.
            return nil
        default:
            throw OAuthTokenStoreError.keychainFailure(status)
        }
    }

    /// Adds or overwrites the credential for `provider`. Update-then-add
    /// (rather than delete-then-add) keeps the Keychain item's creation date
    /// stable across refreshes, which is harmless here but avoids surprises
    /// for anything that later inspects item metadata.
    public func save(_ credential: OAuthCredential, for provider: Provider) throws {
        let data: Data
        do {
            data = try JSONEncoder.quotaPulse.encode(credential)
        } catch {
            throw OAuthTokenStoreError.encodingFailed(error.localizedDescription)
        }

        let query = dataProtectionQuery(for: provider)
        let updateStatus = secItem.update(query, [kSecValueData as String: data])
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw OAuthTokenStoreError.keychainFailure(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = secItem.add(addQuery)
        guard addStatus == errSecSuccess else {
            throw OAuthTokenStoreError.keychainFailure(addStatus)
        }
    }

    /// Idempotent: deleting a credential that was never stored (or already
    /// removed) is not an error, since callers use this both for explicit
    /// "sign out" and for clearing a rejected refresh token that may or may
    /// not still be present. Removes the pre-migration legacy item too, so
    /// signing out never leaves a stale copy behind.
    public func delete(_ provider: Provider) throws {
        let status = secItem.delete(dataProtectionQuery(for: provider))
        guard status == errSecSuccess || status == errSecItemNotFound
            || status == errSecMissingEntitlement else {
            throw OAuthTokenStoreError.keychainFailure(status)
        }
        let legacyStatus = secItem.delete(legacyQuery(for: provider))
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw OAuthTokenStoreError.keychainFailure(legacyStatus)
        }
    }

    /// One-time move of an item written by a legacy-keychain version of this
    /// app. Only ever reached after the data-protection keychain answered
    /// "no item" — which also proves this process *has* data-protection
    /// access, so a successfully read credential can always be re-saved.
    private func migrateLegacyItem(for provider: Provider) throws -> OAuthCredential? {
        var query = legacyQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Same belt as `ClaudeOAuthCredentialsLoader.keychainQuery`: the
        // LAContext flag alone does not suppress the legacy cross-app
        // Allow/Deny sheet on every macOS release, so also fail any query
        // that would need UI via the stable string values of the deprecated
        // kSecUseAuthenticationUI/UIFail constants. Migration must be
        // strictly silent no matter which build reads first.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query["u_AuthUI"] = "u_AuthUIF" as CFString

        let (status, result) = secItem.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credential = try? JSONDecoder.quotaPulse.decode(OAuthCredential.self, from: data)
            else {
                // A legacy payload this version cannot decode would fail
                // identically on every future launch; drop it so the app
                // reports a clean "not logged in" instead of a permanent
                // decode error.
                _ = secItem.delete(legacyQuery(for: provider))
                return nil
            }
            // Only remove the legacy item once the data-protection copy is
            // safely written — a failed save must not cost the user their
            // login.
            if (try? save(credential, for: provider)) != nil {
                _ = secItem.delete(legacyQuery(for: provider))
            }
            return credential
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem:
            // The item exists, but macOS would need the legacy authorization
            // dialog to hand over its secret — its ACL no longer matches
            // this build (created by a test runner, an older signature, a
            // renamed product). This app never shows that dialog, so the
            // item is unreadable for good: delete it (deletion needs no
            // authorization) and report "not logged in". One fresh login
            // recreates it, silently, in the data-protection keychain.
            _ = secItem.delete(legacyQuery(for: provider))
            return nil
        default:
            throw OAuthTokenStoreError.keychainFailure(status)
        }
    }

    private func dataProtectionQuery(for provider: Provider) -> [String: Any] {
        var query = legacyQuery(for: provider)
        query[kSecUseDataProtectionKeychain as String] = true
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func legacyQuery(for provider: Provider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(provider),
            kSecAttrAccount as String: account,
        ]
    }
}
