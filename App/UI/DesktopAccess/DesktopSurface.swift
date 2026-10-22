import DeskMateCore
import Foundation
import OSLog
import SwiftUI

/// Where a request to open the assistant came from. A plain label for timing; never any content.
enum OpenTrigger: String {
    case shortcut
    case widget
    case menuBar
    case link
}

/// Measures how long it takes from a shortcut press or widget link to the composer being ready for typing, so the
/// roughly-one-second goal can be measured on the target Mac rather than assumed. It records only the trigger, whether
/// the panel already existed, and the elapsed milliseconds. It never records a message, a title or a file name.
///
/// Read it with:
///     log stream --predicate 'subsystem == "com.t13foundation.DeskMate" AND category == "DesktopAccess"' --level info
/// or as the "PanelOpen" interval in Instruments (os_signpost).
@MainActor
enum PanelOpenTiming {
    private static let subsystem = "com.t13foundation.DeskMate"
    private static let signposter = OSSignposter(subsystem: subsystem, category: "DesktopAccess")
    private static let logger = Logger(subsystem: subsystem, category: "DesktopAccess")
    private static var pending: (state: OSSignpostIntervalState, start: ContinuousClock.Instant, trigger: OpenTrigger, warm: Bool)?

    /// Starts the interval at the moment the request arrives. A newer request replaces an unfinished one.
    static func begin(trigger: OpenTrigger, warm: Bool) {
        end(reason: "replaced")
        let state = signposter.beginInterval("PanelOpen", id: signposter.makeSignpostID(), "\(trigger.rawValue, privacy: .public)")
        pending = (state, ContinuousClock.now, trigger, warm)
    }

    /// Ends the interval when the composer has become the first responder.
    static func composerReady() {
        end(reason: "ready")
    }

    /// Gives up on an interval that will never reach the composer (the panel was closed first).
    static func abandon() {
        end(reason: "abandoned")
    }

    private static func end(reason: String) {
        guard let pending else { return }
        self.pending = nil
        signposter.endInterval("PanelOpen", pending.state, "\(reason, privacy: .public)")
        guard reason == "ready" else { return }
        let elapsed = ContinuousClock.now - pending.start
        let milliseconds = Int((Double(elapsed.components.seconds) * 1_000) + (Double(elapsed.components.attoseconds) / 1e15))
        logger.info("Panel ready for typing after \(milliseconds, privacy: .public) ms (trigger: \(pending.trigger.rawValue, privacy: .public), panel already open before: \(pending.warm, privacy: .public))")
    }
}

/// Whether this window is the one that presents sheets that belong to the conversation (a saved result, a tool
/// approval). The main window and the compact panel show the same conversation; only the one on top presents
/// them, so a person is never asked the same thing twice and an approval is never answered twice.
private struct PresentsConversationSheetsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var presentsConversationSheets: Bool {
        get { self[PresentsConversationSheetsKey.self] }
        set { self[PresentsConversationSheetsKey.self] = newValue }
    }
}
