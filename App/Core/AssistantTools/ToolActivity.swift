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
        case .failed: sentRequest ? "approved, failed" : "approved, not sent"
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
    ///
    /// Saved wording, which `remoteHosts(inSummary:)` reads back after a restart:
    /// - "Asked ..." means a request was sent or may have been sent, so its host counts as reached. A call that was
    ///   approved and then failed after sending is "Asked ... (approved, failed: <reason>)".
    /// - "Not sent to ..." means nothing left this Mac (refused, stopped before sending, or approved but rejected before
    ///   any request: "Not sent to ... (approved, failed before sending: <reason>)"). Its host never counts.
    /// Lines saved by earlier versions describe every failure as "Asked ... (approved, failed: ...)"; they keep that
    /// meaning (possibly sent), because the old text cannot tell the two cases apart. They still decode and display.
    public var summaryLine: String {
        let place = "\(Self.line(connectionName, limit: 40)) (\(Self.line(host, limit: 60))): \(Self.line(toolName, limit: 40))"
        let tag = label.map { "[\($0)] " } ?? ""
        switch outcome {
        case .succeeded, .running, .awaitingApproval:
            return "\(tag)Asked \(place) (approved)"
        case .failed(let reason):
            let shortReason = Self.line(reason, limit: 80)
            return sentRequest
                ? "Asked \(place) (approved, failed: \(shortReason))"
                : "Not sent to \(place) (approved, failed before sending: \(shortReason))"
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
            if let host = askedHost(inLine: String(line)), !seen.contains(host) { seen.append(host) }
        }
        return seen
    }

    /// The host of one saved "Asked ..." line, or nil for any other kind of line ("Not sent to", "Declined").
    static func askedHost(inLine text: String) -> String? {
        guard let range = text.range(of: "Asked ") else { return nil }
        guard text[..<range.lowerBound].allSatisfy({ $0 == "]" || $0 == " " || $0 == "M" || $0.isNumber || $0 == "[" }) else { return nil }
        // "Asked Name (host): tool (approved)": the host is the last "(...)" before the colon.
        guard let colon = text.range(of: "): ", range: range.upperBound..<text.endIndex) else { return nil }
        let head = text[range.upperBound..<colon.lowerBound]
        guard let open = head.lastIndex(of: "(") else { return nil }
        let host = String(head[head.index(after: open)...])
        return host.isEmpty ? nil : host
    }

    /// The label a saved line starts with ("[M1] Asked ..." gives "M1"). Only a call that returned a result carries one.
    static func label(inSummaryLine line: String) -> String? {
        guard line.hasPrefix("[M"), let close = line.firstIndex(of: "]") else { return nil }
        let label = String(line[line.index(after: line.startIndex)..<close])
        return label.dropFirst().allSatisfy(\.isNumber) && label.count > 1 ? label : nil
    }

    /// Saved lines that carry a result label, in order: the results the model was given in an answer.
    static func labelledLines(in lines: [String]) -> [(label: String, line: String)] {
        lines.compactMap { line in label(inSummaryLine: line).map { ($0, line) } }
    }
}

