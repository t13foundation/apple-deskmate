import DeskMateMCPFixtureKit
import Foundation

// Synthetic loopback MCP server for DeskMate demonstrations and tests.
// Serves fictional “Project Lumen” data. Binds to 127.0.0.1 only. Never use a real credential with it.

let usage = """
    DeskMateMCPFixture: synthetic Streamable HTTP MCP server (127.0.0.1 only, fictional data)

    Usage: DeskMateMCPFixture [options]
      --port <n>          Port to listen on (default 8765; 0 picks a free port)
      --token <value>     Require "Authorization: Bearer <value>". Synthetic values only.
                          The DESKMATE_FIXTURE_TOKEN environment variable does the same without
                          putting the value in the process list.
      --delay <seconds>   Wait before answering each MCP request (timeout demonstrations)
      --oversize          Make replies larger than DeskMate accepts (size-limit demonstration)
      --reject-auth       Answer every request with 401 Unauthorized
      --redirect          Answer every request with a 307 redirect to another host
      --stateless         Use plain JSON replies without sessions (default: sessions with event streams)
      --demo-tools        Add six extra synthetic tools (enum, integer, boolean, two unsupported shapes)
      --run-for <seconds> Stop by itself after this long (for scripted checks)
      --help              Show this text

    Endpoint: http://127.0.0.1:<port>/mcp
    """

var options = FixtureOptions()
options.requiredToken = ProcessInfo.processInfo.environment["DESKMATE_FIXTURE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

var runForSeconds: Double?
var arguments = CommandLine.arguments.dropFirst()[...]
while let flag = arguments.popFirst() {
    func value() -> String {
        guard let next = arguments.popFirst() else { fail("\(flag) needs a value") }
        return next
    }
    switch flag {
    case "--port":
        guard let port = UInt16(value()) else { fail("--port must be a number from 0 to 65535") }
        options.port = port
    case "--token":
        let token = value()
        guard !token.isEmpty else { fail("--token must not be empty") }
        options.requiredToken = token
    case "--delay":
        guard let seconds = Double(value()), seconds >= 0 else { fail("--delay must be a number of seconds") }
        options.delaySeconds = seconds
    case "--oversize": options.oversizedResponses = true
    case "--reject-auth": options.rejectAllAuth = true
    case "--redirect": options.redirectAll = true
    case "--stateless": options.stateless = true
    case "--demo-tools": options.demoTools = true
    case "--run-for":
        guard let seconds = Double(value()), seconds > 0 else { fail("--run-for must be a positive number of seconds") }
        runForSeconds = seconds
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        fail("unknown option \(flag)")
    }
}

let outputLock = NSLock()
func emit(_ line: String) {
    outputLock.withLock {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

options.log = { line in emit("\(Date().formatted(.iso8601)) \(line)") }

let server = FixtureServer(options: options)
do {
    let port = try await server.start()
    emit("DeskMate MCP fixture (synthetic data only, no real credentials)")
    emit("Listening on http://127.0.0.1:\(port)\(options.path) (loopback only)")
    emit("Transport: \(options.stateless ? "stateless JSON replies" : "sessions with event-stream replies")")
    emit(options.rejectAllAuth ? "Auth: every request is answered 401" : options.requiredToken == nil ? "Auth: none" : "Auth: Bearer token required (value not printed)")
    emit("Tools: get_project_status, search_project_notes" + (options.demoTools ? ", list_milestones, get_risk_detail, budget_summary, team_contacts, find_dependencies, bulk_status" : ""))
    if options.delaySeconds > 0 { emit("Delay: \(options.delaySeconds) s per request") }
    if options.oversizedResponses { emit("Replies are padded beyond the client size limit") }
    if options.redirectAll { emit("Every request is answered with a redirect") }
    emit("Request log follows. Press Control-C to stop.")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
for source in [interrupt, terminate] {
    source.setEventHandler {
        emit("Stopping.")
        exit(0)
    }
    source.resume()
}

if let runForSeconds {
    try? await Task.sleep(for: .seconds(runForSeconds))
    emit("Stopping after \(runForSeconds) s.")
    await server.stop()
    exit(0)
}
while true {
    try? await Task.sleep(for: .seconds(3600))
}
