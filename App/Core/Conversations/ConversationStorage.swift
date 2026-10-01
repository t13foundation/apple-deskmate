import Foundation

/// Versioned JSON storage in `Application Support/DeskMate/Conversations`.
///
/// - One file per conversation, `<uuid>.json`, written atomically (a temporary file, then a rename), so a crash or a
///   power cut leaves either the old complete file or the new complete file.
/// - `index.json` is a small cache of one summary per conversation, so the Recent list does not read every
///   conversation. It is validated against each file's size and modification time and rebuilt when it is missing or
///   stale. It is never the only copy of anything.
/// - A file that cannot be read (damaged, or written by a newer DeskMate) is moved aside with a visible suffix and
///   reported. A readable record is never rewritten by a load, and a failure never touches another record.
/// - Directory mode 0700 and file mode 0600, like the connection list.
///
/// This type is synchronous and holds no state. `ConversationHistory` serialises every call that writes.
public struct ConversationStorage: Sendable {
    public static let indexVersion = 1

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The standard per-user location (inside the app container when sandboxed).
    public static func standard() -> ConversationStorage {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return ConversationStorage(directory: base.appendingPathComponent("DeskMate", isDirectory: true).appendingPathComponent("Conversations", isDirectory: true))
    }

    // MARK: Types

