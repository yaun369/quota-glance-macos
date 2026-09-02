import AppKit
import Combine
import ServiceManagement

/// Owns the system login-item registration. `isEnabled` is always derived
/// from `SMAppService.mainApp.status`; UserDefaults is used only to remember
/// whether the post-connection suggestion has already been dismissed.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    enum RegistrationState: Equatable {
        case off
        case enabled
        case requiresApproval
        case unavailable
    }

    @Published private(set) var state: RegistrationState = .off
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var shouldShowPrompt = false

    private let service: SMAppService
    private let defaults: UserDefaults
    private var activationObserver: AnyCancellable?

    private enum DefaultsKey {
        static let providerConnected = "mac.launchAtLogin.providerConnected"
        static let promptDismissed = "mac.launchAtLogin.promptDismissed"
    }

    init(service: SMAppService = .mainApp, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        refreshStatus()
        activationObserver = NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )
        .sink { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    var isEnabled: Bool { state == .enabled }

    var statusText: String {
        switch state {
        case .off:
            return String(localized: "Off")
        case .enabled:
            return String(localized: "On")
        case .requiresApproval:
            return String(localized: "Needs approval")
        case .unavailable:
            return String(localized: "Unavailable")
        }
    }

    var statusDetail: String? {
        switch state {
        case .requiresApproval:
            return String(localized: "Allow QuotaGlance in System Settings → General → Login Items, then return here.")
        case .unavailable:
            return String(localized: "Move QuotaGlance to Applications and reopen it before enabling launch at login.")
        case .off, .enabled:
            return nil
        }
    }

    func refreshStatus() {
        switch service.status {
        case .notRegistered:
            state = .off
        case .enabled:
            state = .enabled
        case .requiresApproval:
            state = .requiresApproval
        case .notFound:
            state = .unavailable
        @unknown default:
            state = .unavailable
        }
        updatePromptVisibility()
    }

    func setEnabled(_ enabled: Bool) {
        guard !isChanging else { return }
        isChanging = true
        errorMessage = nil
        defer {
            isChanging = false
            refreshStatus()
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = enabled
                ? String(localized: "Could not enable launch at login: \(error.localizedDescription). Open Login Items in System Settings and try again.")
                : String(localized: "Could not disable launch at login: \(error.localizedDescription). Open Login Items in System Settings and try again.")
        }
    }

    /// Called after either provider produces its first successful, non-
    /// fallback reading. This is the earliest point where the app has shown
    /// its value, so the persistent-surface suggestion has useful context.
    func recordSuccessfulProviderConnection() {
        guard !defaults.bool(forKey: DefaultsKey.providerConnected) else { return }
        defaults.set(true, forKey: DefaultsKey.providerConnected)
        updatePromptVisibility()
    }

    func dismissPrompt() {
        defaults.set(true, forKey: DefaultsKey.promptDismissed)
        updatePromptVisibility()
    }

    func openSystemLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func updatePromptVisibility() {
        shouldShowPrompt = defaults.bool(forKey: DefaultsKey.providerConnected)
            && !defaults.bool(forKey: DefaultsKey.promptDismissed)
            && state != .enabled
    }
}
