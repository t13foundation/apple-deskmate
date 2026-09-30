import DeskMateCore
import SwiftUI

/// One rounded surface: the attachment strip (when there is one), then attach, the message field and Send or Stop
/// on one row. A single line is 48 pt tall. Below it, one short supporting line.
struct ComposerView: View {
    @Bindable var controller: ConversationController

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            VStack(spacing: 0) {
                AttachmentStrip(controller: controller)

                HStack(alignment: .bottom, spacing: DS.Spacing.s) {
                    attachMenu

                    ComposerTextView(
                        text: $controller.draft,
                        placeholder: placeholder,
                        focusToken: controller.focusRequest,
                        onSubmit: { controller.send() },
                        onCancel: { controller.cancel() }
                    )
                    // A one-line field is centred against the 32 pt buttons; a taller field grows upward.
                    .frame(minHeight: DS.Layout.controlSize, alignment: .center)
                    .help("Return sends. Shift+Return adds a new line.")

                    actionButton
                }
                .padding(DS.Spacing.s)
            }
            .dmSurface()

            Text("Answers come from Apple’s on-device model and can be wrong.")
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
            Button("Attach files…") { AttachActions.chooseAndAttach(to: controller) }
                .disabled(!controller.canAttachMore)
            Button("Compare two documents…") { AttachActions.startComparison(with: controller) }
        } label: {
            Image(systemName: "paperclip")
                .font(.dmBody)
                .frame(width: DS.Layout.controlSize, height: DS.Layout.controlSize)
                .contentShape(Rectangle())
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
}
