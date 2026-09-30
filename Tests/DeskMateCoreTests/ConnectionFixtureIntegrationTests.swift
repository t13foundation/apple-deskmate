import DeskMateMCPFixtureKit
import Foundation
import Testing

@testable import DeskMateCore

// These tests start the synthetic fixture server in this process on an ephemeral 127.0.0.1 port and talk to it with the
// real client stack (MCP Swift SDK over the bounded transport). Data is fictional; the token is a synthetic value.

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

private let fixtureToken = "synthetic-fixture-token-7F3a"

@MainActor
private func withFixture<T>(
    configure: (inout FixtureOptions) -> Void = { _ in },
    limits: ConnectionLimits = ConnectionLimits(),
    _ body: (ConnectionManager, String, LogBox) async throws -> T
) async throws -> T {
    let log = LogBox()
    var options = FixtureOptions()
    options.port = 0
    options.log = { log.add($0) }
    configure(&options)
    let server = FixtureServer(options: options)
    let port = try await server.start()
    let manager = ConnectionManager(configStore: InMemoryConnectionConfigStore(), secretStore: InMemorySecretStore(), limits: limits)
    do {
        let result = try await body(manager, "http://127.0.0.1:\(port)/mcp", log)
        await manager.disconnectAll()
        await server.stop()
        return result
    } catch {
        await manager.disconnectAll()
        await server.stop()
        throw error
    }
}

@MainActor
@Suite(.serialized) struct ConnectionFixtureIntegrationTests {
    @Test func negotiatesAndListsExactlyTheTwoRetrievalToolsWithTheirSchemas() async throws {
        try await withFixture { manager, address, _ in
            let report = try await manager.probe(address: address, token: nil).get()
            #expect(["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(report.negotiation.protocolVersion))
            #expect(report.listing.tools.map(\.name) == ["get_project_status", "search_project_notes"])
            let search = try #require(report.listing.tools.last?.support.schema)
            #expect(search.requiredNames == ["query"])
            #expect(search.properties.first { $0.name == "limit" }?.maximum == 10)
            #expect(report.listing.tools.allSatisfy { $0.serverClaimsReadOnly == true })
        }
    }

    @Test func worksWithAStatelessJsonServerToo() async throws {
        try await withFixture(configure: { $0.stateless = true }) { manager, address, _ in
            let report = try await manager.probe(address: address, token: nil).get()
            #expect(report.listing.tools.count == 2)
        }
    }

    @Test func callsAnEnabledToolWithValidatedArgumentsAndDeniedCallsNeverReachTheServer() async throws {
        try await withFixture { manager, address, log in
            let connection = try manager.addConnection(name: "Lumen", address: address, token: nil).get()
            await manager.connect(connection.id)
            #expect(manager.status(of: connection.id).isConnected)
            #expect(manager.setTool("get_project_status", enabled: true, in: connection.id) == .changed)

            // Denied: not enabled, unknown, invalid arguments.
            for (name, arguments) in [
                ("search_project_notes", ["query": ToolArgumentValue.string("budget")]),
                ("delete_everything", ["query": .string("x")]),
                ("get_project_status", [:]),
                ("get_project_status", ["project": .string("Lumen"), "path": .string("/etc/passwd")]),
            ] {
                if case .success = await manager.callEnabledTool(connectionID: connection.id, toolName: name, arguments: arguments) {
                    Issue.record("\(name) should have been denied")
                }
            }
            #expect(!log.all.contains { $0.contains("tools/call") }, "no tools/call request may be sent for denied calls")

            // Allowed.
            let output = try await manager.callEnabledTool(
                connectionID: connection.id, toolName: "get_project_status", arguments: ["project": .string("Project Lumen")]
            ).get()
            // The overlap matches Fixtures/Library (plan version 2); the live-status facts exist only in the service.
            #expect(output.text.contains("Launch target: 28 July 2026"))
            #expect(output.text.contains("Status: At risk"))
            #expect(output.text.contains("Status date: 14 July 2026"))
            #expect(output.text.contains("Reported by: Priya Raman (project lead)"))
            #expect(output.text.contains("Open risks: 3"))
            #expect(output.text.contains("Next milestone: Go/no-go review on 21 July 2026"))
            #expect(!output.text.contains("14 October"))
            #expect(!output.text.contains("Dana Whitfield"))
            let calls = log.all.filter { $0.contains("rpc=tools/call") }
            #expect(calls.count == 1)
            #expect(calls[0].contains("tool=get_project_status"))
            #expect(calls[0].contains("Project Lumen"))
            #expect(!log.all.contains { $0.contains("search_project_notes") && $0.contains("tools/call") })
        }
    }

