import Testing
import Foundation
@testable import DeskMateCore

/// Deleting one conversation must say what really happened. A file that could not be removed keeps its row and a visible,
/// recoverable notice; only a real removal updates the list, fires the removal hook and may be announced. These use a
/// real read-only folder and synthetic data.
@MainActor
@Suite struct ConversationDeletionTests {
    private func setPermissions(_ mode: Int, of directory: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
    }

    @Test func storageReportsWhetherTheRecordIsReallyGone() throws {
        let store = TempStore()
        defer {
            try? setPermissions(0o700, of: store.storage.directory)
            store.remove()
        }
        let record = sampleRecord()
        let other = sampleRecord(title: "Other")
        try store.storage.save(record)
        try store.storage.save(other)

        try setPermissions(0o500, of: store.storage.directory)
        #expect(store.storage.delete(record.id) == false)
        #expect(store.storage.load(record.id) == .loaded(record), "the record is untouched by the failed removal")

        try setPermissions(0o700, of: store.storage.directory)
        #expect(store.storage.delete(record.id))
        #expect(store.storage.load(record.id) == .missing)
        #expect(store.storage.delete(record.id), "a record that is already gone counts as gone")
        #expect(store.storage.load(other.id) == .loaded(other))
    }

    @Test func aFailedDeletionKeepsTheRowExposesTheNoticeAndRetrySucceedsAndFiresTheHookOnce() async throws {
        let store = TempStore()
        defer {
            try? setPermissions(0o700, of: store.storage.directory)
            store.remove()
        }
        // A user file outside the conversation folder must never be touched.
        let source = store.root.appendingPathComponent("attached.txt")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data("Source text".utf8).write(to: source)

        let history = ConversationHistory(storage: store.storage)
        var removals: [HistoryRemoval] = []
        history.onRemoval { removals.append($0) }
        await history.load()
        let target = sampleRecord(title: "Keep until deleted", updated: 2_000)
        let neighbour = sampleRecord(title: "Neighbour", updated: 1_000)
        history.save(target)
        history.save(neighbour)
        await history.waitForWrites()

        // Removal fails in a read-only folder.
        try setPermissions(0o500, of: store.storage.directory)
        let firstTry = await history.delete(target.id)

        #expect(firstTry == false)
        #expect(store.storage.load(target.id) == .loaded(target), "the record still exists")
        #expect(store.storage.list().summaries.contains { $0.id == target.id }, "and is still listed on disk")
        #expect(history.summaries.map(\.id) == [target.id, neighbour.id], "the row stays")
        #expect(removals.isEmpty, "the removal hook does not fire for a conversation that is still here")
        let problem = try #require(history.deletionProblem)
        #expect(problem.conversationID == target.id)
        #expect(problem.message == "DeskMate couldn’t delete this conversation from your Mac.")
        #expect(!problem.message.contains("/") && !problem.message.contains(store.root.lastPathComponent), "no path")
        #expect(!problem.message.contains("Keep until deleted") && !problem.message.contains("budget"), "no content")

        // Retrying while it is still read-only fails again and nothing changes.
        #expect(await history.retryDeletion() == false)
        #expect(history.summaries.count == 2)
        #expect(removals.isEmpty)
        #expect(history.deletionProblem == problem)

        // Permissions are back: Try again deletes it, the row goes, the hook fires exactly once.
        try setPermissions(0o700, of: store.storage.directory)
        #expect(await history.retryDeletion())
        #expect(history.summaries.map(\.id) == [neighbour.id])
        #expect(history.deletionProblem == nil)
        #expect(removals == [.conversation(target.id)])
        #expect(store.storage.load(target.id) == .missing)
        #expect(store.storage.load(neighbour.id) == .loaded(neighbour), "other conversations are untouched")
        #expect(try String(contentsOf: source, encoding: .utf8) == "Source text", "the person's own files are untouched")
        #expect(await history.retryDeletion() == false, "nothing is left to retry")
        #expect(removals == [.conversation(target.id)])
    }

    @Test func aConversationWhoseDeletionFailedCanStillBeSavedAndDismissingTheNoticeKeepsTheRow() async throws {
        let store = TempStore()
        defer {
            try? setPermissions(0o700, of: store.storage.directory)
            store.remove()
        }
        let history = ConversationHistory(storage: store.storage)
        let record = sampleRecord(title: "Still here")
        history.save(record)
        await history.waitForWrites()

        try setPermissions(0o500, of: store.storage.directory)
        #expect(await history.delete(record.id) == false)
        history.dismissDeletionProblem()
        #expect(history.deletionProblem == nil)
        #expect(history.summaries.map(\.id) == [record.id])
        #expect(!history.wasDeleted(record.id), "it was not deleted, so later saves are not dropped")

        try setPermissions(0o700, of: store.storage.directory)
        var changed = record
        changed.title = "Still here, renamed"
        changed.updatedAt = record.updatedAt.addingTimeInterval(30)
        history.save(changed)
        await history.waitForWrites()
        #expect(store.storage.load(record.id) == .loaded(changed))
    }

    @Test func deletingTheConversationOnScreenFailsTruthfullyAndSucceedsOnTryAgain() async throws {
        let store = TempStore()
        defer {
            try? setPermissions(0o700, of: store.storage.directory)
            store.remove()
        }
        let history = ConversationHistory(storage: store.storage)
        let engine = ScriptedEngine()
        let controller = ConversationController(engine: engine, history: history)
        var removals: [HistoryRemoval] = []
        history.onRemoval { removals.append($0) }
        engine.behaviors = [.chunks(["A plan for money."])]
        controller.draft = "What is a budget?"
        controller.send()
        await controller.waitUntilIdle()
        await history.waitForWrites()
        let id = controller.conversationID

        try setPermissions(0o500, of: store.storage.directory)
        controller.draft = "half-typed"
        #expect(await controller.deleteConversation(id) == false)
        await history.waitForWrites()

        #expect(controller.conversationID == id, "the conversation is still on screen")
        #expect(controller.messages.map(\.text) == ["What is a budget?", "A plan for money."])
        #expect(history.summaries.map(\.id) == [id])
        #expect(history.deletionProblem?.conversationID == id)
        #expect(removals.isEmpty)

        try setPermissions(0o700, of: store.storage.directory)
        #expect(await controller.retryDeletion())
        await history.waitForWrites()
        #expect(controller.messages.isEmpty)
        #expect(controller.conversationID != id)
        #expect(controller.draft == "half-typed")
        #expect(history.summaries.isEmpty)
        #expect(history.deletionProblem == nil)
        #expect(removals == [.conversation(id)])
        #expect(store.storage.load(id) == .missing)
    }
}
