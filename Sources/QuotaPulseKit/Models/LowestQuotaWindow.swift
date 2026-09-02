import Foundation

/// The window that will run out first: the smallest `remainingPercent` across
/// every provider and every window that has a reading.
///
/// This is the one number on the home screen that no single card can show,
/// which is the whole justification for the Hero card carrying it (UI 规范
/// §4.11). Two things it is deliberately *not*:
///
/// - It is not "resets soonest". An early reset is good news; the card is
///   about what is about to be exhausted, not about what is about to refill.
/// - It is not a replacement for the card below it. The window named here is
///   always rendered again in that provider's own card — Hero promotes it,
///   it does not own it.
///
/// Lives here rather than in the iPhone's store so the comparison is testable
/// without a `@MainActor` object, and so the Mac panel can reuse it later.
public struct LowestQuotaWindow: Equatable, Sendable {
    public let provider: Provider
    public let kind: QuotaWindowKind
    /// Non-optional by construction: a window with no reading can't be the
    /// lowest one, it is simply unknown.
    public let remainingPercent: Double
    public let resetAt: Date?

    public init(provider: Provider, kind: QuotaWindowKind, remainingPercent: Double, resetAt: Date?) {
        self.provider = provider
        self.kind = kind
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
    }

    /// The lowest window among the given snapshots, or `nil` when not one of
    /// them has a single readable window — in which case the Hero card does
    /// not render at all (§4.8), rather than showing a card full of `--`.
    ///
    /// Ties keep the first candidate in argument order, so a screen that is
    /// redrawn with unchanged data never swaps which window it is promoting.
    public static func lowest(among snapshots: [QuotaSnapshot?]) -> LowestQuotaWindow? {
        var lowest: LowestQuotaWindow?
        for snapshot in snapshots.compactMap({ $0 }) {
            for kind in QuotaWindowKind.allCases {
                let window = snapshot.window(kind)
                guard let remaining = window.remainingPercent else { continue }
                if let current = lowest, current.remainingPercent <= remaining { continue }
                lowest = LowestQuotaWindow(
                    provider: snapshot.provider,
                    kind: kind,
                    remainingPercent: remaining,
                    resetAt: window.resetAt
                )
            }
        }
        return lowest
    }
}
