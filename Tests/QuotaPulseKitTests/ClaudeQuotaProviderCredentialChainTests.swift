#if os(macOS)
import Security
import XCTest
@testable import QuotaPulseKit

/// Exercises the credential source chain `ClaudeQuotaProvider.fetchFromOAuth`
/// walks: an explicit environment override, then a self-issued token this
/// app obtained via `ClaudeOAuthLoginService`, then whatever Claude Code
/// itself is using. `ClaudeQuotaProviderTests` already covers the
/// StatusLine/OAuth split and the borrowed-credential retry-on-401 behavior
/// in detail; this file only covers the new ordering these two additional
/// tiers introduce.
final class ClaudeQuotaProviderCredentialChainTests: XCTestCase {
    private var tempDirectory: URL!
    private let fixedNow = Date(timeIntervalSince1970: 1_779_999_030)

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testEnvironmentOverrideTakesPriorityOverOwnAccountAndBorrowed() async throws {
        let store = try makeSeededOwnAccountStore(accessToken: "own-token", refreshToken: "own-refresh")
        let recorder = TokenRecorder(response: .success(usedPercent: 1))
        let provider = makeProvider(
            loadCredentials: { self.makeBorrowedCredentials(accessToken: "borrowed-token") },
            oauth: { token, _ in try await recorder.fetch(token: token) },
            ownAccountStore: store,
            environment: ["QUOTAPULSE_CLAUDE_OAUTH_TOKEN": "env-token"]
        )

        _ = try await provider.fetchSnapshotResult(userInitiated: false)

        let requested = await recorder.tokens
        XCTAssertEqual(requested, ["env-token"])
    }

    func testOwnAccountCredentialIsUsedBeforeBorrowedWhenBothAreAvailable() async throws {
        let store = try makeSeededOwnAccountStore(accessToken: "own-token", refreshToken: "own-refresh")
        let recorder = TokenRecorder(response: .success(usedPercent: 1))
        let provider = makeProvider(
            loadCredentials: { self.makeBorrowedCredentials(accessToken: "borrowed-token") },
            oauth: { token, _ in try await recorder.fetch(token: token) },
            ownAccountStore: store
        )

        let result = try await provider.fetchSnapshotResult(userInitiated: false)

        XCTAssertEqual(result.source, .oauthUsage)
        let requested = await recorder.tokens
        XCTAssertEqual(requested, ["own-token"])
    }

    func testNoOwnCredentialFallsBackToBorrowed() async throws {
        // An empty (never-seeded) store — the default the test initializer
        // uses when no store is supplied.
        let recorder = TokenRecorder(response: .success(usedPercent: 1))
        let provider = makeProvider(
            loadCredentials: { self.makeBorrowedCredentials(accessToken: "borrowed-token") },
            oauth: { token, _ in try await recorder.fetch(token: token) }
        )

        let result = try await provider.fetchSnapshotResult(userInitiated: false)

        XCTAssertEqual(result.source, .oauthUsage)
        let requested = await recorder.tokens
        XCTAssertEqual(requested, ["borrowed-token"])
    }

    func testOwnAccountUnauthorizedForcesARefreshThenRetriesOnce() async throws {
        let store = try makeSeededOwnAccountStore(accessToken: "own-token-stale", refreshToken: "own-refresh")
        let recorder = TokenRecorder(response: .unauthorizedThenSucceed(rejectedToken: "own-token-stale", newToken: "own-token-fresh"))
        let provider = makeProvider(
            loadCredentials: { self.makeBorrowedCredentials(accessToken: "borrowed-token") },
            oauth: { token, _ in try await recorder.fetch(token: token) },
            ownAccountStore: store,
            performOwnRefresh: { refreshToken in
                XCTAssertEqual(refreshToken, "own-refresh")
                return OAuthRefreshResult(
                    accessToken: "own-token-fresh",
                    refreshToken: "own-refresh-2",
                    expiresAt: self.fixedNow.addingTimeInterval(3_600),
                    scopes: nil
                )
            }
        )

        let result = try await provider.fetchSnapshotResult(userInitiated: false)

        XCTAssertEqual(result.source, .oauthUsage)
        let requested = await recorder.tokens
        XCTAssertEqual(requested, ["own-token-stale", "own-token-fresh"])
    }

    func testOwnAccountHardFailureDoesNotFallThroughToBorrowed() async throws {
        let store = try makeSeededOwnAccountStore(accessToken: "own-token", refreshToken: "own-refresh")
        let recorder = TokenRecorder(response: .networkErrorFor(token: "own-token"))
        let provider = makeProvider(
            loadCredentials: { self.makeBorrowedCredentials(accessToken: "borrowed-token") },
            oauth: { token, _ in try await recorder.fetch(token: token) },
            ownAccountStore: store
        )

        do {
            _ = try await provider.fetchSnapshotResult(userInitiated: false)
            XCTFail("expected the own-account network failure to propagate")
        } catch QuotaError.claudeOAuthFallbackFailed(_, let oauthReason) {
            XCTAssertTrue(oauthReason.contains("synthetic network failure"))
        }

        // Only the own-account token should ever have been tried — a
        // fallthrough bug would show "borrowed-token" here too.
        let requested = await recorder.tokens
        XCTAssertEqual(requested, ["own-token"])
    }

