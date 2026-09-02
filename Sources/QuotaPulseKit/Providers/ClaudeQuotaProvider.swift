#if os(macOS)
import CryptoKit
import Darwin
import Foundation

public enum ClaudeQuotaSource: String, Sendable, Equatable {
    case statusLine
    case oauthUsage

    public var displayName: String {
        switch self {
        case .statusLine: return "StatusLine"
        case .oauthUsage: return "OAuth Usage"
        }
    }
}

public struct ClaudeQuotaFetchResult: Sendable, Equatable {
    public let snapshot: QuotaSnapshot
    public let source: ClaudeQuotaSource
    public let warning: String?
    public let warningRecoveryAction: QuotaRecoveryAction?

    public init(
        snapshot: QuotaSnapshot,
        source: ClaudeQuotaSource,
        warning: String? = nil,
        warningRecoveryAction: QuotaRecoveryAction? = nil
    ) {
        self.snapshot = snapshot
        self.source = source
        self.warning = warning
        self.warningRecoveryAction = warningRecoveryAction
    }

    /// Prevents an old StatusLine fallback from replacing a newer OAuth
    /// reading already visible in the app.
    public func isNewer(than current: QuotaSnapshot?) -> Bool {
        guard let current else { return true }
        return snapshot.capturedAt > current.capturedAt
    }
}

public final class ClaudeQuotaProvider: QuotaProvider, Sendable {
    public let provider: Provider = .claude

    private let cacheURL: URL
    private let statusLineFreshnessInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let loadCredentials: @Sendable () throws -> ClaudeOAuthCredentials
    private let fetchOAuthSnapshot: @Sendable (String, Bool) async throws -> QuotaSnapshot
    /// Refreshes and persists a token this app obtained itself via
    /// `ClaudeOAuthLoginService` — entirely separate from `loadCredentials`
    /// above, which only ever reads Claude Code's borrowed credential file
    /// and never refreshes it. Consulted first; `loadCredentials` remains
    /// the fallback for anyone who hasn't logged in through the app. `nil`
    /// only when built through the injecting test initializer, in which
    /// case the self-issued-token tier is skipped entirely.
    private let ownAccountRefresher: OAuthTokenRefresher?
    private let environment: [String: String]
    private let revisionStore = ClaudeStatusLineRevisionStore()

    public init(
        cacheURL: URL = ClaudeStatusLineInstaller.default.cacheURL,
        statusLineFreshnessInterval: TimeInterval = 120
    ) {
        self.cacheURL = cacheURL
        self.statusLineFreshnessInterval = statusLineFreshnessInterval
        self.now = { Date() }
        self.environment = ProcessInfo.processInfo.environment

        let credentialsLoader = ClaudeOAuthCredentialsLoader()
        let oauthCoordinator = ClaudeOAuthRequestCoordinator(
            client: ClaudeOAuthUsageClient(),
            minimumBackgroundInterval: 120,
            now: { Date() }
        )
        self.loadCredentials = { try credentialsLoader.load() }
        self.fetchOAuthSnapshot = { accessToken, userInitiated in
            try await oauthCoordinator.fetch(
                accessToken: accessToken,
                userInitiated: userInitiated
            )
        }

        let loginService = ClaudeOAuthLoginService()
        self.ownAccountRefresher = OAuthTokenRefresher(
            provider: .claude,
            store: OAuthTokenStore(),
            now: { Date() },
            performRefresh: { token in try await loginService.refresh(refreshToken: token) }
        )
    }

    /// Test-only entry point. Leaving `ownAccountRefresher` nil skips the
    /// self-issued-token tier entirely, so tests that don't care about it
    /// get "not logged in" deterministically without touching any keychain.
    init(
        cacheURL: URL,
        statusLineFreshnessInterval: TimeInterval,
        now: @escaping @Sendable () -> Date,
        loadCredentials: @escaping @Sendable () throws -> ClaudeOAuthCredentials,
        fetchOAuthSnapshot: @escaping @Sendable (String, Bool) async throws -> QuotaSnapshot,
        ownAccountRefresher: OAuthTokenRefresher? = nil,
        environment: [String: String] = [:]
    ) {
        self.cacheURL = cacheURL
        self.statusLineFreshnessInterval = statusLineFreshnessInterval
        self.now = now
        self.loadCredentials = loadCredentials
        self.fetchOAuthSnapshot = fetchOAuthSnapshot
        self.ownAccountRefresher = ownAccountRefresher
        self.environment = environment
    }

    // MARK: - Credential lifecycle

    /// Persists a credential from a completed interactive login, through the
    /// same cached refresher the fetch path reads — the app layer must never
    /// write the Keychain item with its own `OAuthTokenStore`, or the cache
    /// would go stale against it.
    public func storeCredential(_ credential: OAuthCredential) async throws {
        try await requireOwnRefresher().storeCredential(credential)
    }

    /// Local sign-out: removes the stored credential so the next refresh
    /// falls back to the borrowed Claude Code credential (or the status
    /// line, or the setup guidance).
    public func signOut() async throws {
        try await requireOwnRefresher().clearCredential()
    }

