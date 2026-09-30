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

    public init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date(), status: Status = .complete) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.status = status
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
