import SwiftUI

/// The T13 brand colours for the widget. The extension cannot link the app's design tokens, so the same Display P3
/// values live here (see App/UI/DesignSystem/DesignTokens.swift and docs/design-system.md). In a tinted or accented
/// widget the system supplies the colour, so these apply to full-colour rendering only.
struct WidgetPalette {
    let scheme: ColorScheme
    let highContrast: Bool

    init(scheme: ColorScheme, contrast: ColorSchemeContrast) {
        self.scheme = scheme
        self.highContrast = contrast == .increased
    }

    /// Primary fills with white on top: at least 5.5:1 in every appearance.
    var brandFill: Color {
        switch (scheme, highContrast) {
        case (.dark, true): Color(.displayP3, red: 0.4721, green: 0.0472, blue: 0.8375)
        case (.dark, false): Color(.displayP3, red: 0.5446, green: 0.1318, blue: 0.9462)
        case (_, true): Color(.displayP3, red: 0.3880, green: 0.1068, blue: 0.6777)
        default: Color(.displayP3, red: 0.4658, green: 0.0648, blue: 0.8239)
        }
    }

    /// Accent text and icons on the widget background: at least 6.6:1 in every appearance.
    var brandText: Color {
        switch (scheme, highContrast) {
        case (.dark, true): Color(.displayP3, red: 0.8331, green: 0.7350, blue: 0.9825)
        case (.dark, false): Color(.displayP3, red: 0.7566, green: 0.5906, blue: 0.9844)
        case (_, true): Color(.displayP3, red: 0.3172, green: 0.0455, blue: 0.5703)
        default: Color(.displayP3, red: 0.3989, green: 0.1250, blue: 0.6906)
        }
    }

    /// Needs-attention text. Dark enough in light mode to be read as text.
    var warning: Color {
        switch (scheme, highContrast) {
        case (.dark, true): Color(red: 255 / 255, green: 179 / 255, blue: 64 / 255)
        case (.dark, false): Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
        case (_, true): Color(red: 146 / 255, green: 64 / 255, blue: 0)
        default: Color(red: 178 / 255, green: 84 / 255, blue: 0)
        }
    }
}

/// Spacing and type from the design system, at the sizes a widget can use.
enum WidgetMetrics {
    static let inset: CGFloat = 4
    static let gap: CGFloat = 8
    static let tightGap: CGFloat = 4
    static let markSize: CGFloat = 28
    static let markRadius: CGFloat = 8
    static let controlRadius: CGFloat = 10
    static let caption = Font.system(size: 12)
    static let captionStrong = Font.system(size: 12, weight: .semibold)
    static let body = Font.system(size: 14, weight: .semibold)
}
