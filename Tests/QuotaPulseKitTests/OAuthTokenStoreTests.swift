#if os(macOS)
import Security
import XCTest
@testable import QuotaPulseKit

final class OAuthTokenStoreTests: XCTestCase {
    private var fake: FakeSecItem!
    private var store: OAuthTokenStore!
    private let fixedNow = Date(timeIntervalSince1970: 1_779_999_030)

    private var claudeService: String { "QuotaPulseTest-claude" }
    private var codexService: String { "QuotaPulseTest-codex" }

    override func setUp() {
        fake = FakeSecItem()
        store = OAuthTokenStore(
            serviceName: { "QuotaPulseTest-\($0.rawValue)" },
            secItem: fake.calls
        )
    }

    // MARK: - Round trips (all against the data-protection keychain)

    func testLoadReturnsNilWhenNothingIsStored() throws {
        XCTAssertNil(try store.load(.claude))
    }

    func testSaveThenLoadRoundTripsAllFields() throws {
        let credential = makeCredential(accessToken: "access-1", refreshToken: "refresh-1")
        try store.save(credential, for: .claude)

        let loaded = try store.load(.claude)

        XCTAssertEqual(loaded, credential)
    }

    func testSaveOverwritesAnExistingCredentialForTheSameProvider() throws {
        try store.save(makeCredential(accessToken: "access-1", refreshToken: "refresh-1"), for: .claude)
        try store.save(makeCredential(accessToken: "access-2", refreshToken: "refresh-2"), for: .claude)

        let loaded = try store.load(.claude)

        XCTAssertEqual(loaded?.accessToken, "access-2")
        XCTAssertEqual(loaded?.refreshToken, "refresh-2")
    }

    func testProvidersAreStoredIndependently() throws {
        try store.save(makeCredential(accessToken: "claude-token", refreshToken: "claude-refresh"), for: .claude)
        try store.save(makeCredential(accessToken: "codex-token", refreshToken: "codex-refresh"), for: .codex)

        XCTAssertEqual(try store.load(.claude)?.accessToken, "claude-token")
        XCTAssertEqual(try store.load(.codex)?.accessToken, "codex-token")
    }

    func testDeleteRemovesTheCredential() throws {
        try store.save(makeCredential(accessToken: "access-1", refreshToken: "refresh-1"), for: .claude)
        try store.delete(.claude)

        XCTAssertNil(try store.load(.claude))
    }

    func testDeleteIsIdempotentWhenNothingIsStored() throws {
        XCTAssertNoThrow(try store.delete(.claude))
        XCTAssertNoThrow(try store.delete(.claude))
    }

    func testSaveWritesOnlyTheDataProtectionKeychain() throws {
        try store.save(makeCredential(accessToken: "access-1", refreshToken: "refresh-1"), for: .claude)

        XCTAssertNotNil(fake.dataProtectionData(service: claudeService))
        XCTAssertNil(fake.legacyData(service: claudeService))
    }

    func testLoadPrefersTheDataProtectionItemOverALeftoverLegacyOne() throws {
        fake.seedDataProtection(
            service: claudeService,
            data: try encode(makeCredential(accessToken: "new-world", refreshToken: nil))
        )
        fake.seedLegacy(
            service: claudeService,
            data: try encode(makeCredential(accessToken: "old-world", refreshToken: nil))
        )

        XCTAssertEqual(try store.load(.claude)?.accessToken, "new-world")
    }

    // MARK: - Legacy migration

    func testLoadMigratesACleanLegacyItemIntoTheDataProtectionKeychain() throws {
        let credential = makeCredential(accessToken: "legacy-access", refreshToken: "legacy-refresh")
        fake.seedLegacy(service: claudeService, data: try encode(credential))

        let loaded = try store.load(.claude)

        XCTAssertEqual(loaded, credential)
        // Moved, not copied: the data-protection keychain now owns the item
        // and the legacy original is gone.
        XCTAssertNotNil(fake.dataProtectionData(service: claudeService))
        XCTAssertNil(fake.legacyData(service: claudeService))
    }

