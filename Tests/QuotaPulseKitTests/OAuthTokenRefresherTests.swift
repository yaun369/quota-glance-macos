#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class OAuthTokenRefresherTests: XCTestCase {
    private var fake: FakeSecItem!
    private var store: OAuthTokenStore!
    private let fixedNow = Date(timeIntervalSince1970: 1_779_999_030)

    override func setUp() {
        fake = FakeSecItem()
        store = OAuthTokenStore(
            serviceName: { "QuotaPulseTest-\($0.rawValue)" },
            secItem: fake.calls
        )
    }

    func testValidCredentialReturnsNilWhenNothingStored() async throws {
        let refresher = makeRefresher(performRefresh: { _ in XCTFail("unexpected refresh"); return Self.dummyResult })

        let result = try await refresher.validCredential()

        XCTAssertNil(result)
    }

    func testValidCredentialReturnsStoredCredentialUnchangedWhenNotExpiring() async throws {
        let fresh = makeCredential(accessToken: "fresh-access", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(3_600))
        try store.save(fresh, for: .claude)
        let recorder = RefreshRecorder()
        let refresher = makeRefresher(performRefresh: { token in try await recorder.refresh(token: token) })

        let result = try await refresher.validCredential()

        XCTAssertEqual(result, fresh)
        let count = await recorder.callCount
        XCTAssertEqual(count, 0)
    }

    func testValidCredentialRefreshesAndPersistsWhenWithinLeeway() async throws {
        let expiring = makeCredential(accessToken: "old-access", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(100))
        try store.save(expiring, for: .claude)
        let recorder = RefreshRecorder(result: .success(
            OAuthRefreshResult(accessToken: "new-access", refreshToken: "refresh-2", expiresAt: fixedNow.addingTimeInterval(3_600), scopes: ["user:profile"])
        ))
        let refresher = makeRefresher(performRefresh: { token in try await recorder.refresh(token: token) })

        let result = try await refresher.validCredential()

        XCTAssertEqual(result?.accessToken, "new-access")
        XCTAssertEqual(result?.refreshToken, "refresh-2")
        let stored = try store.load(.claude)
        XCTAssertEqual(stored?.accessToken, "new-access")
        let requestedToken = await recorder.lastRequestedToken
        XCTAssertEqual(requestedToken, "refresh-1")
    }

    func testRefreshKeepsPreviousRefreshTokenWhenResultOmitsANewOne() async throws {
        let expired = makeCredential(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: fixedNow.addingTimeInterval(-10))
        try store.save(expired, for: .claude)
        let recorder = RefreshRecorder(result: .success(
            OAuthRefreshResult(accessToken: "new-access", refreshToken: nil, expiresAt: fixedNow.addingTimeInterval(3_600), scopes: nil)
        ))
        let refresher = makeRefresher(performRefresh: { token in try await recorder.refresh(token: token) })

        let result = try await refresher.validCredential()

        XCTAssertEqual(result?.refreshToken, "old-refresh")
        let stored = try store.load(.claude)
        XCTAssertEqual(stored?.refreshToken, "old-refresh")
    }

    func testValidCredentialWithoutARefreshTokenReturnsStaleCredentialInsteadOfThrowing() async throws {
        let stale = makeCredential(accessToken: "stale-access", refreshToken: nil, expiresAt: fixedNow.addingTimeInterval(-10))
        try store.save(stale, for: .claude)
        let recorder = RefreshRecorder()
        let refresher = makeRefresher(performRefresh: { token in try await recorder.refresh(token: token) })

        let result = try await refresher.validCredential()

        XCTAssertEqual(result?.accessToken, "stale-access")
        let count = await recorder.callCount
        XCTAssertEqual(count, 0)
    }

    func testConcurrentValidCredentialCallsCoalesceIntoOneRefresh() async throws {
        let expiring = makeCredential(accessToken: "old-access", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(100))
        try store.save(expiring, for: .claude)
        let recorder = BlockingRefreshRecorder()
        let refresher = makeRefresher(performRefresh: { token in try await recorder.refresh(token: token) })

        async let first = refresher.validCredential()
        async let second = refresher.validCredential()
        await recorder.release()

        let (firstResult, secondResult) = try await (first, second)

        XCTAssertEqual(firstResult?.accessToken, "new-access")
        XCTAssertEqual(secondResult?.accessToken, "new-access")
        let count = await recorder.callCount
        XCTAssertEqual(count, 1)
    }

    func testForceRefreshRefreshesEvenWhenNotExpiring() async throws {
        let fresh = makeCredential(accessToken: "fresh-access", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(3_600))
        try store.save(fresh, for: .claude)
        let recorder = RefreshRecorder(result: .success(
            OAuthRefreshResult(accessToken: "forced-access", refreshToken: "refresh-2", expiresAt: fixedNow.addingTimeInterval(3_600), scopes: nil)
        ))
        let refresher = makeRefresher(performRefresh: { token in try await recorder.refresh(token: token) })

        let result = try await refresher.forceRefresh()

        XCTAssertEqual(result.accessToken, "forced-access")
        let count = await recorder.callCount
        XCTAssertEqual(count, 1)
    }

    func testForceRefreshWithNothingStoredThrowsNotLoggedIn() async throws {
        let refresher = makeRefresher(performRefresh: { _ in XCTFail("unexpected refresh"); return Self.dummyResult })

        do {
            _ = try await refresher.forceRefresh()
            XCTFail("expected notLoggedIn")
        } catch OAuthTokenRefreshError.notLoggedIn {
            // expected
        }
    }

    func testInvalidGrantClearsStoredCredentialAndPropagatesError() async throws {
        let expiring = makeCredential(accessToken: "old-access", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(100))
        try store.save(expiring, for: .claude)
        let recorder = RefreshRecorder(result: .failure(.invalidGrant("refresh token revoked")))
        let refresher = makeRefresher(performRefresh: { token in try await recorder.refresh(token: token) })

        do {
            _ = try await refresher.validCredential()
            XCTFail("expected invalidGrant")
        } catch OAuthTokenRefreshError.invalidGrant(let message) {
            XCTAssertEqual(message, "refresh token revoked")
        }

        XCTAssertNil(try store.load(.claude))
    }

    func testNetworkErrorDuringRefreshLeavesStoredCredentialInPlace() async throws {
        let expiring = makeCredential(accessToken: "old-access", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(100))
        try store.save(expiring, for: .claude)
        let recorder = RefreshRecorder(result: .failure(.network("offline")))
        let refresher = makeRefresher(performRefresh: { token in try await recorder.refresh(token: token) })

        do {
            _ = try await refresher.validCredential()
            XCTFail("expected network error")
        } catch OAuthTokenRefreshError.network(let reason) {
            XCTAssertEqual(reason, "offline")
        }

        let stored = try store.load(.claude)
        XCTAssertEqual(stored, expiring)
    }

    func testClearCredentialDeletesFromStore() async throws {
        try store.save(makeCredential(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(3_600)), for: .claude)
        let refresher = makeRefresher(performRefresh: { _ in Self.dummyResult })

        try await refresher.clearCredential()

        XCTAssertNil(try store.load(.claude))
    }

    // MARK: - In-memory caching

    func testValidCredentialReadsTheKeychainOnlyOnceAcrossCalls() async throws {
        let fresh = makeCredential(accessToken: "fresh-access", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(3_600))
        try store.save(fresh, for: .claude)
        let refresher = makeRefresher(performRefresh: { _ in XCTFail("unexpected refresh"); return Self.dummyResult })
        let readsBefore = fake.readCount

        _ = try await refresher.validCredential()
        _ = try await refresher.validCredential()
        _ = try await refresher.storedCredential()

        // One read to populate the cache; the app's 120-second poll loop
        // must not turn into a keychain read per tick.
        XCTAssertEqual(fake.readCount - readsBefore, 1)
    }

    func testStoreCredentialPrimesTheCacheWithoutAKeychainRead() async throws {
        let refresher = makeRefresher(performRefresh: { _ in XCTFail("unexpected refresh"); return Self.dummyResult })
        let credential = makeCredential(accessToken: "logged-in", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(3_600))

        try await refresher.storeCredential(credential)
        let result = try await refresher.validCredential()

        XCTAssertEqual(result, credential)
        XCTAssertEqual(fake.readCount, 0)
        // And it really is persisted, not only cached.
        XCTAssertEqual(try store.load(.claude), credential)
    }

    func testClearCredentialCachesTheSignedOutState() async throws {
        try store.save(makeCredential(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(3_600)), for: .claude)
        let refresher = makeRefresher(performRefresh: { _ in XCTFail("unexpected refresh"); return Self.dummyResult })
        _ = try await refresher.validCredential()
        let readsAfterFirstLoad = fake.readCount

        try await refresher.clearCredential()
        let result = try await refresher.validCredential()

        XCTAssertNil(result)
        XCTAssertEqual(fake.readCount, readsAfterFirstLoad)
    }

    func testInvalidGrantAdoptsACredentialRotatedByAnotherProcess() async throws {
        let expiring = makeCredential(accessToken: "old-access", refreshToken: "refresh-1", expiresAt: fixedNow.addingTimeInterval(100))
        try store.save(expiring, for: .claude)
        let refresher = makeRefresher(performRefresh: { _ in throw OAuthTokenRefreshError.invalidGrant("already rotated") })
        // Warm the cache, then simulate another process spending refresh-1
        // and saving the rotated successor behind this refresher's back.
        _ = try await refresher.storedCredential()
        let rotated = makeCredential(accessToken: "rotated-access", refreshToken: "refresh-2", expiresAt: fixedNow.addingTimeInterval(3_600))
        try OAuthTokenStore(
            serviceName: { "QuotaPulseTest-\($0.rawValue)" },
            secItem: fake.calls
        ).save(rotated, for: .claude)

        let result = try await refresher.validCredential()

        // The login is not dead — the rejection only proved someone else got
        // there first. The newer credential must be adopted, not deleted.
        XCTAssertEqual(result, rotated)
        XCTAssertEqual(try store.load(.claude), rotated)
    }

    // MARK: - Helpers

    private static let dummyResult = OAuthRefreshResult(accessToken: "unused", refreshToken: nil, expiresAt: nil, scopes: nil)

    private func makeRefresher(
        performRefresh: @escaping @Sendable (String) async throws -> OAuthRefreshResult
    ) -> OAuthTokenRefresher {
        OAuthTokenRefresher(
            provider: .claude,
            store: store,
            now: { [fixedNow] in fixedNow },
            performRefresh: performRefresh
        )
    }

    private func makeCredential(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?
    ) -> OAuthCredential {
        OAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: ["user:profile"],
            accountLabel: "person@example.com",
            obtainedAt: fixedNow
        )
    }
}

private actor RefreshRecorder {
    private(set) var callCount = 0
    private(set) var lastRequestedToken: String?
    private let result: Result<OAuthRefreshResult, OAuthTokenRefreshError>

    init(result: Result<OAuthRefreshResult, OAuthTokenRefreshError> = .success(
        OAuthRefreshResult(accessToken: "new-access", refreshToken: "new-refresh", expiresAt: nil, scopes: nil)
    )) {
        self.result = result
    }

    func refresh(token: String) throws -> OAuthRefreshResult {
        callCount += 1
        lastRequestedToken = token
        return try result.get()
    }
}

/// Blocks the first `refresh(token:)` call on a continuation until
/// `release()` is called, so a test can assert that two concurrent
/// `validCredential()` calls coalesce into exactly one in-flight request
/// rather than racing to find out empirically.
private actor BlockingRefreshRecorder {
    private(set) var callCount = 0
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func refresh(token: String) async throws -> OAuthRefreshResult {
        callCount += 1
        if !released {
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }
        return OAuthRefreshResult(accessToken: "new-access", refreshToken: "new-refresh", expiresAt: nil, scopes: nil)
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
#endif
