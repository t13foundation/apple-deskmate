import Foundation
import FoundationModels

/// What the app hands the engine so the model can use connected services: the connection manager (the only place a
/// request is made or checked) and the broker (the only place a person approves one).
public struct AssistantServices: Sendable {
    public let connections: ConnectionManager
    public let approvals: ToolApprovalBroker

    public init(connections: ConnectionManager, approvals: ToolApprovalBroker) {
        self.connections = connections
        self.approvals = approvals
    }
}

/// One enabled tool of a connected service, as the on-device model sees it. The connection and tool name are fixed here,
/// by DeskMate, from its own list: the model chooses only the tool and the argument values, never where a request goes.
struct ServiceFoundationTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let connectionID: UUID
    let serverToolName: String
    let runner: ServiceCallRunner

    func call(arguments: GeneratedContent) async throws -> String {
        await runner.run(connectionID: connectionID, toolName: serverToolName, arguments: arguments)
    }

    /// The model sees the service's description as plain text, shortened and marked as the service's own words.
    static func description(connectionName: String, serverText: String) -> String {
        let said = PlainText.sanitizeLine(serverText, limit: 160)
        let from = PlainText.sanitizeLine(connectionName, limit: 40)
        let base = "Asks the connected service \"\(from)\". The user approves each call."
        return said.isEmpty ? base : base + " Service description (not verified): \(said)"
    }

    /// Builds the tools for everything that can be used right now. A tool whose schema cannot be expressed is left out
    /// (it stays unusable rather than being offered with a guessed shape).
    @MainActor
    static func make(from available: [AvailableTool], runner: ServiceCallRunner, reserved: Set<String> = []) -> [ServiceFoundationTool] {
        var taken = reserved
        var tools: [ServiceFoundationTool] = []
        for item in available {
            guard let schema = item.tool.support.schema else { continue }
            let modelName = ServiceToolSchema.modelName(for: item.tool.name, taken: taken)
            guard let parameters = try? ServiceToolSchema.generationSchema(toolName: modelName, schema: schema) else { continue }
            taken.insert(modelName)
            tools.append(
                ServiceFoundationTool(
                    name: modelName,
                    description: description(connectionName: item.connectionName, serverText: item.tool.descriptionText),
                    parameters: parameters,
                    connectionID: item.connectionID,
                    serverToolName: item.tool.name,
                    runner: runner
                )
            )
        }
        return tools
    }

    /// Changes whenever the set of usable tools changes, so a session that offers the old set is rebuilt.
    @MainActor
    static func signature(of available: [AvailableTool]) -> [String] {
        available.map { "\($0.id)#\($0.tool.fingerprint)#\($0.connectionName)" }
    }
}