    func testMigratedItemIsServedFromTheDataProtectionKeychainOnTheNextLoad() throws {
        let credential = makeCredential(accessToken: "legacy-access", refreshToken: "legacy-refresh")
        fake.seedLegacy(service: claudeService, data: try encode(credential))
        _ = try store.load(.claude)

        // If the second load consulted the legacy bucket again, this forced
        // status would surface; a data-protection hit never sees it.
        fake.legacyReadStatus = errSecInteractionNotAllowed

        XCTAssertEqual(try store.load(.claude), credential)
    }

    func testLoadDropsALegacyItemThatWouldRequireTheAuthorizationDialog() throws {
        let credential = makeCredential(accessToken: "tainted", refreshToken: "tainted-refresh")
        fake.seedLegacy(service: codexService, data: try encode(credential))
        fake.legacyReadStatus = errSecInteractionNotAllowed

        // Unreadable-without-a-dialog counts as "not logged in" — the app
        // never shows the legacy dialog, so the item can never be read again.
        XCTAssertNil(try store.load(.codex))
        // And it is deleted outright so it stops re-triggering this path
        // (deletion needs no authorization, unlike reading).
        XCTAssertNil(fake.legacyData(service: codexService))
        XCTAssertNil(fake.dataProtectionData(service: codexService))
    }

    func testLoadDropsALegacyItemWhoseACLDeniesAccess() throws {
        fake.seedLegacy(
            service: codexService,
            data: try encode(makeCredential(accessToken: "denied", refreshToken: nil))
        )
        fake.legacyReadStatus = errSecAuthFailed

        XCTAssertNil(try store.load(.codex))
        XCTAssertNil(fake.legacyData(service: codexService))
    }

    func testLoadDropsACorruptLegacyItem() throws {
        fake.seedLegacy(service: claudeService, data: Data("not json".utf8))

        XCTAssertNil(try store.load(.claude))
        XCTAssertNil(fake.legacyData(service: claudeService))
    }

    func testLoadTreatsAMissingEntitlementAsNotLoggedInWithoutTouchingLegacy() throws {
        // An unsigned process (`swift run quota-cli`) has no data-protection
        // keychain. It must report "not logged in" — and must NOT consume or
        // clean up a legacy item it could never re-create.
        fake.seedLegacy(
            service: claudeService,
            data: try encode(makeCredential(accessToken: "app-owned", refreshToken: nil))
        )
        fake.dataProtectionStatus = errSecMissingEntitlement

        XCTAssertNil(try store.load(.claude))
        XCTAssertNotNil(fake.legacyData(service: claudeService))
    }

    func testDeleteRemovesBothDataProtectionAndLegacyItems() throws {
        fake.seedDataProtection(
            service: claudeService,
            data: try encode(makeCredential(accessToken: "a", refreshToken: nil))
        )
        fake.seedLegacy(
            service: claudeService,
            data: try encode(makeCredential(accessToken: "b", refreshToken: nil))
        )

        try store.delete(.claude)

        XCTAssertNil(fake.dataProtectionData(service: claudeService))
        XCTAssertNil(fake.legacyData(service: claudeService))
    }

    func testDeleteToleratesAMissingEntitlementForTheDataProtectionKeychain() throws {
        fake.dataProtectionStatus = errSecMissingEntitlement
        fake.seedLegacy(
            service: claudeService,
            data: try encode(makeCredential(accessToken: "b", refreshToken: nil))
        )

        XCTAssertNoThrow(try store.delete(.claude))
        XCTAssertNil(fake.legacyData(service: claudeService))
    }

    func testLoadSurfacesUnexpectedKeychainFailures() {
        fake.dataProtectionStatus = errSecNotAvailable

        XCTAssertThrowsError(try store.load(.claude)) { error in
            XCTAssertEqual(
                error as? OAuthTokenStoreError,
                .keychainFailure(errSecNotAvailable)
            )
        }
    }

    // MARK: - Helpers

    private func makeCredential(accessToken: String, refreshToken: String?) -> OAuthCredential {
        OAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: fixedNow.addingTimeInterval(3_600),
            scopes: ["user:profile"],
            accountLabel: "person@example.com",
            obtainedAt: fixedNow
        )
    }

    private func encode(_ credential: OAuthCredential) throws -> Data {
        try JSONEncoder.quotaPulse.encode(credential)
    }
}
#endif
