import Foundation
import Testing
@testable import DeskMateCore

@MainActor
@Suite("My files")
struct LibraryStoreTests {
    @Test func addingAFolderIndexesMixedFilesAndListsWhatWasSkipped() async throws {
        let folder = try ScratchFolder()
        try SyntheticLibrary.populate(folder)
        try folder.write("old.txt", data: Data([0x63, 0x61, 0x66, 0xE9]))
        try folder.write("scan.pdf", data: TestPDF.imageOnly())
        try folder.write("image.png", data: Data([1, 2, 3]))

        let store = makeStore()
        let outcome = await store.addSources(urls: [folder.url])

        #expect(outcome.added == [folder.url.lastPathComponent])
        #expect(Set(store.searchableFiles.map(\.relativePath)) == ["notes/budget.md", "notes/meeting.txt", "reports/security.pdf"])
        let reasons = Dictionary(uniqueKeysWithValues: store.skippedFiles.map { ($0.relativePath, $0.skip) })
        #expect(reasons["old.txt"] == .notUTF8)
        #expect(reasons["scan.pdf"] == .needsOCR)
        #expect(reasons["image.png"] == .unsupportedType(pathExtension: "png"))

        let hits = store.search(query: "Who is the finance approver?", limit: 3)
        #expect(hits.first?.fileName == "budget.md")
        #expect(hits.first?.text.contains("Ana Costa") == true)
        let pdfHit = store.search(query: "How long is sensor data stored?", limit: 3).first
        #expect(pdfHit?.fileName == "security.pdf")
        #expect(pdfHit?.page == 1)
    }

    @Test func libraryIsCappedAtTwoHundredFilesAndTheRestIsListedAsSkipped() async throws {
        let folder = try ScratchFolder()
        for number in 0..<(LibraryLimits.maxFiles + 7) {
            try folder.write(String(format: "note-%03d.txt", number), "Synthetic note number \(number) about planning.")
        }
        let store = makeStore()
        await store.addSources(urls: [folder.url])

        #expect(store.searchableFiles.count == LibraryLimits.maxFiles)
        let overflow = store.skippedFiles.filter { $0.skip == .libraryFull }
        #expect(overflow.count == 7)
        // Skipped files were not read, so none of their text is searchable.
        #expect(store.search(query: "number \(LibraryLimits.maxFiles + 6)", limit: 5).allSatisfy { !$0.fileName.contains("\(LibraryLimits.maxFiles + 6)") })
    }

    @Test func refreshFindsAddedChangedAndDeletedFiles() async throws {
        let folder = try ScratchFolder()
        try SyntheticLibrary.populate(folder)
        let store = makeStore()
        await store.addSources(urls: [folder.url])
        #expect(store.search(query: "Lisbon office capacity", limit: 3).isEmpty)

        try folder.write("notes/new.txt", "The Lisbon office has capacity for 38 desks.")
        try folder.write("notes/budget.md", "# Budget\nThe approved budget is EUR 52,500 after the revision.\n")
        try FileManager.default.removeItem(at: folder.path("notes/meeting.txt"))

        // Before refresh a changed or deleted file is already not served from stale text.
        #expect(store.search(query: "Priya Raman leads", limit: 3).isEmpty)
        #expect(store.needsRefresh)

        let report = await store.refresh()
        #expect(report.added == 1)
        #expect(report.updated == 1)
        #expect(report.removed == 1)
        #expect(store.search(query: "Lisbon office capacity", limit: 3).first?.text.contains("38 desks") == true)
        #expect(store.search(query: "approved budget", limit: 3).first?.text.contains("52,500") == true)
        #expect(store.search(query: "Priya Raman leads", limit: 3).isEmpty)
        #expect(!store.needsRefresh)
    }

    @Test func removingASourceMakesItUnreadableAndLeavesTheFilesOnDisk() async throws {
        let folder = try ScratchFolder()
        try SyntheticLibrary.populate(folder)
        let store = makeStore()
        await store.addSources(urls: [folder.url])
        let epoch = store.removalEpoch
        let sourceID = try #require(store.sources.first?.id)

        store.remove(sourceID: sourceID)

        #expect(store.sources.isEmpty)
        #expect(store.search(query: "finance approver", limit: 5).isEmpty)
        #expect(store.removalEpoch > epoch)
        #expect(FileManager.default.fileExists(atPath: folder.path("notes/budget.md").path))
    }

