import Foundation

/// Scans chosen sources and turns supported files into chunks. Pure file work: no UI, no network, no logging
/// of content. It reads only inside the source root it is given and never follows symbolic links.
public enum LibraryIndexer {
    public struct Input: Sendable {
        public var source: LibrarySource
        /// Resolved, currently accessible URL of the source.
        public var root: URL
        public var previousFiles: [IndexedFile]
        public var previousChunks: [SourceChunk]

        public init(source: LibrarySource, root: URL, previousFiles: [IndexedFile] = [], previousChunks: [SourceChunk] = []) {
            self.source = source
            self.root = root
            self.previousFiles = previousFiles
            self.previousChunks = previousChunks
        }
    }

    public struct Stats: Equatable, Sendable {
        public var added = 0
        public var updated = 0
        public var removed = 0
        public var unchanged = 0
        public var skipped = 0

        public init() {}

        mutating func add(_ other: Stats) {
            added += other.added
            updated += other.updated
            removed += other.removed
            unchanged += other.unchanged
            skipped += other.skipped
        }
    }

    public struct Result: Sendable {
        public var sourceID: UUID
        public var files: [IndexedFile]
        public var chunks: [SourceChunk]
        public var omittedIgnoredCount: Int
        public var walkStoppedEarly: Bool
        public var stats: Stats
    }

    /// Indexes the inputs in order, sharing one file budget so the library never exceeds `maxFiles` indexed files.
    public static func run(_ inputs: [Input], maxFiles: Int = LibraryLimits.maxFiles) -> [Result] {
        var slotsUsed = 0
        return inputs.map { scan($0, slotsUsed: &slotsUsed, maxFiles: maxFiles) }
    }

