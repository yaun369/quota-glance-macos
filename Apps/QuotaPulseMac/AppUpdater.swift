import Combine
import Sparkle

/// Small SwiftUI-facing wrapper around Sparkle's standard updater UI.
/// Community builds keep it stopped so local runs never query the production
/// feed; the signed official configuration starts checks immediately.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        let shouldStart = Self.bundleBoolean(named: "QuotaSparkleEnabled")
        controller = SPUStandardUpdaterController(
            startingUpdater: shouldStart,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    private static func bundleBoolean(named key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) else {
            return false
        }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }
}
