import Foundation

/// The known failure modes for reading Codex and Claude Code quota, called
/// out explicitly so the CLI and menu bar app can show useful messages
/// instead of a generic failure.
public enum QuotaError: Error, Equatable, CustomStringConvertible, Sendable {
    case executableNotFound(String)
    case appServerLaunchFailed(String)
    case appServerExited(Int32)
    case requestTimedOut
    case invalidResponse(String)
    case noCachedDataYet(path: String)
    case cacheDecodeFailed(String)
    case claudeOAuthFallbackFailed(statusLineReason: String, oauthReason: String)
    case statusLineAlreadyConfigured
    case statusLineHelperUnavailable(path: String)
    case codexDirectFallbackFailed(directReason: String, appServerReason: String)
    /// No Codex login is stored *and* the `codex` CLI is missing — neither
    /// collection path can run. Distinct from `executableNotFound` so the
    /// message can lead with signing in, which needs no install at all,
    /// instead of telling every signed-out user to go install a CLI.
    case codexNotConnected

    /// Developer-facing wording, used by `quota-cli`. Names the exact
    /// command, path or exit status a developer needs in order to debug.
    public var description: String {
        switch self {
        case .executableNotFound(let name):
            return "'\(name)' was not found on PATH. Make sure it is installed and reachable from a login shell."
        case .appServerLaunchFailed(let reason):
            return "Failed to launch 'codex app-server': \(reason)"
        case .appServerExited(let status):
            return "'codex app-server' exited unexpectedly (status \(status))."
        case .requestTimedOut:
            return "Timed out waiting for a response from 'codex app-server'."
        case .invalidResponse(let reason):
            return "Received an unexpected response: \(reason)"
        case .noCachedDataYet(let path):
            return "No Claude Code usage has been captured yet. Run `quota-cli install-claude-hook`, " +
                "then let Claude Code complete one request in a session, and check again. Expected cache at \(path)."
        case .cacheDecodeFailed(let reason):
            return "Could not read the cached Claude Code usage file: \(reason)"
        case .claudeOAuthFallbackFailed(let statusLineReason, let oauthReason):
            return "Claude Code usage refresh failed. StatusLine: \(statusLineReason) OAuth: \(oauthReason)"
        case .statusLineAlreadyConfigured:
            return "~/.claude/settings.json already has a different statusLine command configured. " +
                "Re-run install-claude-hook with --force to overwrite it."
        case .statusLineHelperUnavailable(let path):
            return "The bundled Claude status-line helper is missing or is not executable at \(path)."
        case .codexDirectFallbackFailed(let directReason, let appServerReason):
            return "Codex usage refresh failed. Direct: \(directReason) app-server: \(appServerReason)"
        case .codexNotConnected:
            return "No Codex account is connected and the 'codex' CLI was not found on PATH. " +
                "Sign in with your ChatGPT account from the menu bar app, or install the codex CLI."
        }
    }

    /// Wording for the menu bar app, where the reader is not necessarily the
    /// person who installed the command line tools. It says what went wrong
    /// and what to do next, and never names a `quota-cli` subcommand — the
    /// app offers those actions as buttons instead.
    ///
    /// This is the localized half of the pair. `description` above stays
    /// English on purpose: it is read by whoever ran `quota-cli`, in a
    /// terminal, and it names exact commands, paths and exit statuses —
    /// translating those would make a bug report harder to act on, not
    /// easier.
    ///
    /// **Every case here ends in a next step** (UI 规范 §6) — that is the
    /// difference between this and `description` above, not just the
    /// language. A case that can only name a cause does not belong in a
    /// badge; see `QuotaFormatting.failureText`, which is where system
    /// errors get their next step appended.
    public var userFacingDescription: String {
        switch self {
        case .executableNotFound(let name):
            return QuotaL10n.string(
                "error.executableNotFound",
                "The \(name) command line tool was not found. Install it and confirm it runs in a terminal."
            )
        case .appServerLaunchFailed(let reason):
            return QuotaL10n.string(
                "error.appServerLaunchFailed",
                "Could not start codex app-server: \(reason). Confirm the codex command line runs in a terminal, or tap Sign in with ChatGPT to read your quota directly — that route needs no command line tool."
            )
        case .appServerExited(let status):
            return QuotaL10n.string(
                "error.appServerExited",
                "codex app-server exited unexpectedly (status \(String(status))). If you have never signed in to Codex, run codex login in a terminal first."
            )
        case .requestTimedOut:
            return QuotaL10n.string(
                "error.requestTimedOut",
                "Timed out waiting for codex app-server. QuotaGlance will retry shortly."
            )
        case .invalidResponse(let reason):
            return QuotaL10n.string(
                "error.invalidResponse",
                "Received an unrecognized response: \(reason). QuotaGlance will retry shortly; if this keeps happening, update to the latest version."
            )
        case .noCachedDataYet:
            return QuotaL10n.string(
                "error.noCachedDataYet",
                "No Claude Code usage has been captured yet. Finish the status line setup, then send one request in any Claude Code session."
            )
        case .cacheDecodeFailed(let reason):
            return QuotaL10n.string(
                "error.cacheDecodeFailed",
                "Could not read the Claude Code usage cache file: \(reason). Send another request in any Claude Code session and the cache will be rebuilt."
            )
        case .claudeOAuthFallbackFailed(let statusLineReason, let oauthReason):
            return QuotaL10n.string(
                "error.claudeOAuthFallbackFailed",
                "Could not read Claude Code usage — both collection paths failed. Status line: \(statusLineReason)  OAuth: \(oauthReason)  Sign in to Claude again, or run the status line setup once more."
            )
        case .statusLineAlreadyConfigured:
            return QuotaL10n.string(
                "error.statusLineAlreadyConfigured",
                "~/.claude/settings.json already has a different statusLine command. Choose Overwrite to let QuotaGlance take it over."
            )
        case .statusLineHelperUnavailable:
            return QuotaL10n.string(
                "error.statusLineHelperUnavailable",
                "The bundled Claude status line helper is missing or cannot run. Please reinstall QuotaGlance."
            )
        case .codexDirectFallbackFailed(let directReason, let appServerReason):
            return QuotaL10n.string(
                "error.codexDirectFallbackFailed",
                "Could not read Codex usage — both collection paths failed. Account direct: \(directReason)  codex CLI: \(appServerReason)  Sign in to ChatGPT again, or confirm the codex command line runs in a terminal."
            )
        case .codexNotConnected:
            return QuotaL10n.string(
                "error.codexNotConnected",
                "Codex is not connected. Tap Sign in with ChatGPT to authorize and reading will resume; if you have the codex command line installed, running codex login in a terminal works too."
            )
        }
    }
}
