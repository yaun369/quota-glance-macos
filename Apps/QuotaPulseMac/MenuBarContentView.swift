import AppKit
import SwiftUI
import QuotaPulseKit

struct MenuBarContentView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderRow(
                provider: .codex,
                snapshot: store.codex,
                failure: store.codexFailure,
                sourceText: store.codexSource.map { String(localized: "Source: \($0.displayName)") },
                setupIssue: store.codexSetupIssue,
                store: store,
                updater: updater
            )
            CodexAccountControl(store: store)
            Divider()
            ProviderRow(
                provider: .claude,
                snapshot: store.claude,
                failure: store.claudeFailure,
                sourceText: store.claudeSource.map { String(localized: "Source: \($0.displayName)") },
                setupIssue: store.claudeSetupIssue,
                store: store,
                updater: updater
            )
            ClaudeAccountControl(store: store)
            if launchAtLogin.shouldShowPrompt {
                Divider()
                LaunchAtLoginPrompt(launchAtLogin: launchAtLogin)
            }
            Divider()
            iCloudRow
            Divider()
            HStack {
                Button("Refresh now") {
                    Task { await store.refresh(userInitiated: true) }
                }
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("User guide") {
                    NSWorkspace.shared.open(QuotaPulseLinks.usageGuide)
                }
                SettingsLink {
                    Text("Settings")
                }
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        // No warm backdrop and no card shadows here (§5.7): the popover's
        // material belongs to the system, and painting over it is what makes
        // a menu panel look wrong on somebody else's wallpaper. What this
        // panel takes from the design system is the bar, the status colors
        // and the type hierarchy — not the surface.
        .onAppear {
            launchAtLogin.refreshStatus()
            // Opening the menu is a refresh intent, but not user-initiated:
            // it shares the background request throttle instead of forcing
            // fresh network calls on every open.
            Task { await store.refresh() }
        }
    }

    /// 同步状态（§4.5）. A working channel stays a plain timestamp; only the
    /// failure earns a badge, with the reason — which is a full sentence
    /// naming the next step — on its own line underneath.
    private var iCloudRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("iCloud")
                    .font(.caption)
                    .foregroundStyle(QuotaPalette.inkSecondary)
                Spacer(minLength: 8)
                if store.iCloudSyncError != nil {
                    StatusChip(level: .warning, text: store.iCloudStatusText)
                } else {
                    Text(store.iCloudStatusText)
                        .font(.caption)
                        .foregroundStyle(QuotaPalette.inkSecondary)
                }
            }
            if let error = store.iCloudSyncError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(QuotaPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: Provider
    let snapshot: QuotaSnapshot?
    let failure: QuotaFailure?
    let sourceText: String?
    let setupIssue: QuotaSetupIssue?
    @ObservedObject var store: QuotaStore
    @ObservedObject var updater: AppUpdater

    /// The tighter of the two windows, for the chip — same rule as the
    /// iPhone card, so the same data colors the same chip on both.
    private var chipPercent: Double? {
        guard let snapshot else { return nil }
        return QuotaWindowKind.allCases
            .compactMap { snapshot.window($0).remainingPercent }
            .min()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // §4.12 draws this chip at 44; the panel takes it at 28.
                // 44 is a *touch* target, and there is nothing to touch here
                // — at full size it would be the tallest thing in a 320pt
                // popover and push the two providers a scroll apart. The
                // recipe that matters (status tint at 12%, glyph in the dark
                // variant, no identity color) is unchanged.
                IconChip(provider: provider, remainingPercent: chipPercent, size: 28)
                Text(QuotaFormatting.providerText(provider))
                    .font(.headline)
                    .foregroundStyle(QuotaPalette.ink)
                Spacer(minLength: 0)
                StatusChip(level: connectionStatus.level, text: connectionStatus.text)
            }

            if let snapshot {
                if snapshot.session.remainingPercent != nil {
                    WindowRow(
                        kind: .session,
                        window: snapshot.session,
                        height: QuotaMetrics.BarHeight.primary
                    )
                }
                if snapshot.weekly.remainingPercent != nil {
                    WindowRow(
                        kind: .weekly,
                        window: snapshot.weekly,
                        height: QuotaMetrics.BarHeight.secondary
                    )
                }
                Text(freshnessText(for: snapshot.capturedAt))
                    .font(.caption)
                    .foregroundStyle(QuotaPalette.inkTertiary)
                if let sourceText {
                    Text(sourceText)
                        .font(.caption)
                        .foregroundStyle(QuotaPalette.inkTertiary)
                }
                if let failure {
                    // Data on screen, refresh failed: the reading is still
                    // worth having, so this is a footnote about its age and
                    // not an error state for the whole row (§4.8).
                    ProviderRecoveryView(
                        provider: provider,
                        failure: failure,
                        store: store,
                        updater: updater
                    )
                }
            } else if let setupIssue {
                // A fixable setup problem outranks the raw failure text: it
                // is the reason there is no data, and it is the only one of
                // the two the user can act on.
                SetupGuidanceView(issue: setupIssue, store: store)
                // Keep the raw failure only where it adds something the
                // guidance doesn't already say — for Claude it names which of
                // the two collection paths failed and why. "codex is missing"
                // is pure restatement, so it is dropped.
                if let failure, setupIssue != .codexNotConnected {
                    Text(failure.actionableMessage())
                        .font(.caption2)
                        .foregroundStyle(QuotaPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let failure {
                // Never collected anything, and nothing detectable to fix —
                // 完全失败（§4.8）. The panel's own 「立即刷新」 button, two
                // rows down, is the retry.
                ProviderRecoveryView(
                    provider: provider,
                    failure: failure,
                    store: store,
                    updater: updater
                )
            } else {
                Text("Loading\u{2026}")
                    .font(.caption)
                    .foregroundStyle(QuotaPalette.inkSecondary)
            }
        }
    }

    private func freshnessText(for capturedAt: Date) -> String {
        QuotaFormatting.freshnessText(capturedAt: capturedAt)
    }

    private var connectionStatus: ProviderConnectionStatus {
        if let failure, failure.recoveryAction == .reconnect {
            return .credentialsExpired(hasSavedData: snapshot != nil)
        }
        if snapshot != nil, failure != nil {
            return .savedData
        }
        if snapshot != nil {
            return .connected
        }
        if setupIssue != nil {
            return .notConnected
        }
        if failure != nil {
            return .failed
        }
        return .loading
    }
}

private enum ProviderConnectionStatus {
    case connected
    case notConnected
    case credentialsExpired(hasSavedData: Bool)
    case savedData
    case failed
    case loading

    var level: StatusChip.Level {
        switch self {
        case .connected, .loading:
            return .info
        case .notConnected, .savedData:
            return .warning
        case .credentialsExpired, .failed:
            return .error
        }
    }

    var text: String {
        switch self {
        case .connected:
            return String(localized: "Connected")
        case .notConnected:
            return String(localized: "Not connected")
        case .credentialsExpired(let hasSavedData):
            return hasSavedData
                ? String(localized: "Sign-in expired · saved data")
                : String(localized: "Sign-in expired")
        case .savedData:
            return String(localized: "Refresh failed · saved data")
        case .failed:
            return String(localized: "Read failed")
        case .loading:
            return String(localized: "Loading")
        }
    }
}

private struct ProviderRecoveryView: View {
    let provider: Provider
    let failure: QuotaFailure
    @ObservedObject var store: QuotaStore
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(failure.actionableMessage())
                .font(QuotaTypography.caption)
                .foregroundStyle(QuotaPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(actionTitle) {
                performRecovery()
            }
            .controlSize(.small)
            .disabled(failure.recoveryAction == .checkForUpdates && !updater.canCheckForUpdates)
        }
    }

    private var actionTitle: String {
        switch failure.recoveryAction {
        case .retry:
            return String(localized: "Retry")
        case .reconnect:
            return String(localized: "Sign in again")
        case .checkForUpdates:
            return String(localized: "Check for Updates…")
        case .openSystemSettings:
            return String(localized: "Open System Settings")
        }
    }

    private func performRecovery() {
        switch failure.recoveryAction {
        case .retry:
            Task { await store.retry(provider) }
        case .reconnect:
            store.reconnect(provider)
        case .checkForUpdates:
            updater.checkForUpdates()
        case .openSystemSettings:
            store.openSystemPrivacySettings()
        }
    }
}

