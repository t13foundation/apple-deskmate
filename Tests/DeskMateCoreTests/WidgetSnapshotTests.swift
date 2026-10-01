import Testing
import Foundation
import DeskMateShared

/// The widget may learn only generic state and one opaque ID. These keep that true for the stored bytes, and keep the
/// store and the link parser honest about missing containers and untrusted input. Synthetic data only.
@Suite struct WidgetSnapshotTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deskmate-widget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theEncodedSnapshotHasExactlyTheGenericKeysAndNothingElse() throws {
        let id = UUID()
        let snapshot = WidgetSnapshot(readiness: .ready, updatedAt: Date(timeIntervalSince1970: 1_700_000_000), hasConversations: true, lastConversationID: id, latestTask: .answered)
        let data = try WidgetSnapshotStore.encode(snapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["version", "readiness", "updatedAt", "hasConversations", "lastConversationID", "latestTask"])
        #expect(object["readiness"] as? String == "ready")
        #expect(object["latestTask"] as? String == "answered")
        #expect(object["lastConversationID"] as? String == id.uuidString)
        // Every value is a number, a boolean, an ISO date, an enum word or the opaque UUID.
        for (key, value) in object where !(value is NSNumber) {
            let text = try #require(value as? String, "\(key) must be a plain string")
            let allowed = ["ready", "needsAttention", "none", "answered", "stopped", "failed", id.uuidString]
            #expect(allowed.contains(text) || text.hasSuffix("Z"), "\(key) holds an unexpected value")
        }
    }

    @Test func aPointerIsNeverKeptWithoutConversations() {
        let snapshot = WidgetSnapshot(readiness: .needsAttention, updatedAt: Date(), hasConversations: false, lastConversationID: UUID(), latestTask: .none)
        #expect(snapshot.lastConversationID == nil)
    }

    @Test func aSnapshotSurvivesTheStoreAndIsReplacedNotAppended() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        #expect(store.isAvailable)
        #expect(store.read() == nil)

        let first = WidgetSnapshot(readiness: .ready, updatedAt: Date(timeIntervalSince1970: 1_700_000_000), hasConversations: false, lastConversationID: nil, latestTask: .none)
        #expect(store.write(first))
        #expect(store.read() == first)

        let second = WidgetSnapshot(readiness: .needsAttention, updatedAt: Date(timeIntervalSince1970: 1_700_000_100), hasConversations: true, lastConversationID: UUID(), latestTask: .failed)
        #expect(store.write(second))
        #expect(store.read() == second)

        #expect(store.remove())
        #expect(store.read() == nil)
        #expect(store.remove(), "removing what is already gone counts as removed")
    }

    @Test func aMissingContainerDegradesWithoutCrashingOrClaimingSuccess() {
        let store = WidgetSnapshotStore(directory: nil)
        #expect(store.isAvailable == false)
        #expect(store.read() == nil)
        let snapshot = WidgetSnapshot(readiness: .ready, updatedAt: Date(), hasConversations: false, lastConversationID: nil, latestTask: .none)
        #expect(store.write(snapshot) == false)
        #expect(store.remove() == false)
        // A bundle without the group key (an ad-hoc build) has no container either.
        #expect(WidgetSnapshotStore.appGroup(bundle: Bundle(for: BundleToken.self)).isAvailable == false)
    }

    @Test func unreadableOrNewerSnapshotsAreIgnoredNotTrusted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let file = directory.appendingPathComponent(WidgetSnapshotStore.fileName)

        try Data("not json".utf8).write(to: file)
        #expect(store.read() == nil)

        let newer = #"{"version":99,"readiness":"ready","updatedAt":"2026-01-01T00:00:00Z","hasConversations":false,"latestTask":"none"}"#
        try Data(newer.utf8).write(to: file)
        #expect(store.read() == nil)

        let unknownWord = #"{"version":1,"readiness":"great","updatedAt":"2026-01-01T00:00:00Z","hasConversations":false,"latestTask":"none"}"#
        try Data(unknownWord.utf8).write(to: file)
        #expect(store.read() == nil)
    }

    // MARK: Routes

    @Test func everyRoundTripsThroughItsLink() throws {
        let id = UUID()
        for route in [DeskMateRoute.ask, .new, .files, .resume(id)] {
            #expect(DeskMateRoute(url: route.url) == route)
        }
        #expect(DeskMateRoute.ask.url.absoluteString == "deskmate://ask")
        #expect(DeskMateRoute.new.url.absoluteString == "deskmate://new")
        #expect(DeskMateRoute.files.url.absoluteString == "deskmate://files")
        #expect(DeskMateRoute.resume(id).url.absoluteString == "deskmate://resume?id=\(id.uuidString)")
    }

    @Test func untrustedLinksAreRejectedUnlessTheyAreExactlyAKnownRoute() throws {
        let id = UUID().uuidString
        let rejected = [
            "https://ask",
            "deskmate-other://ask",
            "deskmate://",
            "deskmate://unknown",
            "deskmate://ask/extra",
            "deskmate://ask?x=1",
            "deskmate://ask#frag",
            "deskmate://user:pw@ask",
            "deskmate://ask:80",
            "deskmate://new?id=\(id)",
            "deskmate://resume",
            "deskmate://resume?id=",
            "deskmate://resume?id=not-a-uuid",
            "deskmate://resume?id=\(id)&id=\(id)",
            "deskmate://resume?id=\(id)&extra=1",
            "deskmate://resume?other=\(id)",
            "deskmate://resume?id=\(id)%20",
            "deskmate://resume?id=../../etc/passwd",
            "deskmate:ask",
        ]
        for text in rejected {
            let url = try #require(URL(string: text), "\(text) is not even a URL")
            #expect(DeskMateRoute(url: url) == nil, "\(text) must not open anything")
        }
        // The scheme and host are case-insensitive, as URLs are.
        #expect(DeskMateRoute(url: try #require(URL(string: "DeskMate://ASK"))) == .ask)
    }
}

private final class BundleToken {}
