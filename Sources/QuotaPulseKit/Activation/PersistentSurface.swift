import Foundation

/// 一个「常驻位」——把码量放到用户每天都会看到的地方（ROADMAP v0.3 §4）。
///
/// 产品的核心差异化是 Glanceable：一个装了但从没出现在视线里的 App 等于没装。
/// 所以 Activation 分两级，强的那一级要求至少有一个常驻位，而这个枚举就是
/// 「至少一个」里的那些「一个」。
///
/// 顺序即引导顺序：从每台 iPhone 都有、成本最低的桌面小组件开始，最后才是
/// 需要另一台设备的 Mac 菜单栏。
public enum PersistentSurface: String, CaseIterable, Codable, Sendable {
    /// 主屏幕小组件（systemSmall / systemMedium）。
    case homeScreenWidget
    /// 锁屏小组件（accessory 家族）。
    case lockScreenWidget
    /// Apple Watch 表盘复杂功能。
    case watchComplication
    /// Mac 菜单栏。
    case macMenuBar

    public var title: String {
        switch self {
        case .homeScreenWidget:
            return QuotaL10n.string("surface.homeScreenWidget.title", "Home Screen widget")
        case .lockScreenWidget:
            return QuotaL10n.string("surface.lockScreenWidget.title", "Lock Screen widget")
        case .watchComplication:
            return QuotaL10n.string("surface.watchComplication.title", "Watch complication")
        case .macMenuBar:
            return QuotaL10n.string("surface.macMenuBar.title", "Mac menu bar")
        }
    }

    /// 一句话说明「放在这里能得到什么」，而不是「这是什么」——用户已经知道
    /// 什么是小组件，需要被说服的是为什么值得占一格。
    public var promise: String {
        switch self {
        case .homeScreenWidget:
            return QuotaL10n.string(
                "surface.homeScreenWidget.promise",
                "See what is left the moment you reach the Home Screen, without opening the app."
            )
        case .lockScreenWidget:
            return QuotaL10n.string(
                "surface.lockScreenWidget.promise",
                "There the instant you raise your phone — the fastest of the four."
            )
        case .watchComplication:
            return QuotaL10n.string(
                "surface.watchComplication.promise",
                "Glance at your wrist without taking your hands off the keyboard."
            )
        case .macMenuBar:
            return QuotaL10n.string(
                "surface.macMenuBar.promise",
                "Right in the menu bar of the screen you write code on. Nothing is closer."
            )
        }
    }

    public var symbolName: String {
        switch self {
        case .homeScreenWidget: return "square.grid.2x2"
        case .lockScreenWidget: return "lock.iphone"
        case .watchComplication: return "applewatch"
        case .macMenuBar: return "menubar.rectangle"
        }
    }

    /// 添加步骤。按系统实际操作写，不做「打开设置」这种没有落点的空话（§6）。
    public var steps: [String] {
        switch self {
        case .homeScreenWidget:
            return [
                QuotaL10n.string(
                    "surface.homeScreenWidget.step1",
                    "Go to the Home Screen and press and hold an empty spot until the icons jiggle."
                ),
                QuotaL10n.string(
                    "surface.homeScreenWidget.step2",
                    "Tap + in the top-left corner and search for QuotaGlance."
                ),
                QuotaL10n.string("surface.homeScreenWidget.step3", "Pick a size and tap Add Widget."),
            ]
        case .lockScreenWidget:
            return [
                QuotaL10n.string(
                    "surface.lockScreenWidget.step1",
                    "Lock your phone, press and hold the Lock Screen, then tap Customize and Lock Screen."
                ),
                QuotaL10n.string("surface.lockScreenWidget.step2", "Tap the widget area below the clock."),
                QuotaL10n.string(
                    "surface.lockScreenWidget.step3",
                    "Find QuotaGlance in the list and tap it to add it."
                ),
            ]
        case .watchComplication:
            return [
                QuotaL10n.string(
                    "surface.watchComplication.step1",
                    "On your Apple Watch, press and hold the current watch face and tap Edit."
                ),
                QuotaL10n.string(
                    "surface.watchComplication.step2",
                    "Swipe to the complications page and tap a slot."
                ),
                QuotaL10n.string("surface.watchComplication.step3", "Choose QuotaGlance from the list."),
            ]
        case .macMenuBar:
            return [
                QuotaL10n.string("surface.macMenuBar.step1", "Download and open QuotaGlance on your Mac."),
                QuotaL10n.string(
                    "surface.macMenuBar.step2",
                    "It lives in the menu bar; sign in once and you are done."
                ),
                QuotaL10n.string(
                    "surface.macMenuBar.step3",
                    "Use the same iCloud account on your Mac and iPhone and the two stay in sync."
                ),
            ]
        }
    }

