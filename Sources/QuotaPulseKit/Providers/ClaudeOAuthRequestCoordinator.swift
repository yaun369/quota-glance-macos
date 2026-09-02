import CryptoKit
import Foundation

/// Serializes and throttles requests against Claude's OAuth usage endpoint:
/// merges concurrent fetches, reuses a success for 120s of background polls,
/// and backs off after rate-limit/5xx/network failures. Keyed by the access
/// token's SHA-256 fingerprint so multiple accounts stay isolated without
/// retaining a reusable credential in memory. Shared by the macOS
/// `ClaudeQuotaProvider` OAuth tier and the cross-platform
/// `AccountDirectQuotaService` (iOS), which is why it lives outside the
/// macOS-gated provider file.
actor ClaudeOAuthRequestCoordinator {
    private struct CachedSnapshot: Sendable {
        let snapshot: QuotaSnapshot
        let succeededAt: Date
    }

    private struct RequestBlock: Sendable {
        let until: Date
        let error: ClaudeOAuthUsageError
    }

    private let minimumBackgroundInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let fetchSnapshot: @Sendable (String) async throws -> QuotaSnapshot

    // Access tokens are never retained as cache keys. Their SHA-256 digests
    // isolate accounts without preserving a reusable credential in memory.
    private var inFlightByToken: [Data: Task<QuotaSnapshot, Error>] = [:]
    private var cacheByToken: [Data: CachedSnapshot] = [:]
    private var requestBlockByToken: [Data: RequestBlock] = [:]

    init(
        client: ClaudeOAuthUsageClient,
        minimumBackgroundInterval: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) {
        self.minimumBackgroundInterval = minimumBackgroundInterval
        self.now = now
        self.fetchSnapshot = { accessToken in
            try await client.fetchSnapshot(accessToken: accessToken)
        }
    }

    init(
        minimumBackgroundInterval: TimeInterval,
        now: @escaping @Sendable () -> Date,
        fetchSnapshot: @escaping @Sendable (String) async throws -> QuotaSnapshot
    ) {
        self.minimumBackgroundInterval = minimumBackgroundInterval
        self.now = now
        self.fetchSnapshot = fetchSnapshot
    }

    func fetch(accessToken: String, userInitiated: Bool) async throws -> QuotaSnapshot {
        let tokenFingerprint = Self.fingerprint(accessToken)
        if let inFlight = inFlightByToken[tokenFingerprint] {
            return try await inFlight.value
        }

        let currentDate = now()
        if !userInitiated,
           let cached = cacheByToken[tokenFingerprint],
           currentDate.timeIntervalSince(cached.succeededAt) < minimumBackgroundInterval {
            return cached.snapshot
        }
        if let block = requestBlockByToken[tokenFingerprint], block.until > currentDate {
            throw block.error
        }

        let task = Task<QuotaSnapshot, Error> {
            try await fetchSnapshot(accessToken)
        }
        inFlightByToken[tokenFingerprint] = task

        do {
            let snapshot = try await task.value
            inFlightByToken[tokenFingerprint] = nil
            cacheByToken[tokenFingerprint] = CachedSnapshot(
                snapshot: snapshot,
                succeededAt: now()
            )
            requestBlockByToken[tokenFingerprint] = nil
            return snapshot
        } catch {
            inFlightByToken[tokenFingerprint] = nil
            if let oauthError = error as? ClaudeOAuthUsageError {
                switch oauthError {
                case .rateLimited(let retryAfter):
                    let until = retryAfter ?? now().addingTimeInterval(300)
                    requestBlockByToken[tokenFingerprint] = RequestBlock(
                        until: until,
                        error: .rateLimited(retryAfter: until)
                    )
                case .server(let statusCode, let message, let retryAfter)
                    where (500...599).contains(statusCode):
                    let until = retryAfter ?? now().addingTimeInterval(30)
                    requestBlockByToken[tokenFingerprint] = RequestBlock(
                        until: until,
                        error: .server(
                            statusCode: statusCode,
                            message: message,
                            retryAfter: until
                        )
                    )
                case .network:
                    requestBlockByToken[tokenFingerprint] = RequestBlock(
                        until: now().addingTimeInterval(10),
                        error: oauthError
                    )
                default:
                    break
                }
            }
            throw error
        }
    }

    private static func fingerprint(_ accessToken: String) -> Data {
        Data(SHA256.hash(data: Data(accessToken.utf8)))
    }
}
