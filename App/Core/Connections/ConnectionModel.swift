import Foundation
import MCP

public enum ConnectionAuth: String, Sendable, Hashable, Codable, CaseIterable {
    case none
    case bearer
}

/// A tool the user enabled. Only the name and a fingerprint of how the server described it are stored.
/// The fingerprint lets DeskMate turn a tool off again when the server changes it afterwards.
public struct EnabledToolRecord: Sendable, Hashable, Codable {
    public let name: String
    public let fingerprint: String

    public init(name: String, fingerprint: String) {
        self.name = name
        self.fingerprint = fingerprint
    }
}

/// Non-secret configuration of one connection. This is exactly what is written to disk; the token never is.
public struct MCPConnection: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var endpoint: ConnectionEndpoint
    public var auth: ConnectionAuth
    /// The connection as a whole can be turned off without deleting it. A turned-off connection never sends anything.
    public var isEnabled: Bool
    public var enabledTools: [EnabledToolRecord]

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: ConnectionEndpoint,
        auth: ConnectionAuth,
        isEnabled: Bool = true,
        enabledTools: [EnabledToolRecord] = []
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.auth = auth
        self.isEnabled = isEnabled
        self.enabledTools = enabledTools
    }

    public static let maxNameLength = 60

    public static func cleanedName(_ text: String) -> String {
        PlainText.sanitizeLine(text, limit: maxNameLength)
    }
}

/// What the server said during the handshake, as plain text.
public struct ConnectionNegotiation: Sendable, Equatable {
    public let protocolVersion: String
    public let serverName: String
    public let serverVersion: String
    public let offersTools: Bool

    init(protocolVersion: String, serverName: String, serverVersion: String, offersTools: Bool) {
        self.protocolVersion = protocolVersion
        self.serverName = PlainText.sanitizeLine(serverName, limit: 60)
        self.serverVersion = PlainText.sanitizeLine(serverVersion, limit: 30)
        self.offersTools = offersTools
    }
}

public enum ConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(ConnectionNegotiation)
    case failed(ConnectionFailure)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isBusy: Bool {
        if case .connecting = self { return true }
        return false
    }
}

/// One tool as the server lists it. Names and descriptions are untrusted plain text and are only displayed.
public struct ConnectionTool: Identifiable, Sendable, Hashable {
    public var id: String { name }
    /// The exact name used in calls. Always matches `toolNamePattern`; other names are not accepted.
    public let name: String
    public let title: String?
    public let descriptionText: String
    /// What the server claims. It is a claim, not a guarantee, and never changes what DeskMate allows.
    public let serverClaimsReadOnly: Bool?
    public let support: ToolSchemaSupport
    public let fingerprint: String

    public var isEnableable: Bool { support.isSupported }

    public var displayName: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? name }

    init(
        name: String,
        title: String?,
        descriptionText: String,
        serverClaimsReadOnly: Bool?,
        support: ToolSchemaSupport,
        fingerprint: String
    ) {
        self.name = name
        self.title = title
        self.descriptionText = descriptionText
        self.serverClaimsReadOnly = serverClaimsReadOnly
        self.support = support
        self.fingerprint = fingerprint
    }

    /// Builds a display-safe tool from the server's listing. Names DeskMate will not call are marked unsupported.
    static func make(from tool: Tool, limits: ConnectionLimits) -> ConnectionTool {
        var support = ToolInputSchema.evaluate(tool.inputSchema, limits: limits)
        if !IdentifierRules.isSafe(tool.name) {
            let shown = PlainText.sanitizeLine(tool.name, limit: 40)
            support = .unsupported(reasons: ["The tool name “\(shown)” uses unusual characters or is too long."] + support.reasons)
        }
        return ConnectionTool(
            name: tool.name,
            title: tool.title.map { PlainText.sanitizeLine($0, limit: 80) },
            descriptionText: PlainText.sanitize(tool.description ?? "", limit: 600),
            serverClaimsReadOnly: tool.annotations.readOnlyHint,
            support: support,
            fingerprint: ToolInputSchema.fingerprint(
                name: tool.name,
                title: tool.title,
                description: tool.description,
                inputSchema: tool.inputSchema
            )
        )
    }
}

/// Text a tool returned. It is untrusted content: show it, never obey it.
public struct ToolCallOutput: Sendable, Equatable {
    public let text: String
    /// True when the tool reported an error in its own result.
    public let isError: Bool
    public let wasTruncated: Bool
}

/// A tool call that passed every check and is ready to run. Holding one means the connection, the tool and the
/// arguments were valid at preparation time; `execute` checks again before sending.
public struct PreparedToolCall: Sendable {
    public let connectionID: UUID
    public let connectionName: String
    public let host: String
    public let toolName: String
    public let toolDescription: String
    public let arguments: ValidatedToolArguments
    let sessionGeneration: Int
}
