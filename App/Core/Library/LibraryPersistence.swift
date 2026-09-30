import Foundation

/// Versioned JSON storage in Application Support/DeskMate/Library.
///
/// - `sources.json` holds the chosen folders and files (with their bookmarks).
/// - `index.json` holds file records and text chunks. It is a cache: it can always be rebuilt from the sources.
///
/// Unreadable data is set aside with a `.corrupt-<time>` suffix and reported, never silently discarded.
/// DeskMate only ever touches its own two files here, never the person's documents.
public struct LibraryPersistence: Sendable {
    public static let formatVersion = 1

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The standard per-user location (inside the app container when sandboxed).
    public static func standard() -> LibraryPersistence {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return LibraryPersistence(directory: base.appendingPathComponent("DeskMate", isDirectory: true).appendingPathComponent("Library", isDirectory: true))
    }

    struct SourcesFile: Codable {
        var version: Int
        var sources: [LibrarySource]
    }

    struct IndexFile: Codable {
        var version: Int
        var savedAt: Date
        var files: [IndexedFile]
        var chunks: [SourceChunk]
    }

    public struct Loaded: Sendable {
        public var sources: [LibrarySource] = []
        /// nil when there is no usable saved index (first run, or it had to be set aside).
        public var files: [IndexedFile]?
        public var chunks: [SourceChunk] = []
        public var notices: [String] = []
    }

    var sourcesURL: URL { directory.appendingPathComponent("sources.json") }
    var indexURL: URL { directory.appendingPathComponent("index.json") }

    public func load() -> Loaded {
        var loaded = Loaded()
        if let data = try? Data(contentsOf: sourcesURL) {
            if let file = try? JSONDecoder().decode(SourcesFile.self, from: data), file.version <= Self.formatVersion {
                loaded.sources = file.sources
            } else {
                quarantine(sourcesURL)
                loaded.notices.append("The saved list of sources could not be read, so it was set aside. Your files were not touched. Add your folders again.")
            }
        }
        if let data = try? Data(contentsOf: indexURL) {
            if let file = try? JSONDecoder().decode(IndexFile.self, from: data), file.version <= Self.formatVersion {
                loaded.files = file.files
                loaded.chunks = file.chunks
            } else {
                quarantine(indexURL)
                if !loaded.sources.isEmpty {
                    loaded.notices.append("The saved search index could not be read, so DeskMate is rebuilding it from your sources.")
                }
            }
        }
        return loaded
    }

    public func saveSources(_ sources: [LibrarySource]) throws {
        try write(SourcesFile(version: Self.formatVersion, sources: sources), to: sourcesURL)
    }

    public func saveIndex(files: [IndexedFile], chunks: [SourceChunk]) throws {
        try write(IndexFile(version: Self.formatVersion, savedAt: Date(), files: files, chunks: chunks), to: indexURL)
    }

    /// Removes DeskMate's own saved library data. Never touches the person's files.
    public func deleteAll() {
        try? FileManager.default.removeItem(at: sourcesURL)
        try? FileManager.default.removeItem(at: indexURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func quarantine(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: target)
    }
}
