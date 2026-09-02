import XCTest
@testable import QuotaPulseKit

final class QuotaThresholdsStoreTests: XCTestCase {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "quotapulse.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    func testLoadWithoutPriorSaveReturnsDefaults() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = QuotaThresholdsStore(defaults: defaults)
        XCTAssertEqual(store.load(), .default)
    }

    func testSaveThenLoadRoundTrips() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = QuotaThresholdsStore(defaults: defaults)
        let custom = QuotaThresholds(
            lightRemainingPercent: 40,
            importantRemainingPercent: 20,
            urgentRemainingPercent: 8,
            resetNotificationsEnabled: false
        )
        store.save(custom)
        XCTAssertEqual(store.load(), custom)
    }
}