private struct LaunchAtLoginPrompt: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusNote(
                level: .info,
                title: String(localized: "Keep QuotaGlance available"),
                detail: launchAtLogin.statusDetail
                    ?? String(localized: "Open QuotaGlance automatically after you log in so collection keeps running.")
            )
            HStack(spacing: 8) {
                if launchAtLogin.state == .requiresApproval {
                    Button("Open Login Items") {
                        launchAtLogin.openSystemLoginItems()
                    }
                } else {
                    Button("Enable Launch at Login") {
                        launchAtLogin.setEnabled(true)
                    }
                    .disabled(
                        launchAtLogin.isChanging || launchAtLogin.state == .unavailable
                    )
                }
                Button("Not now") {
                    launchAtLogin.dismissPrompt()
                }
            }
            .controlSize(.small)
        }
    }
}

/// One window in the menu panel (§5.7): the same three values and the same
/// bar as the iPhone card, at menu-bar density.
///
/// The bar is the whole point of this batch — until now the Mac showed the
/// only textual copy of a number every other surface drew as a shape, so the
/// same 12% looked alarming on a phone and ordinary here.
///
/// 利用率 stays off this row: the §6 ruling opens that second quantity on the
/// iPhone card only, and this panel is a glance surface with no room to label
/// it (see 规范 §6).
private struct WindowRow: View {
    let kind: QuotaWindowKind
    let window: QuotaWindow
    let height: CGFloat

