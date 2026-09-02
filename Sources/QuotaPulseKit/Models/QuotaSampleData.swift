import Foundation

/// The one set of made-up readings, shared by everything that has to show
/// the app without real data: 演示模式 on the iPhone, the widget's placeholder
/// and preview, and the screenshot scenarios the UI acceptance pass runs
/// (§10).
///
/// One set and not three, because「四端同时展示同一份数据，观感一致」is an
/// actual acceptance item — and it cannot be checked from screenshots taken
/// of three different sets of numbers. It also means a demo screenshot of the
/// phone and a widget gallery preview agree, which they did not before.
///
/// The two providers deliberately sit in different bands so one look covers
/// all three status colors: Codex ample in both windows, Claude low in its
/// 5-hour window and critical in its weekly one — which is also what puts a
/// Hero card on screen (§4.11).
public enum QuotaSampleData {

    /// Sample readings relative to `now`, so countdowns always look live.
    public static func snapshots(now: Date = Date()) -> [Provider: QuotaSnapshot] {
        [
            .codex: QuotaSnapshot(
                provider: .codex,
                session: QuotaWindow(usedPercent: 34, resetAt: now.addingTimeInterval(2.5 * 3600)),
                weekly: QuotaWindow(usedPercent: 58, resetAt: now.addingTimeInterval(3.5 * 24 * 3600)),
                capturedAt: now
            ),
            .claude: QuotaSnapshot(
                provider: .claude,
                session: QuotaWindow(usedPercent: 76, resetAt: now.addingTimeInterval(1.2 * 3600)),
                weekly: QuotaWindow(usedPercent: 88, resetAt: now.addingTimeInterval(1.5 * 24 * 3600)),
                capturedAt: now
            ),
        ]
    }

    /// One provider's sample reading.
    public static func snapshot(_ provider: Provider, now: Date = Date()) -> QuotaSnapshot {
        // Force-unwrapped against a dictionary this file builds itself, with
        // one entry per `Provider` case.
        snapshots(now: now)[provider]!
    }
}
