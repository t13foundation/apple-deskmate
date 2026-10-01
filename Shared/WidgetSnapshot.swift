import Foundation

/// The only thing the widget ever learns about the app. Deliberately small and closed: generic readiness, a generic
/// state of the latest task, a time, and one opaque conversation ID. There is no field that could hold a title, a
/// prompt, a document name, a source excerpt, an answer or a credential, and a test keeps it that way.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Bumped when the shape changes. A reader that does not know the version shows the generic state instead.
    public static let currentVersion = 1

    public enum Readiness: String, Codable, Sendable {
        case ready
        case needsAttention
    }

    public enum LatestTask: String, Codable, Sendable {
        case none
        case answered
        case stopped
        case failed
    }

    public var version: Int
    public var readiness: Readiness
    public var updatedAt: Date
    public var hasConversations: Bool
    /// Opaque. Only ever used to build a `deskmate://resume` link; never shown.
    public var lastConversationID: UUID?
    public var latestTask: LatestTask

    public init(
        readiness: Readiness,
        updatedAt: Date,
        hasConversations: Bool,
        lastConversationID: UUID?,
        latestTask: LatestTask
    ) {
        self.version = Self.currentVersion
        self.readiness = readiness
        self.updatedAt = updatedAt
        self.hasConversations = hasConversations
        self.lastConversationID = hasConversations ? lastConversationID : nil
        self.latestTask = latestTask
    }
}