    /// A file that was moved aside instead of being read.
    public struct SetAside: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case unreadable
            /// Written by a newer DeskMate. It is kept intact for that version.
            case newerVersion(Int)
        }

        public var originalName: String
        public var movedTo: String?
        public var reason: Reason
    }

    public struct Listing: Equatable, Sendable {
        /// Newest first.
        public var summaries: [ConversationSummary]
        public var setAside: [SetAside]
    }

    public enum LoadResult: Equatable, Sendable {
        case loaded(ConversationRecord)
        case missing
        case setAside(SetAside)
    }

    private struct IndexFile: Codable {
        var version: Int
        var entries: [IndexEntry]
    }

    private struct IndexEntry: Codable {
        var summary: ConversationSummary
        var fileSize: Int
        var modified: Double
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }

    // MARK: Locations

    var indexURL: URL { directory.appendingPathComponent("index.json") }

    func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// `<uuid>.json` and nothing else: other files in the folder are not ours to read, move or delete.
    private static func recordID(fromFileName name: String) -> UUID? {
        guard name.hasSuffix(".json"), name != "index.json" else { return nil }
        return UUID(uuidString: String(name.dropLast(".json".count)))
    }

    private static func isOwnedFileName(_ name: String) -> Bool {
        if name == "index.json" || recordID(fromFileName: name) != nil { return true }
        // Set-aside copies: "<uuid>.json.corrupt-<time>" and "<uuid>.json.future-v<n>", also with a "-2" counter.
        guard let dot = name.range(of: ".json.") else { return false }
        let suffix = name[dot.upperBound...]
        return UUID(uuidString: String(name[..<dot.lowerBound])) != nil && (suffix.hasPrefix("corrupt-") || suffix.hasPrefix("future-v"))
    }

    // MARK: Coding

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private enum Decoded {
        case record(ConversationRecord)
        case unreadable
        case newerVersion(Int)
    }

    private static func decode(_ data: Data, expecting id: UUID) -> Decoded {
        guard let probe = try? decoder().decode(VersionProbe.self, from: data) else { return .unreadable }
        if probe.version > ConversationRecord.formatVersion { return .newerVersion(probe.version) }
        guard probe.version >= 1, let record = try? decoder().decode(ConversationRecord.self, from: data), record.id == id else { return .unreadable }
        return .record(record)
    }

    // MARK: Listing

    /// Reads the index and checks it against the files. Only files that are new or changed since the index was written
    /// are decoded; a file that cannot be read is moved aside and reported.
    public func list() -> Listing {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return Listing(summaries: [], setAside: [])
        }
        let known = Dictionary(readIndex().map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [IndexEntry] = []
        var setAside: [SetAside] = []
        var changed = false

        for name in names.sorted() {
            guard let id = Self.recordID(fromFileName: name) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let stamp = Self.fileStamp(url) else { continue }
            if let entry = known[id], entry.fileSize == stamp.size, entry.modified == stamp.modified {
                entries.append(entry)
                continue
            }
            changed = true
            guard let data = try? Data(contentsOf: url) else {
                setAside.append(moveAside(url, reason: .unreadable))
                continue
            }
            switch Self.decode(data, expecting: id) {
            case .record(let record):
                entries.append(IndexEntry(summary: ConversationSummary(record), fileSize: stamp.size, modified: stamp.modified))
            case .unreadable:
                setAside.append(moveAside(url, reason: .unreadable))
            case .newerVersion(let version):
                setAside.append(moveAside(url, reason: .newerVersion(version)))
            }
        }
        if entries.count != known.count { changed = true }
        if changed { writeIndex(entries) }
        return Listing(summaries: entries.map(\.summary).sorted { $0.updatedAt > $1.updatedAt }, setAside: setAside)
    }

    // MARK: Loading

    public func load(_ id: UUID) -> LoadResult {
        let url = recordURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .setAside(moveAside(url, reason: .unreadable)) }
        switch Self.decode(data, expecting: id) {
        case .record(let record): return .loaded(record)
        case .unreadable: return .setAside(moveAside(url, reason: .unreadable))
        case .newerVersion(let version): return .setAside(moveAside(url, reason: .newerVersion(version)))
        }
    }

    // MARK: Writing

    /// Writes the record atomically and updates the index. Throws when the record could not be written; the previous
    /// file, if any, is then still intact.
    public func save(_ record: ConversationRecord) throws {
        try prepareDirectory()
        let data = try Self.encoder().encode(record)
        let url = recordURL(record.id)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard let stamp = Self.fileStamp(url) else { return }
        var entries = readIndex().filter { $0.summary.id != record.id }
        entries.append(IndexEntry(summary: ConversationSummary(record), fileSize: stamp.size, modified: stamp.modified))
        writeIndex(entries)
    }

    /// Removes one conversation and says whether it is gone. Returns true when the record file no longer exists (a file
    /// that was already missing counts as gone) and false when it is still there, for example because the folder is
    /// read-only. A failure leaves the record and the index untouched. Set-aside copies of damaged files are not records
    /// and stay until Clear history.
    @discardableResult
    public func delete(_ id: UUID) -> Bool {
        let url = recordURL(id)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) { return false }
        }
        let entries = readIndex().filter { $0.summary.id != id }
        if FileManager.default.fileExists(atPath: indexURL.path) { writeIndex(entries) }
        return true
    }

    /// Removes every file DeskMate wrote here: records, the index and set-aside copies. Files of other names are left
    /// alone. Returns how many could not be removed. Never reaches outside this folder.
    @discardableResult
    public func deleteAll() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var failures = 0
        for name in names where Self.isOwnedFileName(name) {
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) } catch { failures += 1 }
        }
        return failures
    }

    // MARK: Index and files

    private func readIndex() -> [IndexEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let file = try? Self.decoder().decode(IndexFile.self, from: data),
              file.version == Self.indexVersion
        else { return [] }
        return file.entries
    }

    private func writeIndex(_ entries: [IndexEntry]) {
        guard (try? prepareDirectory()) != nil,
              let data = try? Self.encoder().encode(IndexFile(version: Self.indexVersion, entries: entries))
        else { return }
        try? data.write(to: indexURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private static func fileStamp(_ url: URL) -> (size: Int, modified: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return (size, modified.timeIntervalSince1970)
    }

    /// Moves a file that cannot be read next to itself under a visible name. Never overwrites an existing file.
    private func moveAside(_ url: URL, reason: SetAside.Reason) -> SetAside {
        let suffix: String
        switch reason {
        case .unreadable: suffix = "corrupt-\(Int(Date().timeIntervalSince1970))"
        case .newerVersion(let version): suffix = "future-v\(version)"
        }
        var target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(suffix)")
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(suffix)-\(counter)")
            counter += 1
        }
        let moved = (try? FileManager.default.moveItem(at: url, to: target)) != nil
        return SetAside(originalName: url.lastPathComponent, movedTo: moved ? target.lastPathComponent : nil, reason: reason)
    }
}
