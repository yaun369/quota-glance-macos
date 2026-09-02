#if os(macOS)
import Foundation

/// Mirrors the JSON that `claude-status.sh` writes to
/// `~/.agent-quota/claude-latest.json`, which in turn mirrors the shape of
/// Claude Code's own statusLine input (`rate_limits.five_hour` /
/// `rate_limits.seven_day`, each with `used_percentage` / `resets_at`).
struct ClaudeRateWindow: Codable, Sendable {
    var usedPercentage: Double?
    var resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

struct ClaudeStatusLineCache: Codable, Sendable {
    var fiveHour: ClaudeRateWindow?
    var sevenDay: ClaudeRateWindow?
    var capturedAt: Double
}
#endif
