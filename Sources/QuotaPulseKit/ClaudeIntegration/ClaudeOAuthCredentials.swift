#if os(macOS)
import Foundation

struct ClaudeOAuthCredentials: Sendable, Equatable {
    let accessToken: String
    let expiresAt: Date?
    let scopes: [String]

    func accessTokenForUsage(now: Date) throws -> String {
        if let expiresAt, expiresAt <= now.addingTimeInterval(30) {
            throw ClaudeOAuthCredentialError.expired
        }
        if !scopes.isEmpty, !scopes.contains("user:profile") {
            throw ClaudeOAuthCredentialError.missingUserProfileScope
        }
        return accessToken
    }
}

enum ClaudeOAuthCredentialError: LocalizedError, Sendable, Equatable {
    case notFound
    case invalidPayload
    case missingAccessToken
    case expired
    case missingUserProfileScope
    case fileReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return QuotaL10n.string(
                "claudeCredentials.notFound",
                "No usable Claude OAuth credential was found. Sign in to your Claude account in the app."
            )
        case .invalidPayload:
            return QuotaL10n.string("claudeCredentials.malformed", "The Claude Code OAuth credential is malformed.")
        case .missingAccessToken:
            return QuotaL10n.string(
                "claudeCredentials.missingAccessToken",
                "The Claude Code OAuth credential has no access token."
            )
        case .expired:
            return QuotaL10n.string(
                "claudeCredentials.expired",
                "The Claude Code OAuth access token has expired. Run Claude Code or sign in again, then refresh."
            )
        case .missingUserProfileScope:
            return QuotaL10n.string(
                "claudeCredentials.missingScope",
                "The Claude Code OAuth credential is missing the user:profile scope. Sign in again in Claude Code."
            )
        case .fileReadFailed(let reason):
            return QuotaL10n.string("claudeCredentials.readFailed", "Could not read the Claude Code OAuth credential file: \(reason)")
        }
    }
}

/// Reads the borrowed Claude Code credential from its on-disk credentials
/// file, plus the two environment-variable overrides.
///
/// Deliberately does NOT read Claude Code's Keychain item
/// (`Claude Code-credentials`): that item lives in the legacy login keychain
/// behind an ACL owned by Claude Code, so any read from this app risks the
/// system's cross-app authorization dialog — and a denial re-arms it for the
/// next read, which is exactly the prompt storm this app must never cause.
/// Installs whose credential exists only in the Keychain are treated as "no
/// borrowed credential"; their data comes from the status line or an in-app
/// login instead.
struct ClaudeOAuthCredentialsLoader: Sendable {
    /// `nil` means "wherever Claude Code's configuration directory currently
    /// resolves to", which is only known once `ClaudeConfigLocator`'s probe
    /// has run. Tests and callers with a fixed path pass one in.
    private let credentialsFileOverride: URL?
    private let quotaPulseOverrideToken: String?
    private let claudeCodeOverrideToken: String?

    private var credentialsFileURL: URL {
        credentialsFileOverride ?? ClaudeConfigLocator.shared.credentialsURL(allowLoginShell: false)
    }

    init(
        credentialsFileURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.credentialsFileOverride = credentialsFileURL
        // Retain only the two supported overrides. Keeping a copy of the
        // complete process environment would unnecessarily keep unrelated
        // secrets alive for the lifetime of the provider.
        self.quotaPulseOverrideToken = environment["QUOTAPULSE_CLAUDE_OAUTH_TOKEN"]
        self.claudeCodeOverrideToken = environment["CLAUDE_CODE_OAUTH_TOKEN"]
    }

    func load() throws -> ClaudeOAuthCredentials {
        if let token = quotaPulseOverrideToken?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return ClaudeOAuthCredentials(accessToken: token, expiresAt: nil, scopes: [])
        }
        if let token = claudeCodeOverrideToken?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return ClaudeOAuthCredentials(accessToken: token, expiresAt: nil, scopes: [])
        }

        guard FileManager.default.fileExists(atPath: credentialsFileURL.path) else {
            throw ClaudeOAuthCredentialError.notFound
        }
        do {
            return try Self.parse(data: Data(contentsOf: credentialsFileURL))
        } catch let error as ClaudeOAuthCredentialError {
            throw error
        } catch {
            throw ClaudeOAuthCredentialError.fileReadFailed(error.localizedDescription)
        }
    }

    static func parse(data: Data) throws -> ClaudeOAuthCredentials {
        let payload: Root
        do {
            payload = try JSONDecoder().decode(Root.self, from: data)
        } catch {
            throw ClaudeOAuthCredentialError.invalidPayload
        }

        guard let oauth = payload.claudeAiOauth else {
            throw ClaudeOAuthCredentialError.invalidPayload
        }
        let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw ClaudeOAuthCredentialError.missingAccessToken
        }

        return ClaudeOAuthCredentials(
            accessToken: token,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1_000) },
            scopes: oauth.scopes ?? []
        )
    }

    private struct Root: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?
        let scopes: [String]?
    }
}
#endif
