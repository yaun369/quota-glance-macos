#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class ClaudeOAuthCredentialsTests: XCTestCase {
    func testParsesClaudeCodeCredentialPayload() throws {
        let credentials = try ClaudeOAuthCredentialsLoader.parse(data: Data("""
        {
          "claudeAiOauth": {
            "accessToken": "test-token",
            "refreshToken": "ignored-refresh-token",
            "expiresAt": 1780000000000,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "pro"
          },
          "unknownFutureField": true
        }
        """.utf8))

        XCTAssertEqual(credentials.accessToken, "test-token")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(credentials.scopes, ["user:inference", "user:profile"])
    }

    func testRejectsMCPOnlyCredentialPayload() {
        XCTAssertThrowsError(try ClaudeOAuthCredentialsLoader.parse(data: Data("""
        { "mcpOAuth": { "example": {} } }
        """.utf8))) { error in
            XCTAssertEqual(error as? ClaudeOAuthCredentialError, .invalidPayload)
        }
    }

    func testRejectsMissingAccessToken() {
        XCTAssertThrowsError(try ClaudeOAuthCredentialsLoader.parse(data: Data("""
        { "claudeAiOauth": { "scopes": ["user:profile"] } }
        """.utf8))) { error in
            XCTAssertEqual(error as? ClaudeOAuthCredentialError, .missingAccessToken)
        }
    }

    func testRejectsExpiredCredential() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let credentials = ClaudeOAuthCredentials(
            accessToken: "test-token",
            expiresAt: now.addingTimeInterval(20),
            scopes: ["user:profile"]
        )

        XCTAssertThrowsError(try credentials.accessTokenForUsage(now: now)) { error in
            XCTAssertEqual(error as? ClaudeOAuthCredentialError, .expired)
        }
    }

    func testRejectsCredentialWithoutUserProfileScope() {
        let credentials = ClaudeOAuthCredentials(
            accessToken: "test-token",
            expiresAt: nil,
            scopes: ["user:inference"]
        )

        XCTAssertThrowsError(try credentials.accessTokenForUsage(now: Date())) { error in
            XCTAssertEqual(error as? ClaudeOAuthCredentialError, .missingUserProfileScope)
        }
    }

    func testLoadPrefersEnvironmentOverrideAndTrimsIt() throws {
        let loader = ClaudeOAuthCredentialsLoader(
            credentialsFileURL: URL(fileURLWithPath: "/nonexistent/credentials.json"),
            environment: ["QUOTAPULSE_CLAUDE_OAUTH_TOKEN": " env-token \n"]
        )

        let credentials = try loader.load()

        XCTAssertEqual(credentials.accessToken, "env-token")
        XCTAssertNil(credentials.expiresAt)
        XCTAssertEqual(credentials.scopes, [])
    }

    func testLoadReadsCredentialsFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-credentials-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try """
        { "claudeAiOauth": { "accessToken": "file-token", "scopes": ["user:profile"] } }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = ClaudeOAuthCredentialsLoader(
            credentialsFileURL: fileURL,
            environment: [:]
        )

        XCTAssertEqual(try loader.load().accessToken, "file-token")
    }

    func testLoadWithoutFileOrOverridesThrowsNotFound() {
        let loader = ClaudeOAuthCredentialsLoader(
            credentialsFileURL: URL(fileURLWithPath: "/nonexistent/credentials.json"),
            environment: [:]
        )

        XCTAssertThrowsError(try loader.load()) { error in
            XCTAssertEqual(error as? ClaudeOAuthCredentialError, .notFound)
        }
    }
}
#endif
