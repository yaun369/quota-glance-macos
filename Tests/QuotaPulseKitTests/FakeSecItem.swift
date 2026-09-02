#if os(macOS)
import Foundation
import Security
@testable import QuotaPulseKit

/// In-memory stand-in for the four SecItem calls `OAuthTokenStore` makes,
/// with the data-protection keychain and the legacy keychain modeled as two
/// separate buckets so migration logic is testable.
///
/// Tests must never reach the real login keychain: a read from xctest can
/// trigger the legacy authorization dialog, and granting it once adds
/// xctest to the real item's ACL — the exact taint that caused the app's
/// prompt storm on launch.
final class FakeSecItem: @unchecked Sendable {
    private let lock = NSLock()
    private var dataProtectionItems: [String: Data] = [:]
    private var legacyItems: [String: Data] = [:]

    /// Forced status for every data-protection call, e.g.
    /// `errSecMissingEntitlement` to behave like an unsigned process that
    /// has no data-protection keychain at all.
    var dataProtectionStatus: OSStatus? {
        get { lock.withLock { _dataProtectionStatus } }
        set { lock.withLock { _dataProtectionStatus = newValue } }
    }

    /// Forced status for legacy *reads*, e.g. `errSecInteractionNotAllowed`
    /// to behave like an item whose ACL would require the authorization
    /// dialog. Deletes stay live — deleting a legacy item needs no
    /// authorization, which is what migration relies on.
    var legacyReadStatus: OSStatus? {
        get { lock.withLock { _legacyReadStatus } }
        set { lock.withLock { _legacyReadStatus = newValue } }
    }

    private var _dataProtectionStatus: OSStatus?
    private var _legacyReadStatus: OSStatus?
    private var _readCount = 0

    /// Total `copyMatching` calls across both buckets — the refresher's
    /// cache tests assert this stays flat once a credential is cached.
    var readCount: Int { lock.withLock { _readCount } }

    var calls: SecItemCalls {
        SecItemCalls(
            copyMatching: { [self] query in copyMatching(query) },
            add: { [self] attributes in add(attributes) },
            update: { [self] query, attributes in update(query, attributes) },
            delete: { [self] query in delete(query) }
        )
    }

    // MARK: - Seeding and inspection

    func seedLegacy(service: String, account: String = "oauth-credential", data: Data) {
        lock.withLock { legacyItems[Self.key(service: service, account: account)] = data }
    }

    func seedDataProtection(service: String, account: String = "oauth-credential", data: Data) {
        lock.withLock { dataProtectionItems[Self.key(service: service, account: account)] = data }
    }

    func legacyData(service: String, account: String = "oauth-credential") -> Data? {
        lock.withLock { legacyItems[Self.key(service: service, account: account)] }
    }

    func dataProtectionData(service: String, account: String = "oauth-credential") -> Data? {
        lock.withLock { dataProtectionItems[Self.key(service: service, account: account)] }
    }

    // MARK: - SecItem behavior

    private func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        lock.withLock {
            _readCount += 1
            let key = Self.key(query)
            if Self.isDataProtection(query) {
                if let status = _dataProtectionStatus { return (status, nil) }
                guard let data = dataProtectionItems[key] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data as AnyObject)
            }
            if let status = _legacyReadStatus { return (status, nil) }
            guard let data = legacyItems[key] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data as AnyObject)
        }
    }

    private func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = Self.key(attributes)
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            if Self.isDataProtection(attributes) {
                if let status = _dataProtectionStatus { return status }
                guard dataProtectionItems[key] == nil else { return errSecDuplicateItem }
                dataProtectionItems[key] = data
            } else {
                guard legacyItems[key] == nil else { return errSecDuplicateItem }
                legacyItems[key] = data
            }
            return errSecSuccess
        }
    }

    private func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = Self.key(query)
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            if Self.isDataProtection(query) {
                if let status = _dataProtectionStatus { return status }
                guard dataProtectionItems[key] != nil else { return errSecItemNotFound }
                dataProtectionItems[key] = data
            } else {
                guard legacyItems[key] != nil else { return errSecItemNotFound }
                legacyItems[key] = data
            }
            return errSecSuccess
        }
    }

    private func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = Self.key(query)
            if Self.isDataProtection(query) {
                if let status = _dataProtectionStatus { return status }
                guard dataProtectionItems.removeValue(forKey: key) != nil else { return errSecItemNotFound }
            } else {
                guard legacyItems.removeValue(forKey: key) != nil else { return errSecItemNotFound }
            }
            return errSecSuccess
        }
    }

    private static func isDataProtection(_ query: [String: Any]) -> Bool {
        query[kSecUseDataProtectionKeychain as String] as? Bool == true
    }

    private static func key(_ query: [String: Any]) -> String {
        key(
            service: query[kSecAttrService as String] as? String ?? "",
            account: query[kSecAttrAccount as String] as? String ?? ""
        )
    }

    private static func key(service: String, account: String) -> String {
        "\(service)\u{1}\(account)"
    }
}
#endif
