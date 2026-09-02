import SwiftUI

struct MacSettingsView: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Form {
            Section("General") {
                HStack(alignment: .firstTextBaseline) {
                    Toggle(
                        "Launch at Login",
                        isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        )
                    )
                    .disabled(launchAtLogin.isChanging || launchAtLogin.state == .unavailable)
                    Spacer(minLength: 12)
                    StatusChip(level: .info, text: launchAtLogin.statusText)
                }

                if let detail = launchAtLogin.statusDetail {
                    Text(detail)
                        .font(QuotaTypography.caption)
                        .foregroundStyle(QuotaPalette.inkSecondary)
                    Button("Open Login Items") {
                        launchAtLogin.openSystemLoginItems()
                    }
                }

                if let error = launchAtLogin.errorMessage {
                    StatusNote(level: .error, title: String(localized: "Could not change Login Items"), detail: error)
                    Button("Open Login Items") {
                        launchAtLogin.openSystemLoginItems()
                    }
                }
            }

            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 300)
        .onAppear {
            launchAtLogin.refreshStatus()
        }
    }
}
