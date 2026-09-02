import XCTest
@testable import QuotaPulseKit

final class QuotaConnectivityPayloadTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let codex = QuotaSnapshot(
            provider: .codex,
            session: QuotaWindow(usedPercent: 12, resetAt: Date(timeIntervalSince1970: 1_780_000_000)),
            weekly: QuotaWindow(usedPercent: 34, resetAt: Date(timeIntervalSince1970: 1_780_500_000)),
            capturedAt: Date(timeIntervalSince1970: 1_779_000_000)
        )
        let claude = QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: 55),
            capturedAt: Date(timeIntervalSince1970: 1_779_100_000)
        )
        let payload = QuotaConnectivityPayload(snapshots: [.codex: codex, .claude: claude])

        let data = try JSONEncoder.quotaPulse.encode(payload)
        let decoded = try JSONDecoder.quotaPulse.decode(QuotaConnectivityPayload.self, from: data)

        XCTAssertEqual(decoded.snapshots[.codex], codex)
        XCTAssertEqual(decoded.snapshots[.claude], claude)
    }

    func testSnapshotsIgnoresUnknownProviderKeys() {
        let payload = QuotaConnectivityPayload(snapshots: [:])
        var withBogusKey = payload
        withBogusKey.snapshotsByProvider["not-a-real-provider"] = QuotaSnapshot(provider: .codex)
        XCTAssertTrue(withBogusKey.snapshots.isEmpty)
    }
}
