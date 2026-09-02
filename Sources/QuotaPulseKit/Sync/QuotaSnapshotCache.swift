import Foundation

/// The one on-disk cache every process that can display a `QuotaSnapshot`
/// reads and writes: the iPhone app, the Watch app, and both the iOS and
/// watchOS widget/complication extensions. Extensions run in their own
/// sandboxed container, so without the shared App Group a widget's
/// `UserDefaults.standard` is invisible to its host app and vice versa —
/// this type exists so every one of those processes agrees on the same
/// storage and the same key, and a complication can show data its host app
/// already fetched instead of depending only on its own CloudKit round trip.
public enum QuotaSnapshotCache {
    public static let appGroupIdentifier = "group.dev.yuanmeng.quotapulse"

    public static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    public static func load(_ provider: Provider, defaults: UserDefaults = sharedDefaults) -> QuotaSnapshot? {
        guard let data = defaults.data(forKey: key(provider)) else { return nil }
        return try? JSONDecoder.quotaPulse.decode(QuotaSnapshot.self, from: data)
    }

    public static func save(_ snapshot: QuotaSnapshot, defaults: UserDefaults = sharedDefaults) {
        guard let data = try? JSONEncoder.quotaPulse.encode(snapshot) else { return }
        defaults.set(data, forKey: key(snapshot.provider))
    }

    /// The channel with the newer `capturedAt` wins, matching how the Watch
    /// store already reconciles CloudKit against a WatchConnectivity push.
    public static func newer(_ lhs: QuotaSnapshot?, _ rhs: QuotaSnapshot?) -> QuotaSnapshot? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (let lhs?, nil): return lhs
        case (nil, let rhs?): return rhs
        case (let lhs?, let rhs?): return lhs.capturedAt >= rhs.capturedAt ? lhs : rhs
        }
    }

    private static func key(_ provider: Provider) -> String { "quotapulse.snapshot.\(provider.rawValue)" }
}
