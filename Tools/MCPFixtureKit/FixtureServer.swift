import Foundation
import Logging
import MCP
import Network

/// Configuration of the synthetic MCP fixture server.
public struct FixtureOptions: Sendable {
    /// TCP port on 127.0.0.1. Use 0 to let the system pick a free port.
    public var port: UInt16 = 8765
    public var path = "/mcp"
    /// When set, every request must carry `Authorization: Bearer <token>`. Synthetic value only.
    public var requiredToken: String?
    /// Seconds to wait before answering any MCP request (to demonstrate timeouts).
    public var delaySeconds: Double = 0
    /// Pads tool descriptions and results beyond the client's response limit.
    public var oversizedResponses = false
    /// Answers every request with 401, whatever the token.
    public var rejectAllAuth = false
    /// Answers every request with a 307 redirect to another host.
    public var redirectAll = false
    /// Uses the SDK's stateless transport (plain JSON replies, no session) instead of sessions with event streams.
    public var stateless = false
    /// Adds six extra synthetic tools (enum, integer, boolean and two unsupported shapes) for the UI.
    public var demoTools = false
    /// Receives one line per request. Never contains the token.
    public var log: @Sendable (String) -> Void = { _ in }

    public init() {}
}

public enum FixtureError: Error, CustomStringConvertible {
    case cannotListen(String)

    public var description: String {
        switch self {
        case .cannotListen(let reason): "The fixture could not start listening: \(reason)"
        }
    }
}

