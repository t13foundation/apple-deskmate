import Foundation
import Observation

/// What a refresh (or adding a source) found.
public struct RefreshReport: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    public var unchanged = 0
    public var skipped = 0
    public var unavailableSources = 0
    /// Names of sources whose folder walk stopped at the entry cap.
    public var incompleteSources: [String] = []

    public init() {}

    public var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if updated > 0 { parts.append("\(updated) updated") }
        if removed > 0 { parts.append("\(removed) removed") }
        if parts.isEmpty { parts.append("no changes") }
        var text = parts.joined(separator: ", ")
        if skipped > 0 { text += ", \(skipped) skipped" }
        if unavailableSources > 0 { text += ", \(unavailableSources) source\(unavailableSources == 1 ? "" : "s") unavailable" }
        return text
    }
}

public struct AddOutcome: Equatable, Sendable {
    public var added: [String] = []
    public var notices: [String] = []
    public init() {}
}

/// The library: chosen sources, what was found in them, and the local search index.
/// It reads only inside the sources the person chose, only when asked (add, Refresh) or when a source is searched,
/// and never transmits anything.
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var sources: [LibrarySource] = []
    public private(set) var states: [UUID: SourceState] = [:]
    public private(set) var files: [IndexedFile] = []
    public private(set) var isWorking = false
    public private(set) var lastRefresh: Date?
    public private(set) var lastReport: RefreshReport?
    /// Plain-language messages the person should see (recovered data, skipped additions).
    public private(set) var notices: [String] = []
    /// Set when a search noticed that a file changed or disappeared since the last refresh.
    public private(set) var needsRefresh = false
    /// Increments whenever previously searchable content is removed or revoked, so chats can drop stale excerpts.
    public private(set) var removalEpoch = 0

    @ObservationIgnored private var chunks: [SourceChunk] = []
    @ObservationIgnored private var searchIndex = SearchIndex.empty
    @ObservationIgnored private var indexGeneration = 0
    @ObservationIgnored private let persistence: LibraryPersistence?
    @ObservationIgnored private let scopedBookmarks: Bool
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// - Parameters:
    ///   - persistence: where to save the library; nil keeps everything in memory (command-line and tests).
    ///   - scopedBookmarks: whether added sources get security-scoped bookmarks (true in the app).
    public init(persistence: LibraryPersistence? = LibraryPersistence.standard(), scopedBookmarks: Bool = true) {
        self.persistence = persistence
        self.scopedBookmarks = scopedBookmarks
    }

    // MARK: Derived state

    public var isEmpty: Bool { sources.isEmpty }

    /// Files whose text is searchable right now (their source is available).
    public var searchableFiles: [IndexedFile] {
        files.filter { $0.isIndexed && states[$0.sourceID]?.isAvailable == true }
    }

    public var skippedFiles: [IndexedFile] { files.filter { !$0.isIndexed } }

    public func files(in sourceID: UUID) -> [IndexedFile] { files.filter { $0.sourceID == sourceID } }

    public func state(of source: LibrarySource) -> SourceState { states[source.id] ?? .available }

    /// True when at least one searchable excerpt exists. The search tool is registered only then.
    public var hasSearchableContent: Bool { !searchableFiles.isEmpty }

    public func file(withID id: String) -> IndexedFile? { files.first { $0.id == id } }

    // MARK: Loading

    /// Restores saved sources and index, resolves every bookmark, and rebuilds the index when it is missing.
    public func load() async {
        guard let persistence else { return }
        let loaded = await Task.detached(priority: .userInitiated) { persistence.load() }.value
        sources = loaded.sources
        notices = loaded.notices
        files = loaded.files ?? []
        chunks = loaded.chunks
        resolveAllSources()
        await rebuildIndex()
        if loaded.files == nil, !sources.isEmpty {
            await refresh()
        }
    }

    public func dismissNotices() { notices = [] }

    // MARK: Adding

    /// Adds folders and files chosen in the system open panel, then indexes them.
    @discardableResult
    public func addSources(urls: [URL]) async -> AddOutcome {
        var outcome = AddOutcome()
        for url in urls {
            let candidate: LibrarySource
            do {
                candidate = try SourceAccess.makeSource(for: url, scoped: scopedBookmarks)
            } catch {
                outcome.notices.append("“\(url.lastPathComponent)” could not be added. Check that it still exists and that you can open it.")
                continue
            }
            if sources.contains(where: { $0.path == candidate.path }) {
                outcome.notices.append("“\(candidate.displayName)” is already in My files.")
                continue
            }
            if let parent = sources.first(where: { $0.kind == .folder && candidate.path.hasPrefix($0.path + "/") && states[$0.id]?.isAvailable != false }) {
                outcome.notices.append("“\(candidate.displayName)” is already inside “\(parent.displayName)”, which is in My files.")
                continue
            }
            // A new folder that contains existing sources replaces them, so nothing is indexed twice.
            let covered = sources.filter { $0.path.hasPrefix(candidate.path + "/") }
            for child in covered {
                dropSource(child.id)
                outcome.notices.append("“\(child.displayName)” is now covered by “\(candidate.displayName)”.")
            }
            sources.append(candidate)
            states[candidate.id] = .available
            outcome.added.append(candidate.displayName)
        }
        if !outcome.added.isEmpty {
            saveSources()
            await refresh()
        }
        if !outcome.notices.isEmpty {
            notices.append(contentsOf: outcome.notices)
        }
        return outcome
    }

    // MARK: Refresh

    /// Finds added, changed and removed files in every source and re-checks access. Runs only when asked.
    @discardableResult
    public func refresh() async -> RefreshReport {
        guard !isWorking else { return lastReport ?? RefreshReport() }
        isWorking = true
        defer { isWorking = false }

        var report = RefreshReport()
        var inputs: [LibraryIndexer.Input] = []
        for source in sources {
            switch SourceAccess.resolve(source) {
            case .failure(let reason):
                markUnavailable(source.id, reason: reason)
                report.unavailableSources += 1
            case .success(let root):
                states[source.id] = .available
                inputs.append(LibraryIndexer.Input(
                    source: source,
                    root: root,
                    previousFiles: files.filter { $0.sourceID == source.id },
                    previousChunks: chunks.filter { $0.fileID.hasPrefix(source.id.uuidString + "/") }
                ))
            }
        }

        let results = await Task.detached(priority: .userInitiated) { LibraryIndexer.run(inputs) }.value

        for result in results {
            guard sources.contains(where: { $0.id == result.sourceID }) else { continue }
            let removedBefore = files.filter { $0.sourceID == result.sourceID && $0.isIndexed }.count
            files.removeAll { $0.sourceID == result.sourceID }
            chunks.removeAll { $0.fileID.hasPrefix(result.sourceID.uuidString + "/") }
            files.append(contentsOf: result.files)
            chunks.append(contentsOf: result.chunks)
            if let index = sources.firstIndex(where: { $0.id == result.sourceID }) {
                sources[index].omittedIgnoredCount = result.omittedIgnoredCount
                if result.walkStoppedEarly { report.incompleteSources.append(sources[index].displayName) }
            }
            report.added += result.stats.added
            report.updated += result.stats.updated
            report.removed += result.stats.removed
            report.unchanged += result.stats.unchanged
            report.skipped += result.stats.skipped
            if result.stats.removed > 0 || result.files.filter(\.isIndexed).count < removedBefore { removalEpoch += 1 }
        }
        needsRefresh = false
        lastRefresh = Date()
        lastReport = report
        await rebuildIndex()
        saveAll()
        return report
    }

    // MARK: Removing

    /// Removes a source and its indexed text. The person's files are never touched.
    public func remove(sourceID: UUID) {
        dropSource(sourceID)
        removalEpoch += 1
        saveAll()
        Task { await rebuildIndex() }
    }

    /// Removes every source and all indexed text.
    public func clear() {
        sources = []
        states = [:]
        files = []
        chunks = []
        searchIndex = .empty
        indexGeneration += 1
        needsRefresh = false
        lastReport = nil
        lastRefresh = nil
        removalEpoch += 1
        saveTask?.cancel()
        persistence?.deleteAll()
    }

    private func dropSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        states[id] = nil
        files.removeAll { $0.sourceID == id }
        chunks.removeAll { $0.fileID.hasPrefix(id.uuidString + "/") }
    }

    // MARK: Availability

    private func resolveAllSources() {
        for source in sources {
            switch SourceAccess.resolve(source) {
            case .success:
                states[source.id] = .available
            case .failure(let reason):
                markUnavailable(source.id, reason: reason)
            }
        }
    }

    /// Marks a source unavailable and removes its text from search right away.
    private func markUnavailable(_ id: UUID, reason: UnavailableReason) {
        let hadContent = files.contains { $0.sourceID == id }
        states[id] = .unavailable(reason)
        files.removeAll { $0.sourceID == id }
        chunks.removeAll { $0.fileID.hasPrefix(id.uuidString + "/") }
        if hadContent {
            removalEpoch += 1
            saveIndex()
            Task { await rebuildIndex() }
        }
    }

    // MARK: Search

    /// Ranked excerpts for a query. Each hit is verified against the disk first: if the source was revoked or moved,
    /// or the file was deleted or changed since the last refresh, it is not returned.
    public func search(query: String, limit: Int) -> [SourceChunk] {
        let available = Set(searchableFiles.map(\.id))
        guard !available.isEmpty else { return [] }
        let candidates = searchIndex.search(query, limit: limit * 4) { available.contains($0.fileID) }
        var verdicts: [String: Bool] = [:]
        var rootCache: [UUID: URL?] = [:]
        var results: [SourceChunk] = []
        for candidate in candidates {
            let fileID = candidate.chunk.fileID
            if verdicts[fileID] == nil { verdicts[fileID] = verify(fileID: fileID, rootCache: &rootCache) }
            if verdicts[fileID] == true { results.append(candidate.chunk) }
            if results.count >= limit { break }
        }
        return results
    }

    /// All chunks of one file, in order, after verifying that the file is still there and unchanged.
    public func chunks(forFileID fileID: String) -> [SourceChunk]? {
        var cache: [UUID: URL?] = [:]
        guard verify(fileID: fileID, rootCache: &cache) else { return nil }
        return chunks.filter { $0.fileID == fileID }.sorted { $0.ordinal < $1.ordinal }
    }

    private func verify(fileID: String, rootCache: inout [UUID: URL?]) -> Bool {
        guard let file = files.first(where: { $0.id == fileID }), file.isIndexed,
              let source = sources.first(where: { $0.id == file.sourceID }) else { return false }
        let root: URL?
        if let cached = rootCache[source.id] {
            root = cached
        } else {
            switch SourceAccess.resolve(source) {
            case .success(let url):
                root = url
            case .failure(let reason):
                root = nil
                markUnavailable(source.id, reason: reason)
            }
            rootCache[source.id] = root
        }
        guard let root else { return false }
        let matches: Bool = SourceAccess.withAccess(to: root) {
            let url = source.kind == .file ? root : root.appendingPathComponent(file.relativePath)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return values.fileSize == file.byteCount
                && abs((values.contentModificationDate?.timeIntervalSince1970 ?? 0) - file.modified) < 0.001
        }
        if !matches { needsRefresh = true }
        return matches
    }

    /// The file's location, only when its source is still authorized and the file still exists.
    public func revealURL(forFileID fileID: String) -> URL? {
        guard let file = files.first(where: { $0.id == fileID }),
              let source = sources.first(where: { $0.id == file.sourceID }),
              case .success(let root) = SourceAccess.resolve(source) else { return nil }
        let url = source.kind == .file ? root : root.appendingPathComponent(file.relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Index and persistence

    private func rebuildIndex() async {
        indexGeneration += 1
        let generation = indexGeneration
        let snapshot = chunks
        let built = await Task.detached(priority: .userInitiated) { SearchIndex(chunks: snapshot) }.value
        if generation == indexGeneration { searchIndex = built }
    }

    private func saveAll() {
        saveSources()
        saveIndex()
    }

    private func saveSources() {
        guard let persistence else { return }
        let sources = self.sources
        enqueueSave { try? persistence.saveSources(sources) }
    }

    private func saveIndex() {
        guard let persistence else { return }
        let files = self.files
        let chunks = self.chunks
        enqueueSave { try? persistence.saveIndex(files: files, chunks: chunks) }
    }

    /// Saves run one after another in the background so a slow write never overtakes a newer one.
    private func enqueueSave(_ work: @escaping @Sendable () -> Void) {
        let previous = saveTask
        saveTask = Task.detached(priority: .utility) {
            await previous?.value
            work()
        }
    }

    /// Waits for pending saves. Used by tests.
    public func waitForSaves() async {
        await saveTask?.value
    }
}