    private var level: QuotaPalette.Level {
        QuotaPalette.Level(remainingPercent: window.remainingPercent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(QuotaFormatting.windowText(kind))
                    .font(.subheadline)
                    .foregroundStyle(QuotaPalette.inkSecondary)
                Spacer(minLength: 8)
                Text(QuotaFormatting.remainingText(window))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    // Black until critical, same rule as the iPhone card: a
                    // red number is only loud because it is rare (§4.2).
                    .foregroundStyle(level == .critical ? level.ink : QuotaPalette.ink)
            }

            QuotaBar(remainingPercent: window.remainingPercent, height: height)

            Text(QuotaFormatting.resetCountdownText(window.resetAt))
                .font(.caption)
                .foregroundStyle(QuotaPalette.inkTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(QuotaFormatting.windowText(kind)), \(QuotaFormatting.remainingText(window))"))
        .accessibilityValue(QuotaFormatting.resetCountdownText(window.resetAt))
    }
}

/// Explains a fixable setup problem and, where the app can do something
/// about it, offers the fix as a button so nobody has to know a `quota-cli`
/// subcommand exists.
private struct SetupGuidanceView: View {
    let issue: QuotaSetupIssue
    @ObservedObject var store: QuotaStore
    @State private var isConfirmingOverwrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Waiting for a first reading is not a fault — nothing is broken
            // and there is nothing to fix, so it gets the neutral badge and
            // a clock. Everything else here is a setup step the user has not
            // done yet, which is a `.warning` with a wrench (§4.5).
            StatusNote(
                level: isWaiting ? .info : .warning,
                title: issue.title,
                detail: issue.message,
                symbolName: isWaiting ? "clock" : "wrench.and.screwdriver"
            )

            if let remedy = issue.remedy {
                remedyControls(remedy)
            }

