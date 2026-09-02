import SwiftUI

/// §4.6 的按钮表，写成可复用的样式与容器。
///
/// 分档的依据不是「好不好看」而是**一屏里的唯一性**：主行动一屏最多一个，
/// 底部全宽主行动只在空态和完全失败态出现，其余全是次行动或纯文字。把这条
/// 规则编码进类型名，比写在文档里更难被下一个人绕过。
///
/// 高度一律用 `minHeight` 而不是 `frame(height:)`：§7 禁止给装文字的东西钉死
/// 高度，大字体下要能长高而不是裁掉标签。

// MARK: - 主行动（`ink` 实心药丸）

/// 「登录账号」「一键配置」。深色实心，一屏最多一个。
struct QuotaPrimaryButtonStyle: ButtonStyle {
    /// 全宽版把高度提到 52 并撑满 `gutter` 内的宽度（§4.6 的「底部全宽主行动」）。
    var isFullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(QuotaTypography.body.weight(.semibold))
            .foregroundStyle(QuotaPalette.surface)
            .padding(.horizontal, isFullWidth ? 20 : 18)
            .padding(.vertical, 12)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .frame(minHeight: isFullWidth ? 52 : 44)
            .background(QuotaPalette.ink.opacity(isEnabled ? 1 : 0.35), in: Capsule())
            // 按压反馈只用不透明度，不缩放：底部那颗按钮宽度撑满一屏，
            // 缩放会让整条边界跟着抖，在小屏上尤其明显。
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 次行动（`surfaceSunken` 药丸）

/// 「重试」「取消」「复制下载地址」。
struct QuotaSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(QuotaTypography.body.weight(.medium))
            .foregroundStyle(QuotaPalette.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(QuotaPalette.surfaceSunken, in: Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

extension ButtonStyle where Self == QuotaPrimaryButtonStyle {
    static var quotaPrimary: QuotaPrimaryButtonStyle { QuotaPrimaryButtonStyle() }
    static var quotaPrimaryFullWidth: QuotaPrimaryButtonStyle { QuotaPrimaryButtonStyle(isFullWidth: true) }
}

extension ButtonStyle where Self == QuotaSecondaryButtonStyle {
    static var quotaSecondary: QuotaSecondaryButtonStyle { QuotaSecondaryButtonStyle() }
}

// MARK: - 图标 + 文字药丸

/// 参考稿 `Add Goal` 的落点（§4.6）：`surface` 白底药丸 + 左侧 28pt `ink` 实心
/// 圆图标 + `ink` 文字。用于引导页的「添加账号」。
///
/// 为什么引导页不用主行动那颗黑药丸：引导页上「添加 Codex」和「添加 Claude」
/// 是并列的两个入口，两颗黑药丸会各自宣称自己是这一屏的唯一主行动，谁都不是。
/// 白底 + 深色图标把重量放在图标上，两个并列时仍然读得出是同一层的两个选项。
///
/// 图标交给调用方画，因为 provider 的字形来自资源目录、系统状态来自 SF Symbol，
/// 而这个容器只负责那个 28pt 的 `ink` 圆和它右边的排版。
struct IconTextPillButton<Icon: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(QuotaPalette.ink)
                        .frame(width: 28, height: 28)
                    icon()
                        .foregroundStyle(QuotaPalette.surface)
                }
                Text(title)
                    .font(QuotaTypography.body.weight(.semibold))
                    .foregroundStyle(QuotaPalette.ink)
            }
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .quotaSurface(shape: Capsule())
            // 药丸之外的空白不该吃掉点击：容器本身没有背景时，
            // `contentShape` 是唯一能把命中区限制在药丸上的东西。
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension IconTextPillButton where Icon == Image {
    /// SF Symbol 版。
    init(title: String, systemImage: String, action: @escaping () -> Void) {
        self.init(title: title, action: action) {
            Image(systemName: systemImage)
        }
    }
}

// MARK: - 底部全宽主行动

/// §4.6 的「底部全宽主行动」：撑满 `gutter` 内、高 52、固定在
/// `.safeAreaInset(edge: .bottom)` 上。
///
/// **只用于空态与完全失败态的唯一出路。有数据时不出现。** 参考稿那条常驻按钮
/// 是因为「存钱」是个高频动作；码量的用户不需要频繁点任何东西，一颗永远在
/// 屏幕底部的按钮在这里只会变成一条挡住内容的横幅。
struct BottomPrimaryAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.quotaPrimaryFullWidth)
            .padding(.horizontal, QuotaMetrics.Space.gutter)
            .padding(.bottom, 12)
            .padding(.top, 8)
            // 按钮压在滚动内容之上，底下必须有不透明的地面，
            // 否则文字会从药丸的两侧穿过去。
            .background(QuotaPalette.bg)
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: QuotaMetrics.Space.row) {
        Button("Sign in") {}
            .buttonStyle(.quotaPrimary)
        Button("Retry") {}
            .buttonStyle(.quotaSecondary)
        IconTextPillButton(title: "Add account", systemImage: "plus") {}
        BottomPrimaryAction(title: "Sign in") {}
    }
    .padding(QuotaMetrics.Space.gutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(QuotaPalette.bg)
}
#endif
