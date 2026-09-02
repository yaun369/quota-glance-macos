#if os(macOS)
import Foundation

/// Finds a command line tool the way the user's shell would, rather than the
/// way a GUI process would.
///
/// A menu bar app launched from Finder or as a login item inherits launchd's
/// `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin` — which contains none of the
/// directories `npm install -g`, Homebrew or a Node version manager install
/// into. Looking a tool up in that `PATH` reports "not installed" for a tool
/// the user can run perfectly well in Terminal, which is exactly what the app
/// then tells them, forever.
///
/// So the lookup goes the other way round: check the places these installers
/// actually write, then the inherited `PATH`, and only ask a login shell as a
/// last resort for setups too exotic to enumerate.
public struct ExecutableLocator: Sendable {
    public static let `default` = ExecutableLocator()

    private let environment: [String: String]
    private let homeDirectory: URL
    private let systemDirectories: [String]
    private let loginShellLookup: @Sendable (String, Bool) -> String?

    public init() {
        self.init(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            loginShellLookup: { name, allowSpawn in
                LoginShellLookup.shared.path(of: name, allowSpawn: allowSpawn)
            }
        )
    }

    /// - Parameter systemDirectories: overridable so tests can scan a scratch
    ///   directory instead of the machine they happen to run on.
    init(
        environment: [String: String],
        homeDirectory: URL,
        systemDirectories: [String] = ExecutableLocator.defaultSystemDirectories,
        loginShellLookup: @escaping @Sendable (String, Bool) -> String?
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.systemDirectories = systemDirectories
        self.loginShellLookup = loginShellLookup
    }