    /// Display label of the connected account, or `nil` when no login is
    /// stored. Never refreshes, prompts, or touches the network.
    public func storedAccountLabel() async -> String? {
        guard let ownAccountRefresher,
              let credential = try? await ownAccountRefresher.storedCredential() else { return nil }
        return credential.accountLabel
    }

    private func requireOwnRefresher() -> OAuthTokenRefresher {
        guard let ownAccountRefresher else {
            preconditionFailure("credential lifecycle requires the production initializer")
        }
        return ownAccountRefresher
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        try await fetchSnapshotResult(userInitiated: true).snapshot
    }

    public func fetchSnapshotResult(
        userInitiated: Bool
    ) async throws -> ClaudeQuotaFetchResult {
        let statusLineResult: Result<StatusLineReading, Error>
        do {
            statusLineResult = .success(try readStatusLine())
        } catch {
            statusLineResult = .failure(error)
        }

        if case .success(let reading) = statusLineResult {
            let changed = await revisionStore.observe(reading.revision)
            if changed && isFreshEnoughToPrefer(reading.snapshot) {
                return ClaudeQuotaFetchResult(snapshot: reading.snapshot, source: .statusLine)
            }
        }

        do {
            let snapshot = try await fetchFromOAuth(userInitiated: userInitiated)
            return ClaudeQuotaFetchResult(snapshot: snapshot, source: .oauthUsage)
        } catch {
            let oauthReason = Self.errorDescription(error)
            if case .success(let reading) = statusLineResult {
                return ClaudeQuotaFetchResult(
                    snapshot: reading.snapshot,
                    source: .statusLine,
                    warning: QuotaL10n.string("source.warning.oauthUsage", "OAuth Usage: \(oauthReason)"),
                    warningRecoveryAction: QuotaFailureClassifier.recoveryAction(for: error)
                )
            }

            let statusLineReason: String
            if case .failure(let statusLineError) = statusLineResult {
                statusLineReason = Self.errorDescription(statusLineError)
            } else {
                statusLineReason = QuotaL10n.string("source.statusLine.noData", "No status line data available")
            }
            throw QuotaError.claudeOAuthFallbackFailed(
                statusLineReason: statusLineReason,
                oauthReason: oauthReason
            )
        }
    }

    private func readStatusLine() throws -> StatusLineReading {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            throw QuotaError.noCachedDataYet(path: cacheURL.path)
        }

        let data = try Data(contentsOf: cacheURL)
        let cache: ClaudeStatusLineCache
        do {
            cache = try JSONDecoder().decode(ClaudeStatusLineCache.self, from: data)
        } catch {
            throw QuotaError.cacheDecodeFailed(error.localizedDescription)
        }
        try validate(cache)

        func window(_ raw: ClaudeRateWindow?) -> QuotaWindow {
            QuotaWindow(
                usedPercent: raw?.usedPercentage,
                resetAt: raw?.resetsAt.map(Date.init(timeIntervalSince1970:))
            )
        }

