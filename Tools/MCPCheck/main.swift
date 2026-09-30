import DeskMateCore
import DeskMateMCPFixtureKit
import Foundation

// Headless client check. Drives the same ConnectionManager the app uses (Streamable HTTP, protocol negotiation,
// tool listing, enable cap, validated calls, delete) against one endpoint and prints what happened.
// Stores are in memory, so nothing is written to the Keychain or to disk. Use synthetic endpoints and tokens only.

let usage = """
    DeskMateMCPCheck: headless check of DeskMate's MCP client against one endpoint

    Usage: DeskMateMCPCheck <url> [options]
      --token <value>                Bearer token (or set DESKMATE_CHECK_TOKEN). Synthetic values only.
      --enable <name,name,...>       Tools to enable after connecting (default: every supported tool, up to the cap)
      --call <tool> [key=value ...]  Call a tool through the manager after the checks. Repeatable.
                                     A tool that is not enabled, or invalid arguments, are refused before any request.
      --wait <seconds>               Keep retrying while the endpoint is unreachable (server still starting)
      --request-timeout <seconds>    Per-request deadline (default 15)
      --self-host                    Run the synthetic fixture inside this process (no <url> needed) and print its request log
        --host-token <v> --host-delay <s> --host-oversize --host-reject-auth --host-redirect --host-stateless --host-demo-tools
      --help                         Show this text

    Example: DeskMateMCPCheck http://127.0.0.1:8765/mcp --call get_project_status project="Project Lumen"
    """

struct Plan {
    var address = ""
    var token: String? = ProcessInfo.processInfo.environment["DESKMATE_CHECK_TOKEN"]
    var enable: [String]?
    var waitSeconds: Double = 0
    var calls: [(tool: String, arguments: [String: ToolArgumentValue])] = []
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("error: \(text)\n\n\(usage)\n".utf8))
    exit(2)
}

func parseValue(_ text: String) -> ToolArgumentValue {
    if let number = Int(text) { return .integer(number) }
    if let number = Double(text) { return .number(number) }
    if text == "true" { return .boolean(true) }
    if text == "false" { return .boolean(false) }
    return .string(text)
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

var plan = Plan()
var selfHost = false
var hostOptions = FixtureOptions()
var limits = ConnectionLimits()
var words = CommandLine.arguments.dropFirst()[...]
while let word = words.popFirst() {
    switch word {
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--token":
        guard let value = words.popFirst() else { fail("--token needs a value") }
        plan.token = value
    case "--wait":
        guard let value = words.popFirst(), let seconds = Double(value), seconds >= 0 else { fail("--wait needs a number of seconds") }
        plan.waitSeconds = seconds
    case "--enable":
        guard let value = words.popFirst() else { fail("--enable needs tool names") }
        plan.enable = value.split(separator: ",").map(String.init)
    case "--call":
        guard let tool = words.popFirst() else { fail("--call needs a tool name") }
        var arguments: [String: ToolArgumentValue] = [:]
        while let next = words.first, !next.hasPrefix("--") {
            words.removeFirst()
            guard let equals = next.firstIndex(of: "=") else { fail("arguments look like key=value, got “\(next)”") }
            arguments[String(next[..<equals])] = parseValue(String(next[next.index(after: equals)...]))
        }
        plan.calls.append((tool, arguments))
    case "--self-host": selfHost = true
    case "--host-token":
        guard let value = words.popFirst() else { fail("--host-token needs a value") }
        hostOptions.requiredToken = value
    case "--host-delay":
        guard let value = words.popFirst(), let seconds = Double(value) else { fail("--host-delay needs seconds") }
        hostOptions.delaySeconds = seconds
    case "--host-oversize": hostOptions.oversizedResponses = true
    case "--host-reject-auth": hostOptions.rejectAllAuth = true
    case "--host-redirect": hostOptions.redirectAll = true
    case "--host-stateless": hostOptions.stateless = true
    case "--host-demo-tools": hostOptions.demoTools = true
    case "--request-timeout":
        guard let value = words.popFirst(), let seconds = Double(value), seconds > 0 else { fail("--request-timeout needs seconds") }
        limits.requestTimeout = seconds
    default:
        guard plan.address.isEmpty, !word.hasPrefix("--") else { fail("unexpected argument \(word)") }
        plan.address = word
    }
}
guard selfHost || !plan.address.isEmpty else { fail("an endpoint URL is required (or use --self-host)") }

func line(_ text: String) { print(text) }

// With --self-host the synthetic fixture runs inside this process on a free 127.0.0.1 port. The client still talks to
// it over real HTTP through the same code the app uses; the fixture's request log is printed at the end.
let hostLog = LogBox()
var hostServer: FixtureServer?
if selfHost {
    hostOptions.port = 0
    hostOptions.log = { hostLog.add($0) }
    let server = FixtureServer(options: hostOptions)
    do {
        let port = try await server.start()
        plan.address = "http://127.0.0.1:\(port)\(hostOptions.path)"
        hostServer = server
        line("Self-hosted synthetic fixture listening on \(plan.address) (loopback only, in this process)")
    } catch {
        line("Could not start the self-hosted fixture: \(error)")
        exit(1)
    }
}

@MainActor
func finish(_ code: Int32) async -> Never {
    if let hostServer {
        await hostServer.stop()
        line("")
        line("Fixture request log (what the server actually received):")
        for entry in hostLog.all { line("   " + entry) }
    }
    exit(code)
}

func describe(_ tool: ConnectionTool) {
    let claim = tool.serverClaimsReadOnly.map { $0 ? "server claims read-only" : "server does not claim read-only" } ?? "no read-only claim"
    line("  - \(tool.name) [\(claim)]")
    if !tool.descriptionText.isEmpty { line("      description (untrusted text): \(tool.descriptionText)") }
    switch tool.support {
    case .supported(let schema):
        for property in schema.properties {
            line("      input \(property.name): \(property.kindLabel)\(property.isRequired ? ", required" : "")")
        }
        if schema.properties.isEmpty { line("      no inputs") }
    case .unsupported(let reasons):
        line("      UNSUPPORTED, cannot be enabled: \(reasons.joined(separator: " "))")
    }
}

let secrets = InMemorySecretStore()
let manager = ConnectionManager(configStore: InMemoryConnectionConfigStore(), secretStore: secrets, limits: limits)

switch ConnectionEndpoint.validate(plan.address) {
case .failure(let problem):
    line("Address rejected before any request: \(problem.message)")
    await finish(1)
case .success(let endpoint):
    line("Endpoint: host \(endpoint.displayHost)\(endpoint.isLoopbackDevelopment ? " (local development connection, plain HTTP on loopback)" : " (HTTPS)")")
    line("This connection sends data to \(endpoint.displayHost).")
}

line("")
line("1. Test connection (handshake and tool listing, nothing saved)")
var probeResult = await manager.probe(address: plan.address, token: plan.token)
if plan.waitSeconds > 0 {
    let deadline = Date().addingTimeInterval(plan.waitSeconds)
    while case .failure(let failure) = probeResult, failure.kind == .network, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(300))
        probeResult = await manager.probe(address: plan.address, token: plan.token)
    }
}
switch probeResult {
case .failure(let failure):
    line("   FAILED [\(failure.kind)]: \(failure.message)")
    await finish(1)
case .success(let report):
    line("   Negotiated protocol version \(report.negotiation.protocolVersion)")
    line("   Server: \(report.negotiation.serverName) \(report.negotiation.serverVersion)")
    line("   Tools listed: \(report.listing.tools.count)\(report.listing.omittedCount > 0 ? " (+\(report.listing.omittedCount) omitted)" : "")")
    for tool in report.listing.tools { describe(tool) }
}

