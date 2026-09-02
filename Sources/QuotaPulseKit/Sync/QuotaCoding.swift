import Foundation

/// Consistent JSON coding used everywhere a `QuotaSnapshot` crosses a
/// process/device boundary as bytes: the WatchConnectivity payload and the
/// on-disk caches iPhone and Watch each keep for offline display.
///
/// Plain `.iso8601` truncates to whole seconds, which is enough precision
/// loss to break exact round-tripping (and to make two snapshots captured
/// less than a second apart compare as identical). Fractional seconds keep
/// that intact.
extension JSONEncoder {
    public static let quotaPulse: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(QuotaISO8601.formatter.string(from: date))
        }
        return encoder
    }()
}

extension JSONDecoder {
    public static let quotaPulse: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = QuotaISO8601.formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a fractional-seconds ISO 8601 date, got \(string)"
                )
            }
            return date
        }
        return decoder
    }()
}

private enum QuotaISO8601 {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
