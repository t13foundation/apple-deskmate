import Foundation

/// The words a widget shows for a snapshot, kept here so they are in one place and can be tested. Everything is
/// generic: no title, no prompt, no file name, no excerpt. "Ready" is the model state DeskMate last saw, with the time
/// of that snapshot; it is not a live promise and there is no progress.
public struct WidgetSummary: Equatable, Sendable {
    /// "Ready", "Needs attention", or "Open DeskMate" when there is no snapshot to report.
    public let headline: String
    /// "as of 9:41 AM", or nil when there is no snapshot.
    public let asOf: String?
    /// Generic outcome of the latest task, or nil when there is none to report.
    public let latestTask: String?
    public let isReady: Bool
    public let needsAttention: Bool
    /// The link for Resume, only when the snapshot carries an opaque conversation ID.
    public let resume: DeskMateRoute?

    public init(snapshot: WidgetSnapshot?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        guard let snapshot else {
            headline = "Open DeskMate"
            asOf = nil
            latestTask = nil
            isReady = false
            needsAttention = false
            resume = nil
            return
        }
        isReady = snapshot.readiness == .ready
        needsAttention = snapshot.readiness == .needsAttention
        headline = isReady ? "Ready" : "Needs attention"
        asOf = "as of " + Self.time(snapshot.updatedAt, now: now, calendar: calendar, locale: locale)
        switch snapshot.latestTask {
        case .none: latestTask = nil
        case .answered: latestTask = "Last question answered"
        case .stopped: latestTask = "Last answer stopped"
        case .failed: latestTask = "Last question didn’t finish"
        }
        resume = snapshot.lastConversationID.map(DeskMateRoute.resume)
    }

    /// One sentence for VoiceOver.
    public var spokenStatus: String {
        guard let asOf else { return "Open DeskMate to see its status" }
        return [headline, asOf, latestTask].compactMap { $0 }.joined(separator: ", ")
    }

    private static func time(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let sameDay = calendar.isDate(date, inSameDayAs: now)
        let style = Date.FormatStyle(
            date: sameDay ? .omitted : .abbreviated,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        return date.formatted(style)
    }
}
