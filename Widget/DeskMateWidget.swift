import DeskMateShared
import SwiftUI
import WidgetKit

/// What one widget refresh shows: the snapshot the app last wrote, or nil when there is none.
struct DeskMateEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Reads the snapshot and nothing else. It starts no work, makes no request, and asks for no refresh on a schedule:
/// the timeline never expires on its own, and the app asks WidgetKit to reload it when something meaningful changes.
struct DeskMateProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeskMateEntry {
        DeskMateEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (DeskMateEntry) -> Void) {
        completion(Self.currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<DeskMateEntry>) -> Void) {
        completion(Timeline(entries: [Self.currentEntry()], policy: .never))
    }

    private static func currentEntry() -> DeskMateEntry {
        DeskMateEntry(date: Date(), snapshot: WidgetSnapshotStore.appGroup().read())
    }
}

struct DeskMateWidget: Widget {
    static let kind = "DeskMateWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: DeskMateProvider()) { entry in
            DeskMateWidgetView(entry: entry)
        }
        .configurationDisplayName("DeskMate")
        .description("Open DeskMate to ask a question, start a chat, or ask about your files.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