        // capturedAt reflects when Claude Code last ran the statusLine
        // script, not "now" — that's what lets the UI say "last synced 12
        // minutes ago" instead of always claiming to be fresh.
        let snapshot = QuotaSnapshot(
            provider: .claude,
            session: window(cache.fiveHour),
            weekly: window(cache.sevenDay),
            capturedAt: Date(timeIntervalSince1970: cache.capturedAt)
        )
        return StatusLineReading(
            snapshot: snapshot,
            revision: StatusLineRevision(
                capturedAt: cache.capturedAt,
                fiveHourUsedPercent: cache.fiveHour?.usedPercentage,
                fiveHourResetsAt: cache.fiveHour?.resetsAt,
                sevenDayUsedPercent: cache.sevenDay?.usedPercentage,
                sevenDayResetsAt: cache.sevenDay?.resetsAt
            )
        )
    }

    private func validate(_ cache: ClaudeStatusLineCache) throws {
        guard cache.capturedAt.isFinite, cache.capturedAt > 0 else {
            throw QuotaError.cacheDecodeFailed("capturedAt is invalid")
        }
        guard cache.capturedAt <= now().addingTimeInterval(300).timeIntervalSince1970 else {
            throw QuotaError.cacheDecodeFailed("capturedAt is too far in the future")
        }
        guard cache.fiveHour?.usedPercentage != nil || cache.sevenDay?.usedPercentage != nil else {
            throw QuotaError.cacheDecodeFailed("cache does not contain any quota windows")
        }

        for window in [cache.fiveHour, cache.sevenDay].compactMap({ $0 }) {
            if let usedPercentage = window.usedPercentage,
               (!usedPercentage.isFinite || !(0...100).contains(usedPercentage)) {
                throw QuotaError.cacheDecodeFailed("used_percentage is outside 0...100")
            }

            // A status-line payload describes a currently active limit
            // window. If it claims to have been captured well after that
            // window reset, it is stale or synthetic and must not replace a
            // real reading. Allow five minutes for clock skew.
            if let resetsAt = window.resetsAt,
               (!resetsAt.isFinite || cache.capturedAt > resetsAt + 300) {
                throw QuotaError.cacheDecodeFailed(
                    "capturedAt is later than the reported reset time"
                )
            }
        }
    }

    private func isFreshEnoughToPrefer(_ snapshot: QuotaSnapshot) -> Bool {
        let currentDate = now()
        let age = currentDate.timeIntervalSince(snapshot.capturedAt)
        guard age >= -300, age <= statusLineFreshnessInterval else { return false }
        guard snapshot.session.usedPercent != nil || snapshot.weekly.usedPercent != nil else {
            return false
        }

        for window in [snapshot.session, snapshot.weekly] where window.usedPercent != nil {
            if let resetAt = window.resetAt, resetAt <= currentDate {
                return false
            }
        }
        return true
    }

    private func fetchFromOAuth(userInitiated: Bool) async throws -> QuotaSnapshot {
        // Highest priority: an explicit override always wins, even over a
        // completed in-app login — it exists specifically so a developer or
        // CI run can force a particular token regardless of what's stored.
        if let token = Self.environmentOverrideToken(environment) {
            return try await fetchOAuthSnapshot(token, userInitiated)
        }

        // Next: a token this app obtained itself. `validCredential()`
        // refreshes proactively when needed; only a genuine "nothing ever
        // stored" (`nil`) falls through to the borrowed credential below. A
        // stored login that cannot be produced right now (keychain failure,
        // failed or rejected refresh) throws instead of falling through —
        // blaming the borrowed tier would point the user at Claude Code
        // rather than at their own signed-in account, and the status-line
        // fallback in `fetchSnapshotResult` still keeps data flowing while
        // the real reason shows as the warning.
        if let ownAccountRefresher,
           let ownCredential = try await ownAccountRefresher.validCredential() {
            do {
                return try await fetchOAuthSnapshot(ownCredential.accessToken, userInitiated)
            } catch ClaudeOAuthUsageError.unauthorized {
                // The clock-based check above was optimistic (clock skew,
                // early server-side revocation) — force one refresh, same
                // "retry exactly once" contract as the borrowed path below.
                let refreshed = try await ownAccountRefresher.forceRefresh()
                return try await fetchOAuthSnapshot(refreshed.accessToken, userInitiated)
            }
        }

        // Last resort: whatever Claude Code itself is using — read from its
        // credentials file only, never from its Keychain item.
        let credentials = try loadCredentials()
        let accessToken = try credentials.accessTokenForUsage(now: now())

        do {
            return try await fetchOAuthSnapshot(accessToken, userInitiated)
        } catch ClaudeOAuthUsageError.unauthorized {
            // Claude Code may have rotated its access token between the first
            // credentials read and this request. Re-read once, but never
            // refresh or write Claude's refresh token ourselves.
            let refreshedCredentials = try loadCredentials()
            let refreshedToken = try refreshedCredentials.accessTokenForUsage(now: now())
            guard refreshedToken != accessToken else {
                throw ClaudeOAuthUsageError.unauthorized
            }
            return try await fetchOAuthSnapshot(refreshedToken, userInitiated)
        }
    }

    /// Same two variables `ClaudeOAuthCredentialsLoader` checks — mirrored
    /// here (rather than routed through it) so the override can take effect
    /// before the self-issued-token tier is even consulted, not just before
    /// the borrowed-credential tier at the end of the chain.
    private static func environmentOverrideToken(_ environment: [String: String]) -> String? {
        if let token = environment["QUOTAPULSE_CLAUDE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        return nil
    }

    /// These strings are embedded in the `warning` and in
    /// `claudeOAuthFallbackFailed`, both of which surface in the menu bar
    /// app. The OAuth half of that pairing is already localized, so the
    /// status-line half uses the user-facing wording too rather than
    /// producing a half-English sentence.
    private static func errorDescription(_ error: Error) -> String {
        if let error = error as? QuotaError {
            return error.userFacingDescription
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    /// Watches the cache directory rather than the file itself so updates
    /// remain observable when the status-line hook writes via atomic rename.
    public func cacheUpdates() -> AsyncStream<Void> {
        let directoryURL = cacheURL.deletingLastPathComponent()

        return AsyncStream { continuation in
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            } catch {
                continuation.finish()
                return
            }

            let descriptor = open(directoryURL.path, O_EVTONLY)
            guard descriptor >= 0 else {
                continuation.finish()
                return
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend, .attrib],
                queue: DispatchQueue(label: "quotapulse.claude-cache-watcher")
            )
            source.setEventHandler {
                continuation.yield(())
            }
            source.setCancelHandler {
                close(descriptor)
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }
    }
}

private struct StatusLineReading: Sendable {
    let snapshot: QuotaSnapshot
    let revision: StatusLineRevision
}

private struct StatusLineRevision: Sendable, Equatable {
    let capturedAt: Double
    let fiveHourUsedPercent: Double?
    let fiveHourResetsAt: Double?
    let sevenDayUsedPercent: Double?
    let sevenDayResetsAt: Double?
}

private actor ClaudeStatusLineRevisionStore {
    private var lastRevision: StatusLineRevision?

    func observe(_ revision: StatusLineRevision) -> Bool {
        defer { lastRevision = revision }
        return lastRevision != revision
    }
}
#endif
