#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class ClaudeStatusLineInstallerTests: XCTestCase {
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

    func testInstallWritesExecutableScriptAndSettingsEntry() throws {
        let installer = makeInstaller()
        try installer.install()

        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.scriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.helperURL.path))

        let script = try String(contentsOf: installer.scriptURL)
        XCTAssertTrue(script.contains(installer.helperURL.path))
        XCTAssertTrue(script.contains(installer.cacheURL.path))
        XCTAssertFalse(script.contains("jq"))

        let attributes = try FileManager.default.attributesOfItem(atPath: installer.scriptURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o755)
        let helperAttributes = try FileManager.default.attributesOfItem(atPath: installer.helperURL.path)
        XCTAssertEqual(helperAttributes[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try Data(contentsOf: installer.helperURL), Data("#!/bin/bash\nexit 0\n".utf8))

        let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: installer.claudeSettingsURL))
        XCTAssertEqual(settings["statusLine"]?["command"]?.stringValue, installer.scriptURL.path)
        XCTAssertEqual(settings["statusLine"]?["type"]?.stringValue, "command")
        XCTAssertEqual(settings["statusLine"]?["refreshInterval"]?.intValue, 30)
    }

    func testInstallPreservesUnrelatedSettingsKeys() throws {
        let installer = makeInstaller()
        try FileManager.default.createDirectory(
            at: installer.claudeSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        { "theme": "dark", "model": "claude-fable-5" }
        """.write(to: installer.claudeSettingsURL, atomically: true, encoding: .utf8)

        try installer.install()

        let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: installer.claudeSettingsURL))
        XCTAssertEqual(settings["theme"]?.stringValue, "dark")
        XCTAssertEqual(settings["model"]?.stringValue, "claude-fable-5")
        XCTAssertEqual(settings["statusLine"]?["command"]?.stringValue, installer.scriptURL.path)
    }

    func testInstallRefusesToOverwriteDifferentStatusLineWithoutForce() throws {
        let installer = makeInstaller()
        try FileManager.default.createDirectory(
            at: installer.claudeSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        { "statusLine": { "type": "command", "command": "/some/other/script.sh" } }
        """.write(to: installer.claudeSettingsURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(error as? QuotaError, .statusLineAlreadyConfigured)
        }

        try installer.install(force: true)
        let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: installer.claudeSettingsURL))
        XCTAssertEqual(settings["statusLine"]?["command"]?.stringValue, installer.scriptURL.path)
    }

    func testNativeHelperPreservesValidCacheForEmptyOrUnchangedInput() throws {
        let installer = makeInstaller()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveHourReset = Int(now.addingTimeInterval(5 * 60 * 60).timeIntervalSince1970)
        let sevenDayReset = Int(now.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970)
        let validInput = """
        {
          "rate_limits": {
            "five_hour": { "used_percentage": 23.5, "resets_at": \(fiveHourReset) },
            "seven_day": { "used_percentage": 41.2, "resets_at": \(sevenDayReset) }
          }
        }
        """
        let statusLine = try ClaudeStatusLineHelper.run(
            input: Data(validInput.utf8),
            cacheURL: installer.cacheURL,
            now: now
        )
        XCTAssertEqual(statusLine, "Claude 5h 77% left · 7d 59% left")
        let original = try Data(contentsOf: installer.cacheURL)

        try ClaudeStatusLineHelper.run(
            input: Data(#"{"rate_limits":{}}"#.utf8),
            cacheURL: installer.cacheURL,
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(try Data(contentsOf: installer.cacheURL), original)

        try ClaudeStatusLineHelper.run(
            input: Data(validInput.utf8),
            cacheURL: installer.cacheURL,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(try Data(contentsOf: installer.cacheURL), original)

        let attributes = try FileManager.default.attributesOfItem(atPath: installer.cacheURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testManagedLegacyScriptIsUpgradedWithoutChangingSettings() throws {
        let installer = makeInstaller()
        try FileManager.default.createDirectory(
            at: installer.agentQuotaDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: installer.claudeSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"statusLine":{"type":"command","command":"\#(installer.scriptURL.path)"}}"#
            .write(to: installer.claudeSettingsURL, atomically: true, encoding: .utf8)
        try "#!/bin/bash\necho input | jq .\n".write(
            to: installer.scriptURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installer.scriptURL.path
        )

        XCTAssertTrue(try installer.upgradeManagedInstallationIfNeeded())
        XCTAssertEqual(installer.installationState(), .installed)
        XCTAssertFalse(try String(contentsOf: installer.scriptURL).contains("jq"))
        XCTAssertFalse(try installer.upgradeManagedInstallationIfNeeded())
    }
}
#endif
