#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class AccountDirectQuotaServiceTests: XCTestCase {
    private var fake: FakeSecItem!
    private var store: OAuthTokenStore!
    private let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() {
        fake = FakeSecItem()
        store = OAuthTokenStore(
            serviceName: { "QuotaPulseTest-Direct-\($0.rawValue)" },
            secItem: fake.calls
        )
    }

    func testFetchReturnsNilWithoutStoredCredentialAndNeverCallsUsage() async throws {
        let usage = UsageRecorder(results: [])
        let service = makeService(usage: usage)

        let snapshot = try await service.fetchSnapshot(userInitiated: false)

        XCTAssertNil(snapshot)
        let tokens = await usage.seenTokens
        XCTAssertEqual(tokens, [])
    }

    func testFetchReturnsSnapshotWithValidCredential() async throws {
        try store.save(makeCredential(accessToken: "fresh-access", expiresAt: fixedNow.addingTimeInterval(3_600)), for: .claude)
        let expected = makeSnapshot()
        let usage = UsageRecorder(results: [.success(expected)])
        let service = makeService(usage: usage)

        let snapshot = try await service.fetchSnapshot(userInitiated: true)

        XCTAssertEqual(snapshot, expected)
        let tokens = await usage.seenTokens
        XCTAssertEqual(tokens, ["fresh-access"])
        let flags = await usage.seenUserInitiated
        XCTAssertEqual(flags, [true])
    }

    func testExpiringCredentialRefreshesBeforeFetch() async throws {
        try store.save(makeCredential(accessToken: "old-access", expiresAt: fixedNow.addingTimeInterval(60)), for: .claude)
        let usage = UsageRecorder(results: [.success(makeSnapshot())])
        let service = makeService(
            usage: usage,
            performRefresh: { _ in
                OAuthRefreshResult(accessToken: "new-access", refreshToken: "refresh-2", expiresAt: self.fixedNow.addingTimeInterval(3_600), scopes: nil)
            }
        )

        _ = try await service.fetchSnapshot(userInitiated: false)

        let tokens = await usage.seenTokens
        XCTAssertEqual(tokens, ["new-access"])
        XCTAssertEqual(try store.load(.claude)?.accessToken, "new-access")
    }

    func testUnauthorizedForcesRefreshAndRetriesExactlyOnce() async throws {
        try store.save(makeCredential(accessToken: "stale-access", expiresAt: fixedNow.addingTimeInterval(3_600)), for: .claude)
        let expected = makeSnapshot()
        let usage = UsageRecorder(results: [
            .failure(StubUnauthorizedError()),
            .success(expected),
        ])
        let service = makeService(
            usage: usage,
            performRefresh: { _ in
                OAuthRefreshResult(accessToken: "forced-access", refreshToken: nil, expiresAt: self.fixedNow.addingTimeInterval(3_600), scopes: nil)
            }
        )

        let snapshot = try await service.fetchSnapshot(userInitiated: false)

        XCTAssertEqual(snapshot, expected)
        let tokens = await usage.seenTokens
        XCTAssertEqual(tokens, ["stale-access", "forced-access"])
    }

    func testUnauthorizedAfterForcedRefreshThrowsLoginExpiredAndKeepsCredential() async throws {
        try store.save(makeCredential(accessToken: "stale-access", expiresAt: fixedNow.addingTimeInterval(3_600)), for: .claude)
        let usage = UsageRecorder(results: [
            .failure(StubUnauthorizedError()),
            .failure(StubUnauthorizedError()),
        ])
        let service = makeService(
            usage: usage,
            performRefresh: { _ in
                OAuthRefreshResult(accessToken: "forced-access", refreshToken: nil, expiresAt: self.fixedNow.addingTimeInterval(3_600), scopes: nil)
            }
        )

        await assertThrowsLoginExpired { try await service.fetchSnapshot(userInitiated: false) }
        XCTAssertNotNil(try store.load(.claude))
    }

    func testInvalidGrantOnForcedRefreshThrowsLoginExpiredAndClearsCredential() async throws {
        try store.save(makeCredential(accessToken: "stale-access", expiresAt: fixedNow.addingTimeInterval(3_600)), for: .claude)
        let usage = UsageRecorder(results: [.failure(StubUnauthorizedError())])
        let service = makeService(
            usage: usage,
            performRefresh: { _ in throw OAuthTokenRefreshError.invalidGrant(nil) }
        )

        await assertThrowsLoginExpired { try await service.fetchSnapshot(userInitiated: false) }

        XCTAssertNil(try store.load(.claude))
        let next = try await service.fetchSnapshot(userInitiated: false)
        XCTAssertNil(next)
    }

    func testInvalidGrantDuringProactiveRefreshThrowsLoginExpired() async throws {
        try store.save(makeCredential(accessToken: "old-access", expiresAt: fixedNow.addingTimeInterval(60)), for: .claude)
        let usage = UsageRecorder(results: [])
        let service = makeService(
            usage: usage,
            performRefresh: { _ in throw OAuthTokenRefreshError.invalidGrant(nil) }
        )

        await assertThrowsLoginExpired { try await service.fetchSnapshot(userInitiated: false) }
        let tokens = await usage.seenTokens
        XCTAssertEqual(tokens, [])
    }

    func testRequireAccountIDThrowsIncompleteCredentialWhenMissing() {
        let credential = makeCredential(accessToken: "a", expiresAt: nil)

        XCTAssertThrowsError(try AccountDirectQuotaService.requireAccountID(credential)) { error in
            XCTAssertEqual(error as? AccountDirectQuotaError, .incompleteCredential)
        }
        XCTAssertEqual(
            try? AccountDirectQuotaService.requireAccountID(makeCredential(accessToken: "a", expiresAt: nil, accountID: "acct-1")),
            "acct-1"
        )
    }

    func testCredentialLifecycle() async throws {
        let service = makeService(usage: UsageRecorder(results: []))

        var stored = await service.hasStoredCredential()
        XCTAssertFalse(stored)

        try await service.storeCredential(makeCredential(accessToken: "a", expiresAt: fixedNow.addingTimeInterval(3_600)))
        stored = await service.hasStoredCredential()
        XCTAssertTrue(stored)
        let label = await service.storedAccountLabel()
        XCTAssertEqual(label, "person@example.com")

        try await service.signOut()
        stored = await service.hasStoredCredential()
        XCTAssertFalse(stored)
        let snapshot = try await service.fetchSnapshot(userInitiated: false)
        XCTAssertNil(snapshot)
    }

    // MARK: - Helpers

    private func makeService(
        usage: UsageRecorder,
        performRefresh: @escaping @Sendable (String) async throws -> OAuthRefreshResult = { _ in
            XCTFail("unexpected refresh")
            return OAuthRefreshResult(accessToken: "unused", refreshToken: nil, expiresAt: nil, scopes: nil)
        }
    ) -> AccountDirectQuotaService {
        let refresher = OAuthTokenRefresher(
            provider: .claude,
            store: store,
            now: { [fixedNow] in fixedNow },
            performRefresh: performRefresh
        )
        return AccountDirectQuotaService(
            provider: .claude,
            refresher: refresher,
            fetchUsage: { credential, userInitiated in
                try await usage.fetch(credential: credential, userInitiated: userInitiated)
            },
            isUnauthorized: { $0 is StubUnauthorizedError }
        )
    }

    private func makeCredential(
        accessToken: String,
        expiresAt: Date?,
        accountID: String? = nil
    ) -> OAuthCredential {
        OAuthCredential(
            accessToken: accessToken,
            refreshToken: "refresh-1",
            expiresAt: expiresAt,
            scopes: ["user:profile"],
            accountLabel: "person@example.com",
            accountID: accountID,
            obtainedAt: fixedNow
        )
    }

    private func makeSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: 25, resetAt: fixedNow.addingTimeInterval(1_800)),
            weekly: QuotaWindow(usedPercent: 40, resetAt: fixedNow.addingTimeInterval(86_400)),
            capturedAt: fixedNow
        )
    }

    private func assertThrowsLoginExpired(
        _ operation: () async throws -> QuotaSnapshot?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected loginExpired", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AccountDirectQuotaError, .loginExpired, file: file, line: line)
        }
    }
}

private struct StubUnauthorizedError: Error {}

/// Scripted stand-in for the per-provider usage fetch: replays queued
/// results in order while recording which access token and priority each
/// call carried.
private actor UsageRecorder {
    private(set) var seenTokens: [String] = []
    private(set) var seenUserInitiated: [Bool] = []
    private var results: [Result<QuotaSnapshot, Error>]

    init(results: [Result<QuotaSnapshot, Error>]) {
        self.results = results
    }

    func fetch(credential: OAuthCredential, userInitiated: Bool) throws -> QuotaSnapshot {
        seenTokens.append(credential.accessToken)
        seenUserInitiated.append(userInitiated)
        precondition(!results.isEmpty, "usage fetch called more times than scripted")
        return try results.removeFirst().get()
    }
}
#endif