/// One service result as the answer's evidence list shows it: either cited by the answer, or only retrieved for it.
/// A retrieved result is never a citation and backs no claim in the answer.
public struct ToolResultItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The answer cites it as "[M#]".
        case cited
        /// DeskMate gave it to the model for this answer, but the answer does not cite it.
        case retrieved
    }

    public let kind: Kind
    /// "M1".
    public let label: String
    /// The result as it was given to the model. Nil once the app was restarted: raw results are never saved.
    public let source: ToolSource?
    /// The saved one-line summary of the call, when one is known.
    public let summaryLine: String?
    /// True when the result was retrieved in an earlier answer, not by a call in this one.
    public let retrievedEarlier: Bool

    public var id: String { "\(kind.rawValue)-\(label)" }

    /// The text shown when only the summary survived.
    public static let notKeptNote = "Result not kept after restart"
    public static let earlierNote = "Retrieved in an earlier answer"

    public init(kind: Kind, label: String, source: ToolSource?, summaryLine: String?, retrievedEarlier: Bool) {
        self.kind = kind
        self.label = label
        self.source = source
        self.summaryLine = summaryLine
        self.retrievedEarlier = retrievedEarlier
    }

    /// The service host, from the result itself or from the saved summary line.
    public var host: String? {
        source?.host ?? summaryLine.flatMap { ToolCallRecord.askedHost(inLine: $0) }
    }

    /// "Cited" or "Retrieved, not cited".
    public var kindWord: String { kind == .cited ? "Cited" : "Retrieved, not cited" }

    /// What a screen reader announces as the row's label: kind, label and source. The body is the accessibility value.
    public var spokenLabel: String {
        var text = "\(kindWord), \(label), service result"
        if let source {
            text += " from \(source.connectionName), \(source.toolName) on \(source.host)"
        } else if let host {
            text += " from \(host)"
        }
        if retrievedEarlier { text += ", \(Self.earlierNote.lowercased())" }
        return text
    }

    /// What a screen reader announces as the row's value: the body that exists, never an invented one.
    public var spokenBody: String {
        if let source { return source.excerpt + (source.truncated ? " Cut to fit the room left in this chat." : "") }
        return [summaryLine, Self.notKeptNote].compactMap { $0 }.joined(separator: ". ")
    }
}

public extension ChatMessage {
    /// Service results that belong to this answer's evidence: the ones it cites, then the ones only retrieved for it.
    ///
    /// Live, the results come from the answer's memory. After a restart only the saved summary lines survive, so a row
    /// then carries its summary and "Result not kept after restart" and never any text. A result cited from an earlier
    /// answer has no line of its own here; `earlierSummaries` (label to line, from the earlier answers) supplies one.
    func toolResultItems(earlierSummaries: [String: String] = [:]) -> [ToolResultItem] {
        guard role == .assistant else { return [] }
        let own = ToolCallRecord.labelledLines(in: toolActivityLines)
        func ownLine(_ label: String) -> String? { own.first { $0.label == label }?.line }

        var cited = CitationValidator.toolLabels(in: text)
        for source in toolSources where !cited.contains(source.id) { cited.append(source.id) }

        var items: [ToolResultItem] = []
        for label in cited {
            let live = toolSources.first { $0.id == label }
            let line = ownLine(label)
            // Live, the ledger said whether this turn retrieved it. After a restart, a label with no line of its own
            // can only have been retrieved earlier.
            let earlier = live != nil ? earlierToolLabels.contains(label) : line == nil
            items.append(ToolResultItem(kind: .cited, label: label, source: live, summaryLine: line ?? earlierSummaries[label], retrievedEarlier: earlier))
        }
        var listed = Set(cited)
        for source in retrievedToolSources where listed.insert(source.id).inserted {
            items.append(ToolResultItem(kind: .retrieved, label: source.id, source: source, summaryLine: ownLine(source.id), retrievedEarlier: false))
        }
        // After a restart: a call that returned a result but is not cited in the answer.
        for entry in own where listed.insert(entry.label).inserted {
            items.append(ToolResultItem(kind: .retrieved, label: entry.label, source: nil, summaryLine: entry.line, retrievedEarlier: false))
        }
        return items
    }

    /// Hosts of results this answer cites but did not retrieve itself. It sent nothing for them in this answer.
    func earlierResultHosts(earlierSummaries: [String: String] = [:]) -> [String] {
        var hosts: [String] = []
        for item in toolResultItems(earlierSummaries: earlierSummaries) where item.kind == .cited && item.retrievedEarlier {
            if let host = item.host, !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }

    /// Saved summary lines of the answers before `id`, by result label, nearest answer first. Lets an answer that cites
    /// an earlier "[M1]" show where that result came from, also after a restart.
    static func earlierToolSummaries(in messages: [ChatMessage], before id: UUID) -> [String: String] {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return [:] }
        var found: [String: String] = [:]
        for message in messages[..<index].reversed() where message.role == .assistant {
            for entry in ToolCallRecord.labelledLines(in: message.toolActivityLines) where found[entry.label] == nil {
                found[entry.label] = entry.line
            }
        }
        return found
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
