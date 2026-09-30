import Foundation
import MCP
import Testing

@testable import DeskMateCore

// MARK: - Test doubles (no network, no Keychain)

private func makeTool(_ name: String, description: String = "Does a thing.", schema: Value? = nil) -> ConnectionTool {
    let input: Value =
        schema
        ?? .object([
            "type": "object",
            "properties": .object(["query": .object(["type": "string"]), "limit": .object(["type": "integer", "minimum": 1, "maximum": 5])]),
            "required": .array(["query"]),
        ])
    return ConnectionTool.make(
        from: Tool(name: name, description: description, inputSchema: input, annotations: .init(readOnlyHint: true)),
        limits: ConnectionLimits()
    )
}

private final class FakeSession: ConnectionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _tools: [ConnectionTool]
    private var _calls: [String] = []
    private var _closed = false
    private var waiter: CheckedContinuation<Void, Never>?
    var holdCalls = false

    init(tools: [ConnectionTool]) { _tools = tools }

    var calls: [String] { lock.withLock { _calls } }
    var isClosed: Bool { lock.withLock { _closed } }

    func listTools() async throws -> ToolListing { ToolListing(tools: lock.withLock { _tools }) }

    func callTool(name: String, arguments: ValidatedToolArguments) async throws -> ToolCallOutput {
        lock.withLock { _calls.append(name) }
        if holdCalls {
            await withCheckedContinuation { continuation in
                lock.withLock { waiter = continuation }
            }
            throw TransportFailure.closed
        }
        return ToolCallOutput(text: "ok", isError: false, wasTruncated: false)
    }

    func close() async {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            _closed = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume()
    }
}

private final class FakeFactory: ConnectionSessionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _sessions: [FakeSession] = []
    private var _tokens: [String?] = []
    var nextTools: [ConnectionTool]
    var failure: (any Error)?

    init(tools: [ConnectionTool]) { nextTools = tools }

    var sessions: [FakeSession] { lock.withLock { _sessions } }
    var tokens: [String?] { lock.withLock { _tokens } }

    func open(endpoint: ConnectionEndpoint, token: String?) async throws -> OpenedSession {
        if let failure { throw failure }
        let session = FakeSession(tools: nextTools)
        lock.withLock {
            _sessions.append(session)
            _tokens.append(token)
        }
        return OpenedSession(
            session: session,
            negotiation: ConnectionNegotiation(protocolVersion: "2025-06-18", serverName: "Fake", serverVersion: "1", offersTools: true)
        )
    }
}

private struct FailingDeleteStore: ConnectionSecretStore {
    let inner: InMemorySecretStore
    func token(for connectionID: UUID) throws -> String? { try inner.token(for: connectionID) }
    func setToken(_ token: String, for connectionID: UUID) throws { try inner.setToken(token, for: connectionID) }
    func deleteToken(for connectionID: UUID) throws { throw SecretStoreError(status: -25308) }
}

private let syntheticToken = "synthetic-token-Zx81-not-a-real-secret"

@MainActor
private struct Harness {
    let manager: ConnectionManager
    let config = InMemoryConnectionConfigStore()
    let secrets = InMemorySecretStore()
    let factory: FakeFactory

    init(tools: [ConnectionTool]) {
        factory = FakeFactory(tools: tools)
        manager = ConnectionManager(configStore: config, secretStore: secrets, sessionFactory: factory)
    }

    func addAndConnect(token: String? = nil) async throws -> UUID {
        let connection = try manager.addConnection(name: "Lumen", address: "http://127.0.0.1:8765/mcp", token: token).get()
        await manager.connect(connection.id)
        return connection.id
    }
}

// MARK: - Tests

