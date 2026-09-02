import Foundation

public enum CodexUsageError: LocalizedError, Sendable, Equatable {
    case unauthorized
    case forbidden(String?)
    case rateLimited(retryAfter: Date?)
    case server(statusCode: Int, message: String?, retryAfter: Date?)
    case invalidResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return QuotaL10n.string(
                "codexUsage.unauthorized",
                "Your Codex sign-in is no longer valid. Please sign in again."
            )
        case .forbidden(let message):
            return message.map {
                QuotaL10n.string("codexUsage.forbidden.reason", "Your Codex account is not allowed to read usage: \($0)")
            } ?? QuotaL10n.string(
                "codexUsage.forbidden",
                "Your Codex account is not allowed to read usage. Please sign in again."
            )
        case .rateLimited(let retryAfter):
            if let retryAfter {
                let time = Self.timeFormatter.string(from: retryAfter)
                return QuotaL10n.string(
                    "codexUsage.rateLimited.retryAfter",
                    "The Codex usage endpoint is rate limiting requests. Try again after \(time)."
                )
            }
            return QuotaL10n.string(
                "codexUsage.rateLimited",
                "The Codex usage endpoint is rate limiting requests. Try again later."
            )
        case .server(let statusCode, let message, _):
            return message.map {
                QuotaL10n.string("codexUsage.httpStatus.reason", "The Codex usage endpoint returned HTTP \(String(statusCode)): \($0)")
            } ?? QuotaL10n.string("codexUsage.httpStatus", "The Codex usage endpoint returned HTTP \(String(statusCode)).")
        case .invalidResponse(let reason):
            return QuotaL10n.string("codexUsage.invalidResponse", "The Codex usage endpoint returned invalid data: \(reason)")
        case .network(let reason):
            return QuotaL10n.string("codexUsage.transportFailed", "The Codex usage request failed: \(reason)")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

extension CodexUsageError {
    /// `UsageRequestCoordinator`'s `classifyFailure` policy for this
    /// endpoint: rate limits and 5xx block further requests until their
    /// Retry-After (defaulting to 300s/30s), network failures get a short
    /// 10s cooldown, and everything else is not block-worthy. Shared by the
    /// macOS `CodexQuotaProvider` and the cross-platform
    /// `AccountDirectQuotaService`.
    static func requestBlockDecision(for error: Error, now: Date) -> (until: Date, error: Error)? {
        guard let usageError = error as? CodexUsageError else { return nil }
        switch usageError {
        case .rateLimited(let retryAfter):
            let until = retryAfter ?? now.addingTimeInterval(300)
            return (until, CodexUsageError.rateLimited(retryAfter: until))
        case .server(let statusCode, let message, let retryAfter) where (500...599).contains(statusCode):
            let until = retryAfter ?? now.addingTimeInterval(30)
            return (until, CodexUsageError.server(statusCode: statusCode, message: message, retryAfter: until))
        case .network:
            return (now.addingTimeInterval(10), usageError)
        default:
            return nil
        }
    }
}

/// Reads Codex usage from the same `/wham/usage` endpoint the ChatGPT web
/// dashboard's Codex analytics page calls — verified against
/// `codex-rs/backend-client/src/client/rate_limit_resets.rs`, which shows
/// this exact path answering `Authorization: Bearer` requests, not just
/// browser-cookie sessions. The `codex` CLI itself doesn't call this
/// endpoint for its own rate-limit display (it reads response headers on
/// ordinary completion calls instead); this client borrows the CLI's OAuth
/// credential to call the dashboard's endpoint, which is the standalone
/// "just tell me my usage" read this app needs.
final class CodexUsageClient: @unchecked Sendable {
    static let defaultEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// The 5-hour and 7-day windows, in seconds, that `CodexQuotaProvider`'s
    /// app-server path already classifies by (there, in minutes: 300 and
    /// 10_080). Kept in sync deliberately rather than derived, since the
    /// backend sends these as opaque integers, not a duration type.
    private static let sessionWindowSeconds = 18_000
    private static let weeklyWindowSeconds = 604_800

    private let endpoint: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let now: @Sendable () -> Date

