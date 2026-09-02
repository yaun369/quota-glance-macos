import SwiftUI

/// Card elevation (§3.3). The token names a *role*, not a shadow — what it
/// resolves to depends on the appearance and on two accessibility switches,
/// and that resolution happens here so no call site ever writes
/// `if colorScheme == .dark`.
enum QuotaElevation {
    /// 卡片静止态。
    case card
    /// 悬浮横幅、按压中的可点卡片。
    case raised
    /// 小组件、Watch、Mac 面板。
    case none
}

extension View {
    /// Fills the view's background with a card surface: the given shape, one
    /// of the surface tokens, and the elevation treatment for the current
    /// appearance.
    ///
    /// Three appearances, one call:
    /// - 浅色：两层柔和阴影（§3.3 的配方）。
    /// - 深色：阴影全关，改为顶部 1px `hairline` 高光——深底上阴影是看不见的，
    ///   卡片边界只能靠亮度差和这道高光立起来。
    /// - 增强对比度：阴影降级为整圈 `hairline` 描边（§7）。
    func quotaSurface<S: InsettableShape>(
        _ fill: Color = QuotaPalette.surface,
        shape: S,
        elevation: QuotaElevation = .card
    ) -> some View {
        modifier(QuotaSurfaceModifier(fill: fill, shape: shape, elevation: elevation))
    }

    /// The common case: one of ``QuotaMetrics/Radius``. Pills and circles pass
    /// `shape:` a `Capsule` — a rounded rect with a huge radius is *not* the
    /// same thing, `.continuous` corners stop rounding well before they close.
    func quotaSurface(
        _ fill: Color = QuotaPalette.surface,
        radius: CGFloat = QuotaMetrics.Radius.card,
        elevation: QuotaElevation = .card
    ) -> some View {
        quotaSurface(
            fill,
            shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
            elevation: elevation
        )
    }
}

private struct QuotaSurfaceModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let fill: Color
    let shape: S
    let elevation: QuotaElevation

    private var drawsShadow: Bool {
        elevation != .none && colorScheme == .light && colorSchemeContrast == .standard
    }

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(fill)
                    .overlay {
                        if colorSchemeContrast == .increased {
                            shape.strokeBorder(QuotaPalette.hairline, lineWidth: 1)
                        } else if colorScheme == .dark {
                            // Strongest along the top edge and gone by the
                            // bottom, which is where a light source would put
                            // it — a full ring reads as a border, not as lift.
                            shape.strokeBorder(
                                LinearGradient(
                                    colors: [QuotaPalette.hairline, .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                        }
                    }
                    // Without this the second shadow below is cast by the
                    // first shadow's blur rather than by the card itself.
                    .compositingGroup()
                    .shadow(
                        color: shadowColor(opacity: primaryShadowOpacity),
                        radius: primaryShadowRadius,
                        y: primaryShadowOffset
                    )
                    .shadow(
                        color: shadowColor(opacity: elevation == .card ? 0.03 : 0),
                        radius: 3,
                        y: 1
                    )
            }
    }

    private func shadowColor(opacity: Double) -> Color {
        drawsShadow ? Color.black.opacity(opacity) : .clear
    }

    private var primaryShadowOpacity: Double { elevation == .raised ? 0.10 : 0.06 }
    private var primaryShadowRadius: CGFloat { elevation == .raised ? 28 : 18 }
    private var primaryShadowOffset: CGFloat { elevation == .raised ? 12 : 6 }
}
