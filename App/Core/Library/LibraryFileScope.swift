import Foundation

/// How a file name the person gave resolved against the files that are searchable now.
public enum FileNameMatch: Equatable, Sendable {
    /// Exactly one file: an exact name match, or else the only file whose name contains the text.
    case file(IndexedFile)
    /// No file name matches.
    case none
    /// More than one file fits equally well. None is chosen.
    case ambiguous([IndexedFile])
}

/// What a search restricted to one named file found, before the disk check.
public enum ScopedSearchResult: Equatable, Sendable {
    /// Ranked chunks of the one matching file. May be empty: the file has nothing for these search words.
    case chunks([SourceChunk])
    /// No file in My files has that name.
    case noFile
    /// Several files match. The text of each is a name that tells them apart (a path when names repeat).
    case ambiguous([String])
}

/// Restricts a search to one library file the person named. It works only on files DeskMate already indexed from
/// folders and files the person chose: it takes no path, opens nothing and widens no access.
public enum LibraryFileScope {
    /// Case-insensitive. An exact file-name match wins; otherwise a file whose name contains the text, if there is
    /// exactly one. Two exact matches (the same name in two folders) or several contains-matches are ambiguous.
    public static func resolve(_ requested: String, in files: [IndexedFile]) -> FileNameMatch {
        let wanted = normalize(requested)
        guard !wanted.isEmpty else { return .none }

        let exact = files.filter { same($0.fileName, wanted) }
        if exact.count == 1 { return .file(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }

        let containing = files.filter { contains($0.fileName, wanted) }
        if containing.count == 1 { return .file(containing[0]) }
        if containing.count > 1 { return .ambiguous(containing) }
        return .none
    }

    /// The matching file's chunks that match `query`, best first, or why there are none. Nothing from any other file is
    /// ever returned. `files` must be the searchable files, so a removed or revoked file cannot be named.
    public static func search(
        query: String,
        fileName: String,
        files: [IndexedFile],
        index: SearchIndex,
        limit: Int
    ) -> (result: ScopedSearchResult, file: IndexedFile?) {
        switch resolve(fileName, in: files) {
        case .none:
            return (.noFile, nil)
        case .ambiguous(let candidates):
            return (.ambiguous(candidates.map(label)), nil)
        case .file(let file):
            let hits = index.search(query, limit: limit) { $0.fileID == file.id }.map(\.chunk)
            return (.chunks(hits), file)
        }
    }

    /// The name that tells files apart: the path inside the chosen folder when there is one.
    private static func label(_ file: IndexedFile) -> String {
        file.relativePath.isEmpty ? file.fileName : file.relativePath
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’`")))
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func same(_ name: String, _ wanted: String) -> Bool {
        name.compare(wanted, options: options) == .orderedSame
    }

    private static func contains(_ name: String, _ wanted: String) -> Bool {
        name.range(of: wanted, options: options) != nil
    }
}
