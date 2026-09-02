#if os(macOS)
import XCTest
@testable import QuotaPulseKit

/// Exercises the real newline-delimited JSON-RPC framing against a fake
/// stand-in for `codex app-server`, since the real `codex` binary cannot be
/// spawned as a subprocess in this test environment.
final class CodexQuotaProviderTests: XCTestCase {
    private var fakeServerURL: URL!

    override func setUpWithError() throws {
        fakeServerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-codex-\(UUID().uuidString).sh")

        // Behave like a strict app-server: quota reads only succeed after
        // initialize has completed and the client has sent initialized.
        let script = """
        #!/bin/bash
        initialized=0
        while IFS= read -r line; do
          method=$(echo "$line" | sed -E 's/.*"method":"([^"]+)".*/\\1/')
          id=$(echo "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          case "$method" in
            initialize)
              printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id"
              ;;
            initialized)
              initialized=1
              ;;
            account/rateLimits/read)
              if [ "$initialized" -ne 1 ]; then
                printf '{"jsonrpc":"2.0","id":%s,"error":{"message":"Not initialized"}}\\n' "$id"
                continue
              fi
              printf '{"jsonrpc":"2.0","id":%s,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1780000000},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1780500000}}}}\\n' "$id"
              printf '{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":26}}}}\\n'
              ;;
          esac
        done
        """
        try script.write(to: fakeServerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeServerURL.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fakeServerURL)
    }

    func testFetchSnapshotParsesPrimaryAndSecondaryWindows() async throws {
        // The fake script ignores the "app-server" argument entirely and
        // just answers whatever request line it receives, so pointing the
        // client at it exercises the same request/response path a real
        // Codex would.
        let client = CodexAppServerClient(executablePath: fakeServerURL.path)
        let provider = makeAppServerOnlyProvider(client: client)

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.session.usedPercent, 25)
        XCTAssertEqual(snapshot.session.resetAt, Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(snapshot.weekly.usedPercent, 42)
        XCTAssertEqual(snapshot.weekly.resetAt, Date(timeIntervalSince1970: 1_780_500_000))

        client.stop()
    }

    func testRateLimitNotificationIsExposedAsAnUpdateTrigger() async throws {
        let client = CodexAppServerClient(executablePath: fakeServerURL.path)
        let provider = makeAppServerOnlyProvider(client: client)
        let updateReceived = expectation(description: "rate-limit update")

        let observation = Task {
            for await _ in provider.rateLimitUpdates() {
                updateReceived.fulfill()
                return
            }
        }

        _ = try await provider.fetchSnapshot()
        await fulfillment(of: [updateReceived], timeout: 1)

        observation.cancel()
        client.stop()
    }

    func testTimeoutRestartsAppServerAndRetriesOnce() async throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-codex-state-\(UUID().uuidString)")
        let retryServerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-codex-retry-\(UUID().uuidString).sh")
        defer {
            try? FileManager.default.removeItem(at: stateURL)
            try? FileManager.default.removeItem(at: retryServerURL)
        }

        let script = """
        #!/bin/bash
        initialized=0
        while IFS= read -r line; do
          method=$(echo "$line" | sed -E 's/.*"method":"([^"]+)".*/\\1/')
          id=$(echo "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          case "$method" in
            initialize)
              printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id"
              ;;
            initialized)
              initialized=1
              ;;
            account/rateLimits/read)
              # mkdir is atomic across the old process and its replacement:
              # exactly the first request sleeps past the timeout.
              if mkdir "\(stateURL.path)" 2>/dev/null; then
                sleep 2
              fi
              printf '{"jsonrpc":"2.0","id":%s,"result":{"rateLimits":{"primary":{"usedPercent":30,"windowDurationMins":300,"resetsAt":1780000000},"secondary":null}}}\\n' "$id"
              ;;
          esac
        done
        """
        try script.write(to: retryServerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: retryServerURL.path
        )

