import Foundation
import Observation

public enum ConnectionFormProblem: Error, Sendable, Equatable {
    case nameMissing
    case address(ConnectionEndpoint.Problem)
    case tokenInvalid
    case tooManyConnections(Int)
    case storage(String)

    public var message: String {
        switch self {
        case .nameMissing: "Give the connection a name."
        case .address(let problem): problem.message
        case .tokenInvalid:
            "The token must be a single line of visible characters without spaces (up to 4,096)."
        case .tooManyConnections(let limit): "You can keep up to \(limit) connections. Delete one first."
        case .storage(let text): text
        }
    }
}

public enum TokenChange: Sendable, Equatable {
    case keep
    case replace(String)
    case remove
}

public enum ToolEnableOutcome: Sendable, Equatable {
    case changed
    case limitReached(Int)
    case unsupported
    case notAvailable

    public var message: String? {
        switch self {
        case .changed: nil
        case .limitReached(let limit):
            "You can enable up to \(limit) tools per connection. Turn one off to enable another."
        case .unsupported: "This tool’s inputs use a format DeskMate cannot check, so it cannot be enabled."
        case .notAvailable: "Connect first so DeskMate can see the tool as the service describes it now."
        }
    }
}

/// Result of trying a connection without saving it.
public struct ConnectionProbeReport: Sendable, Equatable {
    public let negotiation: ConnectionNegotiation
    public let listing: ToolListing
}

/// A tool that is ready for the assistant: connected, turned on, enabled by the user and unchanged since.
public struct AvailableTool: Identifiable, Sendable, Equatable {
    public var id: String { "\(connectionID.uuidString)/\(tool.name)" }
    public let connectionID: UUID
    public let connectionName: String
    public let host: String
    public let tool: ConnectionTool
}

public struct ToolCatalog: Sendable, Equatable {
    public var tools: [ConnectionTool]
    public var omittedCount: Int
}

/// Owns connections, their sessions and the rules about which tools may be called.
/// All permission checks live here, outside any model: a call is refused unless the connection is connected and on,
/// the tool is enabled and unchanged, and every argument passes the tool’s stored schema.
@MainActor
@Observable
public final class ConnectionManager {
    public static let maxConnections = 10

    public private(set) var connections: [MCPConnection] = []
    public private(set) var statuses: [UUID: ConnectionStatus] = [:]
    public private(set) var catalogs: [UUID: ToolCatalog] = [:]
    /// Plain-language notes about changes the service made (for example a tool turned off because it changed).
    public private(set) var notices: [UUID: [String]] = [:]
    /// Set when saved connections could not be read or a change could not be saved.
    public private(set) var storageNotice: String?

    @ObservationIgnored private let configStore: any ConnectionConfigStore
    @ObservationIgnored private let secretStore: any ConnectionSecretStore
    @ObservationIgnored private let sessionFactory: any ConnectionSessionFactory
    @ObservationIgnored private let limits: ConnectionLimits

    private struct Live {
        let session: any ConnectionSession
        let generation: Int
        let redactor: Redactor
    }

    @ObservationIgnored private var live: [UUID: Live] = [:]
    @ObservationIgnored private var generations: [UUID: Int] = [:]
    @ObservationIgnored private var connectTasks: [UUID: Task<Void, Never>] = [:]

    public convenience init(
        configStore: any ConnectionConfigStore = FileConnectionConfigStore.standard(),
        secretStore: any ConnectionSecretStore = KeychainSecretStore(),
        limits: ConnectionLimits = ConnectionLimits()
    ) {
        self.init(
            configStore: configStore,
            secretStore: secretStore,
            sessionFactory: MCPSessionFactory(limits: limits),
            limits: limits
        )
    }

    init(
        configStore: any ConnectionConfigStore,
        secretStore: any ConnectionSecretStore,
        sessionFactory: any ConnectionSessionFactory,
        limits: ConnectionLimits = ConnectionLimits()
    ) {
        self.configStore = configStore
        self.secretStore = secretStore
        self.sessionFactory = sessionFactory
        self.limits = limits
    }

    // MARK: Loading

