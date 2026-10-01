import DeskMateCore
import SwiftUI

/// The separate label for an answer that involved a connected service. It sits next to the model label and never replaces
/// it: the model ran on this Mac, and this says where, if anywhere, data was sent.
struct RemoteConnectionLabel: View {
    let message: ChatMessage

    var body: some View {
        if let text = ModelProvenance.remoteLabel(hosts: message.remoteHosts, usedServices: message.usedServices) {
            Label(text, systemImage: message.remoteHosts.isEmpty ? "network.slash" : "network")
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(message.remoteHosts.isEmpty ? Color.secondary : Color.dmWarning)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(text)
        }
    }
}

/// Collapsible "Tool activity" under an answer: every service call the model asked for and what happened to it. A live
/// answer shows the calls and the results it cited; a reopened one shows the saved one-line summaries only.
struct ToolActivityView: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        if message.usedServices {
            let count = message.toolCalls.isEmpty ? message.toolActivityLines.count : message.toolCalls.count
            DMDisclosure(
                isExpanded: $expanded,
                label: "Tool activity, \(count) \(count == 1 ? "call" : "calls"). \(headline)",
                hint: "Shows which connected services were asked for this answer, and what you decided"
            ) {
                HStack(spacing: DS.Spacing.xs) {
                    Label("Tool activity (\(count))", systemImage: "wrench.and.screwdriver")
                        .font(.dmCaption.weight(.semibold))
                    Text(headline)
                        .font(.dmCaption)
                }
                .foregroundStyle(.secondary)
            } content: {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    if message.toolCalls.isEmpty {
                        // Reopened from history: only the saved summary lines exist.
                        ForEach(Array(message.toolActivityLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.dmCaption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text("Saved with the conversation: one line per call, never the inputs or the service's reply.")
                            .font(.dmCaption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(message.toolCalls) { call in
                            CallRow(call: call)
                        }
                        ForEach(message.toolSources) { source in
                            ResultRow(source: source)
                        }
                    }
                }
                .padding(.top, DS.Spacing.xs)
            }
            .font(.dmCaption)
        }
    }

    /// "1 approved, 1 denied".
    private var headline: String {
        guard !message.toolCalls.isEmpty else { return "" }
        var parts: [String] = []
        func add(_ number: Int, _ word: String) { if number > 0 { parts.append("\(number) \(word)") } }
        add(message.toolCalls.filter { if case .succeeded = $0.outcome { true } else { false } }.count, "approved")
        add(message.toolCalls.filter { if case .denied = $0.outcome { true } else { false } }.count, "denied")
        add(message.toolCalls.filter { if case .failed = $0.outcome { true } else { false } }.count, "failed")
        add(message.toolCalls.filter { if case .notRun = $0.outcome { true } else { false } }.count, "not run")
        add(message.toolCalls.filter { if case .cancelled = $0.outcome { true } else { false } }.count, "stopped")
        add(message.toolCalls.filter { !$0.isFinished }.count, "waiting")
        return parts.joined(separator: ", ")
    }
}

private struct CallRow: View {
    let call: ToolCallRecord

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: DS.Layout.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(call.toolName) · \(call.host)")
                    .font(.dmCaption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(call.connectionName) · \(call.statusWord)")
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
                if let detail = call.detail {
                    Text(detail)
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                }
                ForEach(call.arguments) { argument in
                    Text("\(argument.name) = \(argument.value)")
                        .font(.system(size: DS.FontSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var text = "\(call.toolName) on \(call.host), \(call.statusWord)."
        if !call.arguments.isEmpty { text += " Inputs: " + call.arguments.map { "\($0.name) \($0.value)" }.joined(separator: ", ") + "." }
        if let detail = call.detail { text += " \(detail)" }
        return text
    }

    private var symbol: String {
        switch call.outcome {
        case .succeeded: "checkmark.circle"
        case .denied: "hand.raised"
        case .failed: "exclamationmark.triangle"
        case .notRun: "minus.circle"
        case .cancelled: "stop.circle"
        case .awaitingApproval: "hourglass"
        case .running: "ellipsis.circle"
        }
    }

    private var tint: Color {
        switch call.outcome {
        case .failed: Color.dmWarning
        case .succeeded: Color.dmBrandText
        default: Color.secondary
        }
    }
}

/// A result a service returned and the model was given, under the label the answer cites (for example "M1").
private struct ResultRow: View {
    let source: ToolSource

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Text(source.id)
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(Color.dmBrandText)
                .frame(width: DS.Layout.iconWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(source.title) · \(source.host)")
                    .font(.dmCaption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(source.excerpt)
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                if source.truncated {
                    Text("Cut to fit the room left in this chat.")
                        .font(.dmCaption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.id), result from \(source.connectionName), \(source.toolName)")
    }
}
