import Foundation
import XCTest
@testable import QuotaPulseKit

final class QuotaFailureTests: XCTestCase {
    func testExpiredCredentialReconnects() {
        XCTAssertEqual(
            QuotaFailureClassifier.recoveryAction(for: OAuthTokenRefreshError.invalidGrant(nil)),
            .reconnect
        )
        XCTAssertEqual(
            QuotaFailureClassifier.recoveryAction(for: CodexUsageError.unauthorized),
            .reconnect
        )
    }

    func testNetworkFailureRetries() {
        XCTAssertEqual(
            QuotaFailureClassifier.recoveryAction(for: URLError(.notConnectedToInternet)),
            .retry
        )
    }

    func testParserFailureChecksForUpdates() {
        XCTAssertEqual(
            QuotaFailureClassifier.recoveryAction(for: QuotaError.invalidResponse("shape changed")),
            .checkForUpdates
        )
    }

    func testPermissionFailureOpensSystemSettings() {
        XCTAssertEqual(
            QuotaFailureClassifier.recoveryAction(
                for: CocoaError(.fileReadNoPermission, userInfo: [:])
            ),
            .openSystemSettings
        )
    }

    func testFailureKeepsActionableMessageAndTypedRecovery() {
        let failure = QuotaFailure(OAuthTokenRefreshError.invalidGrant(nil))
        XCTAssertEqual(failure.recoveryAction, .reconnect)
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertTrue(
            failure.actionableMessage(locale: Locale(identifier: "en"))
                .contains("Use Sign in again below")
        )
    }
}
