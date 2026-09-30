import Foundation

/// Hard limits of the prototype library. They are enforced in code, never only in prompts.
public enum LibraryLimits {
    /// Supported files indexed across every selected source.
    public static let maxFiles = 200
    /// Files attached to a single question.
    public static let maxAttachments = 5
    public static let maxPDFBytes = 10 * 1024 * 1024
    public static let maxPDFPages = 50
    /// Plain-text and Markdown files are bounded too, so one file cannot exhaust memory.
    public static let maxTextBytes = 1 * 1024 * 1024
    /// Chunks aim for `targetChunkCharacters` and never exceed `maxChunkCharacters`.
    public static let targetChunkCharacters = 800
    public static let maxChunkCharacters = 1000
    /// A folder walk stops after this many entries so a huge folder cannot stall the app.
    public static let maxEnumeratedEntries = 5000
    /// Files of other types are listed (with a reason) up to this many per source; the rest are counted.
    public static let maxIgnoredListedPerSource = 40
    /// A PDF page with fewer non-whitespace characters than this counts as having no text layer.
    public static let minimumPageCharacters = 20
}

public enum SourceKind: String, Codable, Equatable, Sendable {
    case folder
    case file
}

public enum FileKind: String, Codable, Equatable, Sendable {
    case text
    case markdown
    case pdf

    /// Maps a file extension to a supported kind. Everything else is unsupported.
    public init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "txt", "text": self = .text
        case "md", "markdown": self = .markdown
        case "pdf": self = .pdf
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .text: "Text"
        case .markdown: "Markdown"
        case .pdf: "PDF"
        }
    }
}

/// Why a file is listed but not searchable. Each reason carries a short label and a next step.
public enum SkipReason: Codable, Equatable, Sendable {
    case notUTF8
    case needsOCR
    case pdfTooLarge(bytes: Int)
    case pdfTooManyPages(pages: Int)
    case textTooLarge(bytes: Int)
    case empty
    case encryptedPDF
    case unreadablePDF
    case unreadable
    case libraryFull
    case unsupportedType(pathExtension: String)
    case symbolicLink

    public var label: String {
        switch self {
        case .notUTF8: "Not UTF-8 text"
        case .needsOCR: "Needs OCR, not supported"
        case .pdfTooLarge: "PDF over 10 MB"
        case .pdfTooManyPages: "PDF over 50 pages"
        case .textTooLarge: "File over 1 MB"
        case .empty: "No text"
        case .encryptedPDF: "Password-protected PDF"
        case .unreadablePDF: "PDF can’t be read"
        case .unreadable: "Can’t be read"
        case .libraryFull: "Library limit reached"
        case .unsupportedType: "Not supported"
        case .symbolicLink: "Shortcut not followed"
        }
    }

    /// Plain-language explanation with a next step.
    public var explanation: String {
        switch self {
        case .notUTF8:
            "This file isn’t UTF-8 text, so DeskMate can’t read it reliably. Save it as UTF-8 text and refresh."
        case .needsOCR:
            "This PDF has no text layer (it looks scanned), and DeskMate does not do OCR. Export a text-based PDF or copy the text into a .txt file."
        case .pdfTooLarge(let bytes):
            "This PDF is \(Self.megabytes(bytes)) MB; the limit is 10 MB. Split it into smaller PDFs."
        case .pdfTooManyPages(let pages):
            "This PDF has \(pages) pages; the limit is \(LibraryLimits.maxPDFPages). Split it into smaller PDFs."
        case .textTooLarge(let bytes):
            "This file is \(Self.megabytes(bytes)) MB; the limit for text and Markdown files is 1 MB. Split it into smaller files."
        case .empty:
            "This file has no readable text."
        case .encryptedPDF:
            "This PDF is password-protected. Remove the password and refresh."
        case .unreadablePDF:
            "This PDF could not be opened. It may be damaged; try exporting it again."
        case .unreadable:
            "DeskMate could not read this file. Check that it still exists and that you can open it, then refresh."
        case .libraryFull:
            "The library already holds \(LibraryLimits.maxFiles) files, which is the limit. Remove a source to make room."
        case .unsupportedType(let pathExtension):
            pathExtension.isEmpty
                ? "DeskMate reads .txt, .md and text-based .pdf files only."
                : "DeskMate reads .txt, .md and text-based .pdf files only; .\(pathExtension) files are ignored."
        case .symbolicLink:
            "This is a shortcut (symbolic link). DeskMate doesn’t follow links, so it never reads outside the folder you chose."
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

/// A folder or file the person chose in the system open panel.
public struct LibrarySource: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: SourceKind
    public var displayName: String
    /// Path when it was chosen. A bookmark keeps working after a move; DeskMate treats a moved source as revoked.
    public var path: String
    /// Security-scoped, app-scoped bookmark.
    public var bookmark: Data
    public var addedAt: Date
    /// Unsupported files beyond the listed cap.
    public var omittedIgnoredCount: Int

    public init(id: UUID = UUID(), kind: SourceKind, displayName: String, path: String, bookmark: Data, addedAt: Date = Date(), omittedIgnoredCount: Int = 0) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.bookmark = bookmark
        self.addedAt = addedAt
        self.omittedIgnoredCount = omittedIgnoredCount
    }
}

public enum SourceState: Equatable, Sendable {
    case available
    case unavailable(UnavailableReason)