/// A Streamable HTTP MCP server bound to 127.0.0.1 only, serving fictional “Project Lumen” data through exactly two
/// retrieval tools (plus optional demo tools). It exists for demonstrations and tests; it is not a product feature.
public actor FixtureServer {
    public let options: FixtureOptions
    private var listener: NWListener?
    private var sessions: [String: (server: Server, transport: StatefulHTTPServerTransport)] = [:]
    private var statelessPair: (server: Server, transport: StatelessHTTPServerTransport)?
    private var activeConnections: [ObjectIdentifier: FixtureConnection] = [:]
    private let queue = DispatchQueue(label: "deskmate.mcp.fixture")

    public init(options: FixtureOptions) {
        self.options = options
    }

    /// Starts listening and returns the bound port.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: options.port) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch {
            throw FixtureError.cannotListen(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            Task { await self.accept(connection) }
        }
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: FixtureError.cannotListen(error.localizedDescription)) }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: FixtureError.cannotListen("cancelled")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        return boundPort
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        for connection in activeConnections.values { connection.close() }
        activeConnections.removeAll()
        for session in sessions.values { await session.transport.disconnect() }
        sessions.removeAll()
        if let pair = statelessPair { await pair.transport.disconnect() }
        statelessPair = nil
    }

    // MARK: Connections

    private func accept(_ nwConnection: NWConnection) {
        let connection = FixtureConnection(nwConnection, queue: queue)
        let key = ObjectIdentifier(connection)
        activeConnections[key] = connection
        Task {
            await self.serve(connection)
            self.finished(key)
        }
    }

    private func finished(_ key: ObjectIdentifier) {
        activeConnections[key]?.close()
        activeConnections[key] = nil
    }

    private func serve(_ connection: FixtureConnection) async {
        do {
            guard let request = try await connection.readRequest() else { return }
            let response = await route(request)
            try await connection.write(response.serialized())
        } catch FixtureConnection.ReadError.tooLarge {
            try? await connection.write(FixtureResponse(status: 413).serialized())
        } catch {
            // Client went away or sent garbage: nothing to answer.
        }
    }

    // MARK: Routing

    private func route(_ request: FixtureRequest) async -> FixtureResponse {
        let summary = RPCSummary(body: request.body)
        func log(_ auth: String, _ outcome: String, session: String? = nil) {
            var parts = [request.method, request.path, "auth=\(auth)"]
            if let session { parts.append("session=\(session.prefix(8))") }
            parts.append(contentsOf: summary.logFields)
            parts.append("-> \(outcome)")
            options.log(parts.joined(separator: " "))
        }

        guard request.path == options.path else {
            log("n/a", "404")
            return FixtureResponse(status: 404)
        }
        if options.redirectAll {
            log("n/a", "307 redirect")
            return FixtureResponse(status: 307, headers: ["Location": "https://redirect-target.invalid/mcp"])
        }

        let authorization = request.headers["authorization"]
        var authState = "none"
        if options.rejectAllAuth {
            log(authorization == nil ? "missing" : "rejected", "401")
            return FixtureResponse(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"deskmate-fixture\""])
        }
        if let required = options.requiredToken {
            guard let authorization else {
                log("missing", "401")
                return FixtureResponse(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"deskmate-fixture\""])
            }
            guard authorization == "Bearer \(required)" else {
                log("rejected", "401")
                return FixtureResponse(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"deskmate-fixture\""])
            }
            authState = "ok"
        }

        switch request.method {
        case "POST", "DELETE":
            break
        default:
            log(authState, "405")
            return FixtureResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }

        if options.delaySeconds > 0, summary.isRequest {
            try? await Task.sleep(for: .seconds(options.delaySeconds))
        }

        let response = await handleMCP(request)
        log(authState, "\(response.status)", session: request.headers["mcp-session-id"] ?? response.headers["MCP-Session-Id"])
        return response
    }

    // MARK: MCP

    private func handleMCP(_ request: FixtureRequest) async -> FixtureResponse {
        let httpRequest = HTTPRequest(method: request.method, headers: request.headers, body: request.body, path: request.path)
        if options.stateless {
            return await FixtureResponse(collecting: statelessTransport().handleRequest(httpRequest))
        }

        if let sessionID = request.headers["mcp-session-id"], let session = sessions[sessionID] {
            let response = await session.transport.handleRequest(httpRequest)
            if request.method == "DELETE", response.statusCode == 200 {
                sessions[sessionID] = nil
                options.log("session closed session=\(sessionID.prefix(8))")
            }
            return await FixtureResponse(collecting: response)
        }
        if request.method == "POST", RPCSummary(body: request.body).method == "initialize" {
            let sessionID = UUID().uuidString
            let transport = StatefulHTTPServerTransport(sessionIDGenerator: FixedSessionID(value: sessionID))
            do {
                let server = await makeServer()
                try await server.start(transport: transport)
                sessions[sessionID] = (server, transport)
                let response = await transport.handleRequest(httpRequest)
                if case .error = response {
                    sessions[sessionID] = nil
                    await transport.disconnect()
                } else {
                    options.log("session opened session=\(sessionID.prefix(8))")
                }
                return await FixtureResponse(collecting: response)
            } catch {
                await transport.disconnect()
                return FixtureResponse(status: 500)
            }
        }
        return FixtureResponse(status: request.headers["mcp-session-id"] == nil ? 400 : 404)
    }

    private func statelessTransport() async -> StatelessHTTPServerTransport {
        if let pair = statelessPair { return pair.transport }
        let transport = StatelessHTTPServerTransport()
        let server = await makeServer()
        try? await server.start(transport: transport)
        statelessPair = (server, transport)
        return transport
    }

    private func makeServer() async -> Server {
        let server = Server(
            name: "deskmate-project-lumen-fixture",
            version: "1.0.0",
            title: "Project Lumen (synthetic fixture)",
            capabilities: .init(tools: .init(listChanged: false))
        )
        let demo = options.demoTools
        let padding = options.oversizedResponses ? 300_000 : 0
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: FixtureTools.definitions(includeDemoTools: demo, paddingBytes: padding))
        }
        await server.withMethodHandler(CallTool.self) { params in
            FixtureTools.call(name: params.name, arguments: params.arguments, paddingBytes: padding)
        }
        return server
    }
}

private struct FixedSessionID: SessionIDGenerator {
    let value: String
    func generateSessionID() -> String { value }
}

/// Claims a one-shot continuation from several callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

/// What the log shows about a JSON-RPC message: the method, and for tool calls the tool name and arguments.
struct RPCSummary {
    var method: String?
    var isRequest = false
    var toolName: String?
    var arguments: String?

    init(body: Data) {
        guard !body.isEmpty, let object = try? JSONSerialization.jsonObject(with: body) else { return }
        let first = ((object as? [Any])?.first ?? object) as? [String: Any]
        guard let message = first else { return }
        method = message["method"] as? String
        isRequest = method != nil && message["id"] != nil
        if method == "tools/call", let params = message["params"] as? [String: Any] {
            toolName = params["name"] as? String
            if let arguments = params["arguments"],
                let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
            {
                self.arguments = String(data: data, encoding: .utf8)
            } else {
                arguments = "{}"
            }
        }
    }

    var logFields: [String] {
        var fields: [String] = []
        if let method { fields.append("rpc=\(method)") }
        if let toolName { fields.append("tool=\(toolName)") }
        if let arguments { fields.append("args=\(arguments)") }
        return fields
    }
}
