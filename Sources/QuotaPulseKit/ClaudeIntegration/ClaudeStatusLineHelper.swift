#if os(macOS)
import Foundation

/// Native implementation of the Claude Code status-line hook.
///
/// Claude Code writes a JSON payload to stdin whenever it refreshes its
/// status line. The tiny companion executable calls this type to keep the
/// latest useful quota windows on disk and to produce the text Claude renders
/// in the terminal. Keeping the JSON work in Foundation means end users do
/// not have to install `jq` (or a package manager) first.
public enum ClaudeStatusLineHelper {
    public static let executableName = "claude-status-helper"

    /// Processes one Claude Code status-line payload.
    ///
    /// A cache write only happens when at least one current quota window is
    /// present and its value differs from the existing cache. This preserves
    /// the original `capturedAt` for repeated/empty refreshes, matching the
    /// freshness semantics expected by `ClaudeQuotaProvider`.
    @discardableResult
    public static func run(
        input: Data,
        cacheURL: URL,
        now: Date = Date()
    ) throws -> String {
        let payload = try JSONDecoder().decode(JSONValue.self, from: input)
        let fiveHour = payload["rate_limits"]?["five_hour"]
        let sevenDay = payload["rate_limits"]?["seven_day"]
        let capturedAt = now.timeIntervalSince1970

        let currentFiveHour = currentWindow(fiveHour, capturedAt: capturedAt)
        let currentSevenDay = currentWindow(sevenDay, capturedAt: capturedAt)

        if currentFiveHour != nil || currentSevenDay != nil {
            let candidate = JSONValue.object([
                "fiveHour": currentFiveHour ?? .null,
                "sevenDay": currentSevenDay ?? .null,
                "capturedAt": .number(capturedAt),
            ])

            if cacheNeedsUpdate(candidate: candidate, cacheURL: cacheURL) {
                try writeCache(candidate, to: cacheURL)
            }
        }

        return "Claude 5h \(remainingText(fiveHour)) left · 7d \(remainingText(sevenDay)) left"
    }

    private static func currentWindow(_ value: JSONValue?, capturedAt: TimeInterval) -> JSONValue? {
        guard let value,
              case .object = value,
              let resetsAt = value["resets_at"]?.doubleValue,
              resetsAt >= capturedAt - 300
        else {
            return nil
        }
        return value
    }

    private static func remainingText(_ value: JSONValue?) -> String {
        guard let value, case .object = value else { return "--" }
        let usedPercentage = value["used_percentage"]?.doubleValue ?? 0
        return "\(Int((100 - usedPercentage).rounded()))%"
    }

    private static func cacheNeedsUpdate(candidate: JSONValue, cacheURL: URL) -> Bool {
        guard let existingData = try? Data(contentsOf: cacheURL),
              let existing = try? JSONDecoder().decode(JSONValue.self, from: existingData)
        else {
            return true
        }

        return existing["fiveHour"] != candidate["fiveHour"] ||
            existing["sevenDay"] != candidate["sevenDay"]
    }

    private static func writeCache(_ value: JSONValue, to cacheURL: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = cacheURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: cacheURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}
#endif
