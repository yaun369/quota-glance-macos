import Foundation

public enum QuotaAlertLevel: String, Codable, Sendable, Comparable {
    case light
    case important
    case urgent

    /// Higher means "closer to running out", so alerts can be compared
    /// against the last level the user was already told about.
    private var severity: Int {
        switch self {
        case .light: return 1
        case .important: return 2
        case .urgent: return 3
        }
    }

    public static func < (lhs: QuotaAlertLevel, rhs: QuotaAlertLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

public enum QuotaAlertEvent: Equatable, Sendable {
    case remainingLow(provider: Provider, window: QuotaWindowKind, level: QuotaAlertLevel, remainingPercent: Double)
}

/// What the user has already been told about one provider's *current* weekly
/// window. Persisting this is what makes alerting level-triggered instead of
/// edge-triggered: we no longer need to catch the exact refresh where the
/// number crossed a line, we only need to notice that the current reading is
/// worse than the worst thing we've announced for this window.
///
/// `windowResetAt` identifies the window. When the provider rolls over to a
/// new week the reset date changes, which clears the record and lets the same
/// levels fire again.
public struct QuotaAlertState: Codable, Equatable, Sendable {
    public var windowResetAt: Date?
    public var notifiedLevel: QuotaAlertLevel?

    public init(windowResetAt: Date? = nil, notifiedLevel: QuotaAlertLevel? = nil) {
        self.windowResetAt = windowResetAt
        self.notifiedLevel = notifiedLevel
    }
}

/// Decides which weekly-quota alerts a user should see for a fresh reading.
/// Session quota is intentionally ignored. Pure and side-effect free (no
/// `UNUserNotificationCenter` here) so the logic is unit-testable on its own.
///
/// Deliberately *not* a "previous vs next" comparison. That earlier design
/// missed alerts whenever the crossing itself happened somewhere we weren't
/// evaluating — the app being closed while the widget extension refreshed the
/// shared snapshot cache, or the user raising a threshold above a value the
/// quota had already fallen past. Comparing the current reading against the
/// last announced level catches both.
///
/// Reset notifications are handled separately by scheduling directly off a
/// known `resetAt`, rather than being detected here — that's more reliable
/// than waiting for a refresh to happen to land after the reset moment.
public enum QuotaAlertEvaluator {
    public static func evaluate(
        state: QuotaAlertState?,
        next: QuotaSnapshot,
        thresholds: QuotaThresholds
    ) -> (events: [QuotaAlertEvent], state: QuotaAlertState) {
        let window = next.weekly
        // A changed reset date means a brand new weekly window, so nothing
        // announced for the old one should suppress alerts for this one.
        let carriedLevel = state?.windowResetAt == window.resetAt ? state?.notifiedLevel : nil

        guard let remaining = window.remainingPercent else {
            return ([], QuotaAlertState(windowResetAt: window.resetAt, notifiedLevel: carriedLevel))
        }

        let level = level(forRemaining: remaining, thresholds: thresholds)
        // Tracking the current level rather than a high-water mark means
        // lowering a threshold below the current reading also re-arms it.
        let newState = QuotaAlertState(windowResetAt: window.resetAt, notifiedLevel: level)

        // Only the single most severe threshold fires, so one big drop (or a
        // first launch that already finds the quota nearly spent) doesn't send
        // three redundant notifications at once.
        guard let level, carriedLevel.map({ level > $0 }) ?? true else {
            return ([], newState)
        }
        return ([.remainingLow(provider: next.provider, window: .weekly, level: level, remainingPercent: remaining)], newState)
    }

    private static func level(forRemaining remaining: Double, thresholds: QuotaThresholds) -> QuotaAlertLevel? {
        let levels: [(Double, QuotaAlertLevel)] = [
            (thresholds.urgentRemainingPercent, .urgent),
            (thresholds.importantRemainingPercent, .important),
            (thresholds.lightRemainingPercent, .light),
        ]
        return levels.first(where: { remaining < $0.0 })?.1
    }
}
