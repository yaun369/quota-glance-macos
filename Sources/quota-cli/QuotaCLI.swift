import Foundation
import QuotaPulseKit

@main
struct QuotaCLI {
    static func main() async {
        #if os(macOS)
        // `install-claude-hook` copies this executable under the helper name
        // when quota-cli is run directly through SwiftPM. Dispatch by the
        // installed filename so the CLI and the app-bundled helper share the
        // exact same native implementation without requiring jq.
        if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent ==
            ClaudeStatusLineHelper.executableName {
            exit(runClaudeStatusLineHelper())
        }
        await runMacOS()
        #else
        print("quota-cli only supports macOS today, since it reads local Codex and Claude Code state.")
        exit(1)
        #endif
    }
}

#if os(macOS)
extension QuotaCLI {
    static func runMacOS() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        guard let command = arguments.first else {
            printUsage()
            exit(64)
        }

        switch command {
        case "codex":
            exit(await runSingle(provider: CodexQuotaProvider(), key: "codex") ? 0 : 1)
        case "claude":
            exit(await runClaude() ? 0 : 1)
        case "all":
            exit(await runAll() ? 0 : 1)
        case "install-claude-hook":
            runInstallClaudeHook(force: arguments.contains("--force"))
        case "-h", "--help", "help":
            printUsage()
        default:
            printUsage(toStderr: true)
            exit(64)
        }
    }

    private static func runSingle(provider: some QuotaProvider, key: String) async -> Bool {
        do {
            let snapshot = try await provider.fetchSnapshot()
            print(prettyJSON(jsonObject(from: snapshot)))
            return true
        } catch {
            printError(error)
            return false
        }
    }

    private static func runClaude() async -> Bool {
        do {
            let result = try await ClaudeQuotaProvider().fetchSnapshotResult(
                userInitiated: true
            )
            print(prettyJSON(jsonObject(from: result)))
            // A fallback snapshot remains useful output, but a non-zero exit
            // prevents scripts from mistaking it for a successful refresh.
            return result.warning == nil
        } catch {
            printError(error)
            return false
        }
    }

    private static func runAll() async -> Bool {
        async let codexResult = try? CodexQuotaProvider().fetchSnapshot()
        async let claudeResult = try? ClaudeQuotaProvider().fetchSnapshotResult(
            userInitiated: true
        )

        var combined: [String: Any] = [:]
        var ok = true

        if let snapshot = await codexResult {
            combined["codex"] = jsonObject(from: snapshot)
        } else {
            combined["codex"] = ["error": "unavailable — run `quota-cli codex` for details"]
            ok = false
        }

        if let result = await claudeResult {
            combined["claude"] = jsonObject(from: result)
            if result.warning != nil {
                ok = false
            }
        } else {
            combined["claude"] = ["error": "unavailable — run `quota-cli claude` for details"]
            ok = false
        }

        print(prettyJSON(combined))
        return ok
    }

    private static func runInstallClaudeHook(force: Bool) {
        let defaults = ClaudeStatusLineInstaller.default
        let installer = ClaudeStatusLineInstaller(
            agentQuotaDirectory: defaults.agentQuotaDirectory,
            claudeSettingsURL: defaults.claudeSettingsURL,
            helperSourceURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        )
        do {
            try installer.install(force: force)
            print("""
            Installed \(installer.helperURL.path)
            Installed \(installer.scriptURL.path)
            Updated \(installer.claudeSettingsURL.path) statusLine.
            Now trigger one Claude Code request in any session, then run `quota-cli claude` to confirm data is flowing.
            """)
        } catch QuotaError.statusLineAlreadyConfigured {
            printError(QuotaError.statusLineAlreadyConfigured)
            exit(1)
        } catch {
            FileHandle.standardError.write("Failed to install Claude hook: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    private static func runClaudeStatusLineHelper() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "--cache-file" else {
            FileHandle.standardError.write(
                Data("usage: claude-status-helper --cache-file <path>\n".utf8)
            )
            return 64
        }

        do {
            let statusLine = try ClaudeStatusLineHelper.run(
                input: FileHandle.standardInput.readDataToEndOfFile(),
                cacheURL: URL(fileURLWithPath: arguments[1])
            )
            FileHandle.standardOutput.write(Data((statusLine + "\n").utf8))
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("claude-status-helper: \(error.localizedDescription)\n".utf8)
            )
            return 1
        }
    }

    // MARK: - Output formatting

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func jsonObject(from snapshot: QuotaSnapshot) -> [String: Any] {
        var object: [String: Any] = [
            "capturedAt": isoFormatter.string(from: snapshot.capturedAt),
        ]
        if let remaining = snapshot.session.remainingPercent {
            object["sessionRemaining"] = remaining
        }
        if let resetAt = snapshot.session.resetAt {
            object["sessionResetAt"] = isoFormatter.string(from: resetAt)
        }
        if let remaining = snapshot.weekly.remainingPercent {
            object["weeklyRemaining"] = remaining
        }
        if let resetAt = snapshot.weekly.resetAt {
            object["weeklyResetAt"] = isoFormatter.string(from: resetAt)
        }
        return object
    }

    private static func jsonObject(from result: ClaudeQuotaFetchResult) -> [String: Any] {
        var object = jsonObject(from: result.snapshot)
        object["source"] = result.source.rawValue
        if let warning = result.warning {
            object["warning"] = warning
        }
        return object
    }

    private static func prettyJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private static func printError(_ error: Error) {
        let message = (error as? QuotaError)?.description ?? String(describing: error)
        let text = prettyJSON(["error": message]) + "\n"
        FileHandle.standardError.write(text.data(using: .utf8)!)
    }

    private static func printUsage(toStderr: Bool = false) {
        let text = """
        quota-cli — inspect local Codex and Claude Code usage quotas

        USAGE:
          quota-cli codex                Show Codex usage as JSON
          quota-cli claude               Show Claude Code usage as JSON
          quota-cli all                  Show both providers as one JSON object
          quota-cli install-claude-hook  Install the Claude Code statusLine hook
                                          that keeps Claude usage data current
                                          (add --force to overwrite an existing
                                          statusLine command)

        Claude Code only reports usage after install-claude-hook has been run
        and Claude Code has completed at least one request in a session.
        """
        if toStderr {
            FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
        } else {
            print(text)
        }
    }
}
#endif
