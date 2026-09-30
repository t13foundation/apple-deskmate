import DeskMateCore
import SwiftUI

/// One rounded surface: the attachment strip (when there is one), then attach, the message field and Send or Stop
/// on one row. A single line is 48 pt tall (a 32 pt row in 8 pt padding). Below it, one short supporting line.
struct ComposerView: View {
    @Bindable var controller: ConversationController
    @Environment(AttachPicker.self) private var picker

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            VStack(spacing: 0) {
                AttachmentStrip(controller: controller)

                ComposerBar(
                    text: $controller.draft,
                    placeholder: placeholder,
                    focusToken: controller.focusRequest,
                    onSubmit: { controller.send() },
                    onCancel: { controller.cancel() }
                ) {
                    attachMenu
                } action: {
                    actionButton
                }
            }
            .dmSurface()

            Text(SystemModelEngine.provenance.footnote)
                .dmFootnote()
                .frame(maxWidth: .infinity)
        }
    }

    private var placeholder: String {
        if controller.isComparing { return "Ask how the two documents differ…" }
        return controller.hasConversation ? "Ask a follow-up…" : "Ask anything, in English…"
    }

    private var attachMenu: some View {
        Menu {
            Button("Attach files…") { picker.chooseAndAttach(to: controller) }
                .disabled(!controller.canAttachMore)
            Button("Compare two documents…") { picker.startComparison(with: controller) }
        } label: {
            Image(systemName: "paperclip")
                .font(.dmBody)
                .frame(width: DS.Layout.controlSize, height: DS.Layout.controlSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(Color.dmBrandText)
        .fixedSize()
        .disabled(controller.isBusy || controller.isLoadingAttachments)
        .help("Attach up to \(ConversationController.maxAttachments) files to this question, or compare two documents")
        .accessibilityLabel("Attach files")
        .accessibilityHint("Attach up to \(ConversationController.maxAttachments) files, or compare two documents")
    }

    @ViewBuilder private var actionButton: some View {
        if controller.isBusy {
            Button {
                controller.cancel()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(DMRoundButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Stop generating (Esc or ⌘.)")
            .accessibilityLabel("Stop generating")
        } else {
            Button {
                controller.send()
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(DMRoundButtonStyle())
            .disabled(!controller.canSend)
            .help(sendHelp)
            .accessibilityLabel("Send message")
            .accessibilityHint(sendHelp)
        }
    }

    private var sendHelp: String {
        if controller.trimmedDraft.isEmpty { return "Type a question to send it" }
        if controller.isComparing, controller.attachments.count != 2 { return "Choose two documents to compare" }
        if !controller.readiness.isReady { return "The on-device model isn’t available yet" }
        return "Send (Return)"
    }
}
