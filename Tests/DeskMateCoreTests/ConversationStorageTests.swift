import Testing
import Foundation
@testable import DeskMateCore

/// A throwaway folder that stands in for Application Support/DeskMate/Conversations. Synthetic data only.
struct TempStore {
    let root: URL
    let storage: ConversationStorage

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deskmate-conv-\(UUID().uuidString)", isDirectory: true)
        storage = ConversationStorage(directory: root.appendingPathComponent("Conversations", isDirectory: true))
    }

    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: storage.directory.path)) ?? []).sorted()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

func sampleRecord(id: UUID = UUID(), title: String = "Budget questions", updated: TimeInterval = 1_700_000_000, texts: [String] = ["What is in the budget?", "The budget has three lines."]) -> ConversationRecord {
    var messages: [StoredMessage] = []
    for (index, text) in texts.enumerated() {
        messages.append(StoredMessage(
            id: UUID(),
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: text,
            createdAt: Date(timeIntervalSince1970: updated + Double(index)),
            status: .complete
        ))
    }
    return ConversationRecord(id: id, title: title, createdAt: Date(timeIntervalSince1970: updated - 60), updatedAt: Date(timeIntervalSince1970: updated), messages: messages)
}

@Suite struct ConversationStorageTests {
    @Test func aRecordSurvivesAWriteAndAReadIncludingSourcesAndResults() throws {
        let store = TempStore()
        defer { store.remove() }
        let citation = SourceCitation(id: "S1", chunkID: "c1", fileID: "f1", fileName: "plan.md", location: "Section: Budget", excerpt: "Three lines: rent, tools, travel.", truncated: false, origin: .library)
        var record = sampleRecord()
        record.messages[1].sources = [citation]
        record.messages[1].comparedMaterial = [citation]
        record.messages[0].attachments = [StoredAttachment(id: UUID(), fileName: "notes.txt", kind: .text)]
        record.results = [StoredResult(kind: .brief, markdown: "# Brief: x\n", createdAt: Date(timeIntervalSince1970: 5), updatedAt: Date(timeIntervalSince1970: 6))]

        try store.storage.save(record)
        guard case .loaded(let loaded) = store.storage.load(record.id) else {
            Issue.record("expected the record to load")
            return
        }
        #expect(loaded == record)
        #expect(loaded.version == ConversationRecord.formatVersion)
        #expect(store.storage.list().summaries.map(\.id) == [record.id])
        #expect(store.storage.list().summaries.first?.messageCount == 2)
    }

    @Test func filesAreOwnerOnly() throws {
        let store = TempStore()
        defer { store.remove() }
        let record = sampleRecord()
        try store.storage.save(record)
        let file = try FileManager.default.attributesOfItem(atPath: store.storage.recordURL(record.id).path)
        let folder = try FileManager.default.attributesOfItem(atPath: store.storage.directory.path)
        #expect((file[.posixPermissions] as? Int) == 0o600)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
    }

    @Test func writesAreAtomicAndLeaveNoTemporaryFiles() throws {
        let store = TempStore()
        defer { store.remove() }
        var record = sampleRecord()
        try store.storage.save(record)
        record.messages.append(StoredMessage(id: UUID(), role: .user, text: "A follow-up", createdAt: Date(), status: .complete))
        try store.storage.save(record)

        #expect(store.names() == ["index.json", "\(record.id.uuidString).json"].sorted())
        let data = try Data(contentsOf: store.storage.recordURL(record.id))
        // Either the whole old file or the whole new file: here, always complete valid JSON with the new message.
        let probe = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((probe?["messages"] as? [Any])?.count == 3)
    }

    @Test func aFailedWriteKeepsThePreviousCompleteFile() throws {
        let store = TempStore()
        defer { store.remove() }
        let record = sampleRecord()
        try store.storage.save(record)
        // Make the folder read-only so the replacement cannot be written.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.storage.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.storage.directory.path) }
        var changed = record
        changed.title = "Changed"
        #expect(throws: (any Error).self) { try store.storage.save(changed) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.storage.directory.path)
        guard case .loaded(let loaded) = store.storage.load(record.id) else {
            Issue.record("the previous file must still load")
            return
        }
        #expect(loaded.title == record.title)
    }

    @Test func aDamagedFileIsMovedAsideAndNeverTouchesValidRecords() throws {
        let store = TempStore()
        defer { store.remove() }
        let good = sampleRecord(title: "Good one")
        try store.storage.save(good)
        let goodBytes = try Data(contentsOf: store.storage.recordURL(good.id))

        let brokenID = UUID()
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: store.storage.recordURL(brokenID))

