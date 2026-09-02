import Combine
import Foundation

/// 两级 Activation 的持久化状态。全是**时间戳而不是布尔**：知道「什么时候」
/// 才能算出连接到首次额度、首次额度到第一个常驻位这两段转化的时长，只存
/// `true` 的话这些问题以后一个都答不了。
public struct ActivationMilestones: Codable, Equatable, Sendable {
    /// `Provider.rawValue` -> 首次连接成功的时间。
    public var providerConnectedAt: [String: Date] = [:]
    /// **基础 Activation** 达成的时间：首次拿到真实额度。
    public var firstRealQuotaAt: Date?
    /// `PersistentSurface.rawValue` -> 首次被检测到的时间。非空即
    /// **更强 Activation**。
    public var surfaceDetectedAt: [String: Date] = [:]
    /// 常驻位引导的展示次数与首次展示时间——「引导展示率」这个代理指标的分母。
    public var guideShownCount: Int = 0
    public var guideFirstShownAt: Date?
    /// `PersistentSurface.rawValue` -> 用户首次展开该位置步骤的时间，分子。
    public var guideOpenedAt: [String: Date] = [:]
    /// 引导被主动关掉的时间。关掉之后不再自动弹，只留设置页入口。
    public var guideDismissedAt: Date?

    public init() {}

    public var isBasicallyActivated: Bool { firstRealQuotaAt != nil }
    public var isStronglyActivated: Bool { isBasicallyActivated && !surfaceDetectedAt.isEmpty }

    public var detectedSurfaces: Set<PersistentSurface> {
        Set(surfaceDetectedAt.keys.compactMap(PersistentSurface.init(rawValue:)))
    }
}

/// 记录两级 Activation 的达成情况，并把每一次达成作为事件发出去。
///
/// **闩锁语义**：里程碑只会从「没发生」翻到「发生了」，不会翻回来。用户把
/// 小组件删掉、退出登录，都不会撤销一次已经发生过的 Activation——Activation
/// 是一个历史事实，不是一个当前状态。这也是为什么这里存的是首次时间戳。
///
/// 事件只在**翻转的那一刻**发一次（`surfaceGuideShown` 除外，它需要分母）。
/// 每帧都调用 `noteSurfaceDetected` 是安全的，这正是它的预期用法：
/// 探测是轮询式的，去重放在这里做，而不是让每个调用方自己记「我发过没有」。
@MainActor
public final class ActivationTracker: ObservableObject {
    @Published public private(set) var milestones: ActivationMilestones

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: () -> Date
    private var sinks: [any ActivationEventSink]

    public init(
        defaults: UserDefaults = QuotaSnapshotCache.sharedDefaults,
        storageKey: String = "quotapulse.activation.milestones",
        sinks: [any ActivationEventSink] = [],
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
        self.sinks = sinks
        self.milestones = Self.load(from: defaults, key: storageKey)
    }

    /// 接一个上报后端。现在没有；留着这个口子是为了指标定义和上报实现能分开
    /// 落地，而不是等后端到位才开始记。
    public func addSink(_ sink: any ActivationEventSink) {
        sinks.append(sink)
    }

    // MARK: - 基础 Activation

    public func noteProviderConnected(_ provider: Provider) {
        guard milestones.providerConnectedAt[provider.rawValue] == nil else { return }
        milestones.providerConnectedAt[provider.rawValue] = now()
        persist()
        emit(.providerConnected(provider))
    }

    /// 拿到一次真实额度。**只认真实数据**：演示模式和示例快照永远不该走到这里，
    /// 否则「基础 Activation」会把一个只点了「查看演示数据」的人算成已激活，
    /// 而那恰恰是没有连接任何东西的人。
    public func noteRealQuota(for provider: Provider) {
        noteProviderConnected(provider)
        guard milestones.firstRealQuotaAt == nil else { return }
        milestones.firstRealQuotaAt = now()
        persist()
        emit(.firstRealQuota(provider))
    }

    // MARK: - 更强 Activation

    public func noteSurfaceDetected(_ surface: PersistentSurface) {
        noteSurfacesDetected([surface])
    }

    public func noteSurfacesDetected(_ surfaces: Set<PersistentSurface>) {
        let fresh = surfaces.filter { milestones.surfaceDetectedAt[$0.rawValue] == nil }
        guard !fresh.isEmpty else { return }
        let timestamp = now()
        for surface in fresh {
            milestones.surfaceDetectedAt[surface.rawValue] = timestamp
        }
        persist()
        // 排序后发出，让同一批检测在不同设备上产生同样顺序的事件流。
        for surface in fresh.sorted(by: { $0.rawValue < $1.rawValue }) {
            emit(.persistentSurfaceDetected(surface))
        }
    }

    // MARK: - 引导本身（代理指标）

    public func noteGuideShown(_ surfaces: [PersistentSurface]) {
        milestones.guideShownCount += 1
        if milestones.guideFirstShownAt == nil {
            milestones.guideFirstShownAt = now()
        }
        persist()
        emit(.surfaceGuideShown(surfaces: surfaces))
    }

    public func noteGuideOpened(_ surface: PersistentSurface) {
        guard milestones.guideOpenedAt[surface.rawValue] == nil else { return }
        milestones.guideOpenedAt[surface.rawValue] = now()
        persist()
        emit(.surfaceGuideOpened(surface))
    }

    public func noteGuideDismissed() {
        guard milestones.guideDismissedAt == nil else { return }
        milestones.guideDismissedAt = now()
        persist()
        emit(.surfaceGuideDismissed(completed: milestones.isStronglyActivated))
    }

    // MARK: - 派生状态

    public var isBasicallyActivated: Bool { milestones.isBasicallyActivated }
    public var isStronglyActivated: Bool { milestones.isStronglyActivated }
    public var detectedSurfaces: Set<PersistentSurface> { milestones.detectedSurfaces }

    /// 引导该不该自动弹出来。
    ///
    /// 三个条件缺一不可：已经达成基础 Activation（还没连上账号的人先解决连接，
    /// 一屏两个任务谁都做不完）、还没有任何常驻位、并且用户没有主动关掉过。
    /// 关掉过之后引导只留在设置页——同一个弹窗弹第二次就不再是引导了。
    public var shouldPresentSurfaceGuide: Bool {
        milestones.isBasicallyActivated
            && milestones.surfaceDetectedAt.isEmpty
            && milestones.guideDismissedAt == nil
    }

    // MARK: - 存储

    private func persist() {
        guard let data = try? JSONEncoder.quotaPulse.encode(milestones) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> ActivationMilestones {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder.quotaPulse.decode(ActivationMilestones.self, from: data)
        else { return ActivationMilestones() }
        return decoded
    }

    private func emit(_ event: ActivationEvent) {
        let timestamp = now()
        for sink in sinks {
            sink.record(event, at: timestamp)
        }
    }
}
