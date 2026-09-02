import XCTest
@testable import QuotaPulseKit

final class QuotaWindowTests: XCTestCase {
    func testRemainingPercentComputesFromUsedPercent() {
        let window = QuotaWindow(usedPercent: 27, resetAt: nil)
        XCTAssertEqual(window.remainingPercent, 73)
    }

    func testRemainingPercentIsNilWhenUsedPercentMissing() {
        XCTAssertNil(QuotaWindow().remainingPercent)
    }

    func testRemainingPercentClampsToValidRange() {
        XCTAssertEqual(QuotaWindow(usedPercent: 140).remainingPercent, 0)
        XCTAssertEqual(QuotaWindow(usedPercent: -10).remainingPercent, 100)
    }
}
