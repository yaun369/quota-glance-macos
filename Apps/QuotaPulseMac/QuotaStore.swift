import AppKit
import Foundation
import QuotaPulseKit

/// State of the interactive "登录 ChatGPT 账号" flow. Separate from
/// `codexError`/`codexSetupIssue`, which describe why *data collection* has
/// nothing to show — this describes an in-progress user action instead.
enum CodexLoginState: Equatable {
    case idle
    case inProgress
    case failed(String)
}

/// State of the interactive "登录 Claude 账号" flow, mirroring
/// `CodexLoginState` — both providers now share the same loopback-only
/// shape.
enum ClaudeLoginState: Equatable {
    case idle
    case inProgress
    case failed(String)
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var codex: QuotaSnapshot?
    @Published private(set) var claude: QuotaSnapshot?
    @Published private(set) var codexFailure: QuotaFailure?
    @Published private(set) var claudeFailure: QuotaFailure?
    @Published private(set) var codexSource: CodexQuotaSource?
    @Published private(set) var claudeSource: ClaudeQuotaSource?
    @Published private(set) var isRefreshing = false
    @Published private(set) var iCloudStatusText = String(localized: "Not synced yet")
    /// Why the last push failed, kept apart from `iCloudStatusText` so the
    /// panel can badge the state and print the reason under it (§4.5) rather
    /// than sniffing a prefix off one concatenated string.
    @Published private(set) var iCloudSyncError: String?
    /// Why a provider is showing nothing, when the reason is something the
    /// user can fix. Only ever set while that provider has no snapshot.
    @Published private(set) var codexSetupIssue: QuotaSetupIssue?
    @Published private(set) var claudeSetupIssue: QuotaSetupIssue?
    /// Outcome of the last in-app setup action, shown until the next one.
    @Published private(set) var setupActionMessage: String?
    @Published private(set) var isRunningSetupAction = false
    /// The label shown for a connected Codex account ("person@example.com"),
    /// or `nil` when no account-direct credential is stored. Read through
    /// the provider's cached refresher — this never triggers a login, a
    /// network call, or any Keychain prompt.
    @Published private(set) var codexAccountLabel: String?
    @Published private(set) var codexLoginState: CodexLoginState = .idle
    /// The label shown for a connected Claude account, mirroring
    /// `codexAccountLabel`.
    @Published private(set) var claudeAccountLabel: String?
    @Published private(set) var claudeLoginState: ClaudeLoginState = .idle

    private let codexProvider = CodexQuotaProvider()
    private let claudeProvider = ClaudeQuotaProvider()
    private let codexOAuthLoginService = CodexOAuthLoginService()
    private let claudeOAuthLoginService = ClaudeOAuthLoginService()
    /// Mirrors "is a Codex login stored", for `codexIssue(hasAccountCredential:)`.
    /// Kept in lockstep with `codexAccountLabel` rather than derived from it,
    /// because a stored credential may legitimately have no display label.
    private var codexCredentialStored = false
    private let cloudRepository: any QuotaSyncRepository = CloudKitQuotaRepository()
    private let statusLineInstaller = ClaudeStatusLineInstaller.default
    private let setupInspector = QuotaSetupInspector()
    private var autoRefreshTask: Task<Void, Never>?
    private var codexUpdatesTask: Task<Void, Never>?
    private var claudeUpdatesTask: Task<Void, Never>?
    private var codexEventRefreshTask: Task<Void, Never>?
    private var claudeEventRefreshTask: Task<Void, Never>?
    private var codexLoginTask: Task<Void, Never>?
    private var claudeLoginTask: Task<Void, Never>?
    private var isCodexRefreshing = false
    private var isClaudeRefreshing = false
    private var codexRefreshPending = false
    private var claudeRefreshPending = false
    private var codexUserInitiatedRefreshPending = false
    private var claudeUserInitiatedRefreshPending = false
    private var lastPushedSnapshot: [Provider: QuotaSnapshot] = [:]
    private var lastPushedAt: [Provider: Date] = [:]
    private let onProviderConnected: @MainActor () -> Void