    /// - Parameter allowLoginShell: whether the lookup may spawn a login shell
    ///   when the directory scan comes up empty. Callers on the main thread
    ///   must pass `false`: sourcing a heavy `.zshrc` can take seconds. They
    ///   still see a previously resolved path, because the probe memoizes.
    public func locate(_ name: String, allowLoginShell: Bool = true) -> String? {
        for directory in searchDirectories() {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return loginShellLookup(name, allowLoginShell)
    }

    /// Every directory `locate(_:)` scans, in the order it scans them.
    ///
    /// Also used to build the child environment: a tool installed from npm is
    /// a `#!/usr/bin/env node` script, so launching it needs `node` reachable
    /// on the child's `PATH` — and `node` lives in one of these directories.
    public func searchDirectories() -> [String] {
        var directories: [String] = []
        var seen = Set<String>()

        func append(_ path: String) {
            let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            directories.append(normalized)
        }

        for path in systemDirectories {
            append(path)
        }
        for path in Self.homeRelativeDirectories {
            append(homeDirectory.appendingPathComponent(path).path)
        }
        if let prefix = npmPrefixFromConfig() {
            append(prefix + "/bin")
        }
        for path in versionManagerDirectories() {
            append(path)
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            append(String(directory))
        }

        return directories
    }

    /// Locations that do not depend on the user's home directory.
    static let defaultSystemDirectories = [
        "/opt/homebrew/bin",   // Homebrew on Apple silicon
        "/usr/local/bin",      // Homebrew on Intel, and the nodejs.org installer
        "/opt/local/bin",      // MacPorts
        "/usr/bin",
    ]

    /// Fixed locations under `~`. Mostly npm prefixes and the bin directories
    /// of the JavaScript toolchains that ship their own installer.
    private static let homeRelativeDirectories = [
        ".local/bin",
        ".npm-global/bin",
        ".npm-packages/bin",
        ".node/bin",
        ".volta/bin",
        ".bun/bin",
        ".deno/bin",
        "Library/pnpm",
        ".yarn/bin",
        ".config/yarn/global/node_modules/.bin",
        ".asdf/shims",
        ".local/share/mise/shims",
        ".nodebrew/current/bin",
        ".cargo/bin",
    ]

    /// Version managers keep one bin directory per installed runtime, so the
    /// exact path depends on which versions the user has. Scan the parent and
    /// take the newest-looking version first — that is the one `npm install
    /// -g` most likely wrote to.
    private func versionManagerDirectories() -> [String] {
        let containers: [(parent: String, suffix: String)] = [
            (".nvm/versions/node", "bin"),
            ("Library/Application Support/fnm/node-versions", "installation/bin"),
            (".local/share/fnm/node-versions", "installation/bin"),
            (".asdf/installs/nodejs", "bin"),
            (".local/share/mise/installs/node", "bin"),
            (".nodenv/versions", "bin"),
        ]

        return containers.flatMap { container -> [String] in
            let parent = homeDirectory.appendingPathComponent(container.parent, isDirectory: true)
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            return versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { parent.appendingPathComponent($0).appendingPathComponent(container.suffix).path }
        }
    }

    /// `npm config set prefix` writes to `~/.npmrc`, and a user who has moved
    /// their global prefix to somewhere unusual has recorded it there. Reading
    /// the file is far cheaper than asking `npm` itself.
    private func npmPrefixFromConfig() -> String? {
        let url = homeDirectory.appendingPathComponent(".npmrc")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else { continue }
            guard let separator = trimmed.firstIndex(of: "="),
                  trimmed[..<separator].trimmingCharacters(in: .whitespaces) == "prefix"
            else {
                continue
            }

            var value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'",
               value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if value == "~" {
                return homeDirectory.path
            }
            if value.hasPrefix("~/") {
                return homeDirectory.appendingPathComponent(String(value.dropFirst(2))).path
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Last-resort lookup that asks the user's own shell what it knows: where a
/// tool lives, or what an environment variable is set to.
///
/// This covers everything a GUI process cannot see for itself — a prefix on an
/// external volume, a corporate-managed toolchain, a `CLAUDE_CONFIG_DIR`
/// exported from `.zshrc`. It is deliberately a last step: it spawns a shell
/// and sources the user's startup files, which is slow and can print arbitrary
/// output.
final class LoginShellLookup: @unchecked Sendable {
    static let shared = LoginShellLookup()

    /// Long enough for a login shell that sources a plugin manager, short
    /// enough that a background refresh cycle is not held hostage by it.
    private let timeout: TimeInterval
    /// A resolved path is stable, so it is cached for the lifetime of the
    /// process. A *failed* lookup is cached only briefly, so installing the
    /// tool while the app is open is picked up by the next refresh rather
    /// than requiring a relaunch.
    private let negativeCacheInterval: TimeInterval
    private let spawn: @Sendable (String, [String], TimeInterval) -> String?

    private let lock = NSLock()
    private var results: [String: (value: String?, resolvedAt: Date)] = [:]
    /// Serializes the spawns themselves, so a burst of misses cannot start
    /// several login shells at once.
    private let spawnLock = NSLock()

    init(
        timeout: TimeInterval = 5,
        negativeCacheInterval: TimeInterval = 60,
        spawn: @escaping @Sendable (String, [String], TimeInterval) -> String? = {
            LoginShellLookup.runCapturingOutput(executable: $0, arguments: $1, timeout: $2)
        }
    ) {
        self.timeout = timeout
        self.negativeCacheInterval = negativeCacheInterval
        self.spawn = spawn
    }

    /// Where the shell says `name` is installed.
    func path(of name: String, allowSpawn: Bool) -> String? {
        memoized(key: "path:\(name)", allowSpawn: allowSpawn) {
            // `command -v` also answers for builtins, aliases and functions,
            // none of which can be handed to `Process`.
            self.askLoginShell("command -v '\(name)' 2>/dev/null") { candidate in
                candidate.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate)
            }
        }
    }

    /// What `name` is exported as in the user's shell. This is how a GUI
    /// process learns about variables set in `.zshrc`, which it never
    /// inherits.
    func environmentValue(of name: String, allowSpawn: Bool) -> String? {
        memoized(key: "env:\(name)", allowSpawn: allowSpawn) {
            // `${name-}` keeps `set -u` in a startup file from aborting the
            // probe when the variable is simply unset.
            self.askLoginShell("printf '%s' \"${\(name)-}\"") { !$0.isEmpty }
        }
    }

    private func memoized(
        key: String,
        allowSpawn: Bool,
        resolve: () -> String?
    ) -> String? {
        if let cached = cachedResult(for: key) {
            return cached.value
        }
        guard allowSpawn else { return nil }

        spawnLock.lock()
        defer { spawnLock.unlock() }
        // Another thread may have resolved it while this one waited.
        if let cached = cachedResult(for: key) {
            return cached.value
        }

        let resolved = resolve()
        lock.lock()
        results[key] = (resolved, Date())
        lock.unlock()
        return resolved
    }

    private func cachedResult(for key: String) -> (value: String?, resolvedAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = results[key] else { return nil }
        if cached.value == nil,
           Date().timeIntervalSince(cached.resolvedAt) >= negativeCacheInterval {
            return nil
        }
        return cached
    }

    /// Runs `body` in a login shell and returns what it printed, provided
    /// `isValid` accepts it.
    private func askLoginShell(_ body: String, isValid: (String) -> Bool) -> String? {
        var shells: [String] = []
        if let shell = ProcessInfo.processInfo.environment["SHELL"] {
            shells.append(shell)
        }
        // `$SHELL` is unset for a GUI process on some setups, and a shell that
        // does not understand `-lic` (nushell, xonsh) would fail the probe
        // outright. zsh is the macOS default and reads the same startup files
        // the user's own shell would.
        if !shells.contains("/bin/zsh") {
            shells.append("/bin/zsh")
        }

        for shell in shells {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            // `-l` sources the login files (`.zprofile`, `.bash_profile`) and
            // `-i` the interactive ones (`.zshrc`); users export from either,
            // so both are needed. The markers isolate the answer from whatever
            // else those files print to stdout.
            let script = "printf '\(Self.marker):'; \(body); printf ':\(Self.marker)'"
            guard let output = spawn(shell, ["-l", "-i", "-c", script], timeout),
                  let value = Self.extractMarkedValue(from: output),
                  isValid(value)
            else {
                continue
            }
            return value
        }
        return nil
    }

    static let marker = "QUOTAPULSE_PROBE"

    static func extractMarkedValue(from output: String) -> String? {
        guard let start = output.range(of: "\(marker):"),
              let end = output.range(of: ":\(marker)", range: start.upperBound..<output.endIndex)
        else {
            return nil
        }
        let value = output[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Only an absolute path to something executable is a usable answer.
    static func extractMarkedPath(from output: String) -> String? {
        guard let path = extractMarkedValue(from: output),
              path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path)
        else {
            return nil
        }
        return path
    }

    /// Runs a command and returns its stdout, or `nil` if it could not be
    /// launched. Never blocks past `timeout`: a startup file that waits on
    /// input would otherwise hang the caller indefinitely.
    static func runCapturingOutput(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Startup files sometimes prompt. Give them EOF instead of a terminal.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
            // A shell that ignores SIGTERM would keep the pipe open, and the
            // read below would never return.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return String(data: data, encoding: .utf8)
    }
}
#endif
