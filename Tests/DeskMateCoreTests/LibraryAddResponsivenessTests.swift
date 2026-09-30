import Foundation
import Testing
@testable import DeskMateCore

/// Adding sources must not hold the main actor while files are read, and must publish its result in one step.
@MainActor
@Suite("Adding files keeps the main actor free")
struct LibraryAddResponsivenessTests {
    @Test func addingSourcesReleasesTheMainActorWhileIndexingAndPublishesOnce() async throws {
        let folder = try ScratchFolder()
        try SyntheticLibrary.populate(folder)
        for number in 0..<60 {
            try folder.write("more/note-\(number).txt", "Synthetic note \(number). " + String(repeating: "Planning detail for the Lumen project. ", count: 200))
        }
        try folder.write("reports/long.pdf", data: TestPDF.pages(30))

        let store = makeStore()
        var observedFileCounts: [Int] = []
        var sawWorkingWhileMainActorWasFree = false

        let add = Task { @MainActor in await store.addSources(urls: [folder.url]) }
        // Every pass through this loop means the main actor was not blocked by the add. If indexing or PDF
        // parsing ran on the main actor, the add would finish before the first pass and nothing would be seen.
        for _ in 0..<1_000_000 {
            await Task.yield()
            if store.isWorking { sawWorkingWhileMainActorWasFree = true }
            observedFileCounts.append(store.files.count)
            if !store.isWorking, !store.sources.isEmpty, store.lastReport != nil { break }
        }
        let outcome = await add.value

        #expect(sawWorkingWhileMainActorWasFree)
        #expect(outcome.added == [folder.url.lastPathComponent])
        #expect(!store.isWorking)
        // Results arrive in one step: files are either not there yet or all there, never a partial list.
        let finalCount = store.files.count
        #expect(finalCount > 60)
        #expect(Set(observedFileCounts).isSubset(of: [0, finalCount]))
        #expect(store.searchableFiles.contains { $0.relativePath == "reports/long.pdf" })
    }
}
