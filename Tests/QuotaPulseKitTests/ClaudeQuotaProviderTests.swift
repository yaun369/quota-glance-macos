#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class ClaudeQuotaProviderTests: XCTestCase {
    private var tempDirectory: URL!
    private let fixedNow = Date(timeIntervalSince1970: 1_779_999_030)

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testMissingCacheFallsBackToOAuth() async throws {
        let oauthSnapshot = makeOAuthSnapshot()
        let provider = makeProvider(
            cacheURL: tempDirectory.appendingPathComponent("claude-latest.json"),
            oauth: { _, _ in oauthSnapshot }
        )

        let result = try await provider.fetchSnapshotResult(userInitiated: false)

        XCTAssertEqual(result.source, .oauthUsage)
        XCTAssertEqual(result.snapshot, oauthSnapshot)
    }

    func testParsesCachedStatusLinePayload() async throws {
        let cacheURL = tempDirectory.appendingPathComponent("claude-latest.json")
        let json = """
        {
          "fiveHour": { "used_percentage": 23.5, "resets_at": 1780000000 },
          "sevenDay": { "used_percentage": 41.2, "resets_at": 1780500000 },
          "capturedAt": 1779999000
        }
        """
        try json.write(to: cacheURL, atomically: true, encoding: .utf8)

        let provider = makeProvider(cacheURL: cacheURL)
        let result = try await provider.fetchSnapshotResult(userInitiated: false)
        let snapshot = result.snapshot

        XCTAssertEqual(result.source, .statusLine)
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.session.usedPercent, 23.5)
        XCTAssertEqual(snapshot.weekly.usedPercent, 41.2)
        XCTAssertEqual(snapshot.capturedAt, Date(timeIntervalSince1970: 1_779_999_000))
    }

    func testDecodeFailureAndOAuthFailureSurfaceBothReasons() async throws {
        let cacheURL = tempDirectory.appendingPathComponent("claude-latest.json")
        try "not json".write(to: cacheURL, atomically: true, encoding: .utf8)

        let provider = makeProvider(cacheURL: cacheURL)
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected an error")
        } catch QuotaError.claudeOAuthFallbackFailed(let statusLineReason, let oauthReason) {
            // Both halves of this pairing are shown in the menu bar app, so
            // the status-line half uses the user-facing wording rather than
            // the English text `quota-cli` prints.
            let localizedProbe = QuotaError.cacheDecodeFailed("LOCALIZATION_PROBE").userFacingDescription
            let localizedPrefix = localizedProbe.components(separatedBy: "LOCALIZATION_PROBE")[0]
            XCTAssertTrue(statusLineReason.hasPrefix(localizedPrefix))
            XCTAssertTrue(oauthReason.contains("synthetic OAuth failure"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRejectsSnapshotCapturedAfterItsResetWindow() async throws {
        let cacheURL = tempDirectory.appendingPathComponent("claude-latest.json")
        try """
        {
          "fiveHour": { "used_percentage": 23.5, "resets_at": 1779998000 },
          "sevenDay": { "used_percentage": 41.2, "resets_at": 1780500000 },
          "capturedAt": 1779999000
        }
        """.write(to: cacheURL, atomically: true, encoding: .utf8)

        let provider = makeProvider(cacheURL: cacheURL)
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected an error")
        } catch QuotaError.claudeOAuthFallbackFailed(let statusLineReason, _) {
            XCTAssertTrue(statusLineReason.contains("later than the reported reset time"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRejectsStatusLineCapturedTooFarInFuture() async throws {
        let cacheURL = tempDirectory.appendingPathComponent("claude-latest.json")
        try """
        {
          "fiveHour": { "used_percentage": 23.5, "resets_at": 1781000000 },
          "capturedAt": \(fixedNow.timeIntervalSince1970 + 600)
        }
        """.write(to: cacheURL, atomically: true, encoding: .utf8)

        let provider = makeProvider(cacheURL: cacheURL)
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected an error")
        } catch QuotaError.claudeOAuthFallbackFailed(let statusLineReason, _) {
            XCTAssertTrue(statusLineReason.contains("too far in the future"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUnchangedStatusLineUsesOAuthOnNextFetch() async throws {
        let cacheURL = tempDirectory.appendingPathComponent("claude-latest.json")
        try validStatusLineJSON().write(to: cacheURL, atomically: true, encoding: .utf8)

        let oauthSnapshot = makeOAuthSnapshot()
        let recorder = OAuthSnapshotRecorder(snapshot: oauthSnapshot)
        let provider = makeProvider(
            cacheURL: cacheURL,
            oauth: { _, _ in try await recorder.fetch() }
        )

        let first = try await provider.fetchSnapshotResult(userInitiated: false)
        let second = try await provider.fetchSnapshotResult(userInitiated: false)

        XCTAssertEqual(first.source, .statusLine)
        XCTAssertEqual(second.source, .oauthUsage)
        let fetchCount = await recorder.fetchCount()
        XCTAssertEqual(fetchCount, 1)
    }

    func testStaleStatusLineOAuthFailureKeepsSnapshotAndWarning() async throws {
        let cacheURL = tempDirectory.appendingPathComponent("claude-latest.json")
        try validStatusLineJSON(capturedAt: fixedNow.timeIntervalSince1970 - 600)
            .write(to: cacheURL, atomically: true, encoding: .utf8)

        let provider = makeProvider(cacheURL: cacheURL)
        let result = try await provider.fetchSnapshotResult(userInitiated: false)

        XCTAssertEqual(result.source, .statusLine)
        XCTAssertEqual(result.snapshot.session.usedPercent, 23.5)
        XCTAssertTrue(result.warning?.contains("synthetic OAuth failure") == true)
    }

    func testEmptyStatusLineCannotBecomeFallbackSnapshot() async throws {
        let cacheURL = tempDirectory.appendingPathComponent("claude-latest.json")
        try """
        {
          "fiveHour": { "resets_at": 1780000000 },
          "sevenDay": null,
          "capturedAt": 1779999000
        }
        """.write(to: cacheURL, atomically: true, encoding: .utf8)

        let provider = makeProvider(cacheURL: cacheURL)
        do {
            _ = try await provider.fetchSnapshotResult(userInitiated: false)
            XCTFail("expected both sources to fail")
        } catch QuotaError.claudeOAuthFallbackFailed(let statusLineReason, _) {
            XCTAssertTrue(statusLineReason.contains("does not contain any quota windows"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFallbackResultDoesNotReplaceNewerOAuthSnapshot() {
        let newer = makeOAuthSnapshot()
        let older = QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: 50),
            capturedAt: fixedNow.addingTimeInterval(-600)
        )
        let result = ClaudeQuotaFetchResult(
            snapshot: older,
            source: .statusLine,
            warning: "OAuth Usage failed"
        )

        XCTAssertFalse(result.isNewer(than: newer))
        XCTAssertTrue(result.isNewer(than: nil))
    }

    func testFreshChangedStatusLineRemainsPrimaryForManualRefresh() async throws {
        let cacheURL = tempDirectory.appendingPathComponent("claude-latest.json")
        try validStatusLineJSON().write(to: cacheURL, atomically: true, encoding: .utf8)
        let recorder = OAuthSnapshotRecorder(snapshot: makeOAuthSnapshot())
        let provider = makeProvider(
            cacheURL: cacheURL,
            oauth: { _, _ in try await recorder.fetch() }
        )

        let result = try await provider.fetchSnapshotResult(userInitiated: true)

        XCTAssertEqual(result.source, .statusLine)
        let fetchCount = await recorder.fetchCount()
        XCTAssertEqual(fetchCount, 0)
    }

    func testOAuthCoordinatorCachesSeparatelyForEachToken() async throws {
        let currentDate = fixedNow
        let recorder = TokenOAuthRecorder(now: currentDate)
        let coordinator = ClaudeOAuthRequestCoordinator(
            minimumBackgroundInterval: 120,
            now: { currentDate },
            fetchSnapshot: { token in await recorder.fetch(token: token) }
        )

        let firstA = try await coordinator.fetch(accessToken: "token-a", userInitiated: false)
        let cachedA = try await coordinator.fetch(accessToken: "token-a", userInitiated: false)
        let firstB = try await coordinator.fetch(accessToken: "token-b", userInitiated: false)

        XCTAssertEqual(firstA.session.usedPercent, 11)
        XCTAssertEqual(cachedA.session.usedPercent, 11)
        XCTAssertEqual(firstB.session.usedPercent, 22)
        let requestedTokens = await recorder.tokens()
        XCTAssertEqual(requestedTokens, ["token-a", "token-b"])
    }

    func testOAuthCoordinatorDoesNotShareInFlightRequestAcrossTokens() async throws {
        let currentDate = fixedNow
        let recorder = BlockingTokenOAuthRecorder(now: currentDate)
        let coordinator = ClaudeOAuthRequestCoordinator(
            minimumBackgroundInterval: 120,
            now: { currentDate },
            fetchSnapshot: { token in await recorder.fetch(token: token) }
        )

        let taskA = Task {
            try await coordinator.fetch(accessToken: "token-a", userInitiated: false)
        }
        let requestedA = await waitUntilRequested("token-a", recorder: recorder)
        XCTAssertTrue(requestedA)

        let taskB = Task {
            try await coordinator.fetch(accessToken: "token-b", userInitiated: false)
        }
        let requestedB = await waitUntilRequested("token-b", recorder: recorder)
        XCTAssertTrue(requestedB)

        await recorder.resume(token: "token-a")
        await recorder.resume(token: "token-b")
        let snapshotA = try await taskA.value
        let snapshotB = try await taskB.value

        XCTAssertEqual(snapshotA.session.usedPercent, 11)
        XCTAssertEqual(snapshotB.session.usedPercent, 22)
    }

    func testOAuthCoordinatorRateLimitIsScopedToToken() async throws {
        let currentDate = fixedNow
        let recorder = RateLimitedTokenOAuthRecorder(now: currentDate)
        let coordinator = ClaudeOAuthRequestCoordinator(
            minimumBackgroundInterval: 120,
            now: { currentDate },
            fetchSnapshot: { token in try await recorder.fetch(token: token) }
        )

        do {
            _ = try await coordinator.fetch(accessToken: "token-a", userInitiated: true)
            XCTFail("expected token-a rate limit")
        } catch ClaudeOAuthUsageError.rateLimited {
            // expected
        }
        let tokenB = try await coordinator.fetch(accessToken: "token-b", userInitiated: true)

        XCTAssertEqual(tokenB.session.usedPercent, 22)
    }

    func testExpiredStatusLineWindowFallsBackToOAuth() async throws {
        let cacheURL = tempDirectory.appendingPathComponent("claude-latest.json")
        let capturedAt = fixedNow.timeIntervalSince1970 - 30
        try """
        {
          "fiveHour": { "used_percentage": 23.5, "resets_at": \(fixedNow.timeIntervalSince1970 - 1) },
          "sevenDay": { "used_percentage": 41.2, "resets_at": \(fixedNow.timeIntervalSince1970 + 10_000) },
          "capturedAt": \(capturedAt)
        }
        """.write(to: cacheURL, atomically: true, encoding: .utf8)

        let provider = makeProvider(
            cacheURL: cacheURL,
            oauth: { [oauthSnapshot = makeOAuthSnapshot()] _, _ in oauthSnapshot }
        )
        let result = try await provider.fetchSnapshotResult(userInitiated: false)

        XCTAssertEqual(result.source, .oauthUsage)
    }

    func testCacheUpdatesEmitsWhenDirectoryChanges() async throws {
        let cacheURL = tempDirectory.appendingPathComponent("claude-latest.json")
        let provider = makeProvider(cacheURL: cacheURL)
        let updateReceived = expectation(description: "cache update")

        // Constructing the stream synchronously opens and resumes the file
        // watcher before the write. Creating it inside the child Task races
        // fast CI runners, where the write can win before observation starts.
        let updates = provider.cacheUpdates()
        let observation = Task {
            for await _ in updates {
                updateReceived.fulfill()
                return
            }
        }

        try """
        {
          "fiveHour": { "used_percentage": 25, "resets_at": 1780000000 },
          "capturedAt": 1779999000
        }
        """.write(to: cacheURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [updateReceived], timeout: 1)
        observation.cancel()
    }

    private func makeProvider(
        cacheURL: URL,
        oauth: @escaping @Sendable (String, Bool) async throws -> QuotaSnapshot = { _, _ in
            throw ClaudeProviderTestError.oauthFailure
        }
    ) -> ClaudeQuotaProvider {
        let currentDate = fixedNow
        return ClaudeQuotaProvider(
            cacheURL: cacheURL,
            statusLineFreshnessInterval: 120,
            now: { currentDate },
            loadCredentials: {
                ClaudeOAuthCredentials(
                    accessToken: "test-access-token",
                    expiresAt: currentDate.addingTimeInterval(3_600),
                    scopes: ["user:profile"]
                )
            },
            fetchOAuthSnapshot: oauth
        )
    }

    private func makeOAuthSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: 12, resetAt: fixedNow.addingTimeInterval(3_600)),
            weekly: QuotaWindow(usedPercent: 34, resetAt: fixedNow.addingTimeInterval(86_400)),
            capturedAt: fixedNow
        )
    }

    private func validStatusLineJSON(capturedAt: TimeInterval? = nil) -> String {
        """
        {
          "fiveHour": { "used_percentage": 23.5, "resets_at": 1780000000 },
          "sevenDay": { "used_percentage": 41.2, "resets_at": 1780500000 },
          "capturedAt": \(capturedAt ?? 1_779_999_000)
        }
        """
    }

    private func waitUntilRequested(
        _ token: String,
        recorder: BlockingTokenOAuthRecorder
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await recorder.hasRequested(token: token) {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

private enum ClaudeProviderTestError: LocalizedError, Sendable {
    case oauthFailure

    var errorDescription: String? { "synthetic OAuth failure" }
}

private actor OAuthSnapshotRecorder {
    private let snapshot: QuotaSnapshot
    private var count = 0

    init(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
    }

    func fetch() throws -> QuotaSnapshot {
        count += 1
        return snapshot
    }

    func fetchCount() -> Int { count }
}

private actor TokenOAuthRecorder {
    private let now: Date
    private var requestedTokens: [String] = []

    init(now: Date) {
        self.now = now
    }

    func fetch(token: String) -> QuotaSnapshot {
        requestedTokens.append(token)
        return QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: token == "token-a" ? 11 : 22),
            capturedAt: now
        )
    }

    func tokens() -> [String] { requestedTokens }
}

private actor BlockingTokenOAuthRecorder {
    private let now: Date
    private var requestedTokens: Set<String> = []
    private var continuations: [String: CheckedContinuation<QuotaSnapshot, Never>] = [:]

    init(now: Date) {
        self.now = now
    }

    func fetch(token: String) async -> QuotaSnapshot {
        requestedTokens.insert(token)
        return await withCheckedContinuation { continuation in
            continuations[token] = continuation
        }
    }

    func hasRequested(token: String) -> Bool {
        requestedTokens.contains(token)
    }

    func resume(token: String) {
        continuations.removeValue(forKey: token)?.resume(returning: QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: token == "token-a" ? 11 : 22),
            capturedAt: now
        ))
    }
}

private actor RateLimitedTokenOAuthRecorder {
    private let now: Date

    init(now: Date) {
        self.now = now
    }

    func fetch(token: String) throws -> QuotaSnapshot {
        if token == "token-a" {
            throw ClaudeOAuthUsageError.rateLimited(
                retryAfter: now.addingTimeInterval(300)
            )
        }
        return QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: 22),
            capturedAt: now
        )
    }
}
#endif
