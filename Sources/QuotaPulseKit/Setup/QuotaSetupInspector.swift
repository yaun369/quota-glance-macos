#if os(macOS)
import Foundation

/// A setup problem the user can actually fix, together with the wording the
/// menu bar app shows for it.
///
/// These are detected by inspecting the machine (is the binary installed? is
/// the status line wired up?) rather than by pattern-matching failure
/// messages, so the app can explain a cold start *before* a collection
/// attempt fails, and so a reworded error never silently drops the guidance.
public enum QuotaSetupIssue: Sendable, Equatable {
    case codexNotConnected
    case claudeStatusLineNotInstalled
    case claudeStatusLineUsedByAnotherCommand(String)
    case claudeAwaitingFirstReading

    /// What the app should offer to do about it. `nil` means there is
    /// nothing to click — the user has to act outside the app.
    public enum Remedy: Sendable, Equatable {
        /// The app can wire up Claude Code itself. `overwritesExisting`
        /// marks the case that replaces someone else's status line, which
        /// needs a confirmation before it runs.
        case installClaudeStatusLine(overwritesExisting: Bool)
        /// Opens the account-direct OAuth login flow for `provider`.
        case connectAccount(provider: Provider)
    }

    public var title: String {
        switch self {
        case .codexNotConnected:
            return QuotaL10n.string("setup.codexNotConnected.title", "Codex is not connected")
        case .claudeStatusLineNotInstalled:
            return QuotaL10n.string(
                "setup.claudeStatusLineNotInstalled.title",
                "Claude Code status line is not set up"
            )
        case .claudeStatusLineUsedByAnotherCommand:
            return QuotaL10n.string(
                "setup.claudeStatusLineTaken.title",
                "Claude Code status line is used by another command"
            )
        case .claudeAwaitingFirstReading:
            return QuotaL10n.string(
                "setup.claudeAwaitingFirstReading.title",
                "Waiting for Claude Code's first report"
            )
        }
    }

    public var message: String {
        switch self {
        case .codexNotConnected:
            return QuotaL10n.string(
                "setup.codexNotConnected.message",
                "Sign in with your ChatGPT account to read your quota directly — no command line tool required. If you already have the codex command line, running codex login in a terminal works too."
            )
        case .claudeStatusLineNotInstalled:
            return QuotaL10n.string(
                "setup.claudeStatusLineNotInstalled.message",
                "QuotaGlance reads your quota through the Claude Code status line. The button below sets it up automatically, and your existing ~/.claude/settings.json is backed up first."
            )
        case .claudeStatusLineUsedByAnotherCommand(let command):
            return QuotaL10n.string(
                "setup.claudeStatusLineTaken.message",
                "It is currently set to \(command). QuotaGlance can only read your quota after overwriting it; the existing setting is backed up to ~/.agent-quota first."
            )
        case .claudeAwaitingFirstReading:
            return QuotaL10n.string(
                "setup.claudeAwaitingFirstReading.message",
                "Setup is complete. Send one request in any Claude Code session and your quota will appear here."
            )
        }
    }

    public var remedy: Remedy? {
        switch self {
        case .codexNotConnected:
            return .connectAccount(provider: .codex)
        case .claudeStatusLineNotInstalled:
            return .installClaudeStatusLine(overwritesExisting: false)
        case .claudeStatusLineUsedByAnotherCommand:
            return .installClaudeStatusLine(overwritesExisting: true)
        case .claudeAwaitingFirstReading:
            // Nothing to click: only Claude Code itself can produce the first
            // reading, by completing a request.
            return nil
        }
    }
}

/// Answers "why is this provider showing nothing?" by looking at the local
/// install state. Callers should only consult it when a provider has no
/// snapshot at all — a working provider needs no guidance even if, say, the
/// status line was never installed and the OAuth fallback is carrying it.
public struct QuotaSetupInspector: Sendable {
    private let installer: ClaudeStatusLineInstaller
    private let resolveCodexPath: @Sendable () -> String?

    public init(installer: ClaudeStatusLineInstaller = .default) {
        self.init(
            installer: installer,
            // The inspector is consulted from the main actor while building
            // the menu, so it must never spawn a login shell. The collection
            // pass runs first and off the main thread, so anything that probe
            // can find is already memoized by the time this reads it.
            resolveCodexPath: { CodexAppServerClient.resolveExecutablePath(allowLoginShell: false) }
        )
    }

    init(
        installer: ClaudeStatusLineInstaller,
        resolveCodexPath: @escaping @Sendable () -> String?
    ) {
        self.installer = installer
        self.resolveCodexPath = resolveCodexPath
    }

    /// `nil` (no issue) whenever *either* collection path could plausibly
    /// produce data: a stored account credential (even one that currently
    /// needs a refresh — that failure gets its own transient error text
    /// instead of this call-to-action) or an installed `codex` binary.
    /// `hasAccountCredential` is the caller's knowledge (QuotaStore tracks
    /// it through the provider's cached refresher) rather than a Keychain
    /// probe of this inspector's own — building menu guidance must never
    /// perform keychain I/O.
    public func codexIssue(hasAccountCredential: Bool) -> QuotaSetupIssue? {
        if hasAccountCredential { return nil }
        return resolveCodexPath() == nil ? .codexNotConnected : nil
    }

    public func claudeIssue() -> QuotaSetupIssue? {
        switch installer.installationState() {
        case .notConfigured:
            return .claudeStatusLineNotInstalled
        case .configuredForAnotherCommand(let command):
            return .claudeStatusLineUsedByAnotherCommand(command)
        case .installed:
            return installer.hasCapturedReading() ? nil : .claudeAwaitingFirstReading
        }
    }
}
#endif
