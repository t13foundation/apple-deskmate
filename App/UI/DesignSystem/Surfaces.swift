import AppKit
import SwiftUI

/// A grouped surface: subtle material normally, a solid fill with Reduce Transparency,
/// and a stronger border with Increase Contrast.
struct DMSurface: ViewModifier {
    var radius: CGFloat = DS.Radius.surface
    /// Optional emphasis colour for the border and a faint fill (e.g. warnings).
    var emphasis: Color?
    var highlighted = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                if let emphasis {
                    shape.fill(emphasis.opacity(0.08))
                }
            }
            .overlay {
                shape.strokeBorder(
                    highlighted ? Color.dmAccent : (emphasis?.opacity(0.55) ?? Color(nsColor: .separatorColor)),
                    lineWidth: highlighted ? 2 : (contrast == .increased ? 1.5 : 1)
                )
            }
    }
}

extension View {
    func dmSurface(radius: CGFloat = DS.Radius.surface, emphasis: Color? = nil, highlighted: Bool = false) -> some View {
        modifier(DMSurface(radius: radius, emphasis: emphasis, highlighted: highlighted))
    }

    /// Animates only when Reduce Motion is off.
    func dmAnimation<V: Equatable>(_ animation: Animation = .easeOut(duration: 0.18), value: V) -> some View {
        modifier(DMAnimation(animation: animation, value: value))
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

/// Round action button used by the composer (Send and Stop).
struct DMRoundButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.dmOnAccent : Color.secondary)
            .frame(width: 32, height: 32)
            .background(
                Circle().fill(isEnabled ? Color.dmAccent : Color.primary.opacity(0.12))
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Circle())
    }
}
