import Foundation

/// Formats quota data for display. Shared by the Mac menu bar, iPhone
/// dashboard and Apple Watch pages so all three surfaces phrase things
/// identically — always "remaining", never "used"; the same freshness
/// wording everywhere.
///
/// Every function here is also the *only* place its wording is translated
/// (UI 规范 §6). A view that assembled "2" + "hours" itself would be correct
/// in Chinese and wrong in English, which is why the countdown and freshness
/// strings are plural entries in `Localizable.stringsdict` and this type only
/// ever supplies the numbers.
///
/// The `locale` parameter exists for tests, which have to be able to assert
/// both languages from one process; leaving it at `nil` — what every call
/// site in the apps does — lets the system resolve the language the way the
/// user's settings say it should. See `QuotaL10n.bundle(for:)`.
public enum QuotaFormatting {
    public static func remainingText(_ window: QuotaWindow, locale: Locale? = nil) -> String {
        remainingText(percent: window.remainingPercent, locale: locale)
    }

    /// The same sentence from a bare percentage, for the one caller that has
    /// no `QuotaWindow` to hand: `QuotaBar`'s VoiceOver value. It is the same
    /// utterance a sighted reader gets from the bar's length, so it has to be
    /// the same words — building it in the view is how "剩余 12%" and
    /// "Remaining 12%" drift apart on the surface nobody screenshots.
    public static func remainingText(percent: Double?, locale: Locale? = nil) -> String {
        guard let percent else {
            return QuotaL10n.string("quota.value.none", "No data yet", locale: locale)
        }
        let rounded = Int(percent.rounded())
        return QuotaL10n.string("quota.remaining.percent", "Remaining \(rounded)%", locale: locale)
    }

    /// Just the number, for places where a nearby label already says which
    /// number it is (the Hero metric, a card's window row). `remainingText`
    /// stays the default everywhere else — a bare percentage with nothing
    /// around it would be the one place a reader could mistake it for "used".
    public static func percentText(_ remainingPercent: Double?, locale: Locale? = nil) -> String {
        guard let remainingPercent else {
            return QuotaL10n.string("quota.value.dash", "--", locale: locale)
        }
        return "\(Int(remainingPercent.rounded()))%"
    }

    /// 「本窗口利用率 34%」/ "Window utilization 34%" —— the second quantity,
    /// and the only place the product ever names consumption instead of what
    /// is left (§6).
    ///
    /// The label is not decoration and must not be dropped at a call site: a
    /// bare "34%" next to a "66%" is two numbers of the same unit pointing in
    /// opposite directions, which is the misreading the "永远说剩余" rule
    /// exists to prevent. Wording is 「利用率」/ "utilization", never 「已用」/
    /// "used" — same number, but it lands in "how much of what I bought did I
    /// use" rather than flipping the screen's remaining-first mental model.
    ///
    /// iPhone card rows only. Widgets, the Lock Screen, the Watch and the Mac
    /// panel stay remaining-only — none of them has the room to label a
    /// second quantity, and an unlabeled one there would be worse than none.
    public static func utilizationText(_ window: QuotaWindow, locale: Locale? = nil) -> String? {
        guard let utilization = window.utilizationPercent else { return nil }
        let percent = Int(utilization.rounded())
        return QuotaL10n.string("quota.utilization.percent", "Window utilization \(percent)%", locale: locale)
    }

    /// The name shown to users. Both are product names, so neither is
    /// translated; this exists so the two spellings live in one place.
    public static func providerText(_ provider: Provider) -> String {
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    public static func windowText(_ kind: QuotaWindowKind, locale: Locale? = nil) -> String {
        switch kind {
        case .session: return QuotaL10n.string("quota.window.session", "5 hours", locale: locale)
        case .weekly: return QuotaL10n.string("quota.window.weekly", "Weekly", locale: locale)
        }
    }

    /// Splitting on the largest non-zero unit is a wording decision, not a
    /// math one: "3 days 4 hours 20 minutes" is the shape the copy takes, and
    /// each of the three shapes is a separate plural entry so a translation
    /// can inflect — or reorder — its units freely.
    public static func resetCountdownText(
        _ resetAt: Date?,
        now: Date = Date(),
        locale: Locale? = nil
    ) -> String {
        guard let resetAt else {
            return QuotaL10n.string("quota.reset.unknown", "Reset time unknown", locale: locale)
        }
        let interval = resetAt.timeIntervalSince(now)
        guard interval > 0 else {
            return QuotaL10n.string("quota.reset.passed", "Should have reset", locale: locale)
        }

        let totalMinutes = Int(interval) / 60
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return QuotaL10n.string(
                "quota.reset.daysHoursMinutes",
                "Resets in \(days) days \(hours) hours \(minutes) minutes",
                locale: locale
            )
        }
        if hours > 0 {
            return QuotaL10n.string(
                "quota.reset.hoursMinutes",
                "Resets in \(hours) hours \(minutes) minutes",
                locale: locale
            )
        }
        return QuotaL10n.string("quota.reset.minutes", "Resets in \(minutes) minutes", locale: locale)
    }

    public static func freshnessText(
        capturedAt: Date,
        now: Date = Date(),
        locale: Locale? = nil
    ) -> String {
        let minutes = Int(now.timeIntervalSince(capturedAt) / 60)
        switch minutes {
        case ..<1:
            return QuotaL10n.string("quota.freshness.justNow", "Updated just now", locale: locale)
        case 1..<60:
            return QuotaL10n.string("quota.freshness.minutes", "Updated \(minutes) minutes ago", locale: locale)
        default:
            let hours = minutes / 60
            return QuotaL10n.string("quota.freshness.hours", "Updated \(hours) hours ago", locale: locale)
        }
    }

    public static func syncedTimeText(_ date: Date, locale: Locale? = nil) -> String {
        let time = timeFormatter(locale: locale).string(from: date)
        return QuotaL10n.string("quota.sync.at", "Synced at \(time)", locale: locale)
    }

    /// Built per call when a locale is pinned, cached otherwise: the shared
    /// formatter is the hot path (every row, every refresh), and a test that
    /// asks for a different language must not mutate it out from under it.
    private static func timeFormatter(locale: Locale?) -> DateFormatter {
        guard let locale else { return sharedTimeFormatter }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private static let sharedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
