#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class JWTPayloadTests: XCTestCase {
    func testDecodeReturnsPayloadClaims() throws {
        let jwt = Self.makeJWT(payload: ["sub": "user-1", "exp": 1_780_000_000])

        let payload = try JWTPayload.decode(jwt)

        XCTAssertEqual(payload["sub"]?.stringValue, "user-1")
        XCTAssertEqual(payload["exp"]?.doubleValue, 1_780_000_000)
    }

    func testDecodeReturnsNestedClaims() throws {
        let jwt = Self.makeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-123"],
        ])

        let payload = try JWTPayload.decode(jwt)

        XCTAssertEqual(payload["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue, "acct-123")
    }

    func testDecodeThrowsForMalformedToken() {
        XCTAssertThrowsError(try JWTPayload.decode("not-a-jwt")) { error in
            XCTAssertEqual(error as? JWTDecodingError, .malformed)
        }
    }

    func testDecodeThrowsForTokenMissingASegment() {
        XCTAssertThrowsError(try JWTPayload.decode("onlyheader.")) { error in
            XCTAssertEqual(error as? JWTDecodingError, .malformed)
        }
    }

    func testDecodeThrowsForNonJSONPayload() {
        let jwt = "header.\(Self.base64URLEncode(Data("not json".utf8))).signature"

        XCTAssertThrowsError(try JWTPayload.decode(jwt)) { error in
            guard case .invalidPayload = error as? JWTDecodingError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testExpirationDateDecodesStandardExpClaim() throws {
        let jwt = Self.makeJWT(payload: ["exp": 1_780_000_000])

        let date = try JWTPayload.expirationDate(fromAccessToken: jwt)

        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_780_000_000))
    }

    func testExpirationDateReturnsNilWhenClaimIsMissing() throws {
        let jwt = Self.makeJWT(payload: ["sub": "user-1"])

        XCTAssertNil(try JWTPayload.expirationDate(fromAccessToken: jwt))
    }

    static func makeJWT(payload: [String: Any]) -> String {
        let headerData = try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        return "\(base64URLEncode(headerData)).\(base64URLEncode(payloadData)).signature"
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
