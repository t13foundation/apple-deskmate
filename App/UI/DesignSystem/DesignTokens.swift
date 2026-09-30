import AppKit
import SwiftUI

/// Tokens from docs/design-system.md. Keep values here; views never hard-code spacing, radii, type sizes,
/// stroke widths or fills. If a view needs a number, it belongs in this file.
enum DS {
    /// 4, 8, 12, 16, 24, 32 pt. Primary panel padding is 20 pt.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Primary panel padding: the one horizontal inset shared by every screen.
        static let panel: CGFloat = 20
    }

    /// 10 pt controls, 16 pt grouped surfaces, 22 pt compact panel.
    enum Radius {
        /// Buttons, tiles, notices and other small controls.
        static let control: CGFloat = 10
        /// Grouped surfaces: composer, message bubble, grouped lists.
        static let surface: CGFloat = 16
        /// Compact assistant panel (used by a later package).
        static let panel: CGFloat = 22
    }

    /// Type scale: title 24 semibold, section 16 semibold, body 14, supporting 12.
    enum FontSize {
        static let title: CGFloat = 24
        static let section: CGFloat = 16
        static let body: CGFloat = 14
        static let caption: CGFloat = 12
    }

    /// Opacity of the wash behind a tinted notice or badge.
    enum Fill {
        static let tint: Double = 0.10
        static let tintBorder: Double = 0.40
        /// Fill of a disabled round button.
        static let disabled: Double = 0.12
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let increasedContrast: CGFloat = 1.5
        static let focus: CGFloat = 2
    }

    /// Dimensions of the window and its columns.
    enum Layout {
        /// One reading column for every screen: notice, empty state, transcript, composer, My files.
        static let readingWidth: CGFloat = 680
        /// Widest a question bubble grows; the answer uses the whole column.
        static let bubbleMaxWidth: CGFloat = 520
        /// Square size of icon-only controls (attach, send, stop) and the height of a one-line field.
        static let controlSize: CGFloat = 32
        /// Width reserved for a leading icon in a row.
        static let iconWidth: CGFloat = 20
        /// Starter tile: icon beside a title and one short line, 12 pt padding. Grows only when the text wraps.
        static let tileMinHeight: CGFloat = 60
        /// Share of an empty state's height kept free below its content, so the content sits slightly above centre.
        static let emptyStateLift: CGFloat = 0.16

        static let sidebarMinWidth: CGFloat = 180
        static let sidebarIdealWidth: CGFloat = 200
        static let sidebarMaxWidth: CGFloat = 260
        /// Below this window width the sidebar starts hidden and the conversation gets the whole window.
        static let sidebarCollapseWidth: CGFloat = 820

        static let viewerMinWidth: CGFloat = 280
        static let viewerIdealWidth: CGFloat = 340
        static let viewerMaxWidth: CGFloat = 520

        static let windowMinWidth: CGFloat = 640
        static let windowMinHeight: CGFloat = 520
        static let windowDefaultWidth: CGFloat = 980
        static let windowDefaultHeight: CGFloat = 720

        /// A notice puts its actions on the title row when its column is at least this wide.
        static let noticeInlineActionsWidth: CGFloat = 640
    }
}

extension Font {
    /// Title: 24 pt semibold.
    static let dmTitle = Font.system(size: DS.FontSize.title, weight: .semibold)
    /// Section: 16 pt semibold.
    static let dmSection = Font.system(size: DS.FontSize.section, weight: .semibold)
    /// Body: 14 pt.
    static let dmBody = Font.system(size: DS.FontSize.body)
    /// Supporting text: 12 pt minimum.
    static let dmCaption = Font.system(size: DS.FontSize.caption)
}

extension Color {
    /// Restrained teal. Contrast is tuned for light, dark and increased-contrast appearances.
    static let dmAccent = Color(nsColor: .dmAccent)
    /// Foreground for content drawn on top of the accent.
    static let dmOnAccent = Color(nsColor: .dmOnAccent)
    /// Semantic warning. Dark enough in light mode to be readable as text, not only as an icon.
    static let dmWarning = Color(nsColor: .dmWarning)
    /// Tint of the person's own question.
    static let dmUserBubble = Color(nsColor: .dmUserBubble)
    /// Faint neutral fill for code and badges.
    static let dmSubtleFill = Color.primary.opacity(0.08)
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

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
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

    static let dmWarning = dynamic(
        light: rgb(178, 84, 0),
        lightHighContrast: rgb(146, 64, 0),
        dark: rgb(255, 159, 10),
        darkHighContrast: rgb(255, 179, 64)
    )

    /// Teal wash behind the person's question. Text on it stays primary label colour.
    static let dmUserBubble = dynamic(
        light: rgb(15, 118, 110, alpha: 0.12),
        lightHighContrast: rgb(11, 95, 89, alpha: 0.16),
        dark: rgb(45, 212, 191, alpha: 0.16),
        darkHighContrast: rgb(94, 234, 212, alpha: 0.22)
    )
}