    public var isAvailable: Bool { self == .available }
}

public enum UnavailableReason: Error, Equatable, Sendable {
    /// The bookmark no longer resolves: deleted, on a disconnected disk, or access was revoked.
    case missing
    /// The item now lives somewhere else (moved, renamed or trashed).
    case moved
    case accessDenied

    public var label: String {
        switch self {
        case .missing: "Not found"
        case .moved: "Moved or renamed"
        case .accessDenied: "Access lost"
        }
    }

    public var explanation: String {
        switch self {
        case .missing:
            "DeskMate can’t find this item any more. It was deleted or its disk is disconnected. It is no longer searched. Reconnect the disk and refresh, or remove it."
        case .moved:
            "This item was moved, renamed or trashed after you added it, so DeskMate stopped using it and removed it from search. Add it again from its new location, or remove it."
        case .accessDenied:
            "macOS no longer lets DeskMate read this item. It is no longer searched. Add it again to grant access, or remove it."
        }
    }
}

/// One file seen in a source, searchable or skipped.
public struct IndexedFile: Codable, Identifiable, Equatable, Sendable {
    /// `<source id>/<relative path>`. Stable while the file stays where it is.
    public var id: String
    public var sourceID: UUID
    public var relativePath: String
    public var fileName: String
    public var kind: FileKind?
    public var byteCount: Int
    /// Seconds since 1970 of the last modification seen.
    public var modified: Double
    public var pageCount: Int?
    public var chunkCount: Int
    public var skip: SkipReason?
    /// A non-fatal remark, e.g. some PDF pages had no text.
    public var note: String?

    public init(sourceID: UUID, relativePath: String, fileName: String, kind: FileKind?, byteCount: Int, modified: Double, pageCount: Int? = nil, chunkCount: Int = 0, skip: SkipReason? = nil, note: String? = nil) {
        self.id = Self.makeID(sourceID: sourceID, relativePath: relativePath)
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.fileName = fileName
        self.kind = kind
        self.byteCount = byteCount
        self.modified = modified
        self.pageCount = pageCount
        self.chunkCount = chunkCount
        self.skip = skip
        self.note = note
    }

    public static func makeID(sourceID: UUID, relativePath: String) -> String {
        "\(sourceID.uuidString)/\(relativePath)"
    }

    public var isIndexed: Bool { skip == nil }
}

/// A bounded piece of a file with everything needed to cite it.
public struct SourceChunk: Codable, Identifiable, Equatable, Sendable {
    /// Stable identifier derived from the file, position and text. It changes when the text changes.
    public var id: String
    public var fileID: String
    public var fileName: String
    public var relativePath: String
    public var ordinal: Int
    /// 1-based PDF page.
    public var page: Int?
    /// Markdown heading path, e.g. "Budget › Approvals".
    public var section: String?
    public var text: String

    public init(id: String, fileID: String, fileName: String, relativePath: String, ordinal: Int, page: Int?, section: String?, text: String) {
        self.id = id
        self.fileID = fileID
        self.fileName = fileName
        self.relativePath = relativePath
        self.ordinal = ordinal
        self.page = page
        self.section = section
        self.text = text
    }

    /// Human-readable position, e.g. "Page 3" or "Section: Budget".
    public var location: String? {
        if let page { return "Page \(page)" }
        if let section, !section.isEmpty { return "Section: \(section)" }
        return nil
    }
}
