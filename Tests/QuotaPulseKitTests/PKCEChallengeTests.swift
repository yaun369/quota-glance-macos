#if os(macOS)
import XCTest
@testable import QuotaPulseKit

final class PKCEChallengeTests: XCTestCase {
    /// RFC 7636 Appendix B's worked example — the one fixed vector every
    /// PKCE implementation is expected to reproduce exactly.
    func testCodeChallengeMatchesRFC7636AppendixBVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCEChallenge.codeChallenge(forVerifier: verifier)

        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testBase64URLEncodingHasNoPaddingOrURLUnsafeCharacters() {
        // Three trailing zero bytes force base64's `=` padding, and this
        // specific byte pattern is chosen so the standard-alphabet output
        // would contain both `+` and `/`.
        let data = Data([0xFB, 0xFF, 0xBF, 0x00])
        let encoded = PKCEChallenge.base64URLEncode(data)

        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
    }

    func testCodeVerifierIsWithinRFCLengthAndCharacterSet() {
        let verifier = PKCEChallenge.makeCodeVerifier()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        XCTAssertTrue((43...128).contains(verifier.count))
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testCodeVerifierAndStateAreRandomPerCall() {
        let verifierA = PKCEChallenge.makeCodeVerifier()
        let verifierB = PKCEChallenge.makeCodeVerifier()
        let stateA = PKCEChallenge.makeState()
        let stateB = PKCEChallenge.makeState()

        XCTAssertNotEqual(verifierA, verifierB)
        XCTAssertNotEqual(stateA, stateB)
        // 43 chars = base64url(32 bytes), the exact shape the Claude Code
        // binary generates; its authorize endpoint schema-validates `state`.
        XCTAssertEqual(stateA.count, 43)
    }

    func testPKCESessionDerivesChallengeFromItsOwnVerifier() {
        let session = PKCESession()

        XCTAssertEqual(session.codeChallenge, PKCEChallenge.codeChallenge(forVerifier: session.codeVerifier))
        XCTAssertFalse(session.state.isEmpty)
        XCTAssertNotEqual(session.state, session.codeVerifier)
    }

    func testPKCESessionAcceptsAnInjectedVerifierForDeterministicTests() {
        let session = PKCESession(
            codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            state: "fixed-state"
        )

        XCTAssertEqual(session.codeChallenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(session.state, "fixed-state")
    }
}
#endif
