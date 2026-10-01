import Foundation
import Observation

/// A global keyboard shortcut: a key plus modifiers. Independent of Carbon so it can be saved, shown and tested;
/// the app layer converts it when it registers the shortcut with the system.
public struct Shortcut: Codable, Equatable, Sendable {
    public struct Modifiers: OptionSet, Codable, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// The hardware key code (kVK_*), independent of keyboard layout.
    public var keyCode: UInt32
    public var modifiers: Modifiers
    /// How the key is named on this keyboard, captured when it was recorded ("Space", "K").
    public var keyName: String

    public init(keyCode: UInt32, modifiers: Modifiers, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    /// Option+Space.
    public static let standard = Shortcut(keyCode: 49, modifiers: [.option], keyName: "Space")

    /// A global shortcut needs Control, Option or Command. Shift alone would swallow ordinary typing everywhere.
    public var isUsable: Bool {
        !modifiers.isDisjoint(with: [.control, .option, .command]) && !keyName.isEmpty
    }

    /// Menu-style text, for example "⌥Space".
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName
    }

    /// The name of a key as it is shown, from its hardware key code and the character it types without modifiers.
    public static func keyName(forKeyCode code: UInt32, characters: String?) -> String {
        if let special = specialKeys[code] { return special }
        let typed = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // A printable character is its own name; anything else (a control character or nothing) is not recordable.
        if typed.count == 1, let scalar = typed.unicodeScalars.first, scalar.value >= 0x21, !(0xF700...0xF8FF).contains(scalar.value) {
            return typed
        }
        return ""
    }

    private static let specialKeys: [UInt32: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "Forward Delete", 76: "Enter",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// Spoken form for VoiceOver, for example "Option Space".
    public var spoken: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        return (words + [keyName]).joined(separator: " ")
    }
}

/// What happened when the app asked the system for a shortcut.
public enum ShortcutRegistration: Equatable, Sendable {
    case off
    case registered
    /// Another app or the system already uses this combination.
    case inUse
    /// The system does not accept this combination.
    case invalid
    case failed

    /// Plain explanation with a next step. Nil when nothing needs saying.
    public func explanation(for shortcut: Shortcut?) -> String? {
        let name = shortcut?.display ?? "This shortcut"
        switch self {
        case .off, .registered:
            return nil
        case .inUse:
            return "\(name) is already used by another app or by macOS, so DeskMate can’t listen for it. Choose a different shortcut, or turn it off and use the menu bar icon instead."
        case .invalid:
            return "macOS doesn’t accept \(name) as a global shortcut. Choose a different one that includes Option, Control or Command."
        case .failed:
            return "DeskMate couldn’t set up \(name). Try a different shortcut. The menu bar icon still opens the assistant."
        }
    }
}

/// The saved choice: Option+Space by default, a recorded one, or off. Kept in UserDefaults on this Mac; no content.
@MainActor
@Observable
public final class ShortcutSettings {
    public static let defaultsKey = "desktopAccess.shortcut"
    public static let disabledKey = "desktopAccess.shortcutDisabled"

    /// The shortcut to listen for, or nil when it is turned off.
    public private(set) var shortcut: Shortcut?
    /// The outcome of the last attempt to register it. Set by the app layer that talks to the system.
    public var registration: ShortcutRegistration = .off

    /// A shortcut the person tried that the system would not give, kept until the next change so it can be explained.
    /// The shortcut that was already in use stays in place.
    public struct Rejection: Equatable, Sendable {
        public let shortcut: Shortcut
        public let reason: ShortcutRegistration
        public init(shortcut: Shortcut, reason: ShortcutRegistration) {
            self.shortcut = shortcut
            self.reason = reason
        }
    }
    public var rejection: Rejection?

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.bool(forKey: Self.disabledKey) {
            shortcut = nil
        } else if let data = defaults.data(forKey: Self.defaultsKey),
                  let saved = try? JSONDecoder().decode(Shortcut.self, from: data),
                  saved.isUsable {
            shortcut = saved
        } else {
            shortcut = .standard
        }
    }

    public var isOn: Bool { shortcut != nil }

    /// Saves a recorded shortcut. Returns false, and changes nothing, when it cannot work as a global shortcut.
    @discardableResult
    public func choose(_ new: Shortcut) -> Bool {
        guard new.isUsable, let data = try? JSONEncoder().encode(new) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        defaults.set(false, forKey: Self.disabledKey)
        shortcut = new
        rejection = nil
        return true
    }

    public func turnOff() {
        defaults.set(true, forKey: Self.disabledKey)
        shortcut = nil
        registration = .off
        rejection = nil
    }

    public func restoreStandard() {
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.set(false, forKey: Self.disabledKey)
        shortcut = .standard
        rejection = nil
    }

    /// Why a shortcut is not working, if it is not: the one just tried, or else the one in use.
    public var problem: String? {
        if let rejection { return rejection.reason.explanation(for: rejection.shortcut) }
        return registration.explanation(for: shortcut)
    }
}
