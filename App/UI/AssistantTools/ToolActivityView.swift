import DeskMateCore
import SwiftUI

/// The separate label for an answer that involved a connected service. It sits next to the model label and never replaces
/// it: the model ran on this Mac, and this says where, if anywhere, data was sent.
struct RemoteConnectionLabel: View {
    let message: ChatMessage
    /// Saved lines of earlier answers by result label, so a cited earlier result can name where it came from.
    var earlierSummaries: [String: String] = [:]

    var body: some View {
        let reach = message.remoteReach
        if let text = ModelProvenance.remoteLabel(reach: reach, usedServices: message.usedServices) {
            Label(text, systemImage: reach.isEmpty ? "network.slash" : "network")
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(reach.isEmpty ? Color.secondary : Color.dmWarning)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(text)
        }
        // An answer that only cites a result from an earlier answer sent nothing itself. This says so, and where the
        // result came from; it never claims a new send.
        if let earlier = ModelProvenance.earlierResultLabel(hosts: message.earlierResultHosts(earlierSummaries: earlierSummaries)) {
            Label(earlier, systemImage: "clock.arrow.circlepath")
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(earlier)
        }
    }
}

/// Collapsible "Tool activity" under an answer: every service call the model asked for and what happened to it. A live
/// answer shows the calls; a reopened one shows the saved one-line summaries only. The results themselves, cited or only
/// retrieved, are listed with the sources (`CitationsView`), whether or not this answer made a call.
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

/// One service result in an answer's evidence lists, either cited ("M1" in the answer) or only retrieved for it.
///
/// With the result in memory the row is an inspector: connection, host, tool, the exact inputs, and the excerpt exactly
/// as the model was given it (Show full opens all of it and it can be selected). After a restart the raw result is gone
/// by design, so the row shows the saved summary line and says "Result not kept after restart"; it never shows text
/// that was not kept. A retrieved row is never presented as a citation.
struct ToolResultRow: View {
    let item: ToolResultItem
    @State private var showsFull = false

    /// Collapsed text is clipped to this many lines.
    private static let collapsedLines = 6

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Text(item.label)
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(item.kind == .cited ? Color.dmBrandText : Color.secondary)
                .frame(minWidth: DS.Spacing.xl, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    if let source = item.source {
                        Text("\(source.title) · \(source.host)")
                            .font(.dmCaption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.retrievedEarlier { note(ToolResultItem.earlierNote) }
                        ForEach(source.arguments) { argument in
                            Text("\(argument.name) = \(argument.value)")
                                .font(.system(size: DS.FontSize.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        excerptText(source)
                        if source.truncated { note("Cut to fit the room left in this chat.") }
                    } else {
                        // Restart: the summary line is all that was saved.
                        if let line = item.summaryLine {
                            Text(line)
                                .font(.dmCaption.weight(.medium))
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        if item.retrievedEarlier { note(ToolResultItem.earlierNote) }
                        note(ToolResultItem.notKeptNote)
                    }
                }
                // One element: labelled with its kind, label and source; the body is its value, clipped on screen or not.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.spokenLabel)
                .accessibilityValue(item.spokenBody)
                if let source = item.source, canExpand(source) {
                    Button(showsFull ? "Show less" : "Show full") { showsFull.toggle() }
                        .buttonStyle(.link)
                        .font(.dmCaption)
                        .accessibilityLabel(showsFull ? "Show less of \(item.label)" : "Show the full result \(item.label)")
                        .accessibilityValue(showsFull ? "Expanded" : "Collapsed")
                        .accessibilityHint("Shows or hides the rest of what the service returned and the model received")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.dmCaption)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder private func excerptText(_ source: ToolSource) -> some View {
        if showsFull {
            // The excerpt is already bounded to what the model received; the transcript scrolls around it.
            Text(source.excerpt)
                .font(.dmCaption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(source.excerpt)
                .font(.dmCaption)
                .foregroundStyle(.secondary)
                .lineLimit(Self.collapsedLines)
                .textSelection(.enabled)
        }
    }

    /// Short results fit in the collapsed view, so there is nothing to open.
    private func canExpand(_ source: ToolSource) -> Bool {
        source.excerpt.count > 320 || source.excerpt.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLines
    }
}
