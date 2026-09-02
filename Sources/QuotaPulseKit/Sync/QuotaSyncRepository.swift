import Foundation

/// Persists and reads back the single latest `QuotaSnapshot` per provider.
/// The Mac collector is the only writer; iPhone and Watch are readers.
/// Kept as a protocol (rather than exposing `CloudKitQuotaRepository`
/// directly) so stores can be unit-tested against a fake.
public protocol QuotaSyncRepository: Sendable {
    func push(_ snapshot: QuotaSnapshot) async throws
    func fetchAll() async throws -> [Provider: QuotaSnapshot]
}
