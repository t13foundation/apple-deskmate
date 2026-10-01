import Foundation

/// What one tool call looked like to the person: the service, the tool and the exact inputs. Display text only.
public struct ToolCallArgument: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One MCP call the model asked for, as shown under the answer. Lives in memory with the message.
/// Only `summaryLine` is ever saved: no inputs, no response, no headers.
public struct ToolCallRecord: Identifiable, Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Waiting for the person to allow or deny.
        case awaitingApproval
        /// Allowed once; the request is in flight.
        case running
        /// Allowed and answered.
        case succeeded
        /// Allowed, but the service or the connection failed. The text is a short plain-language reason.
        case failed(String)
        /// The person said no. Nothing was sent.
        case denied
        /// Refused by DeskMate before asking (call limit, invalid inputs, tool turned off, no room). Nothing was sent.
        case notRun(String)
        /// Stop was pressed.
        case cancelled
    }

    public let id: UUID
    public var connectionName: String
    public var host: String
    public var toolName: String
    public var arguments: [ToolCallArgument]
    public var outcome: Outcome
    /// The label the model may cite, e.g. "M1". Set only when the call returned a result.
    public var label: String?
    /// True once a request may have left this Mac. Never true for a denied or refused call.
    public var sentRequest: Bool

    public init(
        id: UUID = UUID(),
        connectionName: String,
        host: String,
        toolName: String,
        arguments: [ToolCallArgument] = [],
        outcome: Outcome,
        label: String? = nil,
        sentRequest: Bool = false
    ) {
        self.id = id
        self.connectionName = connectionName
        self.host = host
        self.toolName = toolName
        self.arguments = arguments
        self.outcome = outcome
        self.label = label
        self.sentRequest = sentRequest
    }

    public var isFinished: Bool {
        switch outcome {
        case .awaitingApproval, .running: false
        default: true
        }
    }

    /// One word for the state, as the activity list shows it.
    public var statusWord: String {
        switch outcome {
        case .awaitingApproval: "waiting for you"
        case .running: "approved, running"
        case .succeeded: "approved"
        case .failed: "approved, failed"
        case .denied: "denied"
        case .notRun: "not run"
        case .cancelled: sentRequest ? "approved, stopped" : "stopped"
        }
    }

    /// The plain-language detail line under the status, when there is one.
    public var detail: String? {
        switch outcome {
        case .failed(let reason), .notRun(let reason): reason
        case .denied: "You declined. Nothing was sent."
        case .cancelled: sentRequest ? "Stopped. The service may already have received the request." : "Stopped before anything was sent."
        default: nil
        }
    }

    /// The single visible line saved with the answer. It carries no inputs, no response and no secrets.
    public var summaryLine: String {
        let place = "\(Self.line(connectionName, limit: 40)) (\(Self.line(host, limit: 60))): \(Self.line(toolName, limit: 40))"
        let tag = label.map { "[\($0)] " } ?? ""
        switch outcome {
        case .succeeded, .running, .awaitingApproval:
            return "\(tag)Asked \(place) (approved)"
        case .failed(let reason):
            return "Asked \(place) (approved, failed: \(Self.line(reason, limit: 80)))"
        case .denied:
            return "Declined \(place) (denied, nothing sent)"
        case .notRun(let reason):
            return "Not sent to \(place) (\(Self.line(reason, limit: 80)))"
        case .cancelled:
            return sentRequest ? "Asked \(place) (approved, stopped)" : "Not sent to \(place) (stopped)"
        }
    }

    private static func line(_ text: String, limit: Int) -> String {
        PlainText.sanitizeLine(text, limit: limit)
    }

    /// Joins one line per call. Nil when there were no calls. A call that never finished (the app was closed or the
    /// answer was stopped) is saved as stopped, never as approved or successful.
    public static func summary(of calls: [ToolCallRecord]) -> String? {
        let lines = calls.map { call -> String in
            var call = call
            switch call.outcome {
            case .awaitingApproval:
                call.outcome = .cancelled
                call.sentRequest = false
            case .running:
                call.outcome = .cancelled
                call.sentRequest = true
            default:
                break
            }
            return call.summaryLine
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Hosts that a request may have reached, in order, without repeats.
    public static func remoteHosts(of calls: [ToolCallRecord]) -> [String] {
        var seen: [String] = []
        for call in calls where call.sentRequest && !seen.contains(call.host) { seen.append(call.host) }
        return seen
    }

    /// Hosts named by saved summary lines that say a request was made ("Asked ...").
    public static func remoteHosts(inSummary summary: String?) -> [String] {
        guard let summary else { return [] }
        var seen: [String] = []
        for line in summary.split(separator: "\n") {
            let text = String(line)
            guard let range = text.range(of: "Asked ") else { continue }
            guard text[..<range.lowerBound].allSatisfy({ $0 == "]" || $0 == " " || $0 == "M" || $0.isNumber || $0 == "[" }) else { continue }
            // "Asked Name (host): tool (approved)": the host is the last "(...)" before the colon.
            guard let colon = text.range(of: "): ", range: range.upperBound..<text.endIndex) else { continue }
            let head = text[range.upperBound..<colon.lowerBound]
            guard let open = head.lastIndex(of: "(") else { continue }
            let host = String(head[head.index(after: open)...])
            if !host.isEmpty, !seen.contains(host) { seen.append(host) }
        }
        return seen
    }
}

/// A tool result the model was given, under a label it may cite (e.g. "M1"). Memory only: it is not Codable on purpose,
/// so a raw service response cannot be written to disk by accident. Only `ToolCallRecord.summaryLine` is saved.
public struct ToolSource: Identifiable, Equatable, Sendable {
    /// The label the model cites, e.g. "M1".
    public let id: String
    public let connectionName: String
    public let host: String
    public let toolName: String
    /// The exact inputs the call carried, as shown in the review.
    public let arguments: [ToolCallArgument]
    /// What the service returned, cut to what the model was given.
    public let excerpt: String
    public let truncated: Bool

    public init(id: String, connectionName: String, host: String, toolName: String, arguments: [ToolCallArgument], excerpt: String, truncated: Bool) {
        self.id = id
        self.connectionName = connectionName
        self.host = host
        self.toolName = toolName
        self.arguments = arguments
        self.excerpt = excerpt
        self.truncated = truncated
    }

    public var title: String { "\(connectionName) · \(toolName)" }
}
