import Testing
import Foundation
@testable import DeskMateCore

/// A failed history write must never be silent: the old file stays, the edit stays in memory, a notice is exposed, and the
/// next attempt (Try again or any later save) recovers and clears it. These use a real read-only folder.
@MainActor
@Suite struct ConversationSaveFailureTests {
    private func setPermissions(_ mode: Int, of directory: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
    }

    private func fileBytes(_ store: TempStore, _ id: UUID) throws -> Data {
        try Data(contentsOf: store.storage.recordURL(id))
    }

    private func edited(_ record: ConversationRecord, markdown: String) -> ConversationRecord {
        var copy = record
        copy.updatedAt = record.updatedAt.addingTimeInterval(60)
        copy.results = [StoredResult(kind: .brief, markdown: markdown, createdAt: record.updatedAt, updatedAt: copy.updatedAt)]
        return copy
    }

    @Test func aFailedWriteKeepsTheOldFileExposesTheProblemAndRetryRecoversAndClearsIt() async throws {
        let store = TempStore()
        defer {
            try? setPermissions(0o700, of: store.storage.directory)
            store.remove()
        }
        let history = ConversationHistory(storage: store.storage)
        await history.load()
        let original = sampleRecord(title: "Original", updated: 1_000)
        history.save(original)
        await history.waitForWrites()
        #expect(history.saveProblem == nil)
        let before = try fileBytes(store, original.id)
        let namesBefore = store.names()

        // The folder becomes read-only: nothing can be created or replaced in it.
        try setPermissions(0o500, of: store.storage.directory)
        let change = edited(original, markdown: "# Brief: edited while the folder was read-only\n")
        history.save(change)
        await history.waitForWrites()

        #expect(try fileBytes(store, original.id) == before, "the previous complete file is untouched")
        #expect(store.names() == namesBefore, "no temporary file is left behind")
        #expect(history.saveProblem?.category == .permission)
        #expect(history.unsavedIDs == [original.id])
        #expect(history.isUnsaved(original.id))
        #expect(history.summaries.first?.updatedAt == change.updatedAt, "the Recent list still reflects the edit in memory")

        let problem = try #require(history.saveProblem)
        let words = problem.title + " " + problem.message
        #expect(words.contains("couldn’t save this conversation on your Mac"))
        #expect(words.contains("Your changes are kept while the app is open."))
        #expect(!words.contains(store.root.lastPathComponent) && !words.contains("/"), "no path in the message")
        #expect(!words.contains("edited while the folder"), "no conversation content in the message")

        // Retrying while still read-only fails again and the notice stays.
        history.retrySave()
        await history.waitForWrites()
        #expect(history.saveProblem?.category == .permission)
        #expect(try fileBytes(store, original.id) == before)

        // Permissions restored: Try again succeeds, the file has the edit, the notice clears.
        try setPermissions(0o700, of: store.storage.directory)
        history.retrySave()
        await history.waitForWrites()
        #expect(history.saveProblem == nil)
        #expect(history.unsavedIDs.isEmpty)
        guard case .loaded(let onDisk) = store.storage.load(original.id) else {
            Issue.record("the retried record should be on disk")
            return
        }
        #expect(onDisk == change, "the retained edit reached the disk, not the old content")
    }

    @Test func theNextSaveRetriesAnEarlierFailureOnItsOwn() async throws {
        let store = TempStore()
        defer {
            try? setPermissions(0o700, of: store.storage.directory)
            store.remove()
        }
        let history = ConversationHistory(storage: store.storage)
        let first = sampleRecord(title: "First", updated: 2_000)
        history.save(first)
        await history.waitForWrites()

        try setPermissions(0o500, of: store.storage.directory)
        let change = edited(first, markdown: "# Brief: kept\n")
        history.save(change)
        await history.waitForWrites()
        #expect(history.isUnsaved(first.id))

        try setPermissions(0o700, of: store.storage.directory)
        let second = sampleRecord(title: "Second", updated: 3_000)
        history.save(second)
        await history.waitForWrites()

        #expect(history.saveProblem == nil, "a later successful save also recovered the earlier one")
        #expect(store.storage.load(first.id) == .loaded(change))
        #expect(store.storage.load(second.id) == .loaded(second))
    }

