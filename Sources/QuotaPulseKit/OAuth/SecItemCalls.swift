import Foundation
import Security

/// The minimal Security-framework surface `OAuthTokenStore` uses, injectable
/// so unit tests can exercise the store's full logic (data-protection
/// queries, legacy-item migration, update-then-add) against an in-memory
/// fake. A test run must never be able to reach the user's real login
/// keychain: reads from xctest trigger the legacy authorization dialog, and
/// granting it once added xctest to a real item's ACL — the exact taint
/// that caused the app's prompt storm.
struct SecItemCalls: @unchecked Sendable {
    var copyMatching: ([String: Any]) -> (status: OSStatus, result: AnyObject?)
    var add: ([String: Any]) -> OSStatus
    var update: ([String: Any], [String: Any]) -> OSStatus
    var delete: ([String: Any]) -> OSStatus

    static let system = SecItemCalls(
        copyMatching: { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        add: { attributes in
            SecItemAdd(attributes as CFDictionary, nil)
        },
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    )
}
