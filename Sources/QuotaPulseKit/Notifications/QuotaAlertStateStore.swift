import Foundation

/// Persists `QuotaAlertState` per provider, so "which level have we already
/// announced for this week" survives app relaunches. Without persistence the
/// level-triggered evaluator would re-announce the same level on every cold
/// start.
public final class QuotaAlertStateStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "quotapulse.alertstate.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(_ provider: Provider) -> QuotaAlertState? {
        all()[provider.rawValue]
    }

    public func save(_ state: QuotaAlertState, for provider: Provider) {
        var states = all()
        states[provider.rawValue] = state
        guard let data = try? JSONEncoder.quotaPulse.encode(states) else { return }
        defaults.set(data, forKey: key)
    }

    private func all() -> [String: QuotaAlertState] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder.quotaPulse.decode([String: QuotaAlertState].self, from: data)
        else { return [:] }
        return decoded
    }
}