            // Only the Claude status-line action can fail with a message, so
            // this never lands under the Codex guidance.
            if let message = store.setupActionMessage, issue != .codexNotConnected {
                StatusNote(level: .error, title: String(localized: "Setup failed"), detail: message)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func remedyControls(_ remedy: QuotaSetupIssue.Remedy) -> some View {
        switch remedy {
        case .connectAccount:
            // The actionable button lives in the always-visible
            // `CodexAccountControl` below the Codex row instead of here:
            // this guidance block only renders while there is no snapshot
            // at all, but sign-in/sign-out needs to stay reachable even
            // after data starts flowing.
            EmptyView()

        case .installClaudeStatusLine(let overwritesExisting):
            HStack(spacing: 8) {
                Button(overwritesExisting ? String(localized: "Overwrite and set up") : String(localized: "Set up for me")) {
                    if overwritesExisting {
                        isConfirmingOverwrite = true
                    } else {
                        Task { await store.installClaudeStatusLine(force: false) }
                    }
                }
                .disabled(store.isRunningSetupAction)
                if store.isRunningSetupAction {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
            .confirmationDialog(
                "Overwrite the existing Claude Code status line setting?",
                isPresented: $isConfirmingOverwrite
            ) {
                Button("Overwrite and set up", role: .destructive) {
                    Task { await store.installClaudeStatusLine(force: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your existing ~/.claude/settings.json is backed up to ~/.agent-quota first, so you can restore it by hand later.")
            }
        }
    }

    private var isWaiting: Bool { issue == .claudeAwaitingFirstReading }
}

/// Always visible under the Codex row — unlike `SetupGuidanceView`, which
/// disappears the moment a snapshot exists (regardless of source), sign-in
/// and sign-out need to stay reachable even while the app-server fallback
/// or a previously connected account is already showing data.
private struct CodexAccountControl: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        HStack(spacing: 8) {
            switch store.codexLoginState {
            case .inProgress:
                Text("Waiting for browser authorization\u{2026}")
                    .foregroundStyle(QuotaPalette.inkSecondary)
                ProgressView().controlSize(.small)
                Spacer()
                Button("Cancel") { store.cancelCodexLogin() }

            case .failed(let message):
                StatusNote(level: .error, title: String(localized: "Sign-in failed"), detail: message)
                Spacer(minLength: 8)
                Button("Retry") { store.loginCodex() }

            case .idle:
                if let accountLabel = store.codexAccountLabel {
                    Text("Connected: \(accountLabel)")
                        .foregroundStyle(QuotaPalette.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Sign out") { store.signOutCodex() }
                } else {
                    Text("Not connected")
                        .foregroundStyle(QuotaPalette.inkSecondary)
                    Spacer()
                    Button("Sign in with ChatGPT") { store.loginCodex() }
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}

/// Claude's equivalent of `CodexAccountControl` — the two providers share
/// the same loopback-only login flow, so the controls are identical in
/// shape.
private struct ClaudeAccountControl: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        HStack(spacing: 8) {
            switch store.claudeLoginState {
            case .inProgress:
                Text("Waiting for browser authorization\u{2026}")
                    .foregroundStyle(QuotaPalette.inkSecondary)
                ProgressView().controlSize(.small)
                Spacer()
                Button("Cancel") { store.cancelClaudeLogin() }

            case .failed(let message):
                StatusNote(level: .error, title: String(localized: "Sign-in failed"), detail: message)
                Spacer(minLength: 8)
                Button("Retry") { store.loginClaude() }

            case .idle:
                if let accountLabel = store.claudeAccountLabel {
                    Text("Connected: \(accountLabel)")
                        .foregroundStyle(QuotaPalette.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Sign out") { store.signOutClaude() }
                } else {
                    Text("Not connected")
                        .foregroundStyle(QuotaPalette.inkSecondary)
                    Spacer()
                    Button("Sign in with Claude") { store.loginClaude() }
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}
