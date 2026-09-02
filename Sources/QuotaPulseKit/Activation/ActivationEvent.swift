import Foundation

/// v0.3 的核心指标是 Conversion，而 Conversion 的分子是 Activation——所以两级
/// Activation 必须能被观测，否则这个版本做完了也说不出它有没有用。
///
/// 这里只定义**事件的形状**，不定义它们被送去哪。当前仓库里没有任何分析后端
/// （没有 SDK、没有上报），所以 `ActivationTracker` 默认把它们落在本地的
/// App Group `UserDefaults` 里，等有后端时把一个 sink 接上即可——事件名和参数
/// 现在就固定下来，是为了那一天不用重新定义指标、也不用丢掉在此之前的数据。
///
/// 每个事件都是**里程碑**，不是计数器：同一个事件对同一台设备只会发一次
/// （`ActivationTracker` 负责闩锁），因为 Activation 问的是「有没有发生过」。
/// 唯一的例外是 `surfaceGuideShown`，它是代理指标，需要分母。
public enum ActivationEvent: Equatable, Sendable {
    /// 成功连接一个 Provider（拿到并存下了凭据）。
    case providerConnected(Provider)
    /// **基础 Activation**：连接 Provider 后首次拿到真实额度。
    case firstRealQuota(Provider)
    /// 常驻位引导展示了一次。代理指标的分母。
    case surfaceGuideShown(surfaces: [PersistentSurface])
    /// 用户在引导里展开了某个位置的步骤。代理指标的分子。
    case surfaceGuideOpened(PersistentSurface)
    /// 引导被关掉。`completed` 表示关掉时是否已经检测到至少一个常驻位。
    case surfaceGuideDismissed(completed: Bool)
    /// **更强 Activation**：首次检测到某个常驻位已经存在。
    case persistentSurfaceDetected(PersistentSurface)

    /// 事件名。写死成 snake_case 字符串而不是从 case 名反射：指标名一旦被
    /// 报表引用就不能随重构改动，编译器管不了这件事，只有写死能管。
    public var name: String {
        switch self {
        case .providerConnected: return "provider_connected"
        case .firstRealQuota: return "activation_basic"
        case .surfaceGuideShown: return "surface_guide_shown"
        case .surfaceGuideOpened: return "surface_guide_opened"
        case .surfaceGuideDismissed: return "surface_guide_dismissed"
        case .persistentSurfaceDetected: return "activation_strong"
        }
    }

    public var parameters: [String: String] {
        switch self {
        case .providerConnected(let provider), .firstRealQuota(let provider):
            return ["provider": provider.rawValue]
        case .surfaceGuideShown(let surfaces):
            return ["surfaces": surfaces.map(\.rawValue).sorted().joined(separator: ",")]
        case .surfaceGuideOpened(let surface), .persistentSurfaceDetected(let surface):
            return ["surface": surface.rawValue]
        case .surfaceGuideDismissed(let completed):
            return ["completed": completed ? "1" : "0"]
        }
    }
}

/// 事件的去处。有分析后端之前，只有 `ActivationTracker` 自带的本地实现。
public protocol ActivationEventSink: AnyObject, Sendable {
    func record(_ event: ActivationEvent, at date: Date)
}
