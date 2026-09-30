import DeskMateCore
import SwiftUI

/// First-run and new-chat surface. Starter prompts only fill the composer; nothing is sent until the person presses Return.
/// Only prompts this build can honestly serve are offered: file and connection prompts arrive with their packages.
struct EmptyStateView: View {
    let controller: ConversationController

    private struct Starter: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let text: String
    }

    private let starters: [Starter] = [
        Starter(id: "explain", symbol: "lightbulb", title: "Explain something simply",
                text: "Explain how compound interest works in plain language, with a small example."),
        Starter(id: "email", symbol: "envelope", title: "Draft a short email",
                text: "Draft a polite two-paragraph email asking a colleague to move our meeting to Thursday afternoon."),
        Starter(id: "summarize", symbol: "list.bullet.rectangle", title: "Summarize a meeting",
                text: "Summarize these meeting notes into decisions and next steps:\n\n"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xl) {
                VStack(spacing: DS.Spacing.s) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.dmAccent)
                        .accessibilityHidden(true)
                    Text("What would you like to work on?")
                        .font(.dmTitle)
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.dmBody)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: DS.Spacing.s) {
                    ForEach(starters) { starter in
                        Button {
                            controller.prefill(starter.text)
                        } label: {
                            HStack(spacing: DS.Spacing.m) {
                                Image(systemName: starter.symbol)
                                    .frame(width: 20)
                                    .foregroundStyle(Color.dmAccent)
                                    .accessibilityHidden(true)
                                Text(starter.title)
                                    .font(.dmBody)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, DS.Spacing.l)
                            .padding(.vertical, DS.Spacing.m)
                            .contentShape(Rectangle())
                            .dmSurface(radius: DS.Radius.control)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(starter.title)
                        .accessibilityHint("Puts a starter question in the message box. Nothing is sent until you press Return.")
                    }
                }
                .frame(maxWidth: 420)
            }
            .padding(DS.Spacing.panel)
            .frame(maxWidth: .infinity, minHeight: 320)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New chat")
    }

    private var subtitle: String {
        controller.readiness.isReady
            ? "Ask a question in English. Answers are written on your Mac by Apple’s on-device model."
            : "You can write your question now. It is kept until the on-device model is available."
    }
}
