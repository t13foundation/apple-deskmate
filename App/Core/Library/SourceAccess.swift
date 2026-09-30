import Foundation

/// Security-scoped access to the folders and files the person chose.
/// A source is usable only while its bookmark resolves to the exact place that was chosen.
public enum SourceAccess {
    public enum AccessError: Error, Equatable {
        case notReadable
        case bookmarkFailed
    }

    /// Builds a source from a URL returned by the system open panel (or given explicitly on the command line).
    /// With `scoped` the source keeps an app-scoped security bookmark; without it the path alone is stored
    /// (command-line and test use, where no sandbox is involved).
    public static func makeSource(for url: URL, scoped: Bool = true) throws -> LibrarySource {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let isDirectory = values?.isDirectory ?? false
        guard isDirectory || values?.isRegularFile == true else { throw AccessError.notReadable }
        var bookmark = Data()
        if scoped {
            do {
                bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                throw AccessError.bookmarkFailed
            }
        }
        return LibrarySource(
            kind: isDirectory ? .folder : .file,
            displayName: url.lastPathComponent,
            path: canonicalPath(url),
            bookmark: bookmark
        )
    }

    /// Resolves the bookmark and checks that it still points at the place that was chosen.
    /// The returned URL must be wrapped in `withAccess` before reading.
    public static func resolve(_ source: LibrarySource) -> Result<URL, UnavailableReason> {
        let url: URL
        if source.bookmark.isEmpty {
            url = URL(fileURLWithPath: source.path)
        } else {
            var stale = false
            do {
                url = try URL(resolvingBookmarkData: source.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
                    return .failure(.missing)
                }
                return .failure(.accessDenied)
            }
        }
        // A bookmark follows a moved item. DeskMate does not: the person approved that place, not the new one.
        if canonicalPath(url) != source.path {
            return .failure(.moved)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        return .success(url)
    }

    /// Runs `body` with security-scoped access to `url` and balances the start/stop calls.
    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    public static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