        let client = CodexAppServerClient(executablePath: retryServerURL.path)
        let provider = makeAppServerOnlyProvider(
            client: client,
            // GitHub's macOS runners may need a few hundred milliseconds to
            // launch and initialize even the tiny shell fake. Keep the first
            // response well beyond this timeout while leaving enough room
            // for the restarted process to answer reliably.
            requestTimeout: 1,
            retryDelay: .milliseconds(10)
        )

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.session.usedPercent, 30)
        client.stop()
    }

    func testRequestFailsWhenExecutablePathIsBogus() async {
        // A non-nil but nonexistent path skips the "not found" lookup and
        // fails at `Process.run()` instead, surfacing as a launch failure.
        let client = CodexAppServerClient(executablePath: "/nonexistent/codex")
        let provider = makeAppServerOnlyProvider(client: client)

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected an error")
        } catch QuotaError.appServerLaunchFailed {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Pins the provider to the app-server path via the injecting
    /// initializer. The public initializer would read the user's real
    /// `QuotaPulse-OAuth-Codex` Keychain item on every fetch (and, with a
    /// stored login, hit the real usage API) — a unit test must never be
    /// able to do either.
    private func makeAppServerOnlyProvider(
        client: CodexAppServerClient,
        requestTimeout: TimeInterval = 15,
        retryDelay: Duration = .milliseconds(300)
    ) -> CodexQuotaProvider {
        CodexQuotaProvider(
            client: client,
            requestTimeout: requestTimeout,
            retryDelay: retryDelay,
            loadCredential: { nil },
            fetchDirectSnapshot: { _, _, _ in
                XCTFail("direct fetch must not run when no credential is stored")
                throw CodexUsageError.invalidResponse("unexpected direct fetch")
            }
        )
    }

    func testCodexChildEnvironmentDoesNotInheritClaudeTokens() {
        let sanitized = CodexAppServerClient.sanitizedChildEnvironment([
            "PATH": "/usr/bin",
            "QUOTAPULSE_CLAUDE_OAUTH_TOKEN": "secret-a",
            "CLAUDE_CODE_OAUTH_TOKEN": "secret-b",
            "KEEP_ME": "yes",
        ])

        XCTAssertNil(sanitized["QUOTAPULSE_CLAUDE_OAUTH_TOKEN"])
        XCTAssertNil(sanitized["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(sanitized["PATH"], "/usr/bin")
        XCTAssertEqual(sanitized["KEEP_ME"], "yes")
    }

    /// `npm install -g @openai/codex` installs a `#!/usr/bin/env node`
    /// launcher, not a native binary. Launching it with the `PATH` a GUI app
    /// inherits fails with "env: node: No such file or directory", so the
    /// child has to be handed the directories `node` actually lives in.
    func testCodexChildEnvironmentCanReachNodeNextToTheLauncher() {
        let environment = CodexAppServerClient.childEnvironment(
            executablePath: "/Users/someone/.nvm/versions/node/v20.20.0/bin/codex",
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CLAUDE_CODE_OAUTH_TOKEN": "secret",
            ],
            searchDirectories: ["/opt/homebrew/bin"]
        )

        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(directories.first, "/Users/someone/.nvm/versions/node/v20.20.0/bin")
        XCTAssertTrue(directories.contains("/opt/homebrew/bin"))
        // The inherited entries stay reachable, so nothing that used to work
        // stops working.
        XCTAssertTrue(directories.contains("/usr/bin"))
        XCTAssertEqual(Set(directories).count, directories.count, "PATH must not repeat directories")
        XCTAssertNil(environment["CLAUDE_CODE_OAUTH_TOKEN"])
    }

    /// A GUI process can be launched with no `PATH` at all.
    func testCodexChildEnvironmentAlwaysKeepsTheSystemDirectoriesReachable() {
        let environment = CodexAppServerClient.childEnvironment(
            executablePath: "/opt/homebrew/bin/codex",
            environment: [:],
            searchDirectories: []
        )

        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(directories, ["/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    }
}
#endif
