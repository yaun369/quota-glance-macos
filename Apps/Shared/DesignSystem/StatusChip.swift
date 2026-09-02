import SwiftUI

/// 状态徽章（§4.5）: the one recipe for "something is wrong" or "here is a
/// state", replacing the loose red and orange text that each surface used to
/// invent for itself.
///
/// The symbol is not decoration and is not optional (§1.3). A badge that
/// separates its three levels by background color alone is unreadable to a
/// color-blind user and gone entirely wherever the system renders monochrome,
/// so the glyph carries the level and the tint only reinforces it.
///
/// Height is a *minimum*, not a frame: §7 forbids fixed heights on anything
/// that holds text, so a badge at AX3 grows instead of clipping its label.
struct StatusChip: View {
    enum Level {
        /// 还能用，但有一件事需要知道——直连失败但旧数据仍在、后台刷新被关掉。
        case warning
        /// 这条路走不通了，需要用户动手。
        case error
        /// 中性事实，不是问题：「已开启」「已连接 iCloud」。
        case info

        /// The default glyph for the level. A call site with a more specific
        /// noun to draw (iCloud, a bell) passes its own; the level's tint
        /// still says how to read it.
        var symbolName: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .info: return "checkmark.circle"
            }
        }

        var background: Color {
            switch self {
            case .warning: return QuotaPalette.quotaLow.opacity(0.12)
            case .error: return QuotaPalette.quotaCritical.opacity(0.12)
            // Neutral rather than tinted: a gray state is a state, not a
            // fourth water level (§1.4).
            case .info: return QuotaPalette.surfaceSunken
            }
        }

        var foreground: Color {
            switch self {
            case .warning: return QuotaPalette.Level.low.ink
            case .error: return QuotaPalette.Level.critical.ink
            case .info: return QuotaPalette.inkSecondary
            }
        }
    }

    let level: Level
    let text: String
    /// Overrides the level's default glyph. The level keeps its color.
    var symbolName: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbolName ?? level.symbolName)
        }
        .font(QuotaTypography.caption.weight(.medium))
        .foregroundStyle(level.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 24)
        .background(
            level.background,
            in: RoundedRectangle(cornerRadius: QuotaMetrics.Radius.chip, style: .continuous)
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A badge with its reason underneath (§4.5): the badge names the state in
/// two or three words, the line below says why and what to do next (§6).
///
/// Split in two on purpose — the short form is what a reader scanning the
/// screen takes in, and burying it inside a paragraph would make every error
/// cost a full read.
struct StatusNote: View {
    let level: StatusChip.Level
    let title: String
    var detail: String?
    var symbolName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusChip(level: level, text: title, symbolName: symbolName)
            if let detail {
                Text(detail)
                    .font(QuotaTypography.caption)
                    .foregroundStyle(QuotaPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Badge and reason are one statement; read apart, the badge announces
        // a fragment and the reason arrives without its subject.
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: QuotaMetrics.Space.row) {
        StatusChip(level: .warning, text: "Account direct read failed")
        StatusChip(level: .error, text: "Sign-in failed")
        StatusChip(level: .info, text: "On")
        StatusChip(level: .info, text: "iCloud connected", symbolName: "icloud")
        StatusNote(
            level: .warning,
            title: "Account direct read failed",
            detail: "Your sign-in has expired. Please sign in again. The reading below is the last one that succeeded."
        )
    }
    .padding(QuotaMetrics.Space.card)
    .background(QuotaPalette.surface)
}
#endif
