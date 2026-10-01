import Foundation

/// One saved conversation, exactly as the person saw it. This is the on-disk format, so every field is a promise.
///
/// Storage contract (read before adding a field):
/// - Only what is visible in the chat is stored: questions, answers, the source references and excerpts the answers
///   showed, the names of attached files, and results the person created or edited.
/// - Never stored: credentials or tokens, raw connector (MCP) responses, system instructions, hidden prompts, the text
///   of attached files, or anything the person did not see.
/// - Tool calls (for example the model-selected MCP calls of a later package) are stored only as a short visible
///   summary in `StoredMessage.toolSummary`, such as "Asked Project Lumen: get_project_status (approved)". Never the
///   arguments' raw JSON, never the response body, never the server's headers.
/// - A new optional field may be added without changing `formatVersion`; older records simply lack it. Anything that
///   changes the meaning of an existing field or removes one raises `formatVersion`, and a record with a higher
///   version than this build knows is set aside, never rewritten.
public struct ConversationRecord: Codable, Identifiable, Equatable, Sendable {
    /// Version written by this build. A record with a larger number is not read, and is moved aside untouched.
    public static let formatVersion = 1

    public var version: Int
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [StoredMessage]
    /// Briefs and task lists the person created in this conversation, with their edits.
    public var results: [StoredResult]

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        messages: [StoredMessage],
        results: [StoredResult] = []
    ) {
        self.version = Self.formatVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.results = results
    }
}

/// A visible message. Mirrors `ChatMessage`, with its own stable string values so the file format never depends on
/// the names of Swift enum cases.
public struct StoredMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    /// A message that was still streaming when it was saved is stored as `stopped`: the text is whatever was shown.
    public enum Status: String, Codable, Sendable { case complete, stopped, failed }

    public var id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date
    public var status: Status
    /// Excerpts the answer cited, as the source drawer showed them (label, file, location and excerpt text).
    public var sources: [SourceCitation]
    public var removedCitations: [String]
    public var consultedCount: Int
    /// Excerpts read for a document comparison, as shown under "Compared material".
    public var comparedMaterial: [SourceCitation]
    /// Names and kinds of files attached to a question. Never their text.
    public var attachments: [StoredAttachment]
    /// Reserved for model-selected tool calls: one short, visible line per call. See the contract above.
    public var toolSummary: String?

    public init(
        id: UUID,
        role: Role,
        text: String,
        createdAt: Date,
        status: Status,
        sources: [SourceCitation] = [],
        removedCitations: [String] = [],
        consultedCount: Int = 0,
        comparedMaterial: [SourceCitation] = [],
        attachments: [StoredAttachment] = [],
        toolSummary: String? = nil
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
        self.toolSummary = toolSummary
    }
}

public struct StoredAttachment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var fileName: String
    public var kind: FileKind

    public init(id: UUID, fileName: String, kind: FileKind) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
    }
}

/// What a result is. The raw value is stored.
public enum ResultKind: String, Codable, CaseIterable, Sendable {
    case brief
    case tasks

    public var title: String {
        switch self {
        case .brief: "Brief"
        case .tasks: "Tasks"
        }
    }

    /// The label of the action that creates it.
    public var actionTitle: String {
        switch self {
        case .brief: "Create brief"
        case .tasks: "Extract tasks"
        }
    }

    public var progressTitle: String {
        switch self {
        case .brief: "Creating a brief…"
        case .tasks: "Extracting tasks…"
        }
    }

    public var suggestedFileName: String {
        switch self {
        case .brief: "Brief"
        case .tasks: "Tasks"
        }
    }
}

/// A result (brief or task list) as Markdown. `markdown` holds the person's latest edit, not the first generated text.
public struct StoredResult: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ResultKind
    public var markdown: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), kind: ResultKind, markdown: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.markdown = markdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One row of the Recent list. Small enough to keep every conversation's summary in memory.
public struct ConversationSummary: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int

    public init(id: UUID, title: String, createdAt: Date, updatedAt: Date, messageCount: Int) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }

    public init(_ record: ConversationRecord) {
        self.init(id: record.id, title: record.title, createdAt: record.createdAt, updatedAt: record.updatedAt, messageCount: record.messages.count)
    }
}

// MARK: Conversion

public extension StoredMessage {
    init(_ message: ChatMessage) {
        self.init(
            id: message.id,
            role: message.role == .user ? .user : .assistant,
            text: message.text,
            createdAt: message.createdAt,
            status: {
                switch message.status {
                case .complete: .complete
                case .streaming, .stopped: .stopped
                case .failed: .failed
                }
            }(),
            sources: message.sources,
            removedCitations: message.removedCitations,
            consultedCount: message.consultedCount,
            comparedMaterial: message.comparedMaterial,
            attachments: message.attachments.map { StoredAttachment(id: $0.id, fileName: $0.fileName, kind: $0.kind) },
            // One visible line per call. Never the inputs, the service's reply or the headers.
            toolSummary: ToolCallRecord.summary(of: message.toolCalls) ?? message.toolSummary
        )
    }

    var chatMessage: ChatMessage {
        ChatMessage(
            id: id,
            role: role == .user ? .user : .assistant,
            text: text,
            createdAt: createdAt,
            status: {
                switch status {
                case .complete: .complete
                case .stopped: .stopped
                case .failed: .failed
                }
            }(),
            sources: sources,
            removedCitations: removedCitations,
            consultedCount: consultedCount,
            comparedMaterial: comparedMaterial,
            attachments: attachments.map { AttachmentSummary(id: $0.id, fileName: $0.fileName, kind: $0.kind) },
            toolSummary: toolSummary
        )
    }
}
