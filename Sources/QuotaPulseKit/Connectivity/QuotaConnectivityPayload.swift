import Foundation

/// What the iPhone pushes to the Watch over WatchConnectivity. Keyed by
/// `Provider.rawValue` (rather than `Provider` itself) so JSON encoding is
/// unambiguous regardless of `Dictionary`'s Codable key-encoding rules.
public struct QuotaConnectivityPayload: Codable, Equatable, Sendable {
    public var snapshotsByProvider: [String: QuotaSnapshot]
    public var sentAt: Date

    public init(snapshots: [Provider: QuotaSnapshot], sentAt: Date = Date()) {
        self.snapshotsByProvider = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.rawValue, $0.value) })
        self.sentAt = sentAt
    }

    public var snapshots: [Provider: QuotaSnapshot] {
        var result: [Provider: QuotaSnapshot] = [:]
        for (key, value) in snapshotsByProvider {
            guard let provider = Provider(rawValue: key) else { continue }
            result[provider] = value
        }
        return result
    }
}
