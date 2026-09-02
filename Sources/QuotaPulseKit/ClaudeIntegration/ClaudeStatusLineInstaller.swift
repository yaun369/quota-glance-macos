#if os(macOS)
import Foundation

/// Installs the shell script that lets Claude Code's statusLine feature
/// push usage data to disk, and wires it into `~/.claude/settings.json`.
///
/// Paths are injectable so tests can point this at a scratch directory
/// instead of the developer's real `~/.claude/settings.json`.
public struct ClaudeStatusLineInstaller: Sendable {
    public let agentQuotaDirectory: URL
    public let helperSourceURL: URL?

    private let claudeSettingsOverride: URL?

    public static let `default` = ClaudeStatusLineInstaller(
        agentQuotaDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-quota", isDirectory: true),
        helperSourceURL: bundledHelperURL()
    )

    /// Resolved on every access rather than captured once: the app builds its
    /// installer on the main actor at launch, before `ClaudeConfigLocator`'s
    /// background probe has had a chance to notice a relocated
    /// `CLAUDE_CONFIG_DIR`. Reading it late means the corrected location is
    /// picked up as soon as it is known, instead of being baked in.
    ///
    /// `agentQuotaDirectory` deliberately does *not* move with it — that
    /// directory is this app's own, not Claude Code's.
    public var claudeSettingsURL: URL {
        claudeSettingsOverride ?? ClaudeConfigLocator.shared.settingsURL(allowLoginShell: false)
    }

    /// Uses whichever configuration directory Claude Code is actually using.
    public init(
        agentQuotaDirectory: URL,
        helperSourceURL: URL? = nil
    ) {
        self.agentQuotaDirectory = agentQuotaDirectory
        self.claudeSettingsOverride = nil
        self.helperSourceURL = helperSourceURL
    }

    /// Pins the settings file explicitly, for tests and for `quota-cli`.
    public init(
        agentQuotaDirectory: URL,
        claudeSettingsURL: URL,
        helperSourceURL: URL? = nil
    ) {
        self.agentQuotaDirectory = agentQuotaDirectory
        self.claudeSettingsOverride = claudeSettingsURL
        self.helperSourceURL = helperSourceURL
    }

    public var scriptURL: URL {
        agentQuotaDirectory.appendingPathComponent("claude-status.sh")
    }

    public var cacheURL: URL {
        agentQuotaDirectory.appendingPathComponent("claude-latest.json")
    }

    public var helperURL: URL {
        agentQuotaDirectory.appendingPathComponent(ClaudeStatusLineHelper.executableName)
    }

    /// Whether Claude Code is currently wired up to feed this app.
    public enum InstallationState: Sendable, Equatable {
        case installed
        case notConfigured
        /// `~/.claude/settings.json` points its status line at someone else's
        /// command. Installing over it needs `force`, so the app has to ask
        /// before touching it.
        case configuredForAnotherCommand(String)
    }

    /// Inspects the on-disk state without changing anything, so the menu bar
    /// app can tell "you never set this up" apart from "it is set up but
    /// Claude Code hasn't reported a reading yet".
    public func installationState() -> InstallationState {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let root) = decoded,
              let command = root["statusLine"]?["command"]?.stringValue
        else {
            return .notConfigured
        }

