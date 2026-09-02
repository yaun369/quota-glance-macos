import XCTest
@testable import QuotaPulseKit

final class LowestQuotaWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        _ provider: Provider,
        session: Double?,
        weekly: Double?
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            session: QuotaWindow(usedPercent: session.map { 100 - $0 }, resetAt: now.addingTimeInterval(3600)),
            weekly: QuotaWindow(usedPercent: weekly.map { 100 - $0 }, resetAt: now.addingTimeInterval(86_400)),
            capturedAt: now
        )
    }

    func testPicksTheSmallestRemainingAcrossProvidersAndWindows() {
        let lowest = LowestQuotaWindow.lowest(among: [
            snapshot(.codex, session: 66, weekly: 42),
            snapshot(.claude, session: 24, weekly: 12),
        ])

        XCTAssertEqual(lowest?.provider, .claude)
        XCTAssertEqual(lowest?.kind, .weekly)
        XCTAssertEqual(lowest?.remainingPercent, 12)
        XCTAssertEqual(lowest?.resetAt, now.addingTimeInterval(86_400))
    }

    /// The card is about running out, not about refilling: the weekly window
    /// here resets days later than the session one and is still the answer.
    func testIgnoresResetTimeWhenChoosing() {
        let lowest = LowestQuotaWindow.lowest(among: [snapshot(.codex, session: 30, weekly: 5)])

        XCTAssertEqual(lowest?.kind, .weekly)
        XCTAssertEqual(lowest?.remainingPercent, 5)
    }

    func testSkipsWindowsWithoutAReading() {
        let lowest = LowestQuotaWindow.lowest(among: [
            snapshot(.codex, session: nil, weekly: nil),
            snapshot(.claude, session: nil, weekly: 40),
        ])

        XCTAssertEqual(lowest?.provider, .claude)
        XCTAssertEqual(lowest?.kind, .weekly)
        XCTAssertEqual(lowest?.remainingPercent, 40)
    }

    func testOneProviderIsEnough() {
        let lowest = LowestQuotaWindow.lowest(among: [snapshot(.codex, session: 80, weekly: 90), nil])

        XCTAssertEqual(lowest?.provider, .codex)
        XCTAssertEqual(lowest?.remainingPercent, 80)
    }

    /// Drives the "整张 Hero 卡不渲染" branch (§4.8): no readings anywhere is
    /// `nil`, never a zero-percent placeholder.
    func testNoReadingsAnywhereIsNil() {
        XCTAssertNil(LowestQuotaWindow.lowest(among: [nil, nil]))
        XCTAssertNil(LowestQuotaWindow.lowest(among: [snapshot(.codex, session: nil, weekly: nil)]))
    }

    /// A redraw with unchanged data must not swap which window is promoted.
    func testTiesKeepTheFirstCandidate() {
        let lowest = LowestQuotaWindow.lowest(among: [
            snapshot(.codex, session: 20, weekly: 20),
            snapshot(.claude, session: 20, weekly: 20),
        ])

        XCTAssertEqual(lowest?.provider, .codex)
        XCTAssertEqual(lowest?.kind, .session)
    }

    func testExhaustedWindowIsReportedAsZeroNotAsMissing() {
        let lowest = LowestQuotaWindow.lowest(among: [snapshot(.claude, session: 0, weekly: 50)])

        XCTAssertEqual(lowest?.kind, .session)
        XCTAssertEqual(lowest?.remainingPercent, 0)
    }
}
