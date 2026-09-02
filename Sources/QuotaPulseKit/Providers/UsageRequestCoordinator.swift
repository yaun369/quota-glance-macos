import Foundation

/// Coalesces concurrent usage-fetch requests, throttles background polling,
/// and backs off after failures — generalized out of the policy
/// `ClaudeQuotaProvider`'s `ClaudeOAuthRequestCoordinator` already
/// implements for Claude, so `CodexQuotaProvider`'s direct-connect path can
/// share the same behavior without duplicating it. `Claude` continues to
/// use its own coordinator unchanged; migrating it onto this shared type is
/// a follow-up with no user-facing benefit on its own.
///
/// `Key` scopes all of the state below — one account's in-flight request,
/// cache and backoff never affect another's. Codex has exactly one signed-in
/// account at a time, so it can use a single constant key; a coordinator
/// that ever needs to support multiple concurrent accounts (as Claude's
/// token-fingerprint keying does today) can key by whatever identifies an
/// account there.
public actor UsageRequestCoordinator<Snapshot: Sendable, Key: Hashable & Sendable> {
    private struct CachedSnapshot: Sendable {
        let snapshot: Snapshot
        let succeededAt: Date
    }

    private struct RequestBlock: Sendable {
        let until: Date
        let error: Error
    }

    private let minimumBackgroundInterval: TimeInterval
    private let now: @Sendable () -> Date
    /// Given a failure and the moment it happened, decides whether (and
    /// until when) subsequent calls for the same key should be blocked
    /// without retrying, and what error to surface for them. Returning
    /// `nil` means "don't block" — the next call retries immediately.
    private let classifyFailure: @Sendable (Error, Date) -> (until: Date, error: Error)?

    private var inFlightByKey: [Key: Task<Snapshot, Error>] = [:]
    private var cacheByKey: [Key: CachedSnapshot] = [:]
    private var requestBlockByKey: [Key: RequestBlock] = [:]

    public init(
        minimumBackgroundInterval: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        classifyFailure: @escaping @Sendable (Error, Date) -> (until: Date, error: Error)? = { _, _ in nil }
    ) {
        self.minimumBackgroundInterval = minimumBackgroundInterval
        self.now = now
        self.classifyFailure = classifyFailure
    }

    /// Runs `operation` for `key`, or returns an in-flight/cached/blocked
    /// result instead:
    /// - a request already in flight for this key is awaited and shared;
    /// - a background call (`userInitiated == false`) within
    ///   `minimumBackgroundInterval` of the last success reuses that
    ///   snapshot rather than issuing a new request;
    /// - a key still inside a backoff window from `classifyFailure` throws
    ///   that window's error immediately instead of retrying.
    public func fetch(
        key: Key,
        userInitiated: Bool,
        operation: @escaping @Sendable () async throws -> Snapshot
    ) async throws -> Snapshot {
        if let inFlight = inFlightByKey[key] {
            return try await inFlight.value
        }

        let currentDate = now()
        if !userInitiated,
           let cached = cacheByKey[key],
           currentDate.timeIntervalSince(cached.succeededAt) < minimumBackgroundInterval {
            return cached.snapshot
        }
        if let block = requestBlockByKey[key], block.until > currentDate {
            throw block.error
        }

        let task = Task<Snapshot, Error> {
            try await operation()
        }
        inFlightByKey[key] = task

        do {
            let snapshot = try await task.value
            inFlightByKey[key] = nil
            cacheByKey[key] = CachedSnapshot(snapshot: snapshot, succeededAt: now())
            requestBlockByKey[key] = nil
            return snapshot
        } catch {
            inFlightByKey[key] = nil
            if let decision = classifyFailure(error, currentDate) {
                requestBlockByKey[key] = RequestBlock(until: decision.until, error: decision.error)
            }
            throw error
        }
    }
}
