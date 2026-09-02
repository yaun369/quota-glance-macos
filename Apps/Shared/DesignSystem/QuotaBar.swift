import QuotaPulseKit
import SwiftUI
import WidgetKit

/// The single quota bar for all four surfaces (§4.3).
///
/// Direction is the part worth spelling out: the colored segment is pinned to
/// the **trailing** edge and shrinks leftward as quota is consumed — gray is
/// what has been used, color is what is left. The iPhone used to run the other
/// way round (a system `ProgressView` fills from the leading edge), which meant
/// the same 66% pointed in opposite directions on the phone and on the widget.
/// Flipping the phone rather than the other three keeps the majority, keeps the
/// VoiceOver wording that was already written against this model, and matches
/// what the product actually does: quota drains, it does not accumulate.
///
/// Reversing this again means changing iOS, both widgets, the Watch **and**
/// the accessibility label together — never just one end.
struct QuotaBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let remainingPercent: Double?
    /// 走 ``QuotaMetrics/BarHeight``：Hero 10 / 主窗口 8 / 次窗口 6 / 小组件 6 / Watch 7。
    var height: CGFloat = QuotaMetrics.BarHeight.primary
    /// 深色 Hero 卡上要换成 ``QuotaPalette/heroTrack``——`track` 在深底上看不见。
    var trackColor: Color = QuotaPalette.track

    private var progress: Double {
        guard let remainingPercent else { return 0 }
        return max(0, min(1, remainingPercent / 100))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(trackColor)

                // No data draws the track alone. A full-width colored bar would
                // read as "plenty left", which is the one thing we do not know.
                if remainingPercent != nil {
                    Capsule()
                        .fill(QuotaPalette.status(for: remainingPercent))
                        .frame(width: proxy.size.width * progress)
                        // Puts the colored segment in the tint color when a
                        // watch face or Lock Screen recolors the widget.
                        .widgetAccentable()
                }
            }
        }
        .frame(height: height)
        // §3.6's recipe for a length change, and the switch that turns it off
        // — both live here rather than at the call sites, so a new surface
        // gets the animation *and* the accessibility behavior by using the
        // bar, instead of by remembering two modifiers.
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: remainingPercent)
        // Read as one element: without this VoiceOver announces the track and
        // the fill separately, which is noise, not information.
        .accessibilityElement(children: .ignore)
        // The one sentence that has to name 「已用」/ "used" (§6): a bar is
        // two lengths, and a reader who cannot see them needs to be told
        // which one is which. The *value* below still leads with what is
        // left, so the announcement as a whole keeps the remaining-first
        // order every other surface uses.
        .accessibilityLabel("Quota progress; the gray portion is what has been used")
        .accessibilityValue(QuotaFormatting.remainingText(percent: remainingPercent))
    }
}

/// The circular form of ``QuotaBar``, for `accessoryCircular` and
/// `accessoryCorner` (§4.4).
///
/// Those families get rendered monochrome, so the fill **ratio** is the signal
/// and the color is only a bonus in the full-color rendering mode. Whatever
/// sits inside the ring has to carry the number.
struct QuotaRing: View {
    let remainingPercent: Double?
    var lineWidth: CGFloat = QuotaMetrics.Ring.lineWidth

    private var progress: Double {
        guard let remainingPercent else { return 0 }
        return max(0, min(1, remainingPercent / 100))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(QuotaPalette.track, lineWidth: lineWidth)

            if remainingPercent != nil {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        QuotaPalette.status(for: remainingPercent),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    // Starts at 12 o'clock and runs clockwise.
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
        }
        // The stroke straddles the circle's edge, so half of it would clip.
        .padding(lineWidth / 2)
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: QuotaMetrics.Space.row) {
        QuotaBar(remainingPercent: 66, height: QuotaMetrics.BarHeight.primary)
        QuotaBar(remainingPercent: 22, height: QuotaMetrics.BarHeight.secondary)
        QuotaBar(remainingPercent: 8, height: QuotaMetrics.BarHeight.hero)
        QuotaBar(remainingPercent: nil, height: QuotaMetrics.BarHeight.watch)
        HStack {
            QuotaRing(remainingPercent: 66).frame(width: 48, height: 48)
            QuotaRing(remainingPercent: 22).frame(width: 48, height: 48)
            QuotaRing(remainingPercent: nil).frame(width: 48, height: 48)
        }
    }
    .padding(QuotaMetrics.Space.card)
}
#endif
