import DeskMateCore
import Foundation

/// Headless approval: the same preview the Review sheet shows, then a question typed by a person in the terminal.
/// Only a typed "y" or "yes" allows the call. End of input, an empty line or anything else denies it. There is no option
/// that answers for the person, and model output cannot reach this code.
@MainActor
final class TerminalApproval {
    private let broker: ToolApprovalBroker
    private let readLine: @Sendable () -> String?
    /// Every answer this run, in order, for the evidence summary: (tool, allowed).
    private(set) var answers: [(tool: String, allowed: Bool)] = []

    init(broker: ToolApprovalBroker, readLine: @escaping @Sendable () -> String? = { Swift.readLine(strippingNewline: true) }) {
        self.broker = broker
        self.readLine = readLine
        broker.setRequestHandler { [weak self] request in self?.ask(request) }
    }

    static func isYes(_ line: String?) -> Bool {
        guard let line else { return false }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    private func ask(_ request: ToolApprovalRequest) {
        print("\n" + request.preview.terminalText)
        print("Allow? [y/N] ", terminator: "")
        fflush(stdout)
        let read = readLine
        Task.detached { [weak self] in
            let line = read()
            await MainActor.run {
                guard let self else { return }
                let allowed = Self.isYes(line)
                if line == nil { print("(no answer: denied)") } else { print(allowed ? "(allowed once)" : "(denied)") }
                self.answers.append((request.preview.toolName, allowed))
                if allowed { self.broker.allowOnce(request.id) } else { self.broker.deny(request.id) }
            }
        }
    }
}
