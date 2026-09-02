import SwiftUI

/// Type scale (§3.5). Chinese falls back to PingFang on its own, so
/// `design: .rounded` is safe to use on mixed 中英 strings.
///
/// Every token here scales with Dynamic Type. The ones with a pinned point
/// size cannot be expressed as a plain `Font` — `Font.system(size:)` is frozen
/// against Dynamic Type — so they ship as view modifiers instead; see
/// ``QuotaTypography/ScaledFont``.
enum QuotaTypography {

    /// 首页大标题「码量」。
    static let display = Font.system(.largeTitle, weight: .bold)
    /// 分组标题（「你的额度」）。
    static let sectionTitle = Font.system(.title3, weight: .semibold)
    /// 卡片标题（Codex / Claude）。
    static let cardTitle = Font.system(.title2, weight: .semibold)
    /// 次级窗口数值。
    static let metricSecondary = Font.system(.title3, design: .rounded, weight: .bold)
    static let body = Font.body
    /// 窗口标签（5 小时 / 每周）。
    static let label = Font.system(.subheadline, weight: .medium)
    /// 倒计时、时间戳。
    static let caption = Font.caption
    /// 小组件里的次级信息。
    static let micro = Font.caption2

    /// 小组件排版（§5.4）。沿用 §4.2 的层级但压缩一档。
    ///
    /// Widgets do not follow Dynamic Type, so fixed sizes are allowed here —
    /// but they still have to be *named*, or the same 9pt reappears in four
    /// files and nobody can change it in one place again.
    enum Widget {
        /// provider 名。
        static let title = Font.headline
        /// 窗口数值。
        static let metric = Font.system(.title3, design: .rounded, weight: .bold)
        /// 窗口标签。
        static let label = Font.caption.weight(.semibold)
        /// 倒计时、时间戳、空态说明。
        static let caption = Font.caption2
    }

    /// 锁屏 / 表盘 accessory 家族（§5.5）。比小组件更紧，且渲染为单色——所以
    /// 这里的字号是主要信号，不是装饰。
    enum Accessory {
        /// 环内 provider 缩写（C / CX）。
        static let initials = Font.system(size: 9, weight: .semibold, design: .rounded)
        /// 环内 / 紧凑行的剩余数值。
        static let metric = Font.system(size: 12, weight: .bold, design: .rounded)
        /// 紧凑行的窗口标签。
        static let label = Font.system(size: 11, weight: .medium)
        /// 矩形家族右上角的时间戳。
        static let timestamp = Font.system(size: 9)
    }

    /// Hero 卡主数值，40pt。用法：`.quotaFont(.heroMetric)`。
    static var heroMetric: ScaledFont { .heroMetric }
    /// 卡片主数值，34pt。用法：`.quotaFont(.metricPrimary)`。
    static var metricPrimary: ScaledFont { .metricPrimary }

    /// A pinned-size rounded numeral face that still answers to Dynamic Type.
    ///
    /// `@ScaledMetric` does the growing that `Font.system(size:)` refuses to
    /// do. Digits are monospaced so a counting-down number does not jitter.
    struct ScaledFont: ViewModifier {
        @ScaledMetric private var size: CGFloat
        private let weight: Font.Weight

        init(size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .bold) {
            _size = ScaledMetric(wrappedValue: size, relativeTo: style)
            self.weight = weight
        }

        /// Hero 卡主数值。
        static var heroMetric: ScaledFont {
            ScaledFont(size: 40, relativeTo: .largeTitle)
        }

        /// 卡片主数值。
        static var metricPrimary: ScaledFont {
            ScaledFont(size: 34, relativeTo: .largeTitle)
        }

        func body(content: Content) -> some View {
            content
                .font(.system(size: size, weight: weight, design: .rounded))
                .monospacedDigit()
        }
    }
}

extension View {
    /// Applies one of the pinned-size tokens, e.g. `.quotaFont(.heroMetric)`.
    func quotaFont(_ font: QuotaTypography.ScaledFont) -> some View {
        modifier(font)
    }
}
