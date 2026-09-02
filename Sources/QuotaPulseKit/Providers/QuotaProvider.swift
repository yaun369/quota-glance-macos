import Foundation

/// Reads a single, current quota reading for one provider. Implementations
/// live only where the underlying data is actually reachable: today that is
/// macOS only, since Codex's app-server and Claude Code's status line both
/// run as local processes on the developer's Mac.
public protocol QuotaProvider: Sendable {
    var provider: Provider { get }
    func fetchSnapshot() async throws -> QuotaSnapshot
}
