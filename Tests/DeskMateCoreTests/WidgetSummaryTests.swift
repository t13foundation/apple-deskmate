import Testing
import Foundation
import DeskMateShared

/// The widget's words: generic, honest about the time of the snapshot, and plain when there is no snapshot.
@Suite struct WidgetSummaryTests {
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let noon = Date(timeIntervalSince1970: 1_767_268_800) // 2026-01-01 12:00 UTC

    @Test func withoutASnapshotItOnlyAsksToOpenTheApp() {
        let summary = WidgetSummary(snapshot: nil, now: noon, calendar: calendar, locale: locale)
        #expect(summary.headline == "Open DeskMate")
        #expect(summary.asOf == nil)
        #expect(summary.latestTask == nil)
        #expect(summary.resume == nil)
        #expect(summary.spokenStatus == "Open DeskMate to see its status")
    }

    @Test func aReadySnapshotShowsTheTimeItWasTakenAndOffersResumeOnlyWithAPointer() {
        let id = UUID()
        let snapshot = WidgetSnapshot(readiness: .ready, updatedAt: noon.addingTimeInterval(-3 * 3600 - 15 * 60), hasConversations: true, lastConversationID: id, latestTask: .answered)
        let summary = WidgetSummary(snapshot: snapshot, now: noon, calendar: calendar, locale: locale)
        #expect(summary.headline == "Ready")
        // The time format may use a narrow no-break space before AM.
        #expect(summary.asOf?.replacingOccurrences(of: "\u{202F}", with: " ") == "as of 8:45 AM")
        #expect(summary.latestTask == "Last question answered")
        #expect(summary.resume == .resume(id))
        #expect(summary.spokenStatus.replacingOccurrences(of: "\u{202F}", with: " ") == "Ready, as of 8:45 AM, Last question answered")

        let none = WidgetSnapshot(readiness: .ready, updatedAt: noon, hasConversations: false, lastConversationID: nil, latestTask: .none)
        let bare = WidgetSummary(snapshot: none, now: noon, calendar: calendar, locale: locale)
        #expect(bare.resume == nil)
        #expect(bare.latestTask == nil)
    }

    @Test func anOlderSnapshotNamesTheDayAndAttentionIsPlain() {
        let old = WidgetSnapshot(readiness: .needsAttention, updatedAt: noon.addingTimeInterval(-3 * 86_400), hasConversations: false, lastConversationID: nil, latestTask: .failed)
        let summary = WidgetSummary(snapshot: old, now: noon, calendar: calendar, locale: locale)
        #expect(summary.headline == "Needs attention")
        #expect(summary.needsAttention)
        #expect(summary.asOf?.contains("Dec 29") == true)
        #expect(summary.latestTask == "Last question didn’t finish")
    }

    @Test func everyStateUsesOnlyFixedGenericWords() {
        let fixed: Set<String> = ["Ready", "Needs attention", "Open DeskMate", "Last question answered", "Last answer stopped", "Last question didn’t finish"]
        for readiness in [WidgetSnapshot.Readiness.ready, .needsAttention] {
            for task in [WidgetSnapshot.LatestTask.none, .answered, .stopped, .failed] {
                let snapshot = WidgetSnapshot(readiness: readiness, updatedAt: noon, hasConversations: true, lastConversationID: UUID(), latestTask: task)
                let summary = WidgetSummary(snapshot: snapshot, now: noon, calendar: calendar, locale: locale)
                #expect(fixed.contains(summary.headline))
                if let text = summary.latestTask { #expect(fixed.contains(text)) }
            }
        }
    }
}