    static func scan(_ input: Input, slotsUsed: inout Int, maxFiles: Int) -> Result {
        let source = input.source
        let previousByID = Dictionary(input.previousFiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousChunksByFile = Dictionary(grouping: input.previousChunks, by: \.fileID)

        let (entries, walkStoppedEarly) = SourceAccess.withAccess(to: input.root) {
            enumerate(source: source, root: input.root)
        }

        var files: [IndexedFile] = []
        var chunks: [SourceChunk] = []
        var stats = Stats()
        var ignoredListed = 0
        var omittedIgnored = 0
        var seen = Set<String>()

        SourceAccess.withAccess(to: input.root) {
            for entry in entries {
                let fileID = IndexedFile.makeID(sourceID: source.id, relativePath: entry.relativePath)
                seen.insert(fileID)
                let previous = previousByID[fileID]

                guard let kind = entry.kind else {
                    // Other file types are listed (up to a cap) so nothing disappears without a reason.
                    if ignoredListed < LibraryLimits.maxIgnoredListedPerSource {
                        ignoredListed += 1
                        files.append(IndexedFile(sourceID: source.id, relativePath: entry.relativePath, fileName: entry.fileName, kind: nil, byteCount: entry.size, modified: entry.modified, skip: .unsupportedType(pathExtension: entry.pathExtension)))
                    } else {
                        omittedIgnored += 1
                    }
                    continue
                }
                if entry.isSymbolicLink {
                    files.append(IndexedFile(sourceID: source.id, relativePath: entry.relativePath, fileName: entry.fileName, kind: kind, byteCount: entry.size, modified: entry.modified, skip: .symbolicLink))
                    stats.skipped += 1
                    continue
                }

                let unchanged = previous.map { isSame($0, entry) && $0.skip != .libraryFull && $0.skip != .unreadable } ?? false
                if unchanged, let previous {
                    if previous.isIndexed {
                        if slotsUsed >= maxFiles {
                            files.append(IndexedFile(sourceID: source.id, relativePath: entry.relativePath, fileName: entry.fileName, kind: kind, byteCount: entry.size, modified: entry.modified, skip: .libraryFull))
                            stats.skipped += 1
                        } else {
                            slotsUsed += 1
                            files.append(previous)
                            chunks.append(contentsOf: previousChunksByFile[fileID] ?? [])
                            stats.unchanged += 1
                        }
                    } else {
                        files.append(previous)
                        stats.unchanged += 1
                        stats.skipped += 1
                    }
                    continue
                }

                // New or changed. Reject before reading when the library is already full.
                if slotsUsed >= maxFiles {
                    files.append(IndexedFile(sourceID: source.id, relativePath: entry.relativePath, fileName: entry.fileName, kind: kind, byteCount: entry.size, modified: entry.modified, skip: .libraryFull))
                    stats.skipped += 1
                    continue
                }

                switch DocumentReader.read(url: entry.url, kind: kind, byteCount: entry.size) {
                case .skipped(let reason):
                    files.append(IndexedFile(sourceID: source.id, relativePath: entry.relativePath, fileName: entry.fileName, kind: kind, byteCount: entry.size, modified: entry.modified, skip: reason))
                    stats.skipped += 1
                case .document(let document):
                    let fileChunks = Chunker.chunks(for: document, fileID: fileID, fileName: entry.fileName, relativePath: entry.relativePath)
                    if fileChunks.isEmpty {
                        files.append(IndexedFile(sourceID: source.id, relativePath: entry.relativePath, fileName: entry.fileName, kind: kind, byteCount: entry.size, modified: entry.modified, skip: .empty))
                        stats.skipped += 1
                    } else {
                        slotsUsed += 1
                        files.append(IndexedFile(sourceID: source.id, relativePath: entry.relativePath, fileName: entry.fileName, kind: kind, byteCount: entry.size, modified: entry.modified, pageCount: document.pageCount, chunkCount: fileChunks.count, note: document.note))
                        chunks.append(contentsOf: fileChunks)
                        if previous == nil { stats.added += 1 } else { stats.updated += 1 }
                    }
                }
            }
        }

        stats.removed = input.previousFiles.filter { !seen.contains($0.id) && $0.kind != nil }.count
        return Result(sourceID: source.id, files: files, chunks: chunks, omittedIgnoredCount: omittedIgnored, walkStoppedEarly: walkStoppedEarly, stats: stats)
    }

    /// The URL with every symbolic link in its path resolved, as the file system reports it.
    private static func realURL(_ url: URL) -> URL {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isSame(_ file: IndexedFile, _ entry: Entry) -> Bool {
        file.byteCount == entry.size && abs(file.modified - entry.modified) < 0.001
    }

    // MARK: Enumeration

    struct Entry {
        var url: URL
        var relativePath: String
        var fileName: String
        var pathExtension: String
        var kind: FileKind?
        var size: Int
        var modified: Double
        var isSymbolicLink: Bool
    }

    /// Lists files inside the source only, sorted by path. Hidden files and packages are skipped.
    static func enumerate(source: LibrarySource, root: URL) -> (entries: [Entry], stoppedEarly: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)

        func entry(for url: URL, relativePath: String) -> Entry? {
            guard let values = try? url.resourceValues(forKeys: keySet) else { return nil }
            let isLink = values.isSymbolicLink ?? false
            guard isLink || values.isRegularFile == true else { return nil }
            return Entry(
                url: url,
                relativePath: relativePath,
                fileName: url.lastPathComponent,
                pathExtension: url.pathExtension.lowercased(),
                kind: FileKind(pathExtension: url.pathExtension),
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                isSymbolicLink: isLink
            )
        }

        if source.kind == .file {
            if let single = entry(for: root, relativePath: root.lastPathComponent) { return ([single], false) }
            return ([], false)
        }

        // The enumerator reports real paths (for example /private/var for /var), so the walk starts from the real path too.
        let base = realURL(root)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return ([], false) }

        var entries: [Entry] = []
        var visited = 0
        var stoppedEarly = false
        let basePath = base.path
        for case let url as URL in enumerator {
            visited += 1
            if visited > LibraryLimits.maxEnumeratedEntries {
                stoppedEarly = true
                break
            }
            // Symbolic links to folders are not followed by the enumerator; links to files are listed and skipped.
            guard url.path.hasPrefix(basePath + "/") else { continue }
            let relative = String(url.path.dropFirst(basePath.count + 1))
            if let found = entry(for: url, relativePath: relative) { entries.append(found) }
        }
        entries.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return (entries, stoppedEarly)
    }
}
