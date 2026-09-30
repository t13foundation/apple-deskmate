import AppKit
import SwiftUI

// MARK: Layout

extension View {
    /// The one reading column. Notice, empty state, transcript, composer and My files all use it,
    /// so their left and right edges line up at every window width.
    func dmReadingColumn() -> some View {
        frame(maxWidth: DS.Layout.readingWidth)
            .padding(.horizontal, DS.Spacing.panel)
            .frame(maxWidth: .infinity)
    }
}

// MARK: Surfaces

/// A grouped surface: subtle material normally, a solid fill with Reduce Transparency,
/// and a stronger border with Increase Contrast.
struct DMSurface: ViewModifier {
    var radius: CGFloat = DS.Radius.surface
    var highlighted = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial))
            }
            .overlay {
                shape.strokeBorder(
                    highlighted ? Color.dmBrandText : Color(nsColor: .separatorColor),
                    lineWidth: highlighted ? DS.Stroke.focus : (contrast == .increased ? DS.Stroke.increasedContrast : DS.Stroke.hairline)
                )
            }
    }
}

/// A faint tinted background with a matching hairline, for notices and badges. Not a material, so it is
/// identical with Reduce Transparency.
struct DMTint: ViewModifier {
    var color: Color
    var radius: CGFloat = DS.Radius.control
    var highlighted = false

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(color.opacity(DS.Fill.tint)))
            .overlay {
                shape.strokeBorder(
                    highlighted ? Color.dmBrandText : color.opacity(DS.Fill.tintBorder),
                    lineWidth: highlighted ? DS.Stroke.focus : (contrast == .increased ? DS.Stroke.increasedContrast : DS.Stroke.hairline)
                )
            }
    }
}

extension View {
    func dmSurface(radius: CGFloat = DS.Radius.surface, highlighted: Bool = false) -> some View {
        modifier(DMSurface(radius: radius, highlighted: highlighted))
    }

    func dmTint(_ color: Color, radius: CGFloat = DS.Radius.control, highlighted: Bool = false) -> some View {
        modifier(DMTint(color: color, radius: radius, highlighted: highlighted))
    }

    /// Animates only when Reduce Motion is off.
    func dmAnimation<V: Equatable>(_ animation: Animation = .easeOut(duration: 0.18), value: V) -> some View {
        modifier(DMAnimation(animation: animation, value: value))
    }

    /// Supporting text that carries information: 12 pt in the secondary label colour. Never tertiary, which
    /// is close to invisible on a light background.
    func dmFootnote() -> some View {
        font(.dmCaption).foregroundStyle(.secondary)
    }

    /// Content of an empty state: centred in the available height, then lifted slightly above the centre
    /// by keeping a share of the height free below it.
    func dmEmptyStateAnchor(height: CGFloat) -> some View {
        padding(.vertical, DS.Spacing.xl)
            .padding(.bottom, max(DS.Spacing.xxl * 2, height * DS.Layout.emptyStateLift))
            .frame(minHeight: height)
    }
}

private struct DMAnimation<V: Equatable>: ViewModifier {
    var animation: Animation
    var value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: Notice

/// A compact inline notice: icon, one-line title, short secondary text, actions.
/// Actions sit on the title row when the column is wide and move below the text when it is narrow.
///
/// Do not put `.fixedSize(vertical: true)` on the message text. SwiftUI asks a container for its minimum size
/// with a near-zero width; fixed-size text then wraps to one word per line, the chat column reports a minimum
/// height taller than the window, and the notice and composer end up clipped off screen.
struct DMNotice<Actions: View>: View {
    private let symbol: String
    private let tint: Color
    private let title: String
    private let message: String?
    private let highlighted: Bool
    private let actionsBelow: Bool
    private let onDismiss: (() -> Void)?
    private let actions: Actions

    @State private var width: CGFloat = .infinity

    /// - Parameter actionsBelow: Keep the actions under the text at every width (for notices with several actions).
    init(
        symbol: String,
        tint: Color,
        title: String,
        message: String? = nil,
        highlighted: Bool = false,
        actionsBelow: Bool = false,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.message = message
        self.highlighted = highlighted
        self.actionsBelow = actionsBelow
        self.onDismiss = onDismiss
        self.actions = actions()
    }

    private var hasActions: Bool { Actions.self != EmptyView.self }
    private var inline: Bool { !actionsBelow && width >= DS.Layout.noticeInlineActionsWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
                Image(systemName: symbol)
                    .font(.dmBody)
                    .foregroundStyle(tint)
                    .frame(width: DS.Layout.iconWidth)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.dmBody.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if inline, hasActions {
                    actionRow
                }
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.dmCaption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss message")
                }
            }
            if let message {
                Text(message)
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, DS.Layout.iconWidth + DS.Spacing.m)
            }
            if !inline, hasActions {
                actionRow
                    .padding(.leading, DS.Layout.iconWidth + DS.Spacing.m)
            }
        }
        .padding(DS.Spacing.m)
        .dmTint(tint, highlighted: highlighted)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
    }

    private var actionRow: some View {
        HStack(spacing: DS.Spacing.s) {
            actions
        }
        .controlSize(.small)
    }
}

extension DMNotice where Actions == EmptyView {
    init(symbol: String, tint: Color, title: String, message: String? = nil, highlighted: Bool = false, onDismiss: (() -> Void)? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, message: message, highlighted: highlighted, onDismiss: onDismiss) { EmptyView() }
    }
}

// MARK: Badge and headers

/// Small status capsule with a count or a state ("12 searchable", "Unavailable").
struct DMBadge: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.dmCaption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs)
            .background(Capsule().fill(tint.opacity(DS.Fill.tint)))
    }
}

/// Icon, 24 pt title and one 14 pt secondary line. The head of every empty state.
struct DMEmptyHeader: View {
    var symbol: String
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            Image(systemName: symbol)
                .font(.dmTitle)
                .foregroundStyle(Color.dmBrandText)
                .padding(.bottom, DS.Spacing.xs)
                .accessibilityHidden(true)
            Text(title)
                .font(.dmTitle)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.dmBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Button styles

/// Round action button used by the composer (Send and Stop).
struct DMRoundButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dmBody.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.dmOnBrandFill : Color.secondary)
            .frame(width: DS.Layout.controlSize, height: DS.Layout.controlSize)
            .background(
                Circle().fill(isEnabled ? Color.dmBrandFill : Color.primary.opacity(DS.Fill.disabled))
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Circle())
    }
}

/// Starter suggestion: an equal-width tile with a hover highlight.
struct DMTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            configuration.label
                .background {
                    shape.fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                }
                .overlay {
                    shape.strokeBorder(
                        hovering || configuration.isPressed ? Color.dmBrandText : Color(nsColor: .separatorColor),
                        lineWidth: contrast == .increased ? DS.Stroke.increasedContrast : DS.Stroke.hairline
                    )
                }
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}
