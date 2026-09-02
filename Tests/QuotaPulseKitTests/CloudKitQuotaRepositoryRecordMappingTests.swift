#if canImport(CloudKit)
import CloudKit
import XCTest
@testable import QuotaPulseKit

/// These exercise only in-memory `CKRecord` field mapping — no network, no
/// iCloud account required — so they run fine in plain `swift test`/CI.
final class CloudKitQuotaRepositoryRecordMappingTests: XCTestCase {
    func testCloudKitAccountErrorsMapToActionableSyncErrors() {
        assertSyncError(.iCloudAccountUnavailable, for: .notAuthenticated)
        assertSyncError(.networkUnavailable, for: .networkUnavailable)
        assertSyncError(.networkUnavailable, for: .accountTemporarilyUnavailable)
    }

    func testFullSnapshotRoundTripsThroughARecord() {
        let snapshot = QuotaSnapshot(
            provider: .codex,
            session: QuotaWindow(usedPercent: 27, resetAt: Date(timeIntervalSince1970: 1_780_000_000)),
            weekly: QuotaWindow(usedPercent: 61, resetAt: Date(timeIntervalSince1970: 1_780_500_000)),
            capturedAt: Date(timeIntervalSince1970: 1_779_000_000),
            sourceVersion: "1.2.3"
        )

        let record = CKRecord(recordType: "QuotaSnapshot", recordID: CKRecord.ID(recordName: "codex-latest"))
        CloudKitQuotaRepository.apply(snapshot, to: record)
        let decoded = CloudKitQuotaRepository.snapshot(from: record)

        // id is regenerated on decode (it isn't stored), so compare fields.
        XCTAssertEqual(decoded?.provider, snapshot.provider)
        XCTAssertEqual(decoded?.session, snapshot.session)
        XCTAssertEqual(decoded?.weekly, snapshot.weekly)
        XCTAssertEqual(decoded?.capturedAt, snapshot.capturedAt)
        XCTAssertEqual(decoded?.sourceVersion, snapshot.sourceVersion)
    }

    func testMissingOptionalWindowsDecodeAsNil() {
        let snapshot = QuotaSnapshot(provider: .claude, capturedAt: Date(timeIntervalSince1970: 1_000))

        let record = CKRecord(recordType: "QuotaSnapshot", recordID: CKRecord.ID(recordName: "claude-latest"))
        CloudKitQuotaRepository.apply(snapshot, to: record)
        let decoded = CloudKitQuotaRepository.snapshot(from: record)

        XCTAssertNil(decoded?.session.usedPercent)
        XCTAssertNil(decoded?.session.resetAt)
        XCTAssertNil(decoded?.sourceVersion)
    }

    func testExcludingSourceVersionStillWritesTheReading() {
        let snapshot = QuotaSnapshot(
            provider: .codex,
            session: QuotaWindow(usedPercent: 27),
            capturedAt: Date(timeIntervalSince1970: 1_779_000_000),
            sourceVersion: "mac/0.3.0"
        )

        let record = CKRecord(recordType: "QuotaSnapshot", recordID: CKRecord.ID(recordName: "codex-latest"))
        CloudKitQuotaRepository.apply(snapshot, to: record, includingSourceVersion: false)

        // The point of the fallback: everything the user can see still syncs.
        XCTAssertNil(record["sourceVersion"] as? String)
        XCTAssertEqual(CloudKitQuotaRepository.snapshot(from: record)?.session.usedPercent, 27)
        XCTAssertEqual(CloudKitQuotaRepository.snapshot(from: record)?.capturedAt, snapshot.capturedAt)
    }

    func testExcludingSourceVersionLeavesAnExistingValueAlone() {
        let record = CKRecord(recordType: "QuotaSnapshot", recordID: CKRecord.ID(recordName: "codex-latest"))
        record["sourceVersion"] = "mac/0.2.0"

        CloudKitQuotaRepository.apply(
            QuotaSnapshot(provider: .codex, capturedAt: Date(timeIntervalSince1970: 2_000), sourceVersion: "mac/0.3.0"),
            to: record,
            includingSourceVersion: false
        )

        // Assigning nil would itself modify the field the server refused.
        XCTAssertEqual(record["sourceVersion"] as? String, "mac/0.2.0")
    }

    func testOnlySchemaRefusalsTriggerTheSourceVersionFallback() {
        XCTAssertTrue(CloudKitQuotaRepository.isSchemaRejection(CKError(.invalidArguments)))
        XCTAssertTrue(CloudKitQuotaRepository.isSchemaRejection(CKError(.serverRejectedRequest)))

        XCTAssertFalse(CloudKitQuotaRepository.isSchemaRejection(CKError(.networkUnavailable)))
        XCTAssertFalse(CloudKitQuotaRepository.isSchemaRejection(CKError(.notAuthenticated)))
        XCTAssertFalse(CloudKitQuotaRepository.isSchemaRejection(CKError(.serverRecordChanged)))
        XCTAssertFalse(CloudKitQuotaRepository.isSchemaRejection(CKError(.unknownItem)))
    }

    func testRecordMissingRequiredFieldsDecodesToNil() {
        let record = CKRecord(recordType: "QuotaSnapshot", recordID: CKRecord.ID(recordName: "bogus"))
        XCTAssertNil(CloudKitQuotaRepository.snapshot(from: record))
    }

    func testOlderSnapshotCannotReplaceNewerCloudRecord() {
        let record = CKRecord(
            recordType: "QuotaSnapshot",
            recordID: CKRecord.ID(recordName: "claude-latest")
        )
        let newer = QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: 10),
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )
        let older = QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: 90),
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        CloudKitQuotaRepository.apply(newer, to: record)

        XCTAssertFalse(CloudKitQuotaRepository.applyIfNotOlder(older, to: record))
        XCTAssertEqual(CloudKitQuotaRepository.snapshot(from: record)?.session.usedPercent, 10)
        XCTAssertEqual(
            CloudKitQuotaRepository.snapshot(from: record)?.capturedAt,
            newer.capturedAt
        )
    }

    func testNewerSnapshotReplacesOlderCloudRecord() {
        let record = CKRecord(
            recordType: "QuotaSnapshot",
            recordID: CKRecord.ID(recordName: "claude-latest")
        )
        let older = QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: 90),
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: 10),
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )
        CloudKitQuotaRepository.apply(older, to: record)

        XCTAssertTrue(CloudKitQuotaRepository.applyIfNotOlder(newer, to: record))
        XCTAssertEqual(CloudKitQuotaRepository.snapshot(from: record)?.session.usedPercent, 10)
    }

    private func assertSyncError(
        _ expected: ExpectedSyncError,
        for code: CKError.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mapped = QuotaSyncError.from(CKError(code))
        switch (expected, mapped) {
        case (.iCloudAccountUnavailable, .iCloudAccountUnavailable),
             (.networkUnavailable, .networkUnavailable):
            break
        default:
            XCTFail("Unexpected mapping: \(mapped)", file: file, line: line)
        }
    }

    private enum ExpectedSyncError {
        case iCloudAccountUnavailable
        case networkUnavailable
    }
}
#endif