    @Test func aFolderThatWasMovedIsTreatedAsRevokedAndNothingIsRetrievable() async throws {
        let parent = try ScratchFolder()
        let folder = parent.path("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "The approved budget is EUR 48,000.".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let store = makeStore()
        await store.addSources(urls: [folder])
        #expect(!store.search(query: "approved budget", limit: 3).isEmpty)
        let epoch = store.removalEpoch

        try FileManager.default.moveItem(at: folder, to: parent.path("renamed"))

        #expect(store.search(query: "approved budget", limit: 3).isEmpty)
        let source = try #require(store.sources.first)
        #expect(!store.state(of: source).isAvailable)
        #expect(store.removalEpoch > epoch)
        #expect(store.revealURL(forFileID: source.id.uuidString + "/b.txt") == nil)
        #expect(!store.hasSearchableContent)
    }

    @Test func nestedAndDuplicateSourcesAreNotIndexedTwice() async throws {
        let folder = try ScratchFolder()
        try SyntheticLibrary.populate(folder)
        let store = makeStore()
        await store.addSources(urls: [folder.path("notes")])
        let inner = store.searchableFiles.count

        let inside = await store.addSources(urls: [folder.path("notes")])
        #expect(inside.added.isEmpty)

        // The parent folder replaces the inner source; each file is indexed once.
        await store.addSources(urls: [folder.url])
        #expect(store.sources.count == 1)
        #expect(store.searchableFiles.count == inner + 1)
    }

    @Test func symbolicLinksAreListedButNeverFollowed() async throws {
        let outside = try ScratchFolder()
        try outside.write("secret.txt", "The secret launch code is 0000.")
        let folder = try ScratchFolder()
        try folder.write("ok.txt", "Ordinary note about planning.")
        try FileManager.default.createSymbolicLink(at: folder.path("link.txt"), withDestinationURL: outside.path("secret.txt"))
        try FileManager.default.createSymbolicLink(at: folder.path("linked-folder"), withDestinationURL: outside.url)

        let store = makeStore()
        await store.addSources(urls: [folder.url])

        #expect(store.search(query: "secret launch code", limit: 5).isEmpty)
        #expect(store.skippedFiles.contains { $0.fileName == "link.txt" && $0.skip == .symbolicLink })
        #expect(store.searchableFiles.map(\.relativePath) == ["ok.txt"])
    }
}

@MainActor
@Suite("Saved library")
struct LibraryPersistenceTests {
    @Test func theIndexSurvivesARestartAndRefreshStillWorks() async throws {
        let folder = try ScratchFolder()
        try SyntheticLibrary.populate(folder)
        let storage = try ScratchFolder()
        let persistence = LibraryPersistence(directory: storage.path("Library"))

        let first = makeStore(persistence: persistence)
        await first.addSources(urls: [folder.url])
        await first.waitForSaves()

        let second = makeStore(persistence: persistence)
        await second.load()
        #expect(second.sources.count == 1)
        #expect(!second.search(query: "finance approver", limit: 3).isEmpty)
        #expect(second.files.count == first.files.count)
    }

    @Test func corruptSavedDataIsQuarantinedRebuiltAndNeverDeletesUserFiles() async throws {
        let folder = try ScratchFolder()
        try SyntheticLibrary.populate(folder)
        let storage = try ScratchFolder()
        let persistence = LibraryPersistence(directory: storage.path("Library"))

        let first = makeStore(persistence: persistence)
        await first.addSources(urls: [folder.url])
        await first.waitForSaves()

        try Data("{ this is not json".utf8).write(to: persistence.directory.appendingPathComponent("index.json"))

        let second = makeStore(persistence: persistence)
        await second.load()

        #expect(!second.notices.isEmpty)
        #expect(!second.search(query: "finance approver", limit: 3).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: persistence.directory.path)
        #expect(names.contains { $0.contains(".corrupt-") })
        #expect(FileManager.default.fileExists(atPath: folder.path("notes/budget.md").path))
    }

    @Test func aFutureFormatVersionIsNotReadAsCurrentData() async throws {
        let folder = try ScratchFolder()
        try SyntheticLibrary.populate(folder)
        let storage = try ScratchFolder()
        let persistence = LibraryPersistence(directory: storage.path("Library"))
        let first = makeStore(persistence: persistence)
        await first.addSources(urls: [folder.url])
        await first.waitForSaves()

        let indexURL = persistence.directory.appendingPathComponent("index.json")
        var text = try String(contentsOf: indexURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"version\":1", with: "\"version\":99").replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        try text.write(to: indexURL, atomically: true, encoding: .utf8)

        let loaded = persistence.load()
        #expect(loaded.files == nil)
        #expect(!loaded.notices.isEmpty)
    }

    @Test func clearingTheLibraryRemovesSavedDataButNotTheFiles() async throws {
        let folder = try ScratchFolder()
        try SyntheticLibrary.populate(folder)
        let storage = try ScratchFolder()
        let persistence = LibraryPersistence(directory: storage.path("Library"))
        let store = makeStore(persistence: persistence)
        await store.addSources(urls: [folder.url])
        await store.waitForSaves()

        store.clear()

        #expect(store.isEmpty)
        #expect(store.search(query: "finance approver", limit: 3).isEmpty)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: persistence.directory.path)) ?? []
        #expect(remaining.filter { $0.hasSuffix(".json") }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path("notes/budget.md").path))
    }
}