    @Test func everyConversationThatFailedIsKeptInMemoryUntilItIsWritten() async throws {
        let store = TempStore()
        defer {
            try? setPermissions(0o700, of: store.storage.directory)
            store.remove()
        }
        let history = ConversationHistory(storage: store.storage)
        let record = sampleRecord(title: "Stuck")
        history.save(record)
        await history.waitForWrites()
        try setPermissions(0o500, of: store.storage.directory)
        let other = sampleRecord(title: "Other")
        history.save(edited(record, markdown: "x"))
        history.save(other)
        await history.waitForWrites()
        #expect(history.unsavedIDs == [record.id, other.id])
        #expect(history.saveProblem != nil)

        try setPermissions(0o700, of: store.storage.directory)
        history.retrySave()
        await history.waitForWrites()
        #expect(history.unsavedIDs.isEmpty)
        #expect(history.saveProblem == nil)
        #expect(store.storage.load(other.id) == .loaded(other))
    }

    @Test func deletingAnUnsavedConversationRemovesItsNotice() async throws {
        let store = TempStore()
        defer {
            try? setPermissions(0o700, of: store.storage.directory)
            store.remove()
        }
        let history = ConversationHistory(storage: store.storage)
        let record = sampleRecord()
        history.save(record)
        await history.waitForWrites()
        try setPermissions(0o500, of: store.storage.directory)
        history.save(edited(record, markdown: "x"))
        await history.waitForWrites()
        #expect(history.saveProblem != nil)

        history.delete(record.id)
        #expect(history.saveProblem == nil)
        #expect(history.unsavedIDs.isEmpty)
        // A retry after the permissions come back must not bring the deleted conversation back.
        try setPermissions(0o700, of: store.storage.directory)
        history.retrySave()
        await history.waitForWrites()
        #expect(store.storage.list().summaries.isEmpty)
    }

    @Test func errorCategoriesAreDerivedFromTheErrorAndCarryNoDetail() {
        #expect(SaveProblem.category(of: CocoaError(.fileWriteNoPermission)) == .permission)
        #expect(SaveProblem.category(of: CocoaError(.fileWriteVolumeReadOnly)) == .permission)
        #expect(SaveProblem.category(of: CocoaError(.fileWriteOutOfSpace)) == .diskFull)
        #expect(SaveProblem.category(of: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .permission)
        #expect(SaveProblem.category(of: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .diskFull)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
        ])
        #expect(SaveProblem.category(of: wrapped) == .permission)
        #expect(SaveProblem.category(of: CocoaError(.fileWriteUnknown)) == .other)
        for category in [SaveProblem.Category.permission, .diskFull, .other] {
            let text = SaveProblem(category: category).message
            #expect(text.hasPrefix("Your changes are kept while the app is open."))
            #expect(!text.contains("/"))
        }
    }

    @Test func anEditedResultSurvivesAFailedSaveOnScreenAndIsWrittenByTryAgain() async throws {
        let store = TempStore()
        defer {
            try? setPermissions(0o700, of: store.storage.directory)
            store.remove()
        }
        let history = ConversationHistory(storage: store.storage)
        let engine = ScriptedEngine()
        let controller = ConversationController(engine: engine, history: history)
        engine.behaviors = [.chunks(["A plan for money."])]
        controller.draft = "What is a budget?"
        controller.send()
        await controller.waitUntilIdle()
        let result = StoredResult(kind: .brief, markdown: "# Brief: first\n")
        controller.results = [result]
        controller.updateResult(result.id, markdown: "# Brief: first, edited once\n")
        await history.waitForWrites()
        #expect(controller.saveProblem == nil)
        #expect(!controller.currentConversationUnsaved)
        let id = controller.conversationID
        let before = try fileBytes(store, id)

        try setPermissions(0o500, of: store.storage.directory)
        controller.updateResult(result.id, markdown: "# Brief: edited with no permission to write\n")
        await history.waitForWrites()

        #expect(controller.saveProblem?.category == .permission)
        #expect(controller.currentConversationUnsaved)
        #expect(controller.result(result.id)?.markdown == "# Brief: edited with no permission to write\n", "the edit stays on screen")
        #expect(try fileBytes(store, id) == before)

        try setPermissions(0o700, of: store.storage.directory)
        controller.retrySave()
        await history.waitForWrites()
        #expect(controller.saveProblem == nil)
        #expect(!controller.currentConversationUnsaved)
        guard case .loaded(let onDisk) = store.storage.load(id) else {
            Issue.record("the conversation should be on disk after Try again")
            return
        }
        #expect(onDisk.results.first?.markdown == "# Brief: edited with no permission to write\n")
        #expect(onDisk.messages.map(\.text) == ["What is a budget?", "A plan for money."])
    }
}
