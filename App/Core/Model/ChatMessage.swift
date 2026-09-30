import Foundation

/// One visible message in the current conversation. Persistence belongs to a later package.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }

    public enum Status: Sendable {
        /// Finished normally (user messages are always complete).
        case complete
        /// The model is still producing this answer.
        case streaming
        /// The person pressed Stop; `text` holds whatever was produced before that.
        case stopped
        /// Generation failed; `text` holds any partial output.
        case failed
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public let createdAt: Date
    public var status: Status
    /// Excerpts the answer cites. Each was really given to the model; unknown citations never appear here.
    public var sources: [SourceCitation]
    /// Citation IDs the model wrote that matched no excerpt it received. They were removed from the text.
    public var removedCitations: [String]
    /// How many excerpts the model was given while writing this answer, cited or not.
    public var consultedCount: Int
    /// A document comparison only: the excerpts read for it. Shown as compared material, not as per-fact citations.
    public var comparedMaterial: [SourceCitation]
    /// Files attached to a question (user messages only).
    public var attachments: [AttachmentSummary]

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        status: Status = .complete,
        sources: [SourceCitation] = [],
        removedCitations: [String] = [],
        consultedCount: Int = 0,
        comparedMaterial: [SourceCitation] = [],
        attachments: [AttachmentSummary] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.status = status
        self.sources = sources
        self.removedCitations = removedCitations
        self.consultedCount = consultedCount
        self.comparedMaterial = comparedMaterial
        self.attachments = attachments
    }
}

/// What the transcript shows about a file attached to a question. Never contains the file's text.
public struct AttachmentSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fileName: String
    public let kind: FileKind

    public init(id: UUID, fileName: String, kind: FileKind) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
    }

    public init(_ attachment: Attachment) {
        self.init(id: attachment.id, fileName: attachment.fileName, kind: attachment.kind)
    }
}

/// A finished question/answer pair. This is the unit used to rebuild model context
/// (after a stopped or failed turn, and later when a saved conversation is reopened).
public struct ConversationTurn: Equatable, Sendable {
    public let prompt: String
    public let response: String

    public init(prompt: String, response: String) {
        self.prompt = prompt
        self.response = response
    }
}
