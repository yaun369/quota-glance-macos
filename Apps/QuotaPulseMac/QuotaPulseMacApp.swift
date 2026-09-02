import SwiftUI

@main
struct QuotaPulseMacApp: App {
    @StateObject private var store: QuotaStore
    @StateObject private var launchAtLogin: LaunchAtLoginController
    @StateObject private var updater = AppUpdater()

    init() {
        let launchAtLogin = LaunchAtLoginController()
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin)
        _store = StateObject(
            wrappedValue: QuotaStore {
                launchAtLogin.recordSuccessfulProviderConnection()
            }
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                store: store,
                launchAtLogin: launchAtLogin,
                updater: updater
            )
        } label: {
            Label {
                Text("QuotaGlance")
            } icon: {
                Image("MenuBarIcon")
                    .renderingMode(.template)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView(launchAtLogin: launchAtLogin, updater: updater)
        }
    }
}