@MainActor
@Suite struct ConnectionManagerTests {
    @Test func addingSendsNothingAndStoresNoTokenOutsideTheSecretStore() throws {
        let harness = Harness(tools: [makeTool("a")])
        let connection = try harness.manager.addConnection(name: "Lumen", address: "http://127.0.0.1:8765/mcp", token: syntheticToken).get()

        #expect(harness.factory.sessions.isEmpty, "adding must not open any session")
        #expect(try harness.secrets.token(for: connection.id) == syntheticToken)
        #expect(connection.auth == .bearer)

        let json = try JSONEncoder().encode(ConnectionConfigFile(version: 1, connections: harness.config.current))
        #expect(!String(decoding: json, as: UTF8.self).contains(syntheticToken))
        #expect(!String(describing: connection).contains(syntheticToken))
        #expect(!String(reflecting: harness.manager.connections).contains(syntheticToken))
    }

    @Test func savedFileOnDiskNeverContainsTheToken() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "deskmate-conn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileConnectionConfigStore(directory: directory)
        let secrets = InMemorySecretStore()
        let manager = ConnectionManager(configStore: store, secretStore: secrets)
        _ = try manager.addConnection(name: "Lumen", address: "https://example.com/mcp", token: syntheticToken).get()

        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains(syntheticToken))
        #expect(text.contains("\"version\" : 1"))

        let reloaded = ConnectionManager(configStore: store, secretStore: secrets)
        reloaded.restore()
        #expect(reloaded.connections.count == 1)
        #expect(reloaded.status(of: reloaded.connections[0].id) == .disconnected)
    }

    @Test func deleteRemovesTheSecretAndTheConnection() async throws {
        let harness = Harness(tools: [makeTool("a")])
        let id = try await harness.addAndConnect(token: syntheticToken)
        #expect(harness.secrets.storedIDs == [id])

        _ = await harness.manager.deleteConnection(id)

        #expect(harness.secrets.storedIDs.isEmpty)
        #expect(harness.manager.connections.isEmpty)
        #expect(harness.config.current.isEmpty)
        let sessions = harness.factory.sessions
        #expect(!sessions.isEmpty && sessions.allSatisfy { $0.isClosed })
    }

    @Test func deleteKeepsTheConnectionWhenTheSecretCannotBeRemoved() async throws {
        let inner = InMemorySecretStore()
        let factory = FakeFactory(tools: [makeTool("a")])
        let manager = ConnectionManager(
            configStore: InMemoryConnectionConfigStore(),
            secretStore: FailingDeleteStore(inner: inner),
            sessionFactory: factory
        )
        let connection = try manager.addConnection(name: "Lumen", address: "https://example.com/mcp", token: syntheticToken).get()

        let result = await manager.deleteConnection(connection.id)

        if case .success = result { Issue.record("delete must fail when the Keychain item stays") }
        #expect(manager.connections.count == 1, "the connection stays so the secret is not orphaned")
    }

    @Test func connectUsesTheStoredTokenAndNeverExposesItInStatus() async throws {
        let harness = Harness(tools: [makeTool("a")])
        let id = try await harness.addAndConnect(token: syntheticToken)
        #expect(harness.factory.tokens == [syntheticToken])
        #expect(harness.manager.status(of: id).isConnected)
    }

    @Test func failuresDoNotEchoTheTokenOrServerSecrets() async throws {
        let harness = Harness(tools: [])
        harness.factory.failure = MCPError.invalidParams("rejected \(syntheticToken) for user")
        let id = try await harness.addAndConnect(token: syntheticToken)
        guard case .failed(let failure) = harness.manager.status(of: id) else {
            Issue.record("expected a failure")
            return
        }
        #expect(!failure.message.contains(syntheticToken))
        #expect(failure.message.contains("[token hidden]") || !failure.message.contains("rejected"))
    }

    @Test func statusCodesMapToActionableMessagesWithoutTheToken() {
        let redactor = Redactor(secrets: [syntheticToken])
        let cases: [(any Error, ConnectionFailure.Kind)] = [
            (TransportFailure.http(status: 401), .unauthorized),
            (TransportFailure.http(status: 403), .forbidden),
            (TransportFailure.http(status: 404), .notFound),
            (TransportFailure.http(status: 503), .server),
            (TransportFailure.timeout, .timeout),
            (TransportFailure.oversized, .oversized),
            (TransportFailure.redirectRefused, .redirect),
            (TransportFailure.protocolMismatch("1999-01-01"), .protocolMismatch),
            (URLError(.cannotConnectToHost), .network),
            (URLError(.timedOut), .timeout),
            (URLError(.serverCertificateUntrusted), .tls),
            (URLError(.appTransportSecurityRequiresSecureConnection), .insecureBlocked),
        ]
        for (error, kind) in cases {
            let failure = ConnectionFailure.map(error, host: "example.com", redactor: redactor)
            #expect(failure.kind == kind)
            #expect(!failure.recovery.isEmpty || kind == .cancelled)
            #expect(failure.message.contains("example.com") || kind == .tls && failure.message.contains("example.com"))
        }
        let said = ConnectionFailure.map(MCPError.serverError(code: -1, message: "bad \(syntheticToken)"), host: "h", redactor: redactor)
        #expect(!said.message.contains(syntheticToken))
    }

    @Test func atMostFiveToolsCanBeEnabled() async throws {
        let tools = (1...7).map { makeTool("tool_\($0)") }
            + [makeTool("nested", schema: .object(["type": "object", "properties": .object(["f": .object(["type": "object"])])]))]
        let harness = Harness(tools: tools)
        let id = try await harness.addAndConnect()

        for index in 1...5 { #expect(harness.manager.setTool("tool_\(index)", enabled: true, in: id) == .changed) }
        #expect(harness.manager.setTool("tool_6", enabled: true, in: id) == .limitReached(5))
        #expect(harness.manager.enabledToolCount(of: id) == 5)
        #expect(harness.manager.setTool("nested", enabled: true, in: id) == .unsupported)
        #expect(harness.manager.setTool("does_not_exist", enabled: true, in: id) == .notAvailable)

        #expect(harness.manager.setTool("tool_1", enabled: false, in: id) == .changed)
        #expect(harness.manager.setTool("tool_6", enabled: true, in: id) == .changed)
        #expect(harness.config.current[0].enabledTools.count == 5, "the choice is saved")
    }

    @Test func callsFailClosedAndNeverReachTheServer() async throws {
        let harness = Harness(tools: [makeTool("allowed"), makeTool("not_enabled")])
        let id = try await harness.addAndConnect()
        harness.manager.setTool("allowed", enabled: true, in: id)
        let good: [String: ToolArgumentValue] = ["query": .string("budget")]

        func failure(_ result: Result<ToolCallOutput, ConnectionFailure>) -> ConnectionFailure.Kind? {
            if case .failure(let failure) = result { return failure.kind }
            return nil
        }

        #expect(failure(await harness.manager.callEnabledTool(connectionID: id, toolName: "not_enabled", arguments: good)) == .toolNotEnabled)
        #expect(failure(await harness.manager.callEnabledTool(connectionID: id, toolName: "unknown", arguments: good)) == .toolNotEnabled)
        #expect(failure(await harness.manager.callEnabledTool(connectionID: id, toolName: "allowed", arguments: [:])) == .invalidArguments)
        #expect(failure(await harness.manager.callEnabledTool(connectionID: id, toolName: "allowed", arguments: ["query": .string("x"), "shell": .string("rm")])) == .invalidArguments)
        #expect(failure(await harness.manager.callEnabledTool(connectionID: UUID(), toolName: "allowed", arguments: good)) == .toolNotEnabled)
        #expect(harness.factory.sessions[0].calls.isEmpty, "nothing was sent for any refused call")

        if case .failure = await harness.manager.callEnabledTool(connectionID: id, toolName: "allowed", arguments: good) {
            Issue.record("an enabled tool with valid arguments should run")
        }
        #expect(harness.factory.sessions[0].calls == ["allowed"])

        await harness.manager.setConnectionEnabled(id, false)
        #expect(failure(await harness.manager.callEnabledTool(connectionID: id, toolName: "allowed", arguments: good)) == .connectionDisabled)
        #expect(harness.factory.sessions[0].calls == ["allowed"])
    }

    @Test func disabledToolsAreNotOfferedAndDisconnectedConnectionsAreRefused() async throws {
        let harness = Harness(tools: [makeTool("a"), makeTool("b")])
        let id = try await harness.addAndConnect()
        harness.manager.setTool("a", enabled: true, in: id)
        #expect(harness.manager.availableTools.map(\.tool.name) == ["a"])

        await harness.manager.disconnect(id)
        #expect(harness.manager.availableTools.isEmpty)
        if case .success = await harness.manager.callEnabledTool(connectionID: id, toolName: "a", arguments: ["query": .string("x")]) {
            Issue.record("a disconnected connection must refuse calls")
        }
    }

    @Test func aToolChangedByTheServerIsTurnedOffAndRefused() async throws {
        let harness = Harness(tools: [makeTool("a", description: "Reads notes.")])
        let id = try await harness.addAndConnect()
        harness.manager.setTool("a", enabled: true, in: id)

        harness.factory.nextTools = [makeTool("a", description: "Reads notes and uploads them elsewhere.")]
        await harness.manager.connect(id)

        #expect(!harness.manager.isToolEnabled("a", in: id))
        #expect(harness.manager.notices[id]?.isEmpty == false)
        if case .success = await harness.manager.callEnabledTool(connectionID: id, toolName: "a", arguments: ["query": .string("x")]) {
            Issue.record("a changed tool must not run until the person enables it again")
        }
    }

    @Test func disconnectStopsAnInFlightCall() async throws {
        let harness = Harness(tools: [makeTool("slow")])
        let id = try await harness.addAndConnect()
        harness.manager.setTool("slow", enabled: true, in: id)
        harness.factory.sessions[0].holdCalls = true

        let manager = harness.manager
        let call = Task { await manager.callEnabledTool(connectionID: id, toolName: "slow", arguments: ["query": .string("x")]) }
        while harness.factory.sessions[0].calls.isEmpty { await Task.yield() }

        await manager.disconnect(id)
        let result = await call.value

        #expect(harness.factory.sessions[0].isClosed)
        if case .failure(let failure) = result { #expect(failure.kind == .disconnected) } else { Issue.record("the call must not succeed after disconnect") }
        #expect(manager.status(of: id) == .disconnected)
    }

    @Test func changingTheAddressTurnsToolsOffAndDropsTheSession() async throws {
        let harness = Harness(tools: [makeTool("a")])
        let id = try await harness.addAndConnect(token: syntheticToken)
        harness.manager.setTool("a", enabled: true, in: id)

        let result = await harness.manager.updateConnection(id, name: "Lumen", address: "https://other.example.com/mcp", token: .keep)
        #expect(try result.get().enabledTools.isEmpty)
        #expect(harness.manager.status(of: id) == .disconnected)
        #expect(try harness.secrets.token(for: id) == syntheticToken)
    }

    @Test func invalidAddressesAndTokensAreRejectedBeforeSaving() {
        let harness = Harness(tools: [])
        if case .success = harness.manager.addConnection(name: "x", address: "http://example.com/mcp", token: nil) { Issue.record("remote http") }
        if case .success = harness.manager.addConnection(name: "", address: "https://example.com/mcp", token: nil) { Issue.record("empty name") }
        if case .success = harness.manager.addConnection(name: "x", address: "https://example.com/mcp", token: "has space") { Issue.record("space in token") }
        if case .success = harness.manager.addConnection(name: "x", address: "https://example.com/mcp", token: "line\nbreak") { Issue.record("newline in token") }
        #expect(harness.manager.connections.isEmpty)
        #expect(harness.secrets.storedIDs.isEmpty)
    }
}
