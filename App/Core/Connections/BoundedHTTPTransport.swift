import Foundation
import Logging
import MCP

/// Refuses every redirect. A redirect could move a Bearer token or request to another host, so the 3xx answer is
/// returned to the transport, which reports it instead of following it.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Reads Server-Sent Events from a byte stream one line at a time, with a hard cap on the bytes accepted.
struct ServerSentEventParser {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName = ""

    /// Feeds one byte. Returns a complete message payload when an event ends.
    mutating func feed(_ byte: UInt8) -> Data? {
        if byte == 0x0A {
            defer { line.removeAll(keepingCapacity: true) }
            return consumeLine()
        }
        line.append(byte)
        return nil
    }

    /// Flushes an event that was not terminated by a blank line when the stream ends.
    mutating func finish() -> Data? {
        var result: Data?
        if !line.isEmpty { result = consumeLine() }
        return result ?? dispatch()
    }

    private mutating func consumeLine() -> Data? {
        if line.last == 0x0D { line.removeLast() }
        if line.isEmpty { return dispatch() }
        guard let text = String(bytes: line, encoding: .utf8) else { return nil }
        if text.hasPrefix(":") { return nil }
        let name: String
        var value: String
        if let colon = text.firstIndex(of: ":") {
            name = String(text[..<colon])
            value = String(text[text.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            name = text
            value = ""
        }
        switch name {
        case "data": dataLines.append(value)
        case "event": eventName = value
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> Data? {
        defer {
            dataLines.removeAll()
            eventName = ""
        }
        guard !dataLines.isEmpty, eventName.isEmpty || eventName == "message" else { return nil }
        // Some servers send a priming event with no data; it carries nothing to deliver.
        let payload = dataLines.joined(separator: "\n")
        guard !payload.isEmpty else { return nil }
        return Data(payload.utf8)
    }
}

/// A Streamable HTTP client transport for the MCP SDK with the guarantees DeskMate needs and the SDK's own transport
/// does not give: no redirects, no cookies, no caching, bounded reply sizes, a total deadline per request, status codes
/// reported as `TransportFailure`, and no server text in error paths.
///
/// Every request is one POST whose reply (JSON or an event stream) is read to its matching response and then closed.
/// No long-lived listening stream is opened.
actor BoundedHTTPTransport: Transport {
    nonisolated let logger: Logger

    private let endpoint: URL
    private let token: String?
    private let limits: ConnectionLimits
    private let urlSession: URLSession

    private var sessionID: String?
    private var protocolVersion: String?
    private var isConnected = false
    private var stream: AsyncThrowingStream<Data, Swift.Error>?
    private var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var inFlight: [UUID: Task<Void, Swift.Error>] = [:]
    private var expired: Set<UUID> = []

    init(endpoint: ConnectionEndpoint, token: String?, limits: ConnectionLimits) {
        self.endpoint = endpoint.url
        self.token = token
        self.limits = limits
        self.logger = Logger(label: "deskmate.mcp.transport") { _ in SwiftLogNoOpLogHandler() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = limits.requestTimeout
        configuration.timeoutIntervalForResource = max(limits.requestTimeout, limits.toolCallTimeout) + 5
        configuration.httpMaximumConnectionsPerHost = 2
        self.urlSession = URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }

    // MARK: Transport

    func connect() async throws {
        guard !isConnected else { return }
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
        isConnected = true
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        continuation?.finish()
        continuation = nil
        stream = nil
        endRemoteSession()
        urlSession.finishTasksAndInvalidate()
    }

    func send(_ data: Data) async throws {
        guard isConnected else { throw TransportFailure.closed }
        let plan = RequestPlan(body: data, limits: limits)
        let id = UUID()
        let work = Task { try await self.perform(data, plan: plan) }
        inFlight[id] = work
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(plan.timeout))
            guard !Task.isCancelled else { return }
            await self?.expire(id)
        }
        defer {
            timer.cancel()
            inFlight[id] = nil
            expired.remove(id)
        }
        do {
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            if expired.contains(id) { throw TransportFailure.timeout }
            throw error
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream ?? AsyncThrowingStream { $0.finish() }
    }

    // MARK: Request handling

    private func expire(_ id: UUID) {
        guard let task = inFlight[id] else { return }
        expired.insert(id)
        task.cancel()
    }

    /// What the outgoing JSON-RPC message expects back, derived before it is sent.
    private struct RequestPlan: Sendable {
        var expectedResponseKeys: Set<String> = []
        var timeout: TimeInterval

        init(body: Data, limits: ConnectionLimits) {
            timeout = limits.requestTimeout
            guard let object = try? JSONSerialization.jsonObject(with: body) else { return }
            let messages = (object as? [Any]) ?? [object]
            for case let message as [String: Any] in messages {
                guard let method = message["method"] as? String, let key = Self.key(message["id"]) else { continue }
                expectedResponseKeys.insert(key)
                if method == "tools/call" { timeout = limits.toolCallTimeout }
            }
        }

        static func key(_ value: Any?) -> String? {
            if let text = value as? String { return "s:" + text }
            if let number = value as? NSNumber { return "n:\(number.intValue)" }
            return nil
        }
    }

    private func perform(_ body: Data, plan: RequestPlan) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = limits.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportFailure.invalidResponse }

        if (300..<400).contains(http.statusCode) { throw TransportFailure.redirectRefused }
        guard (200..<300).contains(http.statusCode) else { throw TransportFailure.http(status: http.statusCode) }
        if http.expectedContentLength > Int64(limits.maxResponseBytes) { throw TransportFailure.oversized }

        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id"), Self.isPlausibleSessionID(id) {
            sessionID = id
        }

        var pending = plan.expectedResponseKeys
        if http.statusCode == 202 || http.expectedContentLength == 0 {
            if pending.isEmpty { return }
            throw TransportFailure.invalidResponse
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        var total = 0

        if contentType.hasPrefix("text/event-stream") {
            var parser = ServerSentEventParser()
            for try await byte in bytes {
                total += 1
                if total > limits.maxResponseBytes { throw TransportFailure.oversized }
                if let payload = parser.feed(byte) {
                    try deliver(payload, pending: &pending)
                    if !plan.expectedResponseKeys.isEmpty, pending.isEmpty { return }
                }
            }
            if let payload = parser.finish() { try deliver(payload, pending: &pending) }
        } else if contentType.hasPrefix("application/json") {
            var collected = Data()
            for try await byte in bytes {
                total += 1
                if total > limits.maxResponseBytes { throw TransportFailure.oversized }
                collected.append(byte)
            }
            if !collected.isEmpty { try deliver(collected, pending: &pending) }
        } else {
            throw TransportFailure.invalidResponse
        }

        if !pending.isEmpty { throw TransportFailure.invalidResponse }
    }

    /// Checks one JSON-RPC payload and hands it to the SDK client.
    private func deliver(_ payload: Data, pending: inout Set<String>) throws {
        guard let object = try? JSONSerialization.jsonObject(with: payload) else { throw TransportFailure.invalidResponse }
        let messages = (object as? [Any]) ?? [object]
        for case let message as [String: Any] in messages {
            if let result = message["result"] as? [String: Any], let version = result["protocolVersion"] as? String {
                guard Version.supported.contains(version) else { throw TransportFailure.protocolMismatch(version) }
                protocolVersion = version
            }
            if message["method"] == nil, message["result"] != nil || message["error"] != nil,
                let key = RequestPlan.key(message["id"])
            {
                pending.remove(key)
            }
        }
        guard isConnected else { throw TransportFailure.closed }
        continuation?.yield(payload)
    }

    private static func isPlausibleSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    /// Politely ends the server-side session. Best effort; failure does not matter.
    private func endRemoteSession() {
        guard let sessionID else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 3
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        urlSession.dataTask(with: request) { _, _, _ in }.resume()
        self.sessionID = nil
    }
}
