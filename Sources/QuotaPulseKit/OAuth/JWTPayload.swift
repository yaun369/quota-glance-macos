import Foundation

enum JWTDecodingError: LocalizedError, Sendable, Equatable {
    case malformed
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .malformed:
            return QuotaL10n.string("token.decodeFailed", "Could not decode the sign-in token.")
        case .invalidPayload(let reason):
            return QuotaL10n.string("token.payloadInvalid", "The sign-in token payload was invalid: \(reason)")
        }
    }
}

/// Decodes the payload of a JWT — without verifying its signature, since
/// this app never receives one over an untrusted channel: every JWT it
/// handles came directly from a provider's own token endpoint over HTTPS,
/// exactly as that provider's official CLI itself trusts it.
enum JWTPayload {
    static func decode(_ jwt: String) throws -> JSONValue {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[1].isEmpty else {
            throw JWTDecodingError.malformed
        }
        guard let data = base64URLDecode(String(parts[1])) else {
            throw JWTDecodingError.malformed
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw JWTDecodingError.invalidPayload(error.localizedDescription)
        }
    }

    /// The standard `exp` claim (seconds since epoch), present on every
    /// access token this app decodes — none of the providers it talks to
    /// return an `expires_in` alongside the token itself.
    static func expirationDate(fromAccessToken jwt: String) throws -> Date? {
        let payload = try decode(jwt)
        guard let exp = payload["exp"]?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
