import Foundation

/// User-configurable weekly-quota alert thresholds, expressed as "remaining"
/// percentages to match the "always show remaining" display rule. Defaults
/// come straight from the plan's recommended v1 values.
public struct QuotaThresholds: Codable, Equatable, Sendable {
    public var lightRemainingPercent: Double
    public var importantRemainingPercent: Double
    public var urgentRemainingPercent: Double
    public var resetNotificationsEnabled: Bool

    public init(
        lightRemainingPercent: Double = 30,
        importantRemainingPercent: Double = 15,
        urgentRemainingPercent: Double = 5,
        resetNotificationsEnabled: Bool = true
    ) {
        self.lightRemainingPercent = lightRemainingPercent
        self.importantRemainingPercent = importantRemainingPercent
        self.urgentRemainingPercent = urgentRemainingPercent
        self.resetNotificationsEnabled = resetNotificationsEnabled
    }

    public static let `default` = QuotaThresholds()
}

/// Persists `QuotaThresholds` to `UserDefaults`. Only the iPhone app writes
/// to this today (it owns notification scheduling); the store lives in Kit
/// so it stays trivially testable with an isolated suite.
public final class QuotaThresholdsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "quotapulse.thresholds.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> QuotaThresholds {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder.quotaPulse.decode(QuotaThresholds.self, from: data)
        else { return .default }
        return decoded
    }

    public func save(_ thresholds: QuotaThresholds) {
        guard let data = try? JSONEncoder.quotaPulse.encode(thresholds) else { return }
        defaults.set(data, forKey: key)
    }
}
