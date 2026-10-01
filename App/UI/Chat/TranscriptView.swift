import AppKit
import DeskMateCore
import SwiftUI

struct TranscriptView: View {
    let controller: ConversationController

    /// While true the view follows new text. Scrolling up by hand pauses it; returning to the bottom resumes.
    @State private var followTail = true
    @State private var distanceFromBottom: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.l) {
                    ForEach(controller.messages) { message in
                        if message.id == controller.memoryBoundaryID {
                            MemoryNote()
                        }
                        MessageView(message: message, isLast: message.id == controller.messages.last?.id, controller: controller)
                            .id(message.id)
                    }
                    if controller.omittedFromMemory > 0, controller.memoryBoundaryID == nil {
                        MemoryNote()
                    }
                    if controller.phase == .creatingResult, let kind = controller.resultInProgress {
                        WorkingIndicator(label: kind.progressTitle)
                    }
                    if !controller.results.isEmpty {
                        SavedResultsSection(controller: controller)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .dmReadingColumn()
                .padding(.vertical, DS.Spacing.l)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY
            } action: { _, distance in
                distanceFromBottom = distance
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting: followTail = false
                case .idle where distanceFromBottom < 48: followTail = true
                default: break
                }
            }
            .onChange(of: controller.messages.count) {
                followTail = true
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: controller.messages.last?.text) {
                if followTail { scrollToBottom(proxy, animated: false) }
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
        .accessibilityLabel("Conversation")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

struct MessageView: View {
    let message: ChatMessage
    let isLast: Bool
    let controller: ConversationController

    var body: some View {
        switch message.role {
        case .user: UserMessageView(text: message.text, attachments: message.attachments)
        case .assistant: AssistantMessageView(message: message, isLast: isLast, controller: controller)
        }
    }
}

struct UserMessageView: View {
    let text: String
    var attachments: [AttachmentSummary] = []

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: DS.Spacing.xxl)
            VStack(alignment: .trailing, spacing: DS.Spacing.s) {
                Text(text)
                    .font(.dmBody)
                    .textSelection(.enabled)
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.vertical, DS.Spacing.m)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                            .fill(Color.dmUserBubble)
                    )
                    .accessibilityLabel("You: \(text)")
                if !attachments.isEmpty {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(attachments) { attachment in
                            Label(attachment.fileName, systemImage: attachment.kind == .pdf ? "doc.richtext" : "doc.text")
                                .font(.dmCaption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, DS.Spacing.s)
                                .padding(.vertical, DS.Spacing.xs)
                                .background(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: DS.Stroke.hairline))
                                .accessibilityLabel("Attached: \(attachment.fileName)")
                        }
                    }
                }
            }
            .frame(maxWidth: DS.Layout.bubbleMaxWidth, alignment: .trailing)
        }
    }
}

struct AssistantMessageView: View {
    let message: ChatMessage
    let isLast: Bool
    let controller: ConversationController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            header
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                content
                statusLine
            }
            .accessibilityElement(children: .combine)

            CitationsView(message: message)
            ToolActivityView(message: message)

            if message.status != .streaming, !message.text.isEmpty {
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "sparkle")
                    .font(.dmCaption.weight(.semibold))
                    .foregroundStyle(Color.dmBrandText)
                    .accessibilityHidden(true)
                // "On this Mac" would be wrong beside a request that left it, so an answer that asked a service names only
                // the model here; the remote label next to it says where data went.
                Text(message.usedServices ? ModelProvenance.inferenceOnlyLabel : SystemModelEngine.provenance.shortLabel)
                    .font(.dmCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            ProvenanceInfoButton()
            RemoteConnectionLabel(message: message)
        }
    }

    @ViewBuilder private var content: some View {
        if message.text.isEmpty {
            if message.status == .streaming {
                WorkingIndicator(label: isLast ? (controller.activity ?? "Working on your Mac") : "Working on your Mac")
            }
        } else {
            MarkdownText(markdown: message.text)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch message.status {
        case .streaming where !message.text.isEmpty:
            WorkingIndicator(label: isLast ? (controller.activity ?? "Writing…") : "Writing…")
        case .stopped:
            Label(message.text.isEmpty ? "Stopped before an answer" : "Stopped", systemImage: "stop.circle")
                .font(.dmCaption)
                .foregroundStyle(.secondary)
        case .failed:
            Label(message.text.isEmpty ? "No answer" : "The answer is incomplete", systemImage: "exclamationmark.triangle")
                .font(.dmCaption)
                .foregroundStyle(Color.dmWarning)
        default:
            EmptyView()
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Spacing.s) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy this answer")
            .accessibilityLabel("Copy answer")

            // Briefs and task lists cover the whole visible conversation, so they sit on the latest finished answer.
            if isLast, message.status == .complete {
                Button {
                    controller.createResult(.brief)
                } label: {
                    Label(ResultKind.brief.actionTitle, systemImage: "doc.text")
                }
                .disabled(!controller.canCreateResult)
                .help("Summarize this conversation as Summary, Decisions, Open questions and Next steps")
                .accessibilityHint("Makes a brief from the conversation so far")
                Button {
                    controller.createResult(.tasks)
                } label: {
                    Label(ResultKind.tasks.actionTitle, systemImage: "checklist")
                }
                .disabled(!controller.canCreateResult)
                .help("List the tasks in this conversation with owner, due date and evidence")
                .accessibilityHint("Makes a task list from the conversation so far")
            }

            if isLast, message.status == .stopped, controller.canRetry {
                Button {
                    controller.retry()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Try this question again")
                Button {
                    controller.editLastQuestion()
                } label: {
                    Label("Edit question", systemImage: "pencil")
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .font(.dmCaption)
        .foregroundStyle(.secondary)
    }
}

/// A small info button beside the answer label. Its popover says, in the engine's own words, what produced the answer.
struct ProvenanceInfoButton: View {
    @State private var isShown = false

    private var provenance: ModelProvenance { SystemModelEngine.provenance }

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.dmCaption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(provenance.detail)
        .accessibilityLabel("About this answer")
        .accessibilityHint(provenance.detail)
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(provenance.detail)
                .font(.dmCaption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: DS.Layout.popoverWidth, alignment: .leading)
                .padding(DS.Spacing.m)
        }
    }
}

/// Activity indicator. A spinner normally; static text with Reduce Motion so nothing animates forever.
struct WorkingIndicator: View {
    var label = "Working on your Mac"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            if reduceMotion {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(label)
                .font(.dmBody)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
