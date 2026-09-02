import CoreGraphics

/// Radii, spacing and bar geometry, shared by all four surfaces (§3.2、§3.4).
///
/// Magic numbers that live at a call site drift apart across targets — that is
/// exactly how the quota bar ended up with three heights and two directions.
enum QuotaMetrics {

    /// 全部搭配 `RoundedRectangle(cornerRadius:style: .continuous)`；
    /// `.circular` 会明显更硬。
    enum Radius {
        /// 深色 Hero 卡，比普通卡片再软一档，撑住更大的面积。
        static let hero: CGFloat = 26
        static let card: CGFloat = 22
        /// 卡片内的次级容器。Watch 的卡片也降到这一档。
        static let inner: CGFloat = 16
        /// provider 图标 chip。
        static let icon: CGFloat = 14
        /// 徽章、小标签。
        static let chip: CGFloat = 12
    }

    /// 4 的倍数。
    enum Space {
        /// 页面左右边距。
        static let gutter: CGFloat = 20
        /// Hero 卡内边距，比普通卡片多 2，撑住 40pt 大数值。
        static let hero: CGFloat = 20
        static let card: CGFloat = 18
        /// 卡片之间。
        static let gap: CGFloat = 14
        /// 卡片内两个额度窗口之间。
        static let row: CGFloat = 12
        /// 分组之间。
        static let section: CGFloat = 28
    }

    /// 条高是层级信号：主窗口比次窗口粗，靠粗细而不是靠颜色区分（§4.2）。
    enum BarHeight {
        static let hero: CGFloat = 10
        static let primary: CGFloat = 8
        static let secondary: CGFloat = 6
        static let widget: CGFloat = 6
        static let watch: CGFloat = 7
    }

    enum Ring {
        static let lineWidth: CGFloat = 4
    }
}
