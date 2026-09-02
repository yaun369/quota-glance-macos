import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The one place a color value is written down. Every surface — iPhone,
/// widgets, Watch, Mac panel — reads from here, so a token changes once and
/// lands everywhere (UI 规范 §3.1).
///
/// Naming is semantic, never literal: `track` says what the color is for, so
/// the light/dark pair can move without renaming a single call site.
enum QuotaPalette {

    // MARK: - 中性骨架

    /// 页面底板。暖灰，不是纯灰。
    static let bg = Color.adaptiveQuota(light: 0xEDEAE6, dark: 0x121110)
    /// 卡片表面。浅色下是纯白，卡片边界才立得住而不必靠描边。
    static let surface = Color.adaptiveQuota(light: 0xFFFFFF, dark: 0x1C1B1A)
    /// 卡片内的次级容器、选中态药丸。浅色下已经白到头，再抬一档只能靠阴影。
    static let surfaceRaised = Color.adaptiveQuota(light: 0xFFFFFF, dark: 0x262524)
    /// 内嵌区域、代码/地址块、图标 chip 的中性底。
    static let surfaceSunken = Color.adaptiveQuota(light: 0xF3F1ED, dark: 0x141312)
    /// 额度条 / 环的轨道，语义上等于「已用掉的那一段」。
    static let track = Color.adaptiveQuota(light: 0xE2DFDA, dark: 0x34322F)
    /// 分割线；深色模式下也用作卡片顶部的 1px 高光。
    static let hairline = Color.adaptiveQuota(
        light: Color.black.opacity(0.06),
        dark: Color.white.opacity(0.08)
    )

    // MARK: - Hero 卡

    /// 浅色下是最暗的一张卡，深色下反转为最亮的一张（§3.1）。反差的方向变了，
    /// 反差本身没丢——所以调用点永远不必写 `if colorScheme`。
    static let heroSurface = Color.adaptiveQuota(light: 0x262422, dark: 0x262524)
    static let heroInk = Color.adaptiveQuota(light: 0xFBFAF9, dark: 0xF2F0EE)
    static let heroInkSecondary = Color.adaptiveQuota(light: 0xA5A09A, dark: 0xA8A29D)
    /// Hero 卡内额度条的轨道。深色卡上不能用 `track`，要用透明白压出来。
    static let heroTrack = Color.adaptiveQuota(
        light: Color.white.opacity(0.14),
        dark: Color.white.opacity(0.12)
    )

    // MARK: - 文字
    //
    // 浅色值经 §7 对比度实测校准（UI-8 #8）：正文 / 次级文字对 `surface`
    // **和** `bg` 都 ≥ 4.5:1，`inkTertiary` 对两者都 ≥ 3:1。校准前
    // `inkSecondary` 落在 `bg` 上只有 4.42:1——设置页与引导页的页脚正好在
    // 这个组合上，这是最容易被漏掉的一处，因为在白卡片上它是过的。

    static let ink = Color.adaptiveQuota(light: 0x171615, dark: 0xF2F0EE)
    static let inkSecondary = Color.adaptiveQuota(light: 0x6C6967, dark: 0xA8A29D)
    /// ≈3:1，**仅限** ≥17pt 或非必要信息（时间戳、序号）。凡是用户读不到就会
    /// 做错事的文案（错误原因、引导步骤），必须用 `inkSecondary` 及以上。
    static let inkTertiary = Color.adaptiveQuota(light: 0x8B8682, dark: 0x7A7570)

    // MARK: - 额度状态色
    //
    // 浅色值同样按 §7 的「图形 ≥ 3:1」实测过（UI-8 #8）：判据是**彩色段对
    // 轨道 `track`**，因为那条边界就是水位本身。原来的绿 / 橙对轨道只有
    // 2.54 / 2.26，在白卡片上看着够，在条上不够——四端的条都由这两个值画，
    // 所以这里改一次，四端一起对。深色值本来就是为深底调的，未动。

    static let quotaAmple = Color.adaptiveQuota(light: 0x2A9061, dark: 0x3FBE84)
    static let quotaLow = Color.adaptiveQuota(light: 0xC1671B, dark: 0xF2A24A)
    static let quotaCritical = Color.adaptiveQuota(light: 0xD6453C, dark: 0xF2635A)
    static let quotaUnknown = Color.adaptiveQuota(light: 0xB5B2AF, dark: 0x5A5755)