    /// A keychain failure on the own-account tier must surface as the OAuth
    /// failure, not silently fall through to the borrowed tier — blaming
    /// Claude Code's credential would hide the user's own broken login.
    func testOwnAccountKeychainFailurePropagatesInsteadOfFallingBackToBorrowed() async {
        let fake = FakeSecItem()
        fake.dataProtectionStatus = errSecAuthFailed
        let store = OAuthTokenStore(
            serviceName: { "QuotaPulseTest-\($0.rawValue)" },
            secItem: fake.calls
        )
        let recorder = TokenRecorder(response: .success(usedPercent: 1))
        let provider = makeProvider(
            loadCredentials: {
                XCTFail("the borrowed tier must not be consulted")
                return self.makeBorrowedCredentials(accessToken: "borrowed-token")
            },
            oauth: { token, _ in try await recorder.fetch(token: token) },
            ownAccountStore: store
        )

        do {
            _ = try await provider.fetchSnapshotResult(userInitiated: false)
            XCTFail("expected the keychain failure to propagate")
        } catch QuotaError.claudeOAuthFallbackFailed(_, let oauthReason) {
            XCTAssertTrue(oauthReason.contains("\(errSecAuthFailed)"), "got: \(oauthReason)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let requested = await recorder.tokens
        XCTAssertTrue(requested.isEmpty)
    }

    // MARK: - Helpers

    private func makeProvider(
        loadCredentials: @escaping @Sendable () throws -> ClaudeOAuthCredentials,
        oauth: @escaping @Sendable (String, Bool) async throws -> QuotaSnapshot,
        ownAccountStore: OAuthTokenStore? = nil,
        environment: [String: String] = [:],
        performOwnRefresh: @escaping @Sendable (String) async throws -> OAuthRefreshResult = { _ in
            throw OAuthTokenRefreshError.notLoggedIn
        }
    ) -> ClaudeQuotaProvider {
        let currentDate = fixedNow
        let refresher: OAuthTokenRefresher? = ownAccountStore.map { store in
            OAuthTokenRefresher(
                provider: .claude,
                store: store,
                now: { currentDate },
                performRefresh: performOwnRefresh
            )
        }
        return ClaudeQuotaProvider(
            cacheURL: tempDirectory.appendingPathComponent("claude-latest.json"),
            statusLineFreshnessInterval: 120,
            now: { currentDate },
            loadCredentials: loadCredentials,
            fetchOAuthSnapshot: oauth,
            ownAccountRefresher: refresher,
            environment: environment
        )
    }

    private func makeSeededOwnAccountStore(accessToken: String, refreshToken: String) throws -> OAuthTokenStore {
        let store = OAuthTokenStore(
            serviceName: { "QuotaPulseTest-\($0.rawValue)" },
            secItem: FakeSecItem().calls
        )
        try store.save(
            OAuthCredential(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: fixedNow.addingTimeInterval(3_600),
                scopes: ["user:profile"],
                accountLabel: "person@example.com",
                obtainedAt: fixedNow
            ),
            for: .claude
        )
        return store
    }

    private func makeBorrowedCredentials(accessToken: String) -> ClaudeOAuthCredentials {
        ClaudeOAuthCredentials(
            accessToken: accessToken,
            expiresAt: fixedNow.addingTimeInterval(3_600),
            scopes: ["user:profile"]
        )
    }
}

private enum TokenRecorderResponse {
    case success(usedPercent: Double)
    case unauthorizedThenSucceed(rejectedToken: String, newToken: String)
    case networkErrorFor(token: String)
}

private enum ChainTestError: LocalizedError {
    case syntheticNetworkFailure
    var errorDescription: String? { "synthetic network failure" }
}

private actor TokenRecorder {
    private(set) var tokens: [String] = []
    private let response: TokenRecorderResponse

    init(response: TokenRecorderResponse) {
        self.response = response
    }

    func fetch(token: String) throws -> QuotaSnapshot {
        tokens.append(token)
        switch response {
        case .success(let usedPercent):
            return QuotaSnapshot(provider: .claude, session: QuotaWindow(usedPercent: usedPercent), capturedAt: Date())
        case .unauthorizedThenSucceed(let rejectedToken, let newToken):
            if token == rejectedToken {
                throw ClaudeOAuthUsageError.unauthorized
            }
            XCTAssertEqual(token, newToken)
            return QuotaSnapshot(provider: .claude, session: QuotaWindow(usedPercent: 1), capturedAt: Date())
        case .networkErrorFor(let expectedToken):
            XCTAssertEqual(token, expectedToken)
            throw ChainTestError.syntheticNetworkFailure
        }
    }
}
#endif
