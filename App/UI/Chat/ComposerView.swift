import DeskMateCore
import SwiftUI

struct ComposerView: View {
    @Bindable var controller: ConversationController

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            HStack(alignment: .bottom, spacing: DS.Spacing.s) {
                ComposerTextView(
                    text: $controller.draft,
                    placeholder: controller.hasConversation ? "Ask a follow-up…" : "Ask anything, in English…",
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
        if !controller.readiness.isReady { return "The on-device model isn’t available yet" }
        return "Send (Return)"
    }

    private var footnote: String {
        "Return to send, Shift+Return for a new line. Answers come from Apple’s on-device model and can be wrong."
    }
}