    /// 水位分档。**全仓库唯一一处 15 / 30 阈值判断** —— 图形色和文字色都从这里
    /// 派生，两者不会各判一次然后慢慢判出分歧。
    enum Level {
        case ample
        case low
        case critical
        case unknown

        /// 剩余低于此值算临界。
        static let criticalThreshold: Double = 15
        /// 剩余低于此值算吃紧。
        static let lowThreshold: Double = 30

        init(remainingPercent: Double?) {
            guard let remainingPercent else {
                self = .unknown
                return
            }
            switch remainingPercent {
            case ..<Self.criticalThreshold: self = .critical
            case ..<Self.lowThreshold: self = .low
            default: self = .ample
            }
        }

        /// 图形专用（条、环、圆点、chip 底）。
        var color: Color {
            switch self {
            case .ample: return quotaAmple
            case .low: return quotaLow
            case .critical: return quotaCritical
            case .unknown: return quotaUnknown
            }
        }

        /// 写字用的深色变体（浅色模式下 ≥4.5:1）。深色模式沿用状态色本身——
        /// 它本来就是为深底设计的。
        var ink: Color {
            switch self {
            case .ample: return Color.adaptiveQuota(light: 0x1F7A50, dark: 0x3FBE84)
            case .low: return Color.adaptiveQuota(light: 0xA8541A, dark: 0xF2A24A)
            case .critical: return Color.adaptiveQuota(light: 0xB0342C, dark: 0xF2635A)
            case .unknown: return inkSecondary
            }
        }
    }

    /// 额度状态色，**图形专用**。要用状态色写字请走 `statusInk(for:)` —— 上面
    /// 那几个色值在纯白卡片上只有 3.4:1，够画图形，不够写文字。
    static func status(for remainingPercent: Double?) -> Color {
        Level(remainingPercent: remainingPercent).color
    }

    /// 需要用状态色写字时的深色变体。
    static func statusInk(for remainingPercent: Double?) -> Color {
        Level(remainingPercent: remainingPercent).ink
    }

    // MARK: - 品牌色

    /// 取自 App 图标。**只用于**链接、开关选中、主按钮的强调态。品牌蓝绝对不能
    /// 参与额度表达，否则用户会把「蓝色」误读成第四种水位。
    ///
    /// 图形专用——它在白卡片上只有 3.8:1。要用品牌蓝**写字**请走 ``brandInk``。
    static let brand = Color.adaptiveQuota(light: 0x2F80F5, dark: 0x6BA6FF)

    /// 品牌蓝的文字变体（浅色下对 `surface` 与 `bg` 都 ≥ 4.5:1）。
    ///
    /// 与状态色的 `color` / `ink` 是同一套办法：图标色照搬到文字上必然差一档，
    /// 与其把 `brand` 整体调暗、让它离 App 图标越来越远，不如让写字的那份单独
    /// 暗下去。深色模式沿用 `brand` 的深色值——它已经是 6.98:1。
    static let brandInk = Color.adaptiveQuota(light: 0x0B62E1, dark: 0x6BA6FF)
}

extension Color {

    /// Resolves to `dark` or `light` by the current appearance.
    ///
    /// The three platforms take three different routes, and watchOS is the one
    /// that forces the shape of this helper: its UIKit subset ships no
    /// `UIColor(dynamicProvider:)` at all. Since the Watch app is always dark
    /// (§5.6) that is not a loss — the watchOS branch just returns the dark
    /// value — but the branch has to exist here, once, or every future batch
    /// would have to route around it.
    static func adaptiveQuota(light: Color, dark: Color) -> Color {
#if os(watchOS)
        return dark
#elseif canImport(UIKit)
        // `UIColor(dynamicProvider:)` is extension-API-safe, which matters:
        // both widget targets build with APPLICATION_EXTENSION_API_ONLY.
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
#elseif canImport(AppKit)
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
#else
        return light
#endif
    }

    static func adaptiveQuota(light: UInt32, dark: UInt32) -> Color {
        adaptiveQuota(light: Color(quotaHex: light), dark: Color(quotaHex: dark))
    }

    /// `0xRRGGBB`, sRGB, opaque — the form the token table in §3.1 is written in.
    init(quotaHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
