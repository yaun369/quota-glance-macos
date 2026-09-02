import SwiftUI
import WidgetKit
import QuotaPulseKit

/// The rounded provider badge at the head of a quota card (§4.12): a 44×44
/// tile tinted with the *status* color at 12%, carrying an SF Symbol in that
/// status color's dark text variant.
///
/// The reference design tints this chip with each item's identity color. That
/// is exactly what this must not do (§1.4): on this screen color already
/// means "how much is left", so it cannot simultaneously mean "which
/// provider". Identity is carried entirely by the glyph and the name beside
/// it — which is also why the two brand marks are used as *shapes only*,
/// template-rendered in the status color and never in a brand color.
///
/// It replaces v1's 8pt status dot on the surfaces that have room. The dot is
/// not retired: widgets and the Watch keep it, same meaning at a size that
/// fits.
struct IconChip: View {
    let provider: Provider
    /// The tighter of the card's two windows — the chip reports the state a
    /// reader should worry about first, not an average.
    let remainingPercent: Double?
    var size: CGFloat = 44

    private var level: QuotaPalette.Level { QuotaPalette.Level(remainingPercent: remainingPercent) }

    var body: some View {
        RoundedRectangle(cornerRadius: QuotaMetrics.Radius.icon, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                Image(provider.quotaGlyph, bundle: .main)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.5, height: size * 0.5)
                    .foregroundStyle(level.ink)
            }
            // Provider and status are both already in this card's text.
            // Reading the chip too would be noise, not information.
            .accessibilityHidden(true)
    }

    /// No reading is neutral rather than invisible: `quotaUnknown` at 12%
    /// would be a barely-there gray, so an empty card's chip sits on the
    /// sunken surface instead and keeps its shape on screen.
    private var background: Color {
        remainingPercent == nil ? QuotaPalette.surfaceSunken : level.color.opacity(0.12)
    }
}

/// The 8pt status dot (§4.12): ``IconChip``'s meaning at the size widgets
/// and the Watch actually have. Same status color, same thresholds; what it
/// drops is the provider glyph, which those surfaces already spell out in
/// text right beside it.
///
/// No reading draws nothing at all here rather than a gray dot — on a widget
/// the word 「暂无数据」 is already the whole content, and a dot next to it
/// would look like a state that exists.
struct QuotaStatusDot: View {
    let remainingPercent: Double?
    var size: CGFloat = 8

    var body: some View {
        if remainingPercent != nil {
            Circle()
                .fill(QuotaPalette.status(for: remainingPercent))
                .frame(width: size, height: size)
                // Puts the dot in the tint color wherever a widget is
                // recolored, same as the bar's colored segment.
                .widgetAccentable()
                // The percentage it stands for is in the text beside it.
                .accessibilityHidden(true)
        }
    }
}

extension Provider {
    /// The glyph that stands for this provider (§4.12): each vendor's own
    /// mark, shipped as a template SVG in `Shared/Assets.xcassets` so it
    /// takes the status color like any symbol would. They satisfy the
    /// grayscale requirement by construction — an angular letterform against
    /// a radial knot — and they are what users already recognize, which two
    /// generic SF Symbols never were.
    ///
    /// Only the surfaces that carry `Shared/Assets.xcassets` can draw these:
    /// the iPhone, the Watch and the Mac panel. The two widget targets
    /// compile the design system without the catalog, which is fine because
    /// §4.12 keeps `IconChip` off widgets anyway — they use the 8pt status
    /// dot. Adding a chip to a widget means adding the catalog to that
    /// target first.
    var quotaGlyph: String {
        switch self {
        case .codex: return "CodexGlyph"
        case .claude: return "ClaudeGlyph"
        }
    }
}

#if DEBUG
#Preview {
    HStack(spacing: QuotaMetrics.Space.row) {
        IconChip(provider: .codex, remainingPercent: 66)
        IconChip(provider: .claude, remainingPercent: 24)
        IconChip(provider: .claude, remainingPercent: 8)
        IconChip(provider: .codex, remainingPercent: nil)
    }
    .padding(QuotaMetrics.Space.card)
}
#endif