    init(
        endpoint: URL = CodexUsageClient.defaultEndpoint,
        session: URLSession? = nil,
        requestTimeout: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.session = session ?? Self.makeEphemeralSession()
        self.requestTimeout = requestTimeout
        self.now = now
    }

    func fetchSnapshot(accessToken: String, accountID: String) async throws -> QuotaSnapshot {
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.host?.lowercased() == "chatgpt.com",
              endpoint.port == nil || endpoint.port == 443,
              endpoint.path == "/backend-api/wham/usage" else {
            throw CodexUsageError.invalidResponse(QuotaL10n.string(
                "reason.codexEndpointNotChatGPT",
                "the usage endpoint is not a ChatGPT HTTPS address"
            ))
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexUsageError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexUsageError.invalidResponse(QuotaL10n.string("reason.missingHTTPResponse", "no HTTP response"))
        }

        switch httpResponse.statusCode {
        case 200:
            return try decodeSnapshot(data)
        case 401:
            throw CodexUsageError.unauthorized
        case 403:
            throw CodexUsageError.forbidden(Self.errorMessage(from: data))
        case 429:
            throw CodexUsageError.rateLimited(
                retryAfter: Self.retryAfterDate(from: httpResponse, now: now())
            )
        default:
            throw CodexUsageError.server(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data),
                retryAfter: Self.retryAfterDate(from: httpResponse, now: now())
            )
        }
    }

    func decodeSnapshot(_ data: Data) throws -> QuotaSnapshot {
        let payload: UsageResponse
        do {
            payload = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw CodexUsageError.invalidResponse(error.localizedDescription)
        }

        var session = QuotaWindow()
        var weekly = QuotaWindow()

        for (key, raw) in [("primary", payload.rateLimit?.primaryWindow), ("secondary", payload.rateLimit?.secondaryWindow)] {
            guard let raw else { continue }
            let parsed = try mapWindow(raw)

            switch raw.limitWindowSeconds {
            case Self.sessionWindowSeconds:
                session = parsed
            case Self.weeklyWindowSeconds:
                weekly = parsed
            default:
                if key == "primary" {
                    session = parsed
                } else {
                    weekly = parsed
                }
            }
        }

        guard session.usedPercent != nil || weekly.usedPercent != nil else {
            throw CodexUsageError.invalidResponse(QuotaL10n.string(
                "reason.codexWindowsMissing",
                "primary_window and secondary_window quotas are both missing"
            ))
        }

        return QuotaSnapshot(provider: .codex, session: session, weekly: weekly, capturedAt: now())
    }

    private func mapWindow(_ raw: UsageWindow) throws -> QuotaWindow {
        guard let usedPercent = raw.usedPercent else { return QuotaWindow() }
        guard usedPercent.isFinite, (0...100).contains(usedPercent) else {
            throw CodexUsageError.invalidResponse(QuotaL10n.string(
                "reason.codexUsedPercentOutOfRange",
                "used_percent is outside 0...100"
            ))
        }
        let resetAt = raw.resetAt.map { Date(timeIntervalSince1970: $0) }
        // Mirrors ClaudeOAuthUsageClient: a window that claims to have been
        // captured after its own reset time is stale, not a fresh reading.
        if let resetAt, resetAt <= now() {
            return QuotaWindow()
        }
        return QuotaWindow(usedPercent: usedPercent, resetAt: resetAt)
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: CodexUsageRedirectBlocker(),
            delegateQueue: nil
        )
    }

    private static func retryAfterDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let message = envelope.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return nil
        }
        return message.count > 240 ? String(message.prefix(240)) + "…" : message
    }

    /// `RateLimitStatusPayload` / `RateLimitStatusDetails` /
    /// `RateLimitWindowSnapshot` in `codex-backend-openapi-models`, trimmed
    /// to the fields this app reads. `rate_limit` nests the windows one
    /// level deeper than the naive shape a first read of the endpoint
    /// suggests.
    private struct UsageResponse: Decodable {
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
        }
    }

    private struct RateLimit: Decodable {
        let primaryWindow: UsageWindow?
        let secondaryWindow: UsageWindow?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    private struct UsageWindow: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody?
    }

    private struct ErrorBody: Decodable {
        let message: String?
    }
}

private final class CodexUsageRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
