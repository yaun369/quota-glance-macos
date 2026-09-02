import Foundation

/// The action a surface can put next to a provider failure. Keeping this
/// typed avoids making recovery depend on translated error-message text.
public enum QuotaRecoveryAction: Sendable, Equatable {
    case retry
    case reconnect
    case checkForUpdates
    case openSystemSettings
}

/// User-facing failure text together with the action that can recover it.
public struct QuotaFailure: Sendable, Equatable {
    public let message: String
    public let recoveryAction: QuotaRecoveryAction

    public init(message: String, recoveryAction: QuotaRecoveryAction) {
        self.message = message
        self.recoveryAction = recoveryAction
    }

    public init(_ error: Error) {
        self.init(
            message: QuotaFormatting.failureText(error),
            recoveryAction: QuotaFailureClassifier.recoveryAction(for: error)
        )
    }

    /// Combines the cause with an explicit reference to the adjacent button.
    /// Some upstream errors already suggest a remedy, but this second short
    /// sentence guarantees that every failure names the exact in-panel exit.
    public func actionableMessage(locale: Locale? = nil) -> String {
        let instruction: String
        switch recoveryAction {
        case .retry:
            instruction = QuotaL10n.string(
                "failure.action.retry",
                "Use Retry below to try again.",
                locale: locale
            )
        case .reconnect:
            instruction = QuotaL10n.string(
                "failure.action.reconnect",
                "Use Sign in again below to reconnect.",
                locale: locale
            )
        case .checkForUpdates:
            instruction = QuotaL10n.string(
                "failure.action.update",
                "Use Check for Updates below, install any available update, then retry.",
                locale: locale
            )
        case .openSystemSettings:
            instruction = QuotaL10n.string(
                "failure.action.settings",
                "Use Open System Settings below, allow access, then retry.",
                locale: locale
            )
        }
        return "\(message) \(instruction)"
    }
}

/// Maps known failure types to recovery controls. This deliberately examines
/// error cases, not their localized descriptions, so changing copy cannot
/// silently turn a "Sign in again" button into a generic retry.
public enum QuotaFailureClassifier {
    public static func recoveryAction(for error: Error) -> QuotaRecoveryAction {
        if let directError = error as? AccountDirectQuotaError {
            switch directError {
            case .loginExpired, .incompleteCredential:
                return .reconnect
            }
        }

        if let refreshError = error as? OAuthTokenRefreshError {
            switch refreshError {
            case .notLoggedIn, .invalidGrant:
                return .reconnect
            case .network, .server:
                return .retry
            case .invalidResponse:
                return .checkForUpdates
            }
        }

        if let usageError = error as? CodexUsageError {
            switch usageError {
            case .unauthorized, .forbidden:
                return .reconnect
            case .invalidResponse:
                return .checkForUpdates
            case .network, .rateLimited, .server:
                return .retry
            }
        }

#if os(macOS)
        if let usageError = error as? ClaudeOAuthUsageError {
            switch usageError {
            case .unauthorized, .forbidden:
                return .reconnect
            case .invalidResponse:
                return .checkForUpdates
            case .network, .rateLimited, .server:
                return .retry
            }
        }
#endif

        if let quotaError = error as? QuotaError {
            switch quotaError {
            case .invalidResponse, .cacheDecodeFailed, .statusLineHelperUnavailable:
                return .checkForUpdates
            case .claudeOAuthFallbackFailed, .codexDirectFallbackFailed:
                return .reconnect
            case .requestTimedOut, .appServerLaunchFailed, .appServerExited:
                return .retry
            case .executableNotFound, .noCachedDataYet, .statusLineAlreadyConfigured,
                 .codexNotConnected:
                return .openSystemSettings
            }
        }

        if let cocoaError = error as? CocoaError {
            switch cocoaError.code {
            case .fileReadNoPermission, .fileWriteNoPermission:
                return .openSystemSettings
            default:
                break
            }
        }

        if let posixError = error as? POSIXError,
           posixError.code == .EACCES || posixError.code == .EPERM {
            return .openSystemSettings
        }

        return .retry
    }
}