    /// Reads saved connections. Nothing is sent over the network; every connection starts disconnected.
    public func restore() {
        do {
            let loaded = try configStore.load()
            connections = loaded.connections
            storageNotice = loaded.notice
        } catch {
            connections = []
            storageNotice = "Saved connections could not be read. Nothing was changed on disk."
        }
        statuses = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, .disconnected) })
    }

    // MARK: Lookup

    public func connection(_ id: UUID) -> MCPConnection? {
        connections.first { $0.id == id }
    }

    public func status(of id: UUID) -> ConnectionStatus {
        statuses[id] ?? .disconnected
    }

    public func tools(of id: UUID) -> [ConnectionTool] {
        catalogs[id]?.tools ?? []
    }

    public func isToolEnabled(_ name: String, in id: UUID) -> Bool {
        connection(id)?.enabledTools.contains { $0.name == name } ?? false
    }

    public func enabledToolCount(of id: UUID) -> Int {
        connection(id)?.enabledTools.count ?? 0
    }

    public var maxEnabledTools: Int { limits.maxEnabledTools }

    /// Tools the assistant may offer right now. Empty until a connection is connected.
    public var availableTools: [AvailableTool] {
        connections.flatMap { connection -> [AvailableTool] in
            guard connection.isEnabled, status(of: connection.id).isConnected else { return [] }
            return tools(of: connection.id).compactMap { tool in
                guard tool.isEnableable,
                    connection.enabledTools.contains(where: { $0.name == tool.name && $0.fingerprint == tool.fingerprint })
                else { return nil }
                return AvailableTool(
                    connectionID: connection.id,
                    connectionName: connection.name,
                    host: connection.endpoint.displayHost,
                    tool: tool
                )
            }
        }
    }

    // MARK: Validation of form input

    static func cleanedToken(_ text: String?) -> Result<String?, ConnectionFormProblem> {
        guard let text else { return .success(nil) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        guard trimmed.utf8.count <= 4_096, trimmed.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else {
            return .failure(.tokenInvalid)
        }
        return .success(trimmed)
    }

    // MARK: Adding, editing, deleting

    /// Saves a connection. Nothing is sent to the address: there is no network traffic until you choose to connect.
    @discardableResult
    public func addConnection(name: String, address: String, token: String?) -> Result<MCPConnection, ConnectionFormProblem> {
        guard connections.count < Self.maxConnections else { return .failure(.tooManyConnections(Self.maxConnections)) }
        let cleanName = MCPConnection.cleanedName(name)
        guard !cleanName.isEmpty else { return .failure(.nameMissing) }
        let endpoint: ConnectionEndpoint
        switch ConnectionEndpoint.validate(address) {
        case .success(let value): endpoint = value
        case .failure(let problem): return .failure(.address(problem))
        }
        let cleanToken: String?
        switch Self.cleanedToken(token) {
        case .success(let value): cleanToken = value
        case .failure(let problem): return .failure(problem)
        }

        let connection = MCPConnection(name: cleanName, endpoint: endpoint, auth: cleanToken == nil ? .none : .bearer)
        if let cleanToken {
            do { try secretStore.setToken(cleanToken, for: connection.id) } catch let error as SecretStoreError {
                return .failure(.storage(error.message))
            } catch {
                return .failure(.storage("The token could not be saved to the Keychain."))
            }
        }
        connections.append(connection)
        statuses[connection.id] = .disconnected
        if let problem = persist() {
            connections.removeAll { $0.id == connection.id }
            statuses[connection.id] = nil
            try? secretStore.deleteToken(for: connection.id)
            return .failure(.storage(problem))
        }
        return .success(connection)
    }

    /// Changes the name, address or token. A changed address or token ends the session and turns all tools off,
    /// because what was approved for the old service must not carry over to a new one.
    @discardableResult
    public func updateConnection(
        _ id: UUID,
        name: String,
        address: String,
        token: TokenChange
    ) async -> Result<MCPConnection, ConnectionFormProblem> {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return .failure(.storage("That connection no longer exists.")) }
        let cleanName = MCPConnection.cleanedName(name)
        guard !cleanName.isEmpty else { return .failure(.nameMissing) }
        let endpoint: ConnectionEndpoint
        switch ConnectionEndpoint.validate(address) {
        case .success(let value): endpoint = value
        case .failure(let problem): return .failure(.address(problem))
        }
        var replacement: String?
        if case .replace(let text) = token {
            switch Self.cleanedToken(text) {
            case .success(let value) where value != nil: replacement = value
            default: return .failure(.tokenInvalid)
            }
        }

        var updated = connections[index]
        let endpointChanged = updated.endpoint != endpoint
        let tokenChanged = token != .keep
        if endpointChanged || tokenChanged { await disconnect(id) }

        do {
            switch token {
            case .keep: break
            case .replace:
                if let replacement { try secretStore.setToken(replacement, for: id) }
                updated.auth = .bearer
            case .remove:
                try secretStore.deleteToken(for: id)
                updated.auth = .none
            }
        } catch let error as SecretStoreError {
            return .failure(.storage(error.message))
        } catch {
            return .failure(.storage("The token could not be updated in the Keychain."))
        }

        updated.name = cleanName
        updated.endpoint = endpoint
        if endpointChanged || tokenChanged {
            updated.enabledTools = []
            catalogs[id] = nil
            notices[id] = nil
        }
        connections[index] = updated
        if let problem = persist() { return .failure(.storage(problem)) }
        return .success(updated)
    }

    /// Removes the connection and its Keychain token. If the token cannot be removed the connection is kept,
    /// so a secret is never left behind without a way to delete it.
    @discardableResult
    public func deleteConnection(_ id: UUID) async -> Result<Void, ConnectionFormProblem> {
        guard connection(id) != nil else { return .success(()) }
        await disconnect(id)
        do {
            try secretStore.deleteToken(for: id)
        } catch let error as SecretStoreError {
            return .failure(.storage("The connection was not deleted. " + error.message))
        } catch {
            return .failure(.storage("The connection was not deleted because its token could not be removed."))
        }
        connections.removeAll { $0.id == id }
        statuses[id] = nil
        catalogs[id] = nil
        notices[id] = nil
        generations[id] = nil
        if let problem = persist() { return .failure(.storage(problem)) }
        return .success(())
    }

    public func setConnectionEnabled(_ id: UUID, _ isEnabled: Bool) async {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        if !isEnabled { await disconnect(id) }
        connections[index].isEnabled = isEnabled
        _ = persist()
    }

    // MARK: Connecting

    /// Tries an address without saving anything. Used by the add form. Sends only the protocol handshake and a
    /// tool listing request, then disconnects.
    public func probe(address: String, token: String?) async -> Result<ConnectionProbeReport, ConnectionFailure> {
        let endpoint: ConnectionEndpoint
        switch ConnectionEndpoint.validate(address) {
        case .success(let value): endpoint = value
        case .failure(let problem): return .failure(.invalidInput(problem.message))
        }
        let cleanToken: String?
        switch Self.cleanedToken(token) {
        case .success(let value): cleanToken = value
        case .failure(let problem): return .failure(.invalidInput(problem.message))
        }
        let host = endpoint.displayHost
        let redactor = Redactor(secrets: [cleanToken])
        let opened: OpenedSession
        do {
            opened = try await sessionFactory.open(endpoint: endpoint, token: cleanToken)
        } catch {
            return .failure(ConnectionFailure.map(error, host: host, redactor: redactor))
        }
        do {
            let listing = opened.negotiation.offersTools ? try await opened.session.listTools() : ToolListing(tools: [])
            await opened.session.close()
            return .success(ConnectionProbeReport(negotiation: opened.negotiation, listing: listing))
        } catch {
            await opened.session.close()
            return .failure(ConnectionFailure.map(error, host: host, redactor: redactor))
        }
    }

    /// Connects a saved connection and lists its tools. Safe to call again to refresh.
    public func connect(_ id: UUID) async {
        guard let connection = connection(id) else { return }
        guard connection.isEnabled else {
            statuses[id] = .failed(.connectionDisabled())
            return
        }
        if status(of: id).isBusy {
            await connectTasks[id]?.value
            return
        }
        await closeLive(id)
        let generation = bumpGeneration(id)
        statuses[id] = .connecting
        let task = Task { await self.runConnect(connection, generation: generation) }
        connectTasks[id] = task
        await task.value
        if generations[id] == generation { connectTasks[id] = nil }
    }

    private func runConnect(_ connection: MCPConnection, generation: Int) async {
        let id = connection.id
        let host = connection.endpoint.displayHost
        var token: String?
        if connection.auth == .bearer {
            do { token = try secretStore.token(for: id) } catch let error as SecretStoreError {
                statuses[id] = .failed(.storage(error.message))
                return
            } catch {
                statuses[id] = .failed(.missingToken)
                return
            }
            guard token != nil else {
                statuses[id] = .failed(.missingToken)
                return
            }
        }
        let redactor = Redactor(secrets: [token])
        do {
            let opened = try await sessionFactory.open(endpoint: connection.endpoint, token: token)
            guard isCurrent(id, generation) else {
                await opened.session.close()
                return
            }
            let listing: ToolListing
            do {
                listing = opened.negotiation.offersTools ? try await opened.session.listTools() : ToolListing(tools: [])
            } catch {
                await opened.session.close()
                throw error
            }
            guard isCurrent(id, generation) else {
                await opened.session.close()
                return
            }
            live[id] = Live(session: opened.session, generation: generation, redactor: redactor)
            catalogs[id] = ToolCatalog(tools: listing.tools, omittedCount: listing.omittedCount)
            reconcileEnabledTools(for: id, with: listing.tools)
            statuses[id] = .connected(opened.negotiation)
        } catch {
            guard isCurrent(id, generation) else { return }
            statuses[id] = .failed(ConnectionFailure.map(error, host: host, redactor: redactor))
        }
    }

    /// Stops in-flight work, closes the session and forgets the tool listing. Enabled-tool choices are kept.
    public func disconnect(_ id: UUID) async {
        _ = bumpGeneration(id)
        connectTasks[id]?.cancel()
        connectTasks[id] = nil
        await closeLive(id)
        catalogs[id] = nil
        if connection(id) != nil { statuses[id] = .disconnected }
    }

    /// Disconnects everything. Call when the app quits.
    public func disconnectAll() async {
        for connection in connections { await disconnect(connection.id) }
    }

    private func closeLive(_ id: UUID) async {
        guard let session = live.removeValue(forKey: id)?.session else { return }
        await session.close()
    }

    private func bumpGeneration(_ id: UUID) -> Int {
        let next = (generations[id] ?? 0) + 1
        generations[id] = next
        return next
    }

    private func isCurrent(_ id: UUID, _ generation: Int) -> Bool {
        generations[id] == generation && connection(id) != nil
    }

    // MARK: Enabling tools

    /// Turns a tool on or off. Turning on requires a live connection, a supported schema and room under the cap.
    @discardableResult
    public func setTool(_ name: String, enabled: Bool, in id: UUID) -> ToolEnableOutcome {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return .notAvailable }
        if !enabled {
            connections[index].enabledTools.removeAll { $0.name == name }
            _ = persist()
            return .changed
        }
        guard status(of: id).isConnected, let tool = tools(of: id).first(where: { $0.name == name }) else {
            return .notAvailable
        }
        guard tool.isEnableable else { return .unsupported }
        if connections[index].enabledTools.contains(where: { $0.name == name }) {
            connections[index].enabledTools.removeAll { $0.name == name }
        } else if connections[index].enabledTools.count >= limits.maxEnabledTools {
            return .limitReached(limits.maxEnabledTools)
        }
        connections[index].enabledTools.append(EnabledToolRecord(name: name, fingerprint: tool.fingerprint))
        _ = persist()
        return .changed
    }

    /// After a listing: a tool that vanished, became unsupported or was described differently is turned off.
    private func reconcileEnabledTools(for id: UUID, with listed: [ConnectionTool]) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        var kept: [EnabledToolRecord] = []
        var messages: [String] = []
        for record in connections[index].enabledTools {
            let shown = PlainText.sanitizeLine(record.name, limit: 40)
            if let tool = listed.first(where: { $0.name == record.name }) {
                if !tool.isEnableable {
                    messages.append("“\(shown)” now uses inputs DeskMate cannot check, so it was turned off.")
                } else if tool.fingerprint != record.fingerprint {
                    messages.append("“\(shown)” was changed by the service since you enabled it, so it was turned off. Review it and enable it again if you still trust it.")
                } else {
                    kept.append(record)
                }
            } else {
                messages.append("“\(shown)” is no longer offered by the service, so it was turned off.")
            }
        }
        if kept.count != connections[index].enabledTools.count {
            connections[index].enabledTools = Array(kept.prefix(limits.maxEnabledTools))
            _ = persist()
        }
        notices[id] = messages.isEmpty ? nil : messages
    }

    // MARK: Calling tools (for the assistant)

    /// Checks everything a call needs and returns it ready to show for confirmation. Nothing is sent.
    /// Fails closed: a missing, off, changed or unsupported tool or an invalid argument is an error.
    public func prepareToolCall(
        connectionID: UUID,
        toolName: String,
        arguments: [String: ToolArgumentValue]
    ) -> Result<PreparedToolCall, ConnectionFailure> {
        guard let connection = connection(connectionID) else { return .failure(.toolNotEnabled(toolName)) }
        let host = connection.endpoint.displayHost
        guard connection.isEnabled else { return .failure(.connectionDisabled()) }
        guard status(of: connectionID).isConnected, let liveSession = live[connectionID] else {
            return .failure(.notConnected(host: host))
        }
        guard let record = connection.enabledTools.first(where: { $0.name == toolName }) else {
            return .failure(.toolNotEnabled(toolName))
        }
        guard let tool = tools(of: connectionID).first(where: { $0.name == toolName }) else {
            return .failure(.toolNotEnabled(toolName))
        }
        guard tool.fingerprint == record.fingerprint else { return .failure(.toolChanged(toolName)) }
        guard let schema = tool.support.schema else { return .failure(.unsupportedTool(toolName)) }
        switch schema.validate(arguments, limits: limits) {
        case .failure(let error):
            return .failure(.invalidArguments(error))
        case .success(let validated):
            return .success(
                PreparedToolCall(
                    connectionID: connectionID,
                    connectionName: connection.name,
                    host: host,
                    toolName: tool.name,
                    toolDescription: tool.descriptionText,
                    arguments: validated,
                    sessionGeneration: liveSession.generation
                )
            )
        }
    }

    /// Sends a prepared call. Every check runs again first, because the connection may have been turned off,
    /// disconnected or changed while the person was deciding. Output is untrusted text.
    public func execute(_ prepared: PreparedToolCall) async -> Result<ToolCallOutput, ConnectionFailure> {
        let id = prepared.connectionID
        // Re-validate from the stored schema; the prepared value alone is never trusted.
        switch prepareToolCall(connectionID: id, toolName: prepared.toolName, arguments: prepared.arguments.values) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let fresh):
            guard fresh.sessionGeneration == prepared.sessionGeneration, let liveSession = live[id] else {
                return .failure(.disconnected(host: prepared.host))
            }
            do {
                let output = try await liveSession.session.callTool(name: fresh.toolName, arguments: fresh.arguments)
                guard live[id]?.generation == liveSession.generation, status(of: id).isConnected else {
                    return .failure(.disconnected(host: prepared.host))
                }
                return .success(output)
            } catch {
                guard live[id]?.generation == liveSession.generation else {
                    return .failure(.disconnected(host: prepared.host))
                }
                let failure = ConnectionFailure.map(error, host: prepared.host, redactor: liveSession.redactor)
                if Self.endsSession(failure.kind) {
                    await disconnect(id)
                    statuses[id] = .failed(failure)
                }
                return .failure(failure)
            }
        }
    }

    /// Prepare and execute in one step. The caller is responsible for asking the person first.
    public func callEnabledTool(
        connectionID: UUID,
        toolName: String,
        arguments: [String: ToolArgumentValue]
    ) async -> Result<ToolCallOutput, ConnectionFailure> {
        switch prepareToolCall(connectionID: connectionID, toolName: toolName, arguments: arguments) {
        case .failure(let failure): return .failure(failure)
        case .success(let prepared): return await execute(prepared)
        }
    }

    private static func endsSession(_ kind: ConnectionFailure.Kind) -> Bool {
        switch kind {
        case .timeout, .network, .tls, .insecureBlocked, .oversized, .redirect, .invalidResponse, .unauthorized,
            .forbidden, .notFound, .disconnected, .protocolMismatch:
            true
        default:
            false
        }
    }

    // MARK: Persistence

    private func persist() -> String? {
        do {
            try configStore.save(connections)
            return nil
        } catch {
            let text = "Your connections could not be saved to disk."
            storageNotice = text
            return text
        }
    }
}