        guard command == scriptURL.path else {
            return .configuredForAnotherCommand(command)
        }
        // settings.json can outlive the script itself (a wiped ~/.agent-quota,
        // a migrated home directory). Treat a dangling reference as "not
        // configured" so the app offers to install rather than to overwrite.
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path),
              FileManager.default.isExecutableFile(atPath: helperURL.path),
              let installedScript = try? String(contentsOf: scriptURL, encoding: .utf8),
              installedScript == Self.scriptContents(
                  helperPath: helperURL.path,
                  cachePath: cacheURL.path
              )
        else {
            return .notConfigured
        }
        return .installed
    }

    /// Whether the status-line hook has ever written a usage reading.
    public func hasCapturedReading() -> Bool {
        FileManager.default.fileExists(atPath: cacheURL.path)
    }

    public func install(force: Bool = false) throws {
        try installArtifacts()
        try updateSettings(force: force)
    }

    /// Upgrades a status-line installation that is already managed by this
    /// app, without claiming another tool's status line or touching settings.
    /// This transparently replaces the legacy jq-based script after an app
    /// update while keeping first-time setup an explicit user action.
    @discardableResult
    public func upgradeManagedInstallationIfNeeded() throws -> Bool {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              decoded["statusLine"]?["command"]?.stringValue == scriptURL.path
        else {
            return false
        }

        let expectedScript = Self.scriptContents(
            helperPath: helperURL.path,
            cachePath: cacheURL.path
        )
        let scriptIsCurrent = FileManager.default.isExecutableFile(atPath: scriptURL.path) &&
            (try? String(contentsOf: scriptURL, encoding: .utf8)) == expectedScript
        let helperIsCurrent = try installedHelperMatchesSource()
        guard !scriptIsCurrent || !helperIsCurrent else { return false }

        try installArtifacts()
        return true
    }

    private func installArtifacts() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: agentQuotaDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agentQuotaDirectory.path
        )

        guard let helperSourceURL,
              fileManager.isExecutableFile(atPath: helperSourceURL.path)
        else {
            throw QuotaError.statusLineHelperUnavailable(path: helperSourceURL?.path ?? "<app bundle>")
        }

        let helperData = try Data(contentsOf: helperSourceURL)
        if (try? Data(contentsOf: helperURL)) != helperData ||
            !fileManager.isExecutableFile(atPath: helperURL.path) {
            try helperData.write(to: helperURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        }

        let expectedScript = Self.scriptContents(
            helperPath: helperURL.path,
            cachePath: cacheURL.path
        )
        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != expectedScript ||
            !fileManager.isExecutableFile(atPath: scriptURL.path) {
            try expectedScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }
    }

    private func installedHelperMatchesSource() throws -> Bool {
        guard let helperSourceURL,
              FileManager.default.isExecutableFile(atPath: helperSourceURL.path),
              FileManager.default.isExecutableFile(atPath: helperURL.path)
        else {
            return false
        }
        return try Data(contentsOf: helperSourceURL) == Data(contentsOf: helperURL)
    }

    private func updateSettings(force: Bool) throws {
        let fileManager = FileManager.default
        var root: [String: JSONValue] = [:]

        if fileManager.fileExists(atPath: claudeSettingsURL.path) {
            let data = try Data(contentsOf: claudeSettingsURL)
            if case .object(let existing) = try JSONDecoder().decode(JSONValue.self, from: data) {
                root = existing
            }

            if let existingStatusLine = root["statusLine"] {
                let alreadyOurs = existingStatusLine["command"]?.stringValue == scriptURL.path
                if !alreadyOurs && !force {
                    throw QuotaError.statusLineAlreadyConfigured
                }
            }

            let backupURL = agentQuotaDirectory
                .appendingPathComponent("settings.json.backup-\(Int(Date().timeIntervalSince1970))")
            try data.write(to: backupURL)
        } else {
            try fileManager.createDirectory(
                at: claudeSettingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        // Use an absolute path rather than `~`, so the command is correct
        // regardless of how Claude Code invokes it.
        root["statusLine"] = .object([
            "type": .string("command"),
            "command": .string(scriptURL.path),
            // Claude Code also invokes the status line after normal session
            // events. The interval covers idle periods and lets the cache
            // observe any rate-limit state the active session learns.
            "refreshInterval": .number(30),
        ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try encoder.encode(JSONValue.object(root))
        try output.write(to: claudeSettingsURL)
    }

    private static func scriptContents(helperPath: String, cachePath: String) -> String {
        let quotedHelperPath = shellSingleQuoted(helperPath)
        let quotedCachePath = shellSingleQuoted(cachePath)
        return """
    #!/bin/bash
    set -euo pipefail
    exec \(quotedHelperPath) --cache-file \(quotedCachePath)
    """
    }

    private static func bundledHelperURL() -> URL? {
        let fileManager = FileManager.default
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [
            executableDirectory?.appendingPathComponent(ClaudeStatusLineHelper.executableName),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent(ClaudeStatusLineHelper.executableName),
        ].compactMap { $0 }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
#endif
