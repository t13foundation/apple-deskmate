import Foundation

/// Untrusted text from a server (tool names, descriptions, error messages, results) is data, never instructions.
/// This type turns it into bounded plain text that is safe to display and to store:
/// control characters and invisible direction overrides are removed, length is capped, and nothing is interpreted.
enum PlainText {
    /// Characters that can make text display differently from how it reads in memory.
    private static let invisible: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2060}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}",
    ]

    /// Returns bounded display text. Newlines and tabs are kept (tabs become spaces); other controls are dropped.
    static func sanitize(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                scalars.append(scalar)
            } else if scalar == "\t" {
                scalars.append(" ")
            } else if scalar == "\r" {
                continue
            } else if scalar.properties.generalCategory == .control || invisible.contains(scalar) {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// True when `text` has control characters (other than newline and tab) or invisible direction overrides.
    /// Used to refuse tool inputs that would show differently from what is sent.
    static func containsHiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            if scalar == "\n" || scalar == "\t" { return false }
            return scalar.properties.generalCategory == .control || invisible.contains(scalar)
        }
    }

    /// Single-line variant for names and labels.
    static func sanitizeLine(_ text: String, limit: Int) -> String {
        sanitize(text, limit: limit)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
    }
}

enum IdentifierRules {
    /// Field and tool names DeskMate will pass on: 1 to 64 characters of letters, digits, underscore, dot and hyphen.
    static func isSafe(_ name: String) -> Bool {
        let bytes = name.utf8
        guard (1...64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x5F || byte == 0x2E || byte == 0x2D
        }
    }
}

/// Removes secrets from text before it can reach a message, log line or screen.
struct Redactor: Sendable {
    private let secrets: [String]

    init(secrets: [String?]) {
        self.secrets = secrets.compactMap { $0 }.filter { $0.count >= 4 }
    }

    static let none = Redactor(secrets: [])

    func redact(_ text: String) -> String {
        var result = text
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "[token hidden]")
        }
        return result
    }
}
