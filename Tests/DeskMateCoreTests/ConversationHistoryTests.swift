import Testing
import Foundation
@testable import DeskMateCore

@MainActor
@Suite struct ConversationHistoryTests {
    @Test func savedConversationsAppearNewestFirstAndReachTheDisk() async throws {
        let store = TempStore()
        defer { store.remove() }
        let history = ConversationHistory(storage: store.storage)
        await history.load()
        history.save(sampleRecord(title: "Older", updated: 100))
        history.save(sampleRecord(title: "Newer", updated: 200))
        #expect(history.summaries.map(\.title) == ["Newer", "Older"])
        await history.waitForWrites()
        #expect(store.storage.list().summaries.map(\.title) == ["Newer", "Older"])
    }

    @Test func deletingTellsTheHookAndALateSaveCannotBringItBack() async throws {
        let store = TempStore()
        defer { store.remove() }
        let history = ConversationHistory(storage: store.storage)
        var removals: [HistoryRemoval] = []
        history.onRemoval { removals.append($0) }
        let record = sampleRecord()
        history.save(record)
        history.delete(record.id)
        history.save(record)
        await history.waitForWrites()
        #expect(removals == [.conversation(record.id)])
        #expect(history.summaries.isEmpty)
        #expect(store.storage.list().summaries.isEmpty)
        #expect(history.wasDeleted(record.id))
    }

    @Test func clearAllRemovesRecordsTellsTheHookAndLeavesSourceFilesAlone() async throws {
        let store = TempStore()
        defer { store.remove() }
        let source = store.root.appendingPathComponent("attached.txt")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data("Source text".utf8).write(to: source)

        let history = ConversationHistory(storage: store.storage)
        var removals: [HistoryRemoval] = []
        history.onRemoval { removals.append($0) }
        history.save(sampleRecord())
        history.save(sampleRecord())
        await history.waitForWrites()
        history.clearAll()
        await history.waitForWrites()

        #expect(removals == [.everything])
        #expect(history.summaries.isEmpty)
        #expect(history.lastClearFailures == 0)
        #expect(store.names().isEmpty)
        #expect(try String(contentsOf: source, encoding: .utf8) == "Source text")
    }

    @Test func aConversationSavedRightAfterClearIsNotSweptUpByIt() async throws {
        let store = TempStore()
        defer { store.remove() }
        let history = ConversationHistory(storage: store.storage)
        history.save(sampleRecord())
        history.clearAll()
        let fresh = sampleRecord(title: "Fresh")
        history.save(fresh)
        await history.waitForWrites()
        #expect(store.storage.list().summaries.map(\.title) == ["Fresh"])
    }

    @Test func aDamagedFileProducesANoticeAndTheOtherConversationsStillOpen() async throws {
        let store = TempStore()
        defer { store.remove() }
        let good = sampleRecord(title: "Good")
        try store.storage.save(good)
        try Data("{ broken".utf8).write(to: store.storage.recordURL(UUID()))

        let history = ConversationHistory(storage: store.storage)
        await history.load()
        #expect(history.summaries.map(\.title) == ["Good"])
        #expect(history.notices.count == 1)
        #expect(history.notices[0].contains("moved it aside"))
        guard case .record(let opened) = await history.open(good.id) else {
            Issue.record("the valid conversation must open")
            return
        }
        #expect(opened == good)
        history.dismissNotices()
        #expect(history.notices.isEmpty)
    }

    @Test func openingAFileThatBecameUnreadableSetsItAsideAndReportsIt() async throws {
        let store = TempStore()
        defer { store.remove() }
        let record = sampleRecord()
        try store.storage.save(record)
        let history = ConversationHistory(storage: store.storage)
        await history.load()
        try Data("overwritten by something else".utf8).write(to: store.storage.recordURL(record.id))
        #expect(await history.open(record.id) == .unavailable)
        #expect(history.summaries.isEmpty)
        #expect(history.notices.count == 1)
        #expect(store.names().contains { $0.contains(".json.corrupt-") })
    }

    @Test func aNewerVersionFileIsNamedInTheNoticeAndKept() async throws {
        let store = TempStore()
        defer { store.remove() }
        let id = UUID()
        try FileManager.default.createDirectory(at: store.storage.directory, withIntermediateDirectories: true)
        try Data(#"{"version":7,"id":"\#(id.uuidString)"}"#.utf8).write(to: store.storage.recordURL(id))
        let history = ConversationHistory(storage: store.storage)
        await history.load()
        #expect(history.notices.first?.contains("newer version") == true)
        #expect(store.names().contains("\(id.uuidString).json.future-v7"))
    }
}
