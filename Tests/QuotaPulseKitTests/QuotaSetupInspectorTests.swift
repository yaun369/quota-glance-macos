#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class QuotaSetupInspectorTests: XCTestCase {
    private var root: URL!
    private var helperSourceURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        helperSourceURL = root.appendingPathComponent("bundled-claude-status-helper")
        try "#!/bin/bash\nexit 0\n".write(
            to: helperSourceURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperSourceURL.path
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeInstaller() -> ClaudeStatusLineInstaller {
        ClaudeStatusLineInstaller(
            agentQuotaDirectory: root.appendingPathComponent(".agent-quota", isDirectory: true),
            claudeSettingsURL: root.appendingPathComponent(".claude/settings.json"),
            helperSourceURL: helperSourceURL
        )
    }

    private func makeInspector(
        _ installer: ClaudeStatusLineInstaller,
        codexPath: String? = "/usr/local/bin/codex"
    ) -> QuotaSetupInspector {
        QuotaSetupInspector(
            installer: installer,
            resolveCodexPath: { codexPath }
        )
    }

    private func writeSettings(_ json: String, to installer: ClaudeStatusLineInstaller) throws {
        try FileManager.default.createDirectory(
            at: installer.claudeSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try json.write(to: installer.claudeSettingsURL, atomically: true, encoding: .utf8)
    }

    func testCodexIssueOnlyWhenExecutableIsMissing() {
        let installer = makeInstaller()
        XCTAssertNil(makeInspector(installer).codexIssue(hasAccountCredential: false))
        XCTAssertEqual(
            makeInspector(installer, codexPath: nil).codexIssue(hasAccountCredential: false),
            .codexNotConnected
        )
    }

    func testCodexIssueSuggestsConnectingTheAccount() {
        let installer = makeInstaller()
        XCTAssertEqual(
            makeInspector(installer, codexPath: nil).codexIssue(hasAccountCredential: false)?.remedy,
            .connectAccount(provider: .codex)
        )
    }

    func testCodexHasNoIssueWhenAnAccountCredentialIsStoredEvenWithoutTheCLI() {
        let installer = makeInstaller()
        XCTAssertNil(
            makeInspector(installer, codexPath: nil).codexIssue(hasAccountCredential: true)
        )
    }

    func testClaudeReportsNotInstalledWithoutSettings() {
        let installer = makeInstaller()
        XCTAssertEqual(installer.installationState(), .notConfigured)
        XCTAssertEqual(makeInspector(installer).claudeIssue(), .claudeStatusLineNotInstalled)
    }

    func testClaudeReportsAnotherCommandWithoutOfferingASilentOverwrite() throws {
        let installer = makeInstaller()
        try writeSettings(
            #"{ "statusLine": { "type": "command", "command": "/some/other/script.sh" } }"#,
            to: installer
        )

        XCTAssertEqual(
            installer.installationState(),
            .configuredForAnotherCommand("/some/other/script.sh")
        )
        XCTAssertEqual(
            makeInspector(installer).claudeIssue(),
            .claudeStatusLineUsedByAnotherCommand("/some/other/script.sh")
        )
        // The remedy for someone else's status line must be the confirming
        // variant, since installing over it discards their configuration.
        XCTAssertEqual(
            makeInspector(installer).claudeIssue()?.remedy,
            .installClaudeStatusLine(overwritesExisting: true)
        )
    }

    func testClaudeAwaitsFirstReadingOnceInstalled() throws {
        let installer = makeInstaller()
        try installer.install()

        XCTAssertEqual(installer.installationState(), .installed)
        XCTAssertFalse(installer.hasCapturedReading())
        XCTAssertEqual(makeInspector(installer).claudeIssue(), .claudeAwaitingFirstReading)
        // Nothing for the app to click: only Claude Code can produce it.
        XCTAssertNil(QuotaSetupIssue.claudeAwaitingFirstReading.remedy)
    }

    func testClaudeHasNoIssueOnceAReadingExists() throws {
        let installer = makeInstaller()
        try installer.install()
        try Data("{}".utf8).write(to: installer.cacheURL)

        XCTAssertTrue(installer.hasCapturedReading())
        XCTAssertNil(makeInspector(installer).claudeIssue())
    }

    /// A settings.json left pointing at a script that no longer exists (wiped
    /// ~/.agent-quota, migrated home directory) must lead to "install", not
    /// to a confusing "already configured" that never produces data.
    func testDanglingScriptReferenceCountsAsNotConfigured() throws {
        let installer = makeInstaller()
        try installer.install()
        try FileManager.default.removeItem(at: installer.scriptURL)

        XCTAssertEqual(installer.installationState(), .notConfigured)
        XCTAssertEqual(makeInspector(installer).claudeIssue(), .claudeStatusLineNotInstalled)
    }

    func testDanglingHelperReferenceCountsAsNotConfigured() throws {
        let installer = makeInstaller()
        try installer.install()
        try FileManager.default.removeItem(at: installer.helperURL)

        XCTAssertEqual(installer.installationState(), .notConfigured)
        XCTAssertEqual(makeInspector(installer).claudeIssue(), .claudeStatusLineNotInstalled)
    }

    func testMalformedSettingsCountAsNotConfigured() throws {
        let installer = makeInstaller()
        try writeSettings("{ not json", to: installer)

        XCTAssertEqual(installer.installationState(), .notConfigured)
    }
}
#endif
