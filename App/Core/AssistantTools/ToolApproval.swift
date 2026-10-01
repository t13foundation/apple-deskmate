import Foundation
import Observation

/// Everything the person sees before a tool call may leave this Mac. Built by DeskMate from the stored connection and the
/// validated arguments, never from model text. The tool description is the service's own claim and is marked as such.
public struct ToolCallPreview: Equatable, Sendable {
    public let connectionName: String
    /// The full endpoint address.
    public let url: String
    /// Host (with port when it is not the default), as in "sends data to {host}".
    public let host: String
    public let toolName: String
    /// The server's plain-text description, bounded. Untrusted; shown collapsed and labelled as unverified.
    public let serverDescription: String
    /// The exact inputs that would be sent, in the tool's own order.
    public let arguments: [ToolCallArgument]
    /// True for a plain-HTTP connection to this Mac (development).
    public let isOnThisMac: Bool

    public init(connectionName: String, url: String, host: String, toolName: String, serverDescription: String, arguments: [ToolCallArgument], isOnThisMac: Bool) {
        self.connectionName = connectionName
        self.url = url
        self.host = host
        self.toolName = toolName
        self.serverDescription = serverDescription
        self.arguments = arguments
        self.isOnThisMac = isOnThisMac
    }

    /// The data-flow sentence. Always names the host.
    public var dataFlow: String {
        let base = "This connection sends the inputs above to \(host). Nothing else from your chat or your files is sent."
        return isOnThisMac ? base + " This address is on this Mac." : base
    }

    /// Terminal rendering for headless runs; the same facts the review sheet shows.
    public var terminalText: String {
        var lines = ["Review tool call", "  Connection: \(connectionName)", "  Address:    \(url)", "  Tool:       \(toolName)"]
        if arguments.isEmpty {
            lines.append("  Inputs:     (none)")
        } else {
            lines.append("  Inputs:")
            for argument in arguments { lines.append("    \(argument.name) = \(argument.value)") }
        }
        lines.append("  \(dataFlow)")
        return lines.joined(separator: "\n")
    }
}

public struct ToolApprovalRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let preview: ToolCallPreview

    public init(id: UUID = UUID(), preview: ToolCallPreview) {
        self.id = id
        self.preview = preview
    }
}

public enum ToolApprovalDecision: Equatable, Sendable {
    /// The person allowed exactly this call, once.
    case allowOnce
    /// The person declined.
    case deny
    /// The turn was stopped (or the app closed) before the person answered. Nothing is sent.
    case cancelled
}

/// The one place a tool call waits for a person. A call is suspended here until `allowOnce(_:)` or `deny(_:)` is called by
/// a UI action (or, in headless mode, by a person typing an answer in the terminal). Model output cannot reach these
/// methods. There is no "always allow": every request needs its own answer.
@MainActor
@Observable
public final class ToolApprovalBroker {
    /// Requests in order. The first one is shown; the rest wait their turn.
    public private(set) var queue: [ToolApprovalRequest] = []

    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<ToolApprovalDecision, Never>] = [:]
    @ObservationIgnored private var onRequest: (@MainActor (ToolApprovalRequest) -> Void)?

    public init() {}

    /// The request the person is being asked about now.
    public var pending: ToolApprovalRequest? { queue.first }

    /// Headless runs register a handler that shows the request on the terminal. It must answer through `allowOnce` or `deny`.
    public func setRequestHandler(_ handler: (@MainActor (ToolApprovalRequest) -> Void)?) {
        onRequest = handler
    }

    /// Suspends until the person decides. Cancelling the calling task resolves the request as `.cancelled`.
    public func requestApproval(_ preview: ToolCallPreview) async -> ToolApprovalDecision {
        if Task.isCancelled { return .cancelled }
        let request = ToolApprovalRequest(preview: preview)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[request.id] = continuation
                queue.append(request)
                onRequest?(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(request.id, .cancelled) }
        }
    }

    public func allowOnce(_ id: UUID) { finish(id, .allowOnce) }

    public func deny(_ id: UUID) { finish(id, .deny) }

    /// Stop, New chat or quitting: every waiting request ends as cancelled and nothing is sent.
    public func cancelAll() {
        for request in queue { finish(request.id, .cancelled) }
    }

    private func finish(_ id: UUID, _ decision: ToolApprovalDecision) {
        queue.removeAll { $0.id == id }
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: decision)
    }
}

extension ToolArgumentValue {
    /// Plain text for the review and the activity list.
    var displayText: String {
        switch self {
        case .string(let text): text
        case .integer(let number): String(number)
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .boolean(let flag): flag ? "yes" : "no"
        }
    }
}
