import Foundation

/// A single reading of one provider's quota. This is the shape that later
/// syncs to CloudKit unchanged, so keep it limited to percentages, reset
/// times and freshness metadata only — never tokens, prompts or project
/// names.
public struct QuotaSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var session: QuotaWindow
    public var weekly: QuotaWindow
    public var capturedAt: Date
    public var sourceVersion: String?

    public init(
        id: UUID = UUID(),
        provider: Provider,
        session: QuotaWindow = QuotaWindow(),
        weekly: QuotaWindow = QuotaWindow(),
        capturedAt: Date = Date(),
        sourceVersion: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.session = session
        self.weekly = weekly
        self.capturedAt = capturedAt
        self.sourceVersion = sourceVersion
    }
}

extension QuotaSnapshot {
    public func window(_ kind: QuotaWindowKind) -> QuotaWindow {
        switch kind {
        case .session: return session
        case .weekly: return weekly
        }
    }
}
