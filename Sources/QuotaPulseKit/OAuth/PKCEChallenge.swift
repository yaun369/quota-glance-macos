import CryptoKit
import Foundation
import Security

/// RFC 7636 (PKCE) primitives shared by the Claude and Codex login flows:
/// a high-entropy code verifier, its S256 challenge, and an unrelated
/// `state` value used to bind the callback to this particular attempt.
public enum PKCEChallenge {
    /// Generates a code verifier: base64url(32 random bytes), which lands at
    /// 43 characters — inside RFC 7636's required 43-128 range and entirely
    /// within its unreserved character set, so no further escaping is ever
    /// needed.
    public static func makeCodeVerifier(byteCount: Int = 32) -> String {
        base64URLEncode(randomBytes(byteCount))
    }

    /// An unrelated random token used as the OAuth `state` parameter. Not
    /// part of PKCE proper. 32 bytes (43 chars) matches the Claude Code
    /// binary, which generates state exactly like the verifier —
    /// base64url(randomBytes(32)) — and every known-working reimplementation
    /// sends ≥32 chars; Claude's authorize endpoint schema-validates the
    /// request, so don't hand it a shape it has never seen.
    public static func makeState(byteCount: Int = 32) -> String {
        base64URLEncode(randomBytes(byteCount))
    }

    /// `code_challenge = BASE64URL(SHA256(ASCII(code_verifier)))`, per RFC
    /// 7636 §4.2. Exposed as a pure function (rather than only via a
    /// convenience initializer) so it can be checked against the RFC's own
    /// test vector.
    public static func codeChallenge(forVerifier verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        // SecRandomCopyBytes only fails when the system CSPRNG itself is
        // unavailable, which is not a condition this app can recover from or
        // usefully report — matching Swift's own crypto libraries, which
        // treat it as a fatal precondition rather than a throwing API.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return Data(bytes)
    }
}

/// A verifier/challenge/state triple for one authorization attempt. Kept in
/// memory only for the lifetime of the login flow — none of it is
/// persisted.
public struct PKCESession: Sendable, Equatable {
    public let codeVerifier: String
    public let codeChallenge: String
    public let state: String

    public init(
        codeVerifier: String = PKCEChallenge.makeCodeVerifier(),
        state: String = PKCEChallenge.makeState()
    ) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = PKCEChallenge.codeChallenge(forVerifier: codeVerifier)
        self.state = state
    }
}
