import XCTest
@testable import QuotaPulseKit

final class QuotaAlertEvaluatorTests: XCTestCase {
    private let resetAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        provider: Provider = .codex,
        sessionUsed: Double? = nil,
        weeklyUsed: Double? = nil,
        weeklyResetAt: Date? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            session: QuotaWindow(usedPercent: sessionUsed),
            weekly: QuotaWindow(usedPercent: weeklyUsed, resetAt: weeklyResetAt ?? resetAt)
        )
    }

    func testFirstReadingAlreadyBelowThresholdFires() {
        // The regression this design exists for: nothing was recorded yet and
        // the quota is already past the line, so there is no crossing to catch.
        let (events, state) = QuotaAlertEvaluator.evaluate(
            state: nil, next: snapshot(weeklyUsed: 71), thresholds: .default
        )
        XCTAssertEqual(events, [.remainingLow(provider: .codex, window: .weekly, level: .light, remainingPercent: 29)])
        XCTAssertEqual(state.notifiedLevel, .light)
    }

    func testReadingAboveEveryThresholdFiresNothing() {
        let (events, state) = QuotaAlertEvaluator.evaluate(
            state: nil, next: snapshot(weeklyUsed: 20), thresholds: .default
        )
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(state.notifiedLevel)
    }

    func testAlreadyNotifiedLevelDoesNotFireAgain() {
        let state = QuotaAlertState(windowResetAt: resetAt, notifiedLevel: .light)
        let (events, newState) = QuotaAlertEvaluator.evaluate(
            state: state, next: snapshot(weeklyUsed: 75), thresholds: .default
        )
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(newState.notifiedLevel, .light)
    }

    func testWorseningLevelFiresOnlyMostSevereLevel() {
        // Remaining drops from a light-level 29% straight to 2%, past both
        // remaining thresholds in one refresh.
        let state = QuotaAlertState(windowResetAt: resetAt, notifiedLevel: .light)
        let (events, newState) = QuotaAlertEvaluator.evaluate(
            state: state, next: snapshot(weeklyUsed: 98), thresholds: .default
        )
        XCTAssertEqual(events, [.remainingLow(provider: .codex, window: .weekly, level: .urgent, remainingPercent: 2)])
        XCTAssertEqual(newState.notifiedLevel, .urgent)
    }

    func testMissedCrossingStillFires() {
        // The widget extension can refresh the shared snapshot cache while the
        // app is closed, so the app may never observe the reading that crossed.
        let (events, _) = QuotaAlertEvaluator.evaluate(
            state: QuotaAlertState(windowResetAt: resetAt, notifiedLevel: nil),
            next: snapshot(weeklyUsed: 71),
            thresholds: .default
        )
        XCTAssertEqual(events, [.remainingLow(provider: .codex, window: .weekly, level: .light, remainingPercent: 29)])
    }

    func testRaisingThresholdPastCurrentReadingFires() {
        // 49% remaining sits under a hand-raised 50% "light" line even though
        // the quota fell past 50% before that line existed.
        let thresholds = QuotaThresholds(
            lightRemainingPercent: 50, importantRemainingPercent: 30, urgentRemainingPercent: 15
        )
        let (events, _) = QuotaAlertEvaluator.evaluate(
            state: QuotaAlertState(windowResetAt: resetAt, notifiedLevel: nil),
            next: snapshot(weeklyUsed: 51),
            thresholds: thresholds
        )
        XCTAssertEqual(events, [.remainingLow(provider: .codex, window: .weekly, level: .light, remainingPercent: 49)])
    }

    func testLoweringThresholdBelowCurrentReadingRearmsIt() {
        let state = QuotaAlertState(windowResetAt: resetAt, notifiedLevel: .light)
        let lowered = QuotaThresholds(lightRemainingPercent: 20, importantRemainingPercent: 15, urgentRemainingPercent: 5)

        let (quiet, quietState) = QuotaAlertEvaluator.evaluate(
            state: state, next: snapshot(weeklyUsed: 71), thresholds: lowered
        )
        XCTAssertTrue(quiet.isEmpty)
        XCTAssertNil(quietState.notifiedLevel)

        let (events, _) = QuotaAlertEvaluator.evaluate(
            state: quietState, next: snapshot(weeklyUsed: 81), thresholds: lowered
        )
        XCTAssertEqual(events, [.remainingLow(provider: .codex, window: .weekly, level: .light, remainingPercent: 19)])
    }

    func testNewWeeklyWindowClearsPreviousNotifiedLevel() {
        let state = QuotaAlertState(windowResetAt: resetAt, notifiedLevel: .urgent)
        let next = snapshot(weeklyUsed: 71, weeklyResetAt: resetAt.addingTimeInterval(7 * 24 * 3600))

        let (events, newState) = QuotaAlertEvaluator.evaluate(state: state, next: next, thresholds: .default)

        XCTAssertEqual(events, [.remainingLow(provider: .codex, window: .weekly, level: .light, remainingPercent: 29)])
        XCTAssertEqual(newState.windowResetAt, next.weekly.resetAt)
    }

    func testMissingWeeklyDataFiresNothingAndKeepsLevel() {
        let state = QuotaAlertState(windowResetAt: resetAt, notifiedLevel: .important)
        let (events, newState) = QuotaAlertEvaluator.evaluate(
            state: state, next: snapshot(weeklyUsed: nil), thresholds: .default
        )
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(newState.notifiedLevel, .important)
    }

    func testSessionQuotaIsIgnored() {
        let (events, _) = QuotaAlertEvaluator.evaluate(
            state: nil, next: snapshot(sessionUsed: 96, weeklyUsed: 10), thresholds: .default
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testClaudeWeeklyAlertKeepsProviderIdentity() {
        let (events, _) = QuotaAlertEvaluator.evaluate(
            state: nil, next: snapshot(provider: .claude, weeklyUsed: 86), thresholds: .default
        )
        XCTAssertEqual(events, [.remainingLow(provider: .claude, window: .weekly, level: .important, remainingPercent: 14)])
    }
}
