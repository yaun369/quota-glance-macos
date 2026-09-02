#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class ClaudeConfigLocatorTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func makeLocator(
        environment: [String: String] = [:],
        loginShellValue: @escaping @Sendable (String, Bool) -> String? = { _, _ in nil }
    ) -> ClaudeConfigLocator {
        ClaudeConfigLocator(
            environment: environment,
            homeDirectory: home,
            loginShellValue: loginShellValue
        )
    }

    func testDefaultsToTheStandardDirectory() {
        XCTAssertEqual(makeLocator().directory().path, "/Users/someone/.claude")
        XCTAssertEqual(makeLocator().settingsURL().path, "/Users/someone/.claude/settings.json")
        XCTAssertEqual(
            makeLocator().credentialsURL().path,
            "/Users/someone/.claude/.credentials.json"
        )
    }

    /// `quota-cli` and a terminal-launched app inherit the variable directly.
    func testUsesTheInheritedVariableWhenThereIsOne() {
        let locator = makeLocator(environment: ["CLAUDE_CONFIG_DIR": "/opt/claude-config"])

        XCTAssertEqual(locator.settingsURL().path, "/opt/claude-config/settings.json")
    }

    /// The case this exists for: a GUI app inherits no shell exports, so the
    /// value has to come from a login shell.
    func testFallsBackToTheLoginShellWhenTheVariableWasNotInherited() {
        let locator = makeLocator(loginShellValue: { name, allowSpawn in
            name == "CLAUDE_CONFIG_DIR" && allowSpawn ? "/opt/claude-config" : nil
        })

        XCTAssertEqual(locator.settingsURL().path, "/opt/claude-config/settings.json")
    }

    /// The main actor reads this while building the menu, so it must answer
    /// with the fallback rather than block on a shell.
    func testDoesNotSpawnALoginShellWhenTheCallerForbidsIt() {
        let locator = makeLocator(loginShellValue: { _, allowSpawn in
            allowSpawn ? "/opt/claude-config" : nil
        })

        XCTAssertEqual(
            locator.settingsURL(allowLoginShell: false).path,
            "/Users/someone/.claude/settings.json"
        )
    }

    func testPrefersTheInheritedVariableOverTheLoginShell() {
        let locator = makeLocator(
            environment: ["CLAUDE_CONFIG_DIR": "/opt/inherited"],
            loginShellValue: { _, _ in "/opt/from-shell" }
        )

        XCTAssertEqual(locator.directory().path, "/opt/inherited")
    }

    func testExpandsATildeValue() {
        XCTAssertEqual(
            makeLocator(environment: ["CLAUDE_CONFIG_DIR": "~/config/claude"]).directory().path,
            "/Users/someone/config/claude"
        )
        XCTAssertEqual(
            makeLocator(environment: ["CLAUDE_CONFIG_DIR": "~"]).directory().path,
            "/Users/someone"
        )
    }

    /// A GUI app's working directory is unrelated to wherever the user was
    /// standing when they set this, so a relative value cannot be honoured.
    func testIgnoresAValueThatIsNotAnAbsolutePath() {
        XCTAssertEqual(
            makeLocator(environment: ["CLAUDE_CONFIG_DIR": "config/claude"]).directory().path,
            "/Users/someone/.claude"
        )
    }

    func testIgnoresAnEmptyOrWhitespaceValue() {
        XCTAssertEqual(
            makeLocator(environment: ["CLAUDE_CONFIG_DIR": "   "]).directory().path,
            "/Users/someone/.claude"
        )
        XCTAssertEqual(
            makeLocator(environment: ["CLAUDE_CONFIG_DIR": ""]).directory().path,
            "/Users/someone/.claude"
        )
    }

    func testTrimsTheNewlineALoginShellLeavesBehind() {
        let locator = makeLocator(loginShellValue: { _, _ in "/opt/claude-config\n" })

        XCTAssertEqual(locator.directory().path, "/opt/claude-config")
    }

    // MARK: - Installer wiring

    /// The installer must follow the relocated directory, but keep its own
    /// `~/.agent-quota` artifacts where they are.
    func testInstallerFollowsTheConfigDirectoryWithoutMovingItsOwnArtifacts() {
        let installer = ClaudeStatusLineInstaller(
            agentQuotaDirectory: URL(fileURLWithPath: "/Users/someone/.agent-quota", isDirectory: true)
        )

        XCTAssertEqual(
            installer.claudeSettingsURL,
            ClaudeConfigLocator.shared.settingsURL(allowLoginShell: false)
        )
        XCTAssertEqual(installer.scriptURL.path, "/Users/someone/.agent-quota/claude-status.sh")
        XCTAssertEqual(installer.cacheURL.path, "/Users/someone/.agent-quota/claude-latest.json")
    }

    func testAnExplicitlyPinnedSettingsURLStillWins() {
        let pinned = URL(fileURLWithPath: "/tmp/pinned/settings.json")
        let installer = ClaudeStatusLineInstaller(
            agentQuotaDirectory: URL(fileURLWithPath: "/tmp/agent-quota", isDirectory: true),
            claudeSettingsURL: pinned
        )

        XCTAssertEqual(installer.claudeSettingsURL, pinned)
    }

    // MARK: - Real login shell

    /// Exercises the real `Process` plumbing for a variable that is always
    /// exported, so the probe itself is covered and not just its parsing.
    func testRealLoginShellReadsAnExportedVariable() throws {
        let value = LoginShellLookup().environmentValue(of: "HOME", allowSpawn: true)

        XCTAssertEqual(value, NSHomeDirectory())
    }

    func testRealLoginShellReturnsNilForAVariableThatIsNotSet() {
        let value = LoginShellLookup().environmentValue(
            of: "QUOTAPULSE_DEFINITELY_NOT_SET",
            allowSpawn: true
        )

        XCTAssertNil(value)
    }
}
#endif
