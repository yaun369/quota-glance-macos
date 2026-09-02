import XCTest
@testable import QuotaPulseKit

final class JSONValueTests: XCTestCase {
    func testRoundTripsNestedStructures() throws {
        let value = JSONValue.object([
            "primary": .object([
                "usedPercent": .number(25),
                "windowDurationMins": .number(300),
                "resetsAt": .number(1_780_000_000),
            ]),
            "tags": .array([.string("a"), .string("b")]),
            "ok": .bool(true),
            "missing": .null,
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["primary"]?["usedPercent"]?.doubleValue, 25)
        XCTAssertEqual(decoded["primary"]?["windowDurationMins"]?.intValue, 300)
        XCTAssertEqual(decoded["tags"], .array([.string("a"), .string("b")]))
    }
}
