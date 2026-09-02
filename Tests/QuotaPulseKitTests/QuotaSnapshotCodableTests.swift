import XCTest
@testable import QuotaPulseKit

final class QuotaSnapshotCodableTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let snapshot = QuotaSnapshot(
            provider: .codex,
            session: QuotaWindow(usedPercent: 25, resetAt: Date(timeIntervalSince1970: 1_780_000_000)),
            weekly: QuotaWindow(usedPercent: 42, resetAt: Date(timeIntervalSince1970: 1_780_500_000)),
            capturedAt: Date(timeIntervalSince1970: 1_779_999_000),
            sourceVersion: "0.1.0"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
    }
}
