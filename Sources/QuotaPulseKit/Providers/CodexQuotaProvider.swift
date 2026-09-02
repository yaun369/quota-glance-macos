#if os(macOS)
import Foundation

public enum CodexQuotaSource: String, Sendable, Equatable {
    case accountDirect
    case appServer

    public var displayName: String {
        switch self {
        case .accountDirect: return QuotaL10n.string("source.accountDirect", "Account direct")
        case .appServer: return "Codex CLI"
        }
    }
}

public struct CodexQuotaFetchResult: Sendable, Equatable {
    public let snapshot: QuotaSnapshot
    public let source: CodexQuotaSource
    public let warning: String?
    public let warningRecoveryAction: QuotaRecoveryAction?

    public init(
        snapshot: QuotaSnapshot,
        source: CodexQuotaSource,
        warning: String? = nil,
        warningRecoveryAction: QuotaRecoveryAction? = nil
    ) {
        self.snapshot = snapshot
        self.source = source
        self.warning = warning
        self.warningRecoveryAction = warningRecoveryAction
    }

    /// Prevents an app-server reading, arriving after a direct-connect
    /// reading already visible in the app, from stomping something newer —
    /// same rationale as `ClaudeQuotaFetchResult.isNewer(than:)`.
    public func isNewer(than current: QuotaSnapshot?) -> Bool {
        guard let current else { return true }
        return snapshot.capturedAt > current.capturedAt
    }
}

public final class CodexQuotaProvider: QuotaProvider, Sendable {
    /// Direct-connect errors that would look identical on a retry (bad
    /// response shape, an access token the server has flatly rejected) fall
    /// back to app-server immediately rather than waiting for three losses
    /// in a row — that budget exists for transient network trouble, not for
    /// errors already known to be sticky.
    private static let consecutiveFailureThreshold = 3

    public let provider: Provider = .codex

    private let client: CodexAppServerClient
    private let requestTimeout: TimeInterval
    private let retryDelay: Duration
    private let loadCredential: @Sendable () async throws -> OAuthCredential?
    private let fetchDirectSnapshot: @Sendable (String, String, Bool) async throws -> QuotaSnapshot
    /// The refresher behind `loadCredential`, kept so the credential
    /// lifecycle below routes every mutation through its in-memory cache.
    /// `nil` only when built through the injecting test initializer.
    private let ownRefresher: OAuthTokenRefresher?
    private let failureTracker = DirectFailureTracker()

    /// Production entry point. Reads (and, via the lifecycle methods below,
    /// writes) the user's real `QuotaPulse-OAuth-Codex` Keychain item once a
    /// fetch runs — tests must always use the injecting initializer instead.
    public init(
        client: CodexAppServerClient = CodexAppServerClient(),
        requestTimeout: TimeInterval = 15,
        retryDelay: Duration = .milliseconds(300)
    ) {
        self.client = client
        self.requestTimeout = requestTimeout
        self.retryDelay = retryDelay

        let store = OAuthTokenStore()
        let usageClient = CodexUsageClient()
        let loginService = CodexOAuthLoginService()
        let refresher = OAuthTokenRefresher(
            provider: .codex,
            store: store,
            performRefresh: { token in try await loginService.refresh(refreshToken: token) }
        )
        let coordinator = UsageRequestCoordinator<QuotaSnapshot, String>(
            minimumBackgroundInterval: 120,
            classifyFailure: { error, now in CodexUsageError.requestBlockDecision(for: error, now: now) }
        )

        self.ownRefresher = refresher
        self.loadCredential = { try await refresher.validCredential() }
        self.fetchDirectSnapshot = { accessToken, accountID, userInitiated in
            try await coordinator.fetch(key: "codex", userInitiated: userInitiated) {
                try await usageClient.fetchSnapshot(accessToken: accessToken, accountID: accountID)
            }
        }
    }

