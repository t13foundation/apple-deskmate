import Foundation

/// A file attached to one question (or picked for a comparison). Its text is read once, when it is attached.
public struct Attachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var fileName: String
    public var kind: FileKind
    public var pageCount: Int?
    public var note: String?
    public var chunks: [SourceChunk]
    /// The file's path, kept so the same file is not attached twice. Never sent anywhere.
    public var path: String

    public init(id: UUID = UUID(), fileName: String, kind: FileKind, pageCount: Int? = nil, note: String? = nil, chunks: [SourceChunk], path: String) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.pageCount = pageCount
        self.note = note
        self.chunks = chunks
        self.path = path
    }

    public var characterCount: Int { chunks.reduce(0) { $0 + $1.text.count } }
    /// Rough word count for messages to the person; never used for budgeting.
    public var approximateWords: Int { max(1, characterCount / 6) }
}

public enum AttachmentLoader {
    public enum Outcome: Equatable, Sendable {
        case attached(Attachment)
        case rejected(fileName: String, reason: SkipReason)
    }

    /// Reads a file the person picked. Applies the same format and size limits as the library.
    public static func load(url: URL) -> Outcome {
        let name = url.lastPathComponent
        guard let kind = FileKind(pathExtension: url.pathExtension) else {
            return .rejected(fileName: name, reason: .unsupportedType(pathExtension: url.pathExtension.lowercased()))
        }
        return SourceAccess.withAccess(to: url) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else {
                return .rejected(fileName: name, reason: .unreadable)
            }
            switch DocumentReader.read(url: url, kind: kind, byteCount: values.fileSize ?? 0) {
            case .skipped(let reason):
                return .rejected(fileName: name, reason: reason)
            case .document(let document):
                let id = UUID()
                let fileID = "attachment:\(id.uuidString)"
                let chunks = Chunker.chunks(for: document, fileID: fileID, fileName: name, relativePath: name)
                guard !chunks.isEmpty else { return .rejected(fileName: name, reason: .empty) }
                return .attached(Attachment(id: id, fileName: name, kind: kind, pageCount: document.pageCount, note: document.note, chunks: chunks, path: SourceAccess.canonicalPath(url)))
            }
        }
    }
}
