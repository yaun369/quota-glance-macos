import Foundation

/// One rate-limit window (e.g. the rolling 5-hour window or the 7-day
/// window) at a single point in time.
public struct QuotaWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double?
    public var resetAt: Date?

    public init(usedPercent: Double? = nil, resetAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.resetAt = resetAt
    }

    /// Remaining percentage, clamped to 0...100. UI surfaces should always
    /// show "remaining", never "used", per the product's consistency rule.
    public var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    /// 本窗口利用率：`usedPercent`, clamped the same way `remainingPercent`
    /// is so the two always add up to 100 on screen.
    ///
    /// The same number `usedPercent` already holds, exposed under the name
    /// the product is allowed to say out loud: 「已用」 is banned on every
    /// surface (§6), 「利用率」 is the iPhone card's one sanctioned way to
    /// answer "how much of what I pay for did I actually use". Raw
    /// `usedPercent` stays what the providers write; nothing but this
    /// property and `QuotaFormatting.utilizationText` should reach a view.
    public var utilizationPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, min(100, usedPercent))
    }
}

/// Which of a snapshot's two windows is being talked about.
///
/// Named properties are enough while a view knows which window it is
/// rendering; this exists for the values that *search* across windows and
/// then have to say which one they found — alert events, and the Hero card's
/// `LowestQuotaWindow`. It moved here from `QuotaAlertEvaluator` when the
/// second caller appeared: it describes the model, not the alerting rules.
///
/// The raw values reach `UNNotificationRequest` identifiers, so renaming a
/// case would orphan already-scheduled reset notifications.
public enum QuotaWindowKind: String, Codable, Sendable, CaseIterable {
    /// The rolling 5-hour window.
    case session
    /// The 7-day window.
    case weekly
}
