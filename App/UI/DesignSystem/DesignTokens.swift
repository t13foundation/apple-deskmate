import AppKit
import SwiftUI

/// Tokens from docs/design-system.md. Keep values here; views never hard-code spacing, radii or type sizes.
enum DS {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Primary panel padding.
        static let panel: CGFloat = 20
    }

    enum Radius {
        /// Buttons and small controls.
        static let control: CGFloat = 10
        /// Grouped surfaces: composer, cards, banners.
        static let surface: CGFloat = 16
        /// Compact assistant panel (used by a later package).
        static let panel: CGFloat = 22
    }

    enum Layout {
        /// Comfortable line length for conversation content.
        static let readingWidth: CGFloat = 760
    }
}

extension Font {
    /// Title: 24 pt semibold.
    static let dmTitle = Font.system(size: 24, weight: .semibold)
    /// Section: 16 pt semibold.
    static let dmSection = Font.system(size: 16, weight: .semibold)
    /// Body: 14 pt.
    static let dmBody = Font.system(size: 14)
    /// Supporting text: 12 pt minimum.
    static let dmCaption = Font.system(size: 12)
}

extension Color {
    /// Restrained teal. Contrast is tuned for light, dark and increased-contrast appearances.
    static let dmAccent = Color(nsColor: .dmAccent)
    /// Foreground for content drawn on top of the accent.
    static let dmOnAccent = Color(nsColor: .dmOnAccent)
}

extension NSColor {
    private static func dynamic(light: NSColor, lightHighContrast: NSColor, dark: NSColor, darkHighContrast: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return dark
            case .accessibilityHighContrastAqua?: return lightHighContrast
            case .accessibilityHighContrastDarkAqua?: return darkHighContrast
            default: return light
            }
        }
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static let dmAccent = dynamic(
        light: rgb(15, 118, 110),
        lightHighContrast: rgb(11, 95, 89),
        dark: rgb(45, 212, 191),
        darkHighContrast: rgb(94, 234, 212)
    )

    static let dmOnAccent = dynamic(
        light: .white,
        lightHighContrast: .white,
        dark: rgb(4, 40, 37),
        darkHighContrast: rgb(4, 40, 37)
    )
}
