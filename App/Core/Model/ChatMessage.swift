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
    /// Connected-service calls the model made for this answer, as they happened. Memory only.
    public var toolCalls: [ToolCallRecord]
    /// Results of those calls that the answer cites ("[M1]"). Memory only: never saved.
    public var toolSources: [ToolSource]
    /// The saved one-line-per-call summary of an answer reopened from history. A live answer derives it from `toolCalls`.
    public var toolSummary: String?

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
        attachments: [AttachmentSummary] = [],
        toolCalls: [ToolCallRecord] = [],
        toolSources: [ToolSource] = [],
        toolSummary: String? = nil
    ) {
        self.toolCalls = toolCalls
        self.toolSources = toolSources
        self.toolSummary = toolSummary
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

public extension ChatMessage {
    /// One visible line per connected-service call. Live calls first; for a reopened answer, the saved lines.
    var toolActivityLines: [String] {
        if !toolCalls.isEmpty { return toolCalls.map(\.summaryLine) }
        return (toolSummary ?? "").split(separator: "\n").map(String.init)
    }

    /// Hosts a request may have reached for this answer. Empty when no request was made (including when every call was declined).
    var remoteHosts: [String] {
        toolCalls.isEmpty ? ToolCallRecord.remoteHosts(inSummary: toolSummary) : ToolCallRecord.remoteHosts(of: toolCalls)
    }

    /// True when the model asked for any service call, even if it was declined or refused.
    var usedServices: Bool { !toolCalls.isEmpty || toolSummary != nil }
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
