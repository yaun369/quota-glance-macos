#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class ClaudeStatusLineHelperTests: XCTestCase {
    private var root: URL!
    private var cacheURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        cacheURL = root.appendingPathComponent("claude-latest.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testChangedQuotaReplacesCacheAndCapturedAt() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try ClaudeStatusLineHelper.run(
            input: payload(used: 20, resetsAt: now.timeIntervalSince1970 + 3_600),
            cacheURL: cacheURL,
            now: now
        )
        let original = try Data(contentsOf: cacheURL)

        try ClaudeStatusLineHelper.run(
            input: payload(used: 21, resetsAt: now.timeIntervalSince1970 + 3_600),
            cacheURL: cacheURL,
            now: now.addingTimeInterval(30)
        )

        let updated = try Data(contentsOf: cacheURL)
        XCTAssertNotEqual(updated, original)
        let value = try JSONDecoder().decode(JSONValue.self, from: updated)
        XCTAssertEqual(value["fiveHour"]?["used_percentage"]?.doubleValue, 21)
        XCTAssertEqual(value["capturedAt"]?.doubleValue, now.timeIntervalSince1970 + 30)
    }

    func testExpiredWindowsDoNotCreateOrEraseCache() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = payload(used: 20, resetsAt: now.timeIntervalSince1970 - 301)

        let statusLine = try ClaudeStatusLineHelper.run(
            input: expired,
            cacheURL: cacheURL,
            now: now
        )
        XCTAssertEqual(statusLine, "Claude 5h 80% left · 7d -- left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))

        try ClaudeStatusLineHelper.run(
            input: payload(used: 25, resetsAt: now.timeIntervalSince1970 + 3_600),
            cacheURL: cacheURL,
            now: now
        )
        let validCache = try Data(contentsOf: cacheURL)
        try ClaudeStatusLineHelper.run(
            input: expired,
            cacheURL: cacheURL,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(try Data(contentsOf: cacheURL), validCache)
    }

    func testMalformedInputDoesNotDamageExistingCache() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try ClaudeStatusLineHelper.run(
            input: payload(used: 20, resetsAt: now.timeIntervalSince1970 + 3_600),
            cacheURL: cacheURL,
            now: now
        )
        let validCache = try Data(contentsOf: cacheURL)

        XCTAssertThrowsError(
            try ClaudeStatusLineHelper.run(
                input: Data("not json".utf8),
                cacheURL: cacheURL,
                now: now.addingTimeInterval(30)
            )
        )
        XCTAssertEqual(try Data(contentsOf: cacheURL), validCache)
    }

    private func payload(used: Double, resetsAt: TimeInterval) -> Data {
        Data(
            """
            {
              "rate_limits": {
                "five_hour": {
                  "used_percentage": \(used),
                  "resets_at": \(resetsAt),
                  "future_field": "preserved"
                }
              }
            }
            """.utf8
        )
    }
}
#endif