        let listing = store.storage.list()
        #expect(listing.summaries.map(\.id) == [good.id])
        #expect(listing.setAside.count == 1)
        #expect(listing.setAside.first?.reason == .unreadable)
        let moved = try #require(listing.setAside.first?.movedTo)
        #expect(moved.hasPrefix("\(brokenID.uuidString).json.corrupt-"))
        #expect(try Data(contentsOf: store.storage.directory.appendingPathComponent(moved)) == garbage, "the damaged bytes are kept, not deleted")
        #expect(!FileManager.default.fileExists(atPath: store.storage.recordURL(brokenID).path))
        #expect(try Data(contentsOf: store.storage.recordURL(good.id)) == goodBytes, "a valid record is never rewritten")
        // Listing again reports nothing new and still works.
        #expect(store.storage.list().setAside.isEmpty)
        #expect(store.storage.list().summaries.map(\.id) == [good.id])
    }

    @Test func aNewerVersionIsSetAsideIntactAndNeverOverwritten() throws {
        let store = TempStore()
        defer { store.remove() }
        let id = UUID()
        try FileManager.default.createDirectory(at: store.storage.directory, withIntermediateDirectories: true)
        let future = Data(#"{"version":99,"id":"\#(id.uuidString)","shape":"unknown to this build"}"#.utf8)
        try future.write(to: store.storage.recordURL(id))

        guard case .setAside(let aside) = store.storage.load(id) else {
            Issue.record("expected the file to be set aside")
            return
        }
        #expect(aside.reason == .newerVersion(99))
        #expect(aside.movedTo == "\(id.uuidString).json.future-v99")
        #expect(try Data(contentsOf: store.storage.directory.appendingPathComponent("\(id.uuidString).json.future-v99")) == future)

        // A new conversation with the same id can be saved without touching the set-aside copy.
        try store.storage.save(sampleRecord(id: id))
        #expect(try Data(contentsOf: store.storage.directory.appendingPathComponent("\(id.uuidString).json.future-v99")) == future)
    }

    @Test func aSecondDamagedFileWithTheSameNameDoesNotOverwriteTheFirstAsideCopy() throws {
        let store = TempStore()
        defer { store.remove() }
        let id = UUID()
        try FileManager.default.createDirectory(at: store.storage.directory, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: store.storage.recordURL(id))
        let first = try #require(store.storage.list().setAside.first?.movedTo)
        try Data("second".utf8).write(to: store.storage.recordURL(id))
        let second = try #require(store.storage.list().setAside.first?.movedTo)
        #expect(first != second)
        #expect(try String(contentsOf: store.storage.directory.appendingPathComponent(first), encoding: .utf8) == "first")
        #expect(try String(contentsOf: store.storage.directory.appendingPathComponent(second), encoding: .utf8) == "second")
    }

    @Test func aFileWhoseIdDoesNotMatchItsNameIsNotTrusted() throws {
        let store = TempStore()
        defer { store.remove() }
        let record = sampleRecord()
        try store.storage.save(record)
        let other = UUID()
        try FileManager.default.moveItem(at: store.storage.recordURL(record.id), to: store.storage.recordURL(other))
        guard case .setAside = store.storage.load(other) else {
            Issue.record("a mismatched id must be set aside")
            return
        }
    }

    @Test func aMissingOrDamagedIndexIsRebuiltFromTheFiles() throws {
        let store = TempStore()
        defer { store.remove() }
        let a = sampleRecord(title: "A", updated: 100)
        let b = sampleRecord(title: "B", updated: 200)
        try store.storage.save(a)
        try store.storage.save(b)
        try Data("nonsense".utf8).write(to: store.storage.indexURL)
        #expect(store.storage.list().summaries.map(\.title) == ["B", "A"])
        try FileManager.default.removeItem(at: store.storage.indexURL)
        #expect(store.storage.list().summaries.map(\.title) == ["B", "A"])
    }

    @Test func deleteRemovesOnlyThatConversation() throws {
        let store = TempStore()
        defer { store.remove() }
        let a = sampleRecord(title: "A")
        let b = sampleRecord(title: "B")
        try store.storage.save(a)
        try store.storage.save(b)
        store.storage.delete(a.id)
        #expect(store.storage.list().summaries.map(\.id) == [b.id])
        if case .missing = store.storage.load(a.id) {} else { Issue.record("deleted record should be missing") }
    }

    @Test func deleteAllRemovesOwnFilesOnlyAndNeverTouchesSourceFiles() throws {
        let store = TempStore()
        defer { store.remove() }
        // A "source file" the person once attached, and another file that is not ours in the same folder.
        let source = store.root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("contract.txt")
        try Data("Original text".utf8).write(to: sourceFile)

        try store.storage.save(sampleRecord())
        try store.storage.save(sampleRecord())
        try Data("garbage".utf8).write(to: store.storage.recordURL(UUID()))
        _ = store.storage.list()
        let foreign = store.storage.directory.appendingPathComponent("notes.txt")
        try Data("not ours".utf8).write(to: foreign)

        let failures = store.storage.deleteAll()
        #expect(failures == 0)
        #expect(store.names() == ["notes.txt"], "records, index and set-aside copies are gone; a foreign file stays")
        #expect(try String(contentsOf: sourceFile, encoding: .utf8) == "Original text")
        #expect(store.storage.list().summaries.isEmpty)
    }
}