line("")
line("2. Save, connect, enable tools")
let id: UUID
switch manager.addConnection(name: "Check", address: plan.address, token: plan.token) {
case .failure(let problem):
    line("   Could not save: \(problem.message)")
    await finish(1)
case .success(let connection):
    id = connection.id
}
await manager.connect(id)
switch manager.status(of: id) {
case .connected(let negotiation):
    line("   Connected, protocol \(negotiation.protocolVersion), \(manager.tools(of: id).count) tools")
default:
    line("   Not connected: \(manager.status(of: id))")
    await finish(1)
}

let candidates = plan.enable ?? manager.tools(of: id).filter(\.isEnableable).map(\.name)
for name in candidates {
    let outcome = manager.setTool(name, enabled: true, in: id)
    line("   enable \(name): \(outcome == .changed ? "enabled" : outcome.message ?? "refused")")
}
line("   Enabled \(manager.enabledToolCount(of: id)) here; \(manager.totalEnabledToolCount) of at most \(manager.maxEnabledTools) in total across all connections")
for tool in manager.tools(of: id) where !tool.isEnableable && plan.enable == nil {
    line("   \(tool.name): \(manager.setTool(tool.name, enabled: true, in: id).message ?? "?")")
}

if !plan.calls.isEmpty {
    line("")
    line("3. Calls through the manager (validated, fail-closed)")
    for call in plan.calls {
        let shown = call.arguments.keys.sorted().joined(separator: ", ")
        line("   call \(call.tool)(\(shown))")
        switch await manager.callEnabledTool(connectionID: id, toolName: call.tool, arguments: call.arguments) {
        case .success(let output):
            line("   -> \(output.isError ? "tool reported an error" : "ok"):")
            for text in output.text.split(separator: "\n", omittingEmptySubsequences: false) { line("      \(text)") }
        case .failure(let failure):
            line("   -> refused or failed [\(failure.kind)]: \(failure.message)")
        }
    }
}

line("")
line("4. Disconnect and delete")
await manager.disconnect(id)
line("   Status after disconnect: \(manager.status(of: id))")
let tokenBefore = (try? secrets.token(for: id)) != nil
_ = await manager.deleteConnection(id)
let tokenAfter = (try? secrets.token(for: id)) != nil
line("   Token stored before delete: \(tokenBefore); after delete: \(tokenAfter)")
line("   Connections remaining: \(manager.connections.count)")
await finish(0)