    init(onProviderConnected: @escaping @MainActor () -> Void = {}) {
        self.onProviderConnected = onProviderConnected
        // Claude Code's configuration directory can be moved with
        // CLAUDE_CONFIG_DIR, which is exported from a shell startup file this
        // app never sees. Kick the lookup off now, off the main thread, so the
        // status line is installed where Claude Code will actually read it.
        ClaudeConfigLocator.prepare()

        // Existing installs used a jq-based script at the same managed path.
        // If that hook is already ours, refresh its artifacts in place so an
        // app update removes the external dependency without asking the user
        // to configure Claude Code again.
        do {
            try statusLineInstaller.upgradeManagedInstallationIfNeeded()
        } catch let error as QuotaError {
            setupActionMessage = error.userFacingDescription
        } catch {
            setupActionMessage = String(localized: "Could not update the Claude status line helper: \(error.localizedDescription)")
        }
        start()
    }

    /// Starts collection as soon as the app creates its store. This must not
    /// depend on the menu popover being opened.
    func start(interval: Duration = .seconds(120)) {
        guard autoRefreshTask == nil else { return }

        observeProviderUpdates()
        autoRefreshTask = Task { [weak self] in
            // Account state first, so `updateSetupIssues()` after the first
            // collection pass never sees a not-yet-loaded "no credential".
            await self?.loadStoredAccountState()
            while let self, !Task.isCancelled {
                await self.refresh()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// One read per provider through the refresher's cache, at startup only —
    /// afterwards login/sign-out update this state directly.
    private func loadStoredAccountState() async {
        codexCredentialStored = await codexProvider.hasStoredCredential()
        codexAccountLabel = await codexProvider.storedAccountLabel()
        claudeAccountLabel = await claudeProvider.storedAccountLabel()
    }

    func refresh(userInitiated: Bool = false) async {
        async let codexRefresh: Void = refreshCodex(userInitiated: userInitiated)
        async let claudeRefresh: Void = refreshClaude(userInitiated: userInitiated)
        _ = await (codexRefresh, claudeRefresh)
    }

    func retry(_ provider: Provider) async {
        switch provider {
        case .codex:
            await refreshCodex(userInitiated: true)
        case .claude:
            await refreshClaude(userInitiated: true)
        }
    }

    func reconnect(_ provider: Provider) {
        switch provider {
        case .codex:
            loginCodex()
        case .claude:
            loginClaude()
        }
    }

    func openSystemPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the system browser to `codex`'s ChatGPT sign-in page and waits
    /// for the redirect. A second call while one is already running is a
    /// no-op — the button that starts this is disabled while `codexLoginState
    /// == .inProgress`, so this only guards against a stray double-invoke.
    func loginCodex() {
        guard codexLoginTask == nil else { return }
        codexLoginState = .inProgress
        codexLoginTask = Task { [weak self] in
            await self?.performCodexLogin()
            self?.codexLoginTask = nil
        }
    }

    /// Abandons an in-progress login. `CodexOAuthLoginService.login` reacts
    /// to the underlying `Task`'s cancellation by tearing down the loopback
    /// listener immediately, rather than leaving it bound for the rest of
    /// its timeout.
    func cancelCodexLogin() {
        codexLoginTask?.cancel()
    }

    /// Local sign-out: removes the stored credential so the next refresh
    /// falls back to `codex app-server` (or the "not connected" setup
    /// guidance, if that isn't available either).
    func signOutCodex() {
        Task {
            try? await codexProvider.signOut()
            codexCredentialStored = false
            codexAccountLabel = nil
            await refreshCodex(userInitiated: true)
        }
    }

    private func performCodexLogin() async {
        do {
            let credential = try await codexOAuthLoginService.login(
                openBrowser: { url in NSWorkspace.shared.open(url) }
            )
            try await codexProvider.storeCredential(credential)
            codexLoginState = .idle
            codexCredentialStored = true
            codexAccountLabel = credential.accountLabel
            await refreshCodex(userInitiated: true)
        } catch is CancellationError {
            codexLoginState = .idle
        } catch CodexOAuthLoginError.cancelled {
            codexLoginState = .idle
        } catch {
            codexLoginState = .failed(Self.errorText(error))
        }
    }

    /// Opens the system browser to Claude's sign-in page and waits for the
    /// `localhost:54545` redirect — the same loopback-only shape as
    /// `loginCodex()`. There's no known second port for this client, unlike
    /// Codex's 1455/1457 pair, so a port conflict surfaces as a failure.
    func loginClaude() {
        guard claudeLoginTask == nil else { return }
        claudeLoginState = .inProgress
        claudeLoginTask = Task { [weak self] in
            await self?.performClaudeLoopbackLogin()
            self?.claudeLoginTask = nil
        }
    }

    /// Abandons an in-progress loopback wait.
    func cancelClaudeLogin() {
        claudeLoginTask?.cancel()
        claudeLoginState = .idle
    }

    /// Local sign-out, mirroring `signOutCodex`.
    func signOutClaude() {
        Task {
            try? await claudeProvider.signOut()
            claudeAccountLabel = nil
            await refreshClaude(userInitiated: true)
        }
    }

    private func performClaudeLoopbackLogin() async {
        do {
            let credential = try await claudeOAuthLoginService.loginViaLoopback(
                openBrowser: { url in NSWorkspace.shared.open(url) }
            )
            try await claudeProvider.storeCredential(credential)
            claudeLoginState = .idle
            claudeAccountLabel = credential.accountLabel
            await refreshClaude(userInitiated: true)
        } catch is CancellationError {
            claudeLoginState = .idle
        } catch ClaudeOAuthLoginError.cancelled {
            claudeLoginState = .idle
        } catch {
            claudeLoginState = .failed(Self.errorText(error))
        }
    }

    /// Wires Claude Code's status line to this app. `force` replaces a status
    /// line belonging to another tool, so the UI must confirm that first.
    func installClaudeStatusLine(force: Bool) async {
        isRunningSetupAction = true
        defer { isRunningSetupAction = false }

        // This writes to Claude Code's configuration directory, so settle
        // where that actually is first. Everywhere else can take the
        // `~/.claude` fallback and self-correct on the next refresh; writing
        // to the wrong file would just leave the user configured for nothing.
        _ = await ClaudeConfigLocator.resolvedDirectory()

        do {
            try statusLineInstaller.install(force: force)
            // Success needs no sentence of its own: the guidance below the
            // button switches to "waiting for the first reading", which says
            // the same thing without repeating itself.
            setupActionMessage = nil
        } catch let error as QuotaError {
            setupActionMessage = error.userFacingDescription
        } catch {
            setupActionMessage = String(localized: "Setup failed: \(error.localizedDescription)")
        }

        await refreshClaude(userInitiated: true)
    }

    /// Setup guidance is only meaningful while a provider has nothing to
    /// show; once a reading arrives it would just be noise, even if the
    /// status line is still unconfigured and the OAuth fallback is what is
    /// actually carrying the data.
    private func updateSetupIssues() {
        codexSetupIssue = codex == nil
            ? setupInspector.codexIssue(hasAccountCredential: codexCredentialStored)
            : nil
        claudeSetupIssue = claude == nil ? setupInspector.claudeIssue() : nil
        if codexSetupIssue == nil && claudeSetupIssue == nil {
            setupActionMessage = nil
        }
    }

    private func refreshCodex(userInitiated: Bool = false) async {
        guard !isCodexRefreshing else {
            codexRefreshPending = true
            codexUserInitiatedRefreshPending = codexUserInitiatedRefreshPending || userInitiated
            return
        }
        isCodexRefreshing = true
        updateRefreshingState()

        do {
            let result = try await codexProvider.fetchSnapshotResult(userInitiated: userInitiated)
            codexFailure = result.warning.map {
                QuotaFailure(
                    message: $0,
                    recoveryAction: result.warningRecoveryAction ?? .retry
                )
            }
            if result.warning == nil {
                onProviderConnected()
            }
            if result.isNewer(than: codex) {
                codex = result.snapshot
                codexSource = result.source
                // A warning result fell back to app-server after the direct
                // path failed — a local last-resort value, not a successful
                // fresh collection. Never let it overwrite a newer value in
                // the user's private CloudKit database.
                if result.warning == nil {
                    await syncToCloudIfNeeded(result.snapshot)
                }
            }
        } catch {
            codexFailure = QuotaFailure(
                message: Self.errorText(error),
                recoveryAction: QuotaFailureClassifier.recoveryAction(for: error)
            )
        }

        isCodexRefreshing = false
        updateRefreshingState()
        updateSetupIssues()
        if codexRefreshPending {
            codexRefreshPending = false
            let pendingWasUserInitiated = codexUserInitiatedRefreshPending
            codexUserInitiatedRefreshPending = false
            await refreshCodex(userInitiated: pendingWasUserInitiated)
        }
    }

    private func refreshClaude(userInitiated: Bool = false) async {
        guard !isClaudeRefreshing else {
            claudeRefreshPending = true
            claudeUserInitiatedRefreshPending = claudeUserInitiatedRefreshPending || userInitiated
            return
        }
        isClaudeRefreshing = true
        updateRefreshingState()

        do {
            let result = try await claudeProvider.fetchSnapshotResult(
                userInitiated: userInitiated
            )
            claudeFailure = result.warning.map {
                QuotaFailure(
                    message: $0,
                    recoveryAction: result.warningRecoveryAction ?? .retry
                )
            }
            if result.warning == nil {
                onProviderConnected()
            }
            if result.isNewer(than: claude) {
                claude = result.snapshot
                claudeSource = result.source
                // A warning result is a local last-resort display value, not
                // a successful fresh collection. Never let it overwrite a
                // newer value in the user's private CloudKit database.
                if result.warning == nil {
                    await syncToCloudIfNeeded(result.snapshot)
                }
            }
        } catch {
            claudeFailure = QuotaFailure(
                message: Self.errorText(error),
                recoveryAction: QuotaFailureClassifier.recoveryAction(for: error)
            )
        }

        isClaudeRefreshing = false
        updateRefreshingState()
        updateSetupIssues()
        if claudeRefreshPending {
            claudeRefreshPending = false
            let pendingWasUserInitiated = claudeUserInitiatedRefreshPending
            claudeUserInitiatedRefreshPending = false
            await refreshClaude(userInitiated: pendingWasUserInitiated)
        }
    }

    private func observeProviderUpdates() {
        let codexUpdates = codexProvider.rateLimitUpdates()
        codexUpdatesTask = Task { [weak self] in
            for await _ in codexUpdates {
                guard let self, !Task.isCancelled else { return }
                self.scheduleCodexEventRefresh()
            }
        }

        let claudeUpdates = claudeProvider.cacheUpdates()
        claudeUpdatesTask = Task { [weak self] in
            for await _ in claudeUpdates {
                guard let self, !Task.isCancelled else { return }
                self.scheduleClaudeEventRefresh()
            }
        }
    }

    private func scheduleCodexEventRefresh() {
        codexEventRefreshTask?.cancel()
        codexEventRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            await self?.refreshCodex()
        }
    }

    private func scheduleClaudeEventRefresh() {
        claudeEventRefreshTask?.cancel()
        claudeEventRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            await self?.refreshClaude()
        }
    }

    /// Failures that aren't a `QuotaError` still reach the menu.
    /// `String(describing:)` would print a raw enum case there, so prefer
    /// whatever localized text the error carries.
    /// §6: every failure the UI shows ends in a next step. Shared with the
    /// iPhone store so one failure never gets two different phrasings.
    private static func errorText(_ error: Error) -> String {
        QuotaFormatting.failureText(error)
    }

    private func updateRefreshingState() {
        isRefreshing = isCodexRefreshing || isClaudeRefreshing
    }

    /// Pushes to the user's private CloudKit database so iPhone and Watch
    /// can pick this reading up, but only when `QuotaSyncThrottle` decides
    /// it is actually worth a network round trip — never on every poll.
    private func syncToCloudIfNeeded(_ snapshot: QuotaSnapshot) async {
        let provider = snapshot.provider
        let shouldSync = QuotaSyncThrottle.shouldSync(
            previous: lastPushedSnapshot[provider],
            next: snapshot,
            lastSyncedAt: lastPushedAt[provider]
        )
        guard shouldSync else { return }

        do {
            // 打上 `mac/` 标记：iPhone 判断「这个用户也在用 Mac 菜单栏」的唯一
            // 证据，就是云端出现过一条 Mac 采集的记录（更强 Activation，
            // ROADMAP v0.3 §4）。Mac 版没有主窗口，它就是菜单栏本身。
            try await cloudRepository.push(snapshot.taggedAsSource(.mac))
            lastPushedSnapshot[provider] = snapshot
            lastPushedAt[provider] = Date()
            iCloudStatusText = QuotaFormatting.syncedTimeText(Date())
            iCloudSyncError = nil
        } catch {
            let message = (error as? QuotaSyncError)?.description ?? error.localizedDescription
            iCloudStatusText = String(localized: "Sync failed")
            iCloudSyncError = message
        }
    }

    deinit {
        autoRefreshTask?.cancel()
        codexUpdatesTask?.cancel()
        claudeUpdatesTask?.cancel()
        codexEventRefreshTask?.cancel()
        claudeEventRefreshTask?.cancel()
        codexLoginTask?.cancel()
        claudeLoginTask?.cancel()
    }
}
