#if os(macOS)
import Foundation

/// Where Claude Code keeps `settings.json` and its credentials file.
///
/// This is `~/.claude` unless the user exported `CLAUDE_CONFIG_DIR`, which
/// Claude Code honours. That export lives in a shell startup file, and a menu
/// bar app launched from Finder inherits none of those — so assuming
/// `~/.claude` writes the status line into a file Claude Code never reads, and
/// the app then waits forever for a first reading that cannot arrive.
///
/// The same trap as the `PATH` lookup in `ExecutableLocator`, and it is
/// answered the same way: read the variable directly when it is there, and ask
/// a login shell for it when it is not.
public struct ClaudeConfigLocator: Sendable {
    public static let shared = ClaudeConfigLocator()

    static let environmentKey = "CLAUDE_CONFIG_DIR"

    private let environment: [String: String]
    private let homeDirectory: URL
    private let loginShellValue: @Sendable (String, Bool) -> String?

    public init() {
        self.init(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            loginShellValue: { name, allowSpawn in
                LoginShellLookup.shared.environmentValue(of: name, allowSpawn: allowSpawn)
            }
        )
    }

    init(
        environment: [String: String],
        homeDirectory: URL,
        loginShellValue: @escaping @Sendable (String, Bool) -> String?
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.loginShellValue = loginShellValue
    }

    /// Resolves the directory once, off the main thread, so that the main
    /// actor can read the answer without ever spawning a shell itself.
    ///
    /// Fire-and-forget: callers get the fallback until the probe lands, and
    /// the corrected value from the next read. Nothing waits on it.
    public static func prepare() {
        DispatchQueue.global(qos: .utility).async {
            _ = shared.directory()
        }
    }

    /// Waits for the answer instead of taking the fallback. For actions that
    /// *write* — installing the status line — where landing in the wrong
    /// directory is worse than taking a moment. Suspends rather than blocks,
    /// so the main actor stays responsive.
    public static func resolvedDirectory() async -> URL {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: shared.directory())
            }
        }
    }

    /// - Parameter allowLoginShell: pass `false` on the main thread. It then
    ///   answers from `prepare()`'s memoized result, or falls back to
    ///   `~/.claude`.
    public func directory(allowLoginShell: Bool = true) -> URL {
        if let directory = expand(environment[Self.environmentKey]) {
            return directory
        }
        if let directory = expand(loginShellValue(Self.environmentKey, allowLoginShell)) {
            return directory
        }
        return homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    public func settingsURL(allowLoginShell: Bool = true) -> URL {
        directory(allowLoginShell: allowLoginShell)
            .appendingPathComponent("settings.json")
    }

    public func credentialsURL(allowLoginShell: Bool = true) -> URL {
        directory(allowLoginShell: allowLoginShell)
            .appendingPathComponent(".credentials.json")
    }

    private func expand(_ raw: String?) -> URL? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value == "~" {
            value = homeDirectory.path
        } else if value.hasPrefix("~/") {
            value = homeDirectory.appendingPathComponent(String(value.dropFirst(2))).path
        }
        // A relative value would be resolved against the working directory,
        // which for a GUI app is `/` and has nothing to do with wherever the
        // user was standing when they set it. Better to fall back to the
        // default than to invent a location.
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }
}
#endif
