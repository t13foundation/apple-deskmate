import DeskMateCore
import SwiftUI

struct ComposerView: View {
    @Bindable var controller: ConversationController

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            AttachmentStrip(controller: controller)

            HStack(alignment: .bottom, spacing: DS.Spacing.s) {
                attachMenu
                    .padding(.bottom, DS.Spacing.xs + 2)

                ComposerTextView(
                    text: $controller.draft,
                    placeholder: placeholder,
                    focusToken: controller.focusRequest,
                    onSubmit: { controller.send() },
                    onCancel: { controller.cancel() }
                )
                .padding(.leading, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xs)

                actionButton
                    .padding(.bottom, DS.Spacing.xs)
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.xs)
            .dmSurface(radius: DS.Radius.surface)

            Text(footnote)
                .font(.dmCaption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.xs)
        }
    }

    private var placeholder: String {
        if controller.isComparing { return "Ask how the two documents differ…" }
        return controller.hasConversation ? "Ask a follow-up…" : "Ask anything, in English…"
    }

    private var attachMenu: some View {
        Menu {
            Button("Attach files…") { AttachActions.chooseAndAttach(to: controller) }
                .disabled(!controller.canAttachMore)
            Button("Compare two documents…") { AttachActions.startComparison(with: controller) }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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

    private var footnote: String {
        "Return to send, Shift+Return for a new line. Answers come from Apple’s on-device model and can be wrong."
    }
}