    @Test func statusAndNotesAgreeWithTheCurrentPlanFileAndAddFactsOnlyTheServiceHas() async throws {
        // Fixtures/Library is canonical. Read the current plan (version 2) and check the overlap instead of copying values.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plan = try String(contentsOf: repository.appendingPathComponent("Fixtures/Library/lumen-plan-v2.md"), encoding: .utf8)
        #expect(plan.contains("Launch: 28 July 2026"))
        #expect(plan.contains("EUR 52,500"))
        #expect(plan.contains("Project lead: Priya Raman"))
        #expect(plan.contains("owned by Nadia Okafor"))

        try await withFixture { manager, address, _ in
            let connection = try manager.addConnection(name: "Lumen", address: address, token: nil).get()
            await manager.connect(connection.id)
            #expect(manager.setTool("get_project_status", enabled: true, in: connection.id) == .changed)
            #expect(manager.setTool("search_project_notes", enabled: true, in: connection.id) == .changed)

            let status = try await manager.callEnabledTool(
                connectionID: connection.id, toolName: "get_project_status", arguments: ["project": .string("Project Lumen")]
            ).get().text
            #expect(status.contains("28 July 2026"))
            #expect(status.contains("EUR 52,500"))
            #expect(!status.contains("48,000") && !status.contains("14 June"), "version 1 values must not appear")

            let notes = try await manager.callEnabledTool(
                connectionID: connection.id, toolName: "search_project_notes",
                arguments: ["query": .string("Is the launch date in our plan still on track?"), "limit": .integer(3)]
            ).get().text
            #expect(notes.contains("N-103"), "the shipment slip that puts the date at risk is the best match")
            #expect(notes.contains("at risk"))
            #expect(notes.contains("- N-"), "each note carries its ID")
            #expect(notes.count < 1500, "responses stay small")
            #expect(!notes.contains("Dana") && !notes.contains("14 October"))
        }
    }

    @Test func bearerTokenIsRequiredAcceptedAndNeverLeaksIntoMessagesOrTheServerLog() async throws {
        try await withFixture(configure: { $0.requiredToken = fixtureToken }) { manager, address, log in
            // Missing token: the service answers 401.
            guard case .failure(let missing) = await manager.probe(address: address, token: nil) else {
                Issue.record("a missing token must be refused")
                return
            }
            #expect(missing.kind == .unauthorized)

            // Wrong token: 401, and the wrong value is not echoed.
            guard case .failure(let wrong) = await manager.probe(address: address, token: "synthetic-wrong-token-1") else {
                Issue.record("a wrong token must be refused")
                return
            }
            #expect(wrong.kind == .unauthorized)
            #expect(!wrong.message.contains("synthetic-wrong-token-1"))

            // Right token works.
            let report = try await manager.probe(address: address, token: fixtureToken).get()
            #expect(report.listing.tools.count == 2)
            #expect(!log.all.contains { $0.contains(fixtureToken) || $0.contains("synthetic-wrong-token-1") })
            #expect(log.all.contains { $0.contains("auth=ok") })
        }
    }

    @Test func rejectedSignInIsReportedAsUnauthorized() async throws {
        try await withFixture(configure: { $0.rejectAllAuth = true }) { manager, address, _ in
            guard case .failure(let failure) = await manager.probe(address: address, token: fixtureToken) else {
                Issue.record("expected 401")
                return
            }
            #expect(failure.kind == .unauthorized)
            #expect(!failure.message.contains(fixtureToken))
            #expect(!failure.recovery.isEmpty)
        }
    }

    @Test func aSlowServerIsReportedAsATimeout() async throws {
        var limits = ConnectionLimits()
        limits.requestTimeout = 1
        try await withFixture(configure: { $0.delaySeconds = 4 }, limits: limits) { manager, address, _ in
            let started = Date()
            guard case .failure(let failure) = await manager.probe(address: address, token: nil) else {
                Issue.record("expected a timeout")
                return
            }
            #expect(failure.kind == .timeout)
            #expect(Date().timeIntervalSince(started) < 3.5, "the deadline, not the server, decides when to give up")
        }
    }

    @Test func anOversizedReplyIsStopped() async throws {
        try await withFixture(configure: { $0.oversizedResponses = true }) { manager, address, _ in
            guard case .failure(let failure) = await manager.probe(address: address, token: nil) else {
                Issue.record("expected the reply to be refused as too large")
                return
            }
            #expect(failure.kind == .oversized)
        }
    }

    @Test func aRedirectIsNotFollowed() async throws {
        try await withFixture(configure: { $0.redirectAll = true }) { manager, address, log in
            guard case .failure(let failure) = await manager.probe(address: address, token: fixtureToken) else {
                Issue.record("expected the redirect to be refused")
                return
            }
            #expect(failure.kind == .redirect)
            #expect(log.all.count == 1, "only the original request was made")
        }
    }

    @Test func aWrongPathIsReportedAsNotFound() async throws {
        try await withFixture { manager, address, _ in
            guard case .failure(let failure) = await manager.probe(address: address + "x", token: nil) else {
                Issue.record("expected 404")
                return
            }
            #expect(failure.kind == .notFound)
        }
    }

    @Test func nothingIsReachableOnAClosedPort() async throws {
        let manager = ConnectionManager(configStore: InMemoryConnectionConfigStore(), secretStore: InMemorySecretStore())
        guard case .failure(let failure) = await manager.probe(address: "http://127.0.0.1:1/mcp", token: nil) else {
            Issue.record("expected a network failure")
            return
        }
        #expect(failure.kind == .network)
    }

    @Test func demoToolsShowTheCapAndTheUnsupportedExplanation() async throws {
        try await withFixture(configure: { $0.demoTools = true }) { manager, address, _ in
            let connection = try manager.addConnection(name: "Lumen", address: address, token: nil).get()
            await manager.connect(connection.id)
            let tools = manager.tools(of: connection.id)
            #expect(tools.count == 8)
            #expect(tools.filter { !$0.isEnableable }.map(\.name).sorted() == ["bulk_status", "find_dependencies"])
            #expect(tools.filter { !$0.isEnableable }.allSatisfy { !$0.support.reasons.isEmpty })
            var outcomes: [ToolEnableOutcome] = []
            for tool in tools where tool.isEnableable { outcomes.append(manager.setTool(tool.name, enabled: true, in: connection.id)) }
            #expect(outcomes.filter { $0 == .changed }.count == 5)
            #expect(outcomes.contains(.limitReached(5)))
        }
    }
}
