import Foundation
import MCP

/// What a server listed, bounded and converted to display-safe values.
public struct ToolListing: Sendable, Equatable {
    public var tools: [ConnectionTool]
    /// Tools beyond the listing limit, or with a repeated name, that were ignored.
    public var omittedCount: Int

    public init(tools: [ConnectionTool], omittedCount: Int = 0) {
        self.tools = tools
        self.omittedCount = omittedCount
    }
}

/// One live conversation with one server. The manager owns sessions; nothing else creates them.
protocol ConnectionSession: Sendable {
    func listTools() async throws -> ToolListing
    func callTool(name: String, arguments: ValidatedToolArguments) async throws -> ToolCallOutput
    /// Stops in-flight requests, tells the server the session is over and releases the connection.
    func close() async
}

struct OpenedSession: Sendable {
    let session: any ConnectionSession
    let negotiation: ConnectionNegotiation
}

protocol ConnectionSessionFactory: Sendable {
    /// Connects and negotiates. Sends only the protocol handshake: no documents, prompts or other content.
    func open(endpoint: ConnectionEndpoint, token: String?) async throws -> OpenedSession
}

/// Production factory: the official MCP Swift SDK client over the bounded transport.
struct MCPSessionFactory: ConnectionSessionFactory {
    var limits = ConnectionLimits()

    func open(endpoint: ConnectionEndpoint, token: String?) async throws -> OpenedSession {
        let transport = BoundedHTTPTransport(endpoint: endpoint, token: token, limits: limits)
        let client = Client(
            name: "DeskMate",
            version: Self.clientVersion,
            title: "DeskMate",
            capabilities: Client.Capabilities(),  // no sampling, elicitation or roots: the server cannot ask for them
            configuration: .default
        )
        do {
            // Cancelling the caller (for example Disconnect while connecting) closes the transport, which stops the request.
            let result = try await withTaskCancellationHandler {
                try await client.connect(transport: transport)
            } onCancel: {
                Task { await transport.disconnect() }
            }
            guard Version.supported.contains(result.protocolVersion) else {
                throw TransportFailure.protocolMismatch(result.protocolVersion)
            }
            let negotiation = ConnectionNegotiation(
                protocolVersion: result.protocolVersion,
                serverName: result.serverInfo.title ?? result.serverInfo.name,
                serverVersion: result.serverInfo.version,
                offersTools: result.capabilities.tools != nil
            )
            return OpenedSession(session: MCPClientSession(client: client, limits: limits), negotiation: negotiation)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}

actor MCPClientSession: ConnectionSession {
    private let client: Client
    private let limits: ConnectionLimits
    private var isClosed = false

    init(client: Client, limits: ConnectionLimits) {
        self.client = client
        self.limits = limits
    }

    func listTools() async throws -> ToolListing {
        guard !isClosed else { throw TransportFailure.closed }
        var tools: [ConnectionTool] = []
        var seen = Set<String>()
        var omitted = 0
        var cursor: String?
        for _ in 0..<10 {
            let page = try await client.listTools(cursor: cursor)
            for tool in page.tools {
                if tools.count >= limits.maxListedTools || !seen.insert(tool.name).inserted {
                    omitted += 1
                    continue
                }
                tools.append(ConnectionTool.make(from: tool, limits: limits))
            }
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return ToolListing(tools: tools, omittedCount: omitted)
    }

    func callTool(name: String, arguments: ValidatedToolArguments) async throws -> ToolCallOutput {
        guard !isClosed else { throw TransportFailure.closed }
        let (content, isError) = try await client.callTool(name: name, arguments: arguments.mcpValues)
        var parts: [String] = []
        for item in content {
            switch item {
            case .text(let text, _, _): parts.append(text)
            case .image: parts.append("[Image omitted]")
            case .audio: parts.append("[Audio omitted]")
            case .resource: parts.append("[Embedded resource omitted]")
            case .resourceLink: parts.append("[Link omitted]")
            }
        }
        let raw = parts.joined(separator: "\n")
        let text = PlainText.sanitize(raw, limit: limits.maxToolOutputCharacters)
        return ToolCallOutput(
            text: text,
            isError: isError ?? false,
            wasTruncated: raw.count > limits.maxToolOutputCharacters
        )
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await client.disconnect()
    }
}
