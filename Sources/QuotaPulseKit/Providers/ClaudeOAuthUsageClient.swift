import Foundation

enum ClaudeOAuthUsageError: LocalizedError, Sendable, Equatable {
    case unauthorized
    case forbidden(String?)
    case rateLimited(retryAfter: Date?)
    case server(statusCode: Int, message: String?, retryAfter: Date?)
    case invalidResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return QuotaL10n.string(
                "claudeUsage.unauthorized",
                "The Claude OAuth request was not authorized. Run Claude Code and sign in again."
            )
        case .forbidden(let message):
            return message.map {
                QuotaL10n.string(
                    "claudeUsage.forbidden.reason",
                    "The Claude OAuth credential is not allowed to read usage: \($0)"
                )
            } ?? QuotaL10n.string(
                "claudeUsage.forbidden",
                "The Claude OAuth credential is not allowed to read usage. Sign in again in Claude Code."
            )
        case .rateLimited(let retryAfter):
            if let retryAfter {
                let time = Self.timeFormatter.string(from: retryAfter)
                return QuotaL10n.string(
                    "claudeUsage.rateLimited.retryAfter",
                    "The Claude OAuth usage endpoint is rate limiting requests. Try again after \(time)."
                )
            }
            return QuotaL10n.string(
                "claudeUsage.rateLimited",
                "The Claude OAuth usage endpoint is rate limiting requests. Try again later."
            )
        case .server(let statusCode, let message, _):
            return message.map {
                QuotaL10n.string(
                    "claudeUsage.httpStatus.reason",
                    "The Claude OAuth usage endpoint returned HTTP \(String(statusCode)): \($0)"
                )
            } ?? QuotaL10n.string(
                "claudeUsage.httpStatus",
                "The Claude OAuth usage endpoint returned HTTP \(String(statusCode))."
            )
        case .invalidResponse(let reason):
            return QuotaL10n.string(
                "claudeUsage.invalidResponse",
                "The Claude OAuth usage endpoint returned invalid data: \(reason)"
            )
        case .network(let reason):
            return QuotaL10n.string("claudeUsage.transportFailed", "The Claude OAuth usage request failed: \(reason)")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

final class ClaudeOAuthUsageClient: @unchecked Sendable {
    static let defaultEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let endpoint: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let now: @Sendable () -> Date

    init(
        endpoint: URL = ClaudeOAuthUsageClient.defaultEndpoint,
        session: URLSession? = nil,
        requestTimeout: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.session = session ?? Self.makeEphemeralSession()
        self.requestTimeout = requestTimeout
        self.now = now
    }

    func fetchSnapshot(accessToken: String) async throws -> QuotaSnapshot {
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.host?.lowercased() == "api.anthropic.com",
              endpoint.port == nil || endpoint.port == 443,
              endpoint.path == "/api/oauth/usage" else {
            throw ClaudeOAuthUsageError.invalidResponse(QuotaL10n.string(
                "reason.claudeEndpointNotAnthropic",
                "the OAuth endpoint is not an Anthropic HTTPS address"
            ))
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeOAuthUsageError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeOAuthUsageError.invalidResponse(QuotaL10n.string("reason.missingHTTPResponse", "no HTTP response"))
        }

        switch httpResponse.statusCode {
        case 200:
            return try decodeSnapshot(data)
        case 401:
            throw ClaudeOAuthUsageError.unauthorized
        case 403:
            throw ClaudeOAuthUsageError.forbidden(Self.errorMessage(from: data))
        case 429:
            throw ClaudeOAuthUsageError.rateLimited(
                retryAfter: Self.retryAfterDate(from: httpResponse, now: now())
            )
        default:
            throw ClaudeOAuthUsageError.server(
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
            throw ClaudeOAuthUsageError.invalidResponse(error.localizedDescription)
        }

        let topLevelSession = try mapWindow(payload.fiveHour)
        let topLevelWeekly = try mapWindow(payload.sevenDay)
        let session = topLevelSession.usedPercent != nil
            ? topLevelSession
            : try firstActiveLimit(in: payload.limits) {
                $0.group == "session" || $0.kind == "session"
            }
        let weekly = topLevelWeekly.usedPercent != nil
            ? topLevelWeekly
            : try firstActiveLimit(in: payload.limits) {
                $0.group == "weekly" || $0.kind == "weekly_all"
            }
        guard session.usedPercent != nil || weekly.usedPercent != nil else {
            throw ClaudeOAuthUsageError.invalidResponse(QuotaL10n.string(
                "reason.claudeWindowsMissing",
                "five_hour and seven_day quotas are both missing"
            ))
        }

        return QuotaSnapshot(
            provider: .claude,
            session: session,
            weekly: weekly,
            capturedAt: now()
        )
    }

    private func mapWindow(_ raw: UsageWindow?) throws -> QuotaWindow {
        guard let raw else { return QuotaWindow() }
        if let utilization = raw.utilization,
           (!utilization.isFinite || !(0...100).contains(utilization)) {
            throw ClaudeOAuthUsageError.invalidResponse(QuotaL10n.string(
                "reason.claudeUtilizationOutOfRange",
                "utilization is outside 0...100"
            ))
        }
        let resetAt = try Self.parseISO8601(raw.resetsAt)
        // An expired API window is not a fresh reading merely because the
        // HTTP request just completed. Drop it and require at least one other
        // active window below.
        if let resetAt, resetAt <= now() {
            return QuotaWindow()
        }
        return QuotaWindow(
            usedPercent: raw.utilization,
            resetAt: resetAt
        )
    }

    private func firstActiveLimit(
        in limits: [UsageLimit]?,
        matching predicate: (UsageLimit) -> Bool
    ) throws -> QuotaWindow {
        for limit in limits ?? []
        where predicate(limit) && limit.percent != nil && (limit.scope?.isUnscoped ?? true) {
            let window = try mapWindow(UsageWindow(limit))
            if window.usedPercent != nil {
                return window
            }
        }
        return QuotaWindow()
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: ClaudeOAuthRedirectBlocker(),
            delegateQueue: nil
        )
    }

    private static func parseISO8601(_ value: String?) throws -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }
        throw ClaudeOAuthUsageError.invalidResponse(QuotaL10n.string(
            "reason.claudeResetsAtUnparsable",
            "resets_at could not be parsed"
        ))
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

    private struct UsageResponse: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let limits: [UsageLimit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }
    }

    private struct UsageWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        init(_ limit: UsageLimit) {
            utilization = limit.percent
            resetsAt = limit.resetsAt
        }

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    private struct UsageLimit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let resetsAt: String?
        let scope: UsageScope?

        enum CodingKeys: String, CodingKey {
            case kind
            case group
            case percent
            case resetsAt = "resets_at"
            case scope
        }
    }

    private struct UsageScope: Decodable {
        let model: JSONValue?
        let surface: JSONValue?

        var isUnscoped: Bool { model == nil && surface == nil }
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody?
    }

    private struct ErrorBody: Decodable {
        let message: String?
    }
}

private final class ClaudeOAuthRedirectBlocker: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The endpoint is fixed. Refusing redirects avoids ever forwarding a
        // Bearer credential across an unexpected redirect boundary.
        completionHandler(nil)
    }
}
