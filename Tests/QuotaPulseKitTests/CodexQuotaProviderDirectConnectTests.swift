#if os(macOS)
import XCTest
@testable import QuotaPulseKit

/// Exercises `CodexQuotaProvider`'s two-level chain (account-direct first,
/// app-server fallback) in isolation from the real network and the real
/// `codex` binary, via the package-internal initializer that injects both
/// collaborators directly.
final class CodexQuotaProviderDirectConnectTests: XCTestCase {
    private var appServerScriptURL: URL!

    override func setUpWithError() throws {
        appServerScriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-codex-chain-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        while IFS= read -r line; do
          method=$(echo "$line" | sed -E 's/.*"method":"([^"]+)".*/\\1/')
          id=$(echo "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          case "$method" in
            initialize)
              printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id"
              ;;
            initialized) ;;
            account/rateLimits/read)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300,"resetsAt":1780000000},"secondary":null}}}\\n' "$id"
              ;;
          esac
        done
        """
        try script.write(to: appServerScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appServerScriptURL.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: appServerScriptURL)
    }

    func testNoCredentialGoesStraightToAppServerWithoutTryingDirect() async throws {
        let (provider, client) = makeProvider(
            loadCredential: { nil },
            fetchDirectSnapshot: { _, _, _ in throw TestError.shouldNotBeCalled }
        )
        defer { client.stop() }

        let result = try await provider.fetchSnapshotResult(userInitiated: true)

        XCTAssertEqual(result.source, .appServer)
        XCTAssertNil(result.warning)
    }

    /// The regression behind "有数据还报没有找到 codex 命令行工具": a keychain
    /// read the user denied (or a failed refresh) used to be swallowed into
    /// "not logged in", sending a signed-in user down the CLI path and
    /// surfacing "install the codex CLI" as the error. The real failure must
    /// propagate untouched instead.
    func testCredentialLoadFailurePropagatesInsteadOfFallingBackToAppServer() async {
        let (provider, client) = makeProvider(
            executablePath: "/nonexistent/codex",
            loadCredential: { throw OAuthTokenStoreError.keychainFailure(-25293) },
            fetchDirectSnapshot: { _, _, _ in throw TestError.shouldNotBeCalled }
        )
        defer { client.stop() }

        do {
            _ = try await provider.fetchSnapshotResult(userInitiated: true)
            XCTFail("expected the keychain failure to propagate")
        } catch let error as OAuthTokenStoreError {
            XCTAssertEqual(error, .keychainFailure(-25293))
        } catch {
            // In particular not appServerLaunchFailed/executableNotFound —
            // the CLI fallback must not even be attempted.
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The regression behind "退出登录后提示先去装 codex CLI": with nothing
    /// signed in, a missing `codex` binary must surface as "connect your
    /// account" — signing in needs no install — not as the raw
    /// executableNotFound install instruction.
    func testNoStoredLoginMapsMissingCLIToCodexNotConnected() {
        let mapped = CodexQuotaProvider.noStoredLoginError(
            from: QuotaError.executableNotFound("codex")
        )

        XCTAssertEqual(mapped as? QuotaError, .codexNotConnected)
    }

    /// Only the missing-CLI case is rewritten: an installed CLI that fails
    /// for its own reasons (say, `codex login` never ran, so app-server
    /// exits) keeps its more specific error.
    func testNoStoredLoginKeepsOtherAppServerErrorsAsIs() {
        let mapped = CodexQuotaProvider.noStoredLoginError(
            from: QuotaError.appServerExited(1)
        )

        XCTAssertEqual(mapped as? QuotaError, .appServerExited(1))
    }

    func testCredentialWithoutAccountIDGoesStraightToAppServer() async throws {
        let (provider, client) = makeProvider(
            loadCredential: { self.makeCredential(accountID: nil) },
            fetchDirectSnapshot: { _, _, _ in throw TestError.shouldNotBeCalled }
        )
        defer { client.stop() }

        let result = try await provider.fetchSnapshotResult(userInitiated: true)

        XCTAssertEqual(result.source, .appServer)
    }

    func testSuccessfulDirectFetchReturnsAccountDirectSourceWithNoWarning() async throws {
        let (provider, client) = makeProvider(
            loadCredential: { self.makeCredential(accountID: "acct-1") },
            fetchDirectSnapshot: { accessToken, accountID, _ in
                XCTAssertEqual(accessToken, "access-token")
                XCTAssertEqual(accountID, "acct-1")
                return Self.makeSnapshot(usedPercent: 10)
            }
        )
        defer { client.stop() }

        let result = try await provider.fetchSnapshotResult(userInitiated: true)

        XCTAssertEqual(result.source, .accountDirect)
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.snapshot.session.usedPercent, 10)
    }

    func testUserInitiatedFlagIsThreadedThroughToDirectFetch() async throws {
        let (provider, client) = makeProvider(
            loadCredential: { self.makeCredential(accountID: "acct-1") },
            fetchDirectSnapshot: { _, _, userInitiated in
                XCTAssertTrue(userInitiated)
                return Self.makeSnapshot(usedPercent: 5)
            }
        )
        defer { client.stop() }

        _ = try await provider.fetchSnapshotResult(userInitiated: true)
    }

    func testPlainFetchSnapshotDefaultsToBackgroundNotUserInitiated() async throws {
        let (provider, client) = makeProvider(
            loadCredential: { self.makeCredential(accountID: "acct-1") },
            fetchDirectSnapshot: { _, _, userInitiated in
                XCTAssertFalse(userInitiated)
                return Self.makeSnapshot(usedPercent: 5)
            }
        )
        defer { client.stop() }

        _ = try await provider.fetchSnapshot()
    }

    func testHardFailureDegradesToAppServerImmediatelyWithWarning() async throws {
        let (provider, client) = makeProvider(
            loadCredential: { self.makeCredential(accountID: "acct-1") },
            fetchDirectSnapshot: { _, _, _ in throw CodexUsageError.invalidResponse("bad shape") }
        )
        defer { client.stop() }

        let result = try await provider.fetchSnapshotResult(userInitiated: true)

        XCTAssertEqual(result.source, .appServer)
        XCTAssertEqual(result.snapshot.session.usedPercent, 50)
        XCTAssertTrue(result.warning?.contains("bad shape") == true)
    }

    func testSingleTransientNetworkFailureSurfacesAsIsWithoutTryingAppServer() async {
        let (provider, client) = makeProvider(
            loadCredential: { self.makeCredential(accountID: "acct-1") },
            fetchDirectSnapshot: { _, _, _ in throw CodexUsageError.network("offline") }
        )
        defer { client.stop() }

        do {
            _ = try await provider.fetchSnapshotResult(userInitiated: true)
            XCTFail("expected the network error to propagate as-is")
        } catch CodexUsageError.network(let reason) {
            XCTAssertEqual(reason, "offline")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testThreeConsecutiveTransientFailuresDegradeToAppServerOnTheThird() async throws {
        let script = ScriptedDirectFetch(steps: [
            .fail(.network("offline-1")),
            .fail(.network("offline-2")),
            .fail(.network("offline-3")),
        ])
        let (provider, client) = makeProvider(
            loadCredential: { self.makeCredential(accountID: "acct-1") },
            fetchDirectSnapshot: { accessToken, accountID, _ in
                try await script.next(accessToken: accessToken, accountID: accountID)
            }
        )
        defer { client.stop() }

        for _ in 0..<2 {
            do {
                _ = try await provider.fetchSnapshotResult(userInitiated: true)
                XCTFail("expected the network error to propagate on attempts 1 and 2")
            } catch CodexUsageError.network {
                // expected
            }
        }

        let result = try await provider.fetchSnapshotResult(userInitiated: true)

        XCTAssertEqual(result.source, .appServer)
        XCTAssertNotNil(result.warning)
        let callCount = await script.callCount
        XCTAssertEqual(callCount, 3)
    }

    func testSuccessResetsTheFailureCounter() async throws {
        let script = ScriptedDirectFetch(steps: [
            .fail(.network("offline-1")),
            .fail(.network("offline-2")),
            .succeed(Self.makeSnapshot(usedPercent: 7)),
            .fail(.network("offline-3")),
        ])
        let (provider, client) = makeProvider(
            loadCredential: { self.makeCredential(accountID: "acct-1") },
            fetchDirectSnapshot: { accessToken, accountID, _ in
                try await script.next(accessToken: accessToken, accountID: accountID)
            }
        )
        defer { client.stop() }

        for _ in 0..<2 {
            do {
                _ = try await provider.fetchSnapshotResult(userInitiated: true)
                XCTFail("expected failure")
            } catch CodexUsageError.network {
                // expected
            }
        }
        let recovered = try await provider.fetchSnapshotResult(userInitiated: true)
        XCTAssertEqual(recovered.source, .accountDirect)

        // The counter should have been reset by the success above, so this
        // single subsequent failure must surface as-is rather than
        // immediately degrading (which would only be correct if the earlier
        // two failures were still being counted).
        do {
            _ = try await provider.fetchSnapshotResult(userInitiated: true)
            XCTFail("expected the network error to propagate as-is")
        } catch CodexUsageError.network(let reason) {
            XCTAssertEqual(reason, "offline-3")
        }
    }

    func testBothDirectAndAppServerFailingThrowsACombinedError() async {
        let (provider, client) = makeProvider(
            executablePath: "/nonexistent/codex",
            loadCredential: { self.makeCredential(accountID: "acct-1") },
            fetchDirectSnapshot: { _, _, _ in throw CodexUsageError.invalidResponse("bad shape") }
        )
        defer { client.stop() }

        do {
            _ = try await provider.fetchSnapshotResult(userInitiated: true)
            XCTFail("expected a combined failure")
        } catch QuotaError.codexDirectFallbackFailed(let directReason, let appServerReason) {
            XCTAssertTrue(directReason.contains("bad shape"))
            XCTAssertFalse(appServerReason.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeProvider(
        executablePath: String? = nil,
        loadCredential: @escaping @Sendable () async throws -> OAuthCredential?,
        fetchDirectSnapshot: @escaping @Sendable (String, String, Bool) async throws -> QuotaSnapshot
    ) -> (CodexQuotaProvider, CodexAppServerClient) {
        let client = CodexAppServerClient(executablePath: executablePath ?? appServerScriptURL.path)
        let provider = CodexQuotaProvider(
            client: client,
            requestTimeout: 5,
            retryDelay: .milliseconds(10),
            loadCredential: loadCredential,
            fetchDirectSnapshot: fetchDirectSnapshot
        )
        return (provider, client)
    }

    private func makeCredential(accountID: String?) -> OAuthCredential {
        OAuthCredential(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3_600),
            scopes: [],
            accountLabel: "person@example.com",
            accountID: accountID,
            obtainedAt: Date()
        )
    }

    private static func makeSnapshot(usedPercent: Double) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .codex,
            session: QuotaWindow(usedPercent: usedPercent),
            capturedAt: Date()
        )
    }
}

private enum TestError: Error {
    case shouldNotBeCalled
}

/// Answers `fetchDirectSnapshot` calls with a pre-scripted sequence of
/// failures/successes, tracking how many calls were actually made — an
/// actor so it stays safe to call from the `@Sendable` closure the provider
/// invokes.
private actor ScriptedDirectFetch {
    enum Step {
        case fail(CodexUsageError)
        case succeed(QuotaSnapshot)
    }

    private var steps: [Step]
    private(set) var callCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func next(accessToken: String, accountID: String) throws -> QuotaSnapshot {
        callCount += 1
        guard !steps.isEmpty else {
            throw TestError.shouldNotBeCalled
        }
        switch steps.removeFirst() {
        case .fail(let error):
            throw error
        case .succeed(let snapshot):
            return snapshot
        }
    }
}
#endif