    /// 按这台设备的实际情况调整过的步骤。
    ///
    /// 目前只有一处分支，但它是必要的一处：配了 Apple Watch 却还没把码量装到
    /// 表上的人，照着「长按表盘 → 编辑 → 选码量」走到第三步会找不到码量，然后
    /// 得出「这个 App 坏了」的结论。缺的那一步必须先补上。
    public func steps(for capabilities: DeviceCapabilities) -> [String] {
        guard self == .watchComplication, !capabilities.isWatchAppInstalled else { return steps }
        let install = QuotaL10n.string(
            "surface.watchComplication.installStep",
            "First install QuotaGlance on your watch from the Watch app on your iPhone."
        )
        return [install] + steps
    }

    /// 这个位置需要 iPhone 之外的设备吗——引导分支就是按它来的：
    /// 没有 Apple Watch 的人不该被要求「添加表盘复杂功能」。
    public var requiredDevice: RequiredDevice {
        switch self {
        case .homeScreenWidget, .lockScreenWidget: return .thisiPhone
        case .watchComplication: return .appleWatch
        case .macMenuBar: return .mac
        }
    }

    public enum RequiredDevice: Sendable, Equatable {
        case thisiPhone
        case appleWatch
        case mac
    }
}

/// 这台 iPhone 眼里的「用户还有哪些设备」。
///
/// 三个字段的把握程度并不一样，这一点必须留在类型里而不是留在注释里：
/// Apple Watch 由 `WCSession` 直接给出，是事实；Mac 没有任何 API 可问，
/// 只能靠「iCloud 里出现过 Mac 采集的数据」或者用户自己说，所以它叫
/// `knownMac` 而不是 `hasMac`——不知道和没有是两件事。
public struct DeviceCapabilities: Equatable, Sendable {
    /// `WCSession.isPaired`。
    public var hasPairedWatch: Bool
    /// `WCSession.isWatchAppInstalled`：配了表但没装 App，引导要多一步。
    public var isWatchAppInstalled: Bool
    /// 确定有 Mac（见类型说明）。`false` 只代表「不知道」。
    public var knownMac: Bool

    public init(hasPairedWatch: Bool = false, isWatchAppInstalled: Bool = false, knownMac: Bool = false) {
        self.hasPairedWatch = hasPairedWatch
        self.isWatchAppInstalled = isWatchAppInstalled
        self.knownMac = knownMac
    }
}

extension PersistentSurface {

    /// 这台设备应该被引导去添加的常驻位，按引导顺序排好。
    ///
    /// 两条规则：
    ///
    /// - **按设备能力分支**，不一股脑列四个。没配 Apple Watch 就不出现表盘那条，
    ///   否则引导页在教用户做一件他做不到的事，而这正是引导被划走的原因。
    /// - **已经添加过的排到后面**，但不删除——留着才有「已添加」的确认，
    ///   用户需要知道自己已经完成了。
    ///
    /// Mac 是唯一一个「不知道有没有」的位置：`knownMac` 为假时它不进主列表，
    /// 由界面放到一个「我还有一台 Mac」的次级入口里——猜不出来的事情让用户说，
    /// 比替他猜错好。
    public static func recommended(
        for capabilities: DeviceCapabilities,
        alreadyAdded: Set<PersistentSurface> = []
    ) -> [PersistentSurface] {
        let candidates = allCases.filter { surface in
            switch surface.requiredDevice {
            case .thisiPhone: return true
            case .appleWatch: return capabilities.hasPairedWatch
            case .mac: return capabilities.knownMac || alreadyAdded.contains(surface)
            }
        }
        // `allCases` 的声明顺序就是引导顺序；这里只把已完成的沉到底部，
        // 组内相对顺序保持不变（`enumerated` 让排序稳定）。
        return candidates.enumerated()
            .sorted { lhs, rhs in
                let lhsDone = alreadyAdded.contains(lhs.element)
                let rhsDone = alreadyAdded.contains(rhs.element)
                if lhsDone != rhsDone { return !lhsDone }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 主列表之外、需要用户自己认领的位置。
    ///
    /// 只装得下「不知道有没有」的设备，装不下「知道没有」的：没配 Apple Watch
    /// 是一个确定的事实，把它降级成一个折叠入口没有意义，只是把同一条无效引导
    /// 换个地方摆。Mac 是目前唯一无法从这台 iPhone 上问出来的设备。
    public static func opportunities(
        for capabilities: DeviceCapabilities,
        alreadyAdded: Set<PersistentSurface> = []
    ) -> [PersistentSurface] {
        let shown = Set(recommended(for: capabilities, alreadyAdded: alreadyAdded))
        return allCases.filter { $0.requiredDevice == .mac && !shown.contains($0) }
    }
}