    /// Test-only entry point: every network-touching collaborator above is
    /// injected directly instead of being reachable only through the
    /// production initializer's closures.
    init(
        client: CodexAppServerClient,
        requestTimeout: TimeInterval,
        retryDelay: Duration,
        loadCredential: @escaping @Sendable () async throws -> OAuthCredential?,
        fetchDirectSnapshot: @escaping @Sendable (String, String, Bool) async throws -> QuotaSnapshot
    ) {
        self.client = client
        self.requestTimeout = requestTimeout
        self.retryDelay = retryDelay
        self.ownRefresher = nil
        self.loadCredential = loadCredential
        self.fetchDirectSnapshot = fetchDirectSnapshot
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
    /// falls back to `codex app-server` (or the "not connected" setup
    /// guidance, if that isn't available either).
    public func signOut() async throws {
        try await requireOwnRefresher().clearCredential()
    }

    /// Whether an account-direct login is stored, without refreshing,
    /// prompting, or touching the network.
    public func hasStoredCredential() async -> Bool {
        guard let ownRefresher else { return false }
        return (try? await ownRefresher.storedCredential()) != nil
    }

    /// Display label of the connected account ("person@example.com"), or
    /// `nil` when no login is stored. Same non-interactive guarantee as
    /// `hasStoredCredential()`.
    public func storedAccountLabel() async -> String? {
        guard let ownRefresher,
              let credential = try? await ownRefresher.storedCredential() else { return nil }
        return credential.accountLabel
    }

    private func requireOwnRefresher() -> OAuthTokenRefresher {
        guard let ownRefresher else {
            preconditionFailure("credential lifecycle requires the production initializer")
        }
        return ownRefresher
    }

    /// Unqualified callers (the app's background poll loop, `quota-cli`)
    /// get the throttled/cached background behavior; callers that want a
    /// forced, immediate direct-connect attempt and the source/warning
    /// detail use `fetchSnapshotResult(userInitiated:)` directly.
    public func fetchSnapshot() async throws -> QuotaSnapshot {
        try await fetchSnapshotResult(userInitiated: false).snapshot
    }

    public func fetchSnapshotResult(userInitiated: Bool) async throws -> CodexQuotaFetchResult {
        // `nil` — nothing ever stored — legitimately falls through to the
        // CLI-backed app-server path below. A stored login that cannot be
        // produced right now (Keychain failure, failed or rejected refresh)
        // must instead propagate as-is: reporting the app-server's "install
        // the codex CLI" guidance to a signed-in user would bury the real,
        // actionable problem behind an irrelevant one.
        if let credential = try await loadCredential(), let accountID = credential.accountID {
            do {
                let snapshot = try await fetchDirectSnapshot(credential.accessToken, accountID, userInitiated)
                await failureTracker.reset()
                return CodexQuotaFetchResult(snapshot: snapshot, source: .accountDirect)
            } catch let directError {
                let failureCount = await failureTracker.recordFailure()
                guard Self.isHardFailure(directError) || failureCount >= Self.consecutiveFailureThreshold else {
                    // A single transient network hiccup: surface it as-is and
                    // let the next poll retry direct-connect, rather than
                    // flapping over to a source that may not even be
                    // available (app-server requires the codex CLI to be
                    // installed and logged in separately).
                    throw directError
                }
                await failureTracker.reset()
                do {
                    let snapshot = try await fetchFromAppServer()
                    return CodexQuotaFetchResult(
                        snapshot: snapshot,
                        source: .appServer,
                        warning: QuotaL10n.string(
                            "source.warning.accountDirect",
                            "Account direct: \(Self.errorDescription(directError))"
                        ),
                        warningRecoveryAction: QuotaFailureClassifier.recoveryAction(for: directError)
                    )
                } catch let appServerError {
                    throw QuotaError.codexDirectFallbackFailed(
                        directReason: Self.errorDescription(directError),
                        appServerReason: Self.errorDescription(appServerError)
                    )
                }
            }
        }

        do {
            let snapshot = try await fetchFromAppServer()
            return CodexQuotaFetchResult(snapshot: snapshot, source: .appServer)
        } catch {
            throw Self.noStoredLoginError(from: error)
        }
    }

    /// Rewrites the app-server path's failure for the "nothing signed in"
    /// case only. A missing CLI there must not surface as "install the codex
    /// CLI" — signing in requires no install at all, so the message should
    /// lead with that. The signed-in fallback path keeps the raw CLI error:
    /// there the user already chose account-direct, and
    /// `codexDirectFallbackFailed` must explain both failures.
    static func noStoredLoginError(from appServerError: Error) -> Error {
        if case QuotaError.executableNotFound = appServerError {
            return QuotaError.codexNotConnected
        }
        return appServerError
    }

    /// Emits whenever the app-server announces that rate limits changed.
    /// Notifications are sparse, so callers should use them as a trigger to
    /// fetch a complete snapshot rather than trying to merge them directly.
    /// Only meaningful while the app-server path is the active source — a
    /// caller on the direct-connect path should rely on
    /// `fetchSnapshotResult`'s own polling interval instead.
    public func rateLimitUpdates() -> AsyncStream<Void> {
        let notifications = client.notifications()
        return AsyncStream { continuation in
            let task = Task {
                for await notification in notifications {
                    guard notification.method == "account/rateLimits/updated" else {
                        continue
                    }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func fetchFromAppServer() async throws -> QuotaSnapshot {
        do {
            return try await fetchSnapshotOnce()
        } catch where Self.isRetryable(error) {
            try? await Task.sleep(for: retryDelay)
            return try await fetchSnapshotOnce()
        }
    }

    private func fetchSnapshotOnce() async throws -> QuotaSnapshot {
        let result = try await client.request(
            method: "account/rateLimits/read",
            timeout: requestTimeout
        )

        // The real payload nests the windows under "rateLimits"
        // (GetAccountRateLimitsResponse, per `codex app-server
        // generate-json-schema`); the top level also carries
        // "rateLimitsByLimitId" and "rateLimitResetCredits", which this app
        // doesn't need.
        guard let rateLimits = result["rateLimits"], case .object = rateLimits else {
            throw QuotaError.invalidResponse("account/rateLimits/read response is missing 'rateLimits'")
        }

        var session = QuotaWindow()
        var weekly = QuotaWindow()

        // Codex documents "primary"/"secondary" windows distinguished by
        // windowDurationMins (300 = 5h, 10080 = 7d). Fall back to the
        // primary/secondary position if Codex ever reports an unfamiliar
        // duration, so a constant change degrades gracefully instead of
        // silently dropping a reading.
        for key in ["primary", "secondary"] {
            // Codex reports an *absent* window as JSON `null` rather than
            // omitting the key (e.g. a plan with only one active window has
            // `"secondary":null`). `rateLimits[key]` returns `.null` itself
            // in that case, not `nil`, so this must check the case
            // explicitly — otherwise the fallback branch below treats the
            // null window as an "unfamiliar duration" primary/secondary
            // reading and overwrites whichever window was already parsed.
            guard let window = rateLimits[key], case .object = window else { continue }
            let parsed = QuotaWindow(
                usedPercent: window["usedPercent"]?.doubleValue,
                resetAt: window["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
            )

            switch window["windowDurationMins"]?.intValue {
            case 300:
                session = parsed
            case 10_080:
                weekly = parsed
            default:
                if key == "primary" {
                    session = parsed
                } else {
                    weekly = parsed
                }
            }
        }

        return QuotaSnapshot(provider: .codex, session: session, weekly: weekly, capturedAt: Date())
    }

    private static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case QuotaError.requestTimedOut,
             QuotaError.appServerExited,
             QuotaError.appServerLaunchFailed:
            return true
        default:
            return false
        }
    }

    /// `false` (a transient, worth-retrying-as-is failure) only for the
    /// network-shaped `CodexUsageError` cases; everything else — a rejected
    /// token, a response this app can't parse, a refresher/keychain error —
    /// is treated as sticky enough to fall back to app-server immediately.
    private static func isHardFailure(_ error: Error) -> Bool {
        guard let usageError = error as? CodexUsageError else { return true }
        switch usageError {
        case .network, .rateLimited, .server:
            return false
        case .unauthorized, .forbidden, .invalidResponse:
            return true
        }
    }

    private static func errorDescription(_ error: Error) -> String {
        if let error = error as? QuotaError {
            return error.userFacingDescription
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

/// Counts consecutive direct-connect failures across calls to decide when
/// to fall back to app-server; reset on any success.
private actor DirectFailureTracker {
    private var count = 0

    func recordFailure() -> Int {
        count += 1
        return count
    }

    func reset() {
        count = 0
    }
}
#endif
