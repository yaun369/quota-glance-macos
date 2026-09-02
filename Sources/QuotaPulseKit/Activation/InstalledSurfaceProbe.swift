import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// 小组件的 `kind`，一个地方定义。
///
/// 这个字符串是**已经装在用户设备上的小组件的身份**：改掉它等于把所有人已经
/// 添加好的小组件变成一个系统不认识的东西。它只允许被读，不允许被改。
public enum QuotaWidgetKind {
    public static let quota = "QuotaPulseQuotaWidget"
}

/// 「这台设备上已经存在哪些常驻位」的探测口。
///
/// 抽成协议是为了两件事：单元测试不需要真的装一个小组件，以及不同平台的探测
/// 手段完全不同（iPhone 问 WidgetKit，Mac 菜单栏只能从同步数据里推断）。
public protocol InstalledSurfaceProbing: Sendable {
    func detectedSurfaces() async -> Set<PersistentSurface>
}

#if canImport(WidgetKit) && (os(iOS) || os(watchOS))

/// 用 `WidgetCenter.getCurrentConfigurations` 直接问系统「我的小组件被添加到
/// 哪儿了」。
///
/// **这是 issue 里那个「可能测不到」的假设的更正**：iOS 上确实没有「用户加了
/// 小组件吗」这种布尔 API，但 WidgetKit 从 iOS 14 起就提供了已添加实例的清单
/// （`WidgetInfo`，带 `kind` 和 `family`），而 family 足以区分主屏幕和锁屏。
/// 所以主屏幕小组件和锁屏小组件都是**直接可测**的，不需要退化成代理指标。
///
/// 拿不到时返回空集合而不是抛错：探测失败和「没添加」在界面上是同一种处理
/// （继续引导），而 Activation 里程碑是闩锁的，下一次探测成功照样会补上。
public struct WidgetKitSurfaceProbe: InstalledSurfaceProbing {
    private let kind: String

    public init(kind: String = QuotaWidgetKind.quota) {
        self.kind = kind
    }

    public func detectedSurfaces() async -> Set<PersistentSurface> {
        let infos = await withCheckedContinuation { (continuation: CheckedContinuation<[WidgetInfo], Never>) in
            WidgetCenter.shared.getCurrentConfigurations { result in
                continuation.resume(returning: (try? result.get()) ?? [])
            }
        }
        return Set(infos.filter { $0.kind == kind }.compactMap { Self.surface(for: $0.family) })
    }

    /// family -> 常驻位。
    ///
    /// watchOS 上 accessory 家族就是表盘复杂功能；iOS 上同一批 family 名字指的
    /// 是锁屏小组件。同名不同物，所以映射必须分平台，不能只看 family。
    static func surface(for family: WidgetFamily) -> PersistentSurface? {
        #if os(watchOS)
        return .watchComplication
        #else
        switch family {
        case .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge:
            return .homeScreenWidget
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            return .lockScreenWidget
        @unknown default:
            // 新家族默认不计入：宁可少算一次 Activation，也不要把一个还没做过
            // 适配的位置当成用户已经拥有的常驻位。
            return nil
        }
        #endif
    }
}

#endif
