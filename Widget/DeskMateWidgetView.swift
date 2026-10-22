import DeskMateShared
import SwiftUI
import WidgetKit

/// Chooses the layout for the widget family. Both lay out the same generic summary.
struct DeskMateWidgetView: View {
    let entry: DeskMateEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var summary: WidgetSummary { WidgetSummary(snapshot: entry.snapshot, now: entry.date) }
    private var palette: WidgetPalette { WidgetPalette(scheme: scheme, contrast: contrast) }
    /// Brand colours only in full colour; a tinted or accented widget takes the colour the system chooses.
    private var fullColor: Bool { renderingMode == .fullColor }

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                MediumLayout(summary: summary, palette: palette, fullColor: fullColor)
            default:
                SmallLayout(summary: summary, palette: palette, fullColor: fullColor)
            }
        }
        .containerBackground(.background, for: .widget)
    }
}

// MARK: Pieces

/// The brand mark: the same sparkle the assistant uses, on brand-fill.
private struct BrandMark: View {
    let palette: WidgetPalette
    let fullColor: Bool

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(fullColor ? Color.white : Color.primary)
            .frame(width: WidgetMetrics.markSize, height: WidgetMetrics.markSize)
            .background {
                RoundedRectangle(cornerRadius: WidgetMetrics.markRadius, style: .continuous)
                    .fill(fullColor ? palette.brandFill : Color.primary.opacity(0.15))
            }
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

/// "Ready" or "Needs attention", with the time of the snapshot. With no snapshot it only says to open the app.
private struct StatusLines: View {
    let summary: WidgetSummary
    let palette: WidgetPalette
    let fullColor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: WidgetMetrics.tightGap) {
                if summary.needsAttention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(WidgetMetrics.caption)
                        .accessibilityHidden(true)
                }
                Text(summary.headline)
                    .font(WidgetMetrics.captionStrong)
            }
            .foregroundStyle(headlineStyle)
            if let asOf = summary.asOf {
                Text(asOf)
                    .font(WidgetMetrics.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headlineStyle: Color {
        guard fullColor else { return .primary }
        return summary.needsAttention ? palette.warning : .primary
    }
}

/// The primary action drawn as a filled pill. The widget itself is the link, so this is not a separate button.
private struct AskPill: View {
    let palette: WidgetPalette
    let fullColor: Bool

    var body: some View {
        Text("Ask DeskMate")
            .font(WidgetMetrics.body)
            .foregroundStyle(fullColor ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: WidgetMetrics.controlRadius, style: .continuous)
                    .fill(fullColor ? palette.brandFill : Color.primary.opacity(0.15))
            }
            .widgetAccentable()
    }
}

// MARK: Small

private struct SmallLayout: View {
    let summary: WidgetSummary
    let palette: WidgetPalette
    let fullColor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.gap) {
            BrandMark(palette: palette, fullColor: fullColor)
            StatusLines(summary: summary, palette: palette, fullColor: fullColor)
            Spacer(minLength: 0)
            AskPill(palette: palette, fullColor: fullColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The whole widget opens the assistant, so nothing inside it needs its own target.
        .widgetURL(DeskMateRoute.ask.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ask DeskMate")
        .accessibilityValue(summary.spokenStatus)
        .accessibilityHint("Opens the assistant")
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: Medium

private struct MediumLayout: View {
    let summary: WidgetSummary
    let palette: WidgetPalette
    let fullColor: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: WidgetMetrics.gap) {
                BrandMark(palette: palette, fullColor: fullColor)
                StatusLines(summary: summary, palette: palette, fullColor: fullColor)
                if let task = summary.latestTask {
                    Text(task)
                        .font(WidgetMetrics.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("DeskMate status")
            .accessibilityValue(summary.spokenStatus)

            VStack(spacing: WidgetMetrics.tightGap + 2) {
                ActionLink(title: "New chat", symbol: "square.and.pencil", route: .new, hint: "Opens the assistant with a new chat", palette: palette, fullColor: fullColor)
                ActionLink(title: "Ask my files", symbol: "folder", route: .files, hint: "Opens the assistant to ask about files you choose", palette: palette, fullColor: fullColor)
                if let resume = summary.resume {
                    ActionLink(title: "Resume", symbol: "arrow.uturn.forward", route: resume, hint: "Opens your most recent conversation", palette: palette, fullColor: fullColor)
                }
            }
            .frame(maxWidth: .infinity)
        }
        // Anywhere else on the widget opens the assistant too.
        .widgetURL(DeskMateRoute.ask.url)
    }
}

private struct ActionLink: View {
    let title: String
    let symbol: String
    let route: DeskMateRoute
    let hint: String
    let palette: WidgetPalette
    let fullColor: Bool

    var body: some View {
        Link(destination: route.url) {
            HStack(spacing: WidgetMetrics.gap) {
                Image(systemName: symbol)
                    .font(WidgetMetrics.captionStrong)
                    .foregroundStyle(fullColor ? palette.brandText : Color.primary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(WidgetMetrics.captionStrong)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: WidgetMetrics.controlRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
            .widgetAccentable()
        }
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }
}
