import Foundation

/// The AI coding tools whose usage quota QuotaPulse can read.
public enum Provider: String, Codable, Sendable, CaseIterable {
    case codex
    case claude
}
