import Testing
import Foundation
import DeskMateShared
@testable import DeskMateCore

/// The publisher turns app state into the generic snapshot, follows deletions, stays quiet while an answer is being
/// written, and never copies content into the file. Uses the scripted test engine and synthetic text only.
@MainActor
@Suite struct WidgetSnapshotPublisherTests {
    @MainActor private final class Rig {
        let conversations = TempStore()
        let widgetDirectory: URL
        let store: WidgetSnapshotStore
        let engine = ScriptedEngine()
        let history: ConversationHistory
        let controller: ConversationController
        let publisher: WidgetSnapshotPublisher

        init(unavailable: Bool = false) {
            widgetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("deskmate-widget-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
            store = WidgetSnapshotStore(directory: unavailable ? nil : widgetDirectory)
            history = ConversationHistory(storage: conversations.storage)
            controller = ConversationController(engine: engine, history: history)
            let box = ReloadCounter()
            publisher = WidgetSnapshotPublisher(controller: controller, history: history, store: store, reload: { box.count += 1 })
            counter = box
        }

        let counter: ReloadCounter
        var reloadCount: Int { counter.count }

        func cleanUp() {
            conversations.remove()
            try? FileManager.default.removeItem(at: widgetDirectory)
        }

        var rawFile: String {
            let data = try? Data(contentsOf: widgetDirectory.appendingPathComponent(WidgetSnapshotStore.fileName))
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    private final class ReloadCounter { var count = 0 }

    @Test func itPublishesReadinessThenTheOutcomeAndPointerWithoutAnyContent() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.engine.behaviors = [.chunks(["The confidential vendor total is large."])]
        await rig.history.load()
        rig.publisher.start()

        let first = rig.store.read()
        #expect(first?.readiness == .ready)
        #expect(first?.hasConversations == false)
        #expect(first?.lastConversationID == nil)
        #expect(first?.latestTask == WidgetSnapshot.LatestTask.none)
        #expect(rig.reloadCount == 1)

        rig.controller.draft = "What is the secret acquisition codename?"
        rig.controller.send()
        await rig.controller.waitUntilIdle()
        await waitUntil { rig.store.read()?.latestTask == .answered }

        let snapshot = rig.store.read()
        #expect(snapshot?.latestTask == .answered)
        #expect(snapshot?.hasConversations == true)
        #expect(snapshot?.lastConversationID == rig.controller.conversationID)
        #expect(rig.reloadCount >= 2)

        let raw = rig.rawFile
        #expect(!raw.isEmpty)
        for secret in ["acquisition", "codename", "confidential", "vendor", "total", "What is"] {
            #expect(!raw.contains(secret), "the snapshot must not hold content: \(secret)")
        }
        #expect(!raw.contains(rig.controller.conversationTitle))
    }

    @Test func itStaysQuietWhileAnAnswerIsBeingWrittenAndRecordsAStoppedTask() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.engine.behaviors = [.manual]
        await rig.history.load()
        rig.publisher.start()
        let before = rig.reloadCount

        rig.controller.draft = "A question"
        rig.controller.send()
        await waitUntil { rig.controller.phase == .generating }
        rig.engine.manual?.yield("partial")
        rig.engine.manual?.yield("partial answer")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(rig.reloadCount == before, "no widget reload while generating")
        #expect(rig.store.read()?.latestTask == WidgetSnapshot.LatestTask.none)

        rig.controller.cancel()
        await rig.controller.waitUntilIdle()
        await waitUntil { rig.store.read()?.latestTask == .stopped }
        #expect(rig.store.read()?.latestTask == .stopped)
    }

    @Test func deletingTheNewestConversationMovesOrClearsThePointerAndReloads() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        let older = sampleRecord(title: "Older", updated: 1_000)
        let newer = sampleRecord(title: "Newer", updated: 2_000)
        rig.history.save(older)
        rig.history.save(newer)
        await rig.history.waitForWrites()
        await rig.history.load()
        rig.publisher.start()
        #expect(rig.store.read()?.lastConversationID == newer.id)
        let reloadsBefore = rig.reloadCount

        await rig.history.delete(newer.id)
        await waitUntil { rig.store.read()?.lastConversationID == older.id }
        #expect(rig.store.read()?.lastConversationID == older.id)
        #expect(rig.reloadCount > reloadsBefore)

        await rig.history.delete(older.id)
        await waitUntil { rig.store.read()?.hasConversations == false }
        #expect(rig.store.read()?.hasConversations == false)
        #expect(rig.store.read()?.lastConversationID == nil)
    }

    @Test func clearHistoryDeletesTheSnapshotAndTheNextOneHasNoPointerOrTask() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.history.save(sampleRecord(updated: 3_000))
        await rig.history.waitForWrites()
        await rig.history.load()
        rig.publisher.start()
        #expect(rig.store.read()?.hasConversations == true)

        rig.history.clearAll()
        // The removal hook deletes the file at once; whatever follows is generic.
        await waitUntil { rig.store.read()?.hasConversations == false }
        let after = rig.store.read()
        #expect(after?.hasConversations == false)
        #expect(after?.lastConversationID == nil)
        #expect(after?.latestTask == WidgetSnapshot.LatestTask.none)
    }

    @Test func itDoesNotPublishBeforeTheHistoryIsLoadedSoAValidPointerIsNotErased() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        let existing = WidgetSnapshot(readiness: .ready, updatedAt: Date(timeIntervalSince1970: 1), hasConversations: true, lastConversationID: UUID(), latestTask: .answered)
        rig.store.write(existing)
        rig.publisher.start()
        #expect(rig.store.read() == existing)
    }

    @Test func withoutAContainerItNeverReloadsOrCrashes() async {
        let rig = Rig(unavailable: true)
        defer { rig.cleanUp() }
        await rig.history.load()
        rig.publisher.start()
        rig.controller.draft = "Hello"
        rig.controller.send()
        await rig.controller.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.reloadCount == 0)
        #expect(rig.store.read() == nil)
    }

    @Test func aModelThatIsNotReadyIsPublishedAsNeedsAttention() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.engine.snapshot = ModelReadinessSnapshot(availability: .unavailable(.appleIntelligenceNotEnabled), supportsEnglish: true, contextSize: 4096, hasExactTokenCounting: true)
        rig.controller.refreshReadiness()
        await rig.history.load()
        rig.publisher.start()
        #expect(rig.store.read()?.readiness == .needsAttention)
    }
}
