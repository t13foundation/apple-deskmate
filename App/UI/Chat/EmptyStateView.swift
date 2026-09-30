import DeskMateCore
import SwiftUI

/// First-run and new-chat surface. Starter prompts only fill the composer; nothing is sent until the person presses Return.
/// Starters that need files guide the person to add or attach them first.
struct EmptyStateView: View {
    let controller: ConversationController
    @Environment(LibraryStore.self) private var library
    @Environment(AppNavigation.self) private var navigation

    private enum Guidance: Equatable {
        case addFiles
        case attachNotes
        case chooseTwo
    }

    @State private var guidance: Guidance?

    private struct Starter: Identifiable {
        let id: String
        let symbol: String
        let title: String
    }

    private let starters: [Starter] = [
        Starter(id: "files", symbol: "folder", title: "Ask about my files"),
        Starter(id: "meeting", symbol: "list.bullet.rectangle", title: "Summarize a meeting"),
        Starter(id: "compare", symbol: "rectangle.split.2x1", title: "Compare documents"),
        Starter(id: "explain", symbol: "lightbulb", title: "Explain something simply"),
        Starter(id: "email", symbol: "envelope", title: "Draft a short email"),
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
                            choose(starter)
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
                        .accessibilityHint(hint(for: starter))
                    }
                    if let guidance = activeGuidance {
                        guidanceCard(guidance)
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
        .dmAnimation(value: guidance)
    }

    /// The guidance disappears once the person has done what it asked.
    private var activeGuidance: Guidance? {
        switch guidance {
        case .attachNotes where !controller.attachments.isEmpty: nil
        case .chooseTwo where controller.attachments.count == 2 || !controller.isComparing: nil
        case .addFiles where library.hasSearchableContent: nil
        default: guidance
        }
    }

    private var subtitle: String {
        controller.readiness.isReady
            ? "Ask a question in English. Answers are written on your Mac by Apple’s on-device model."
            : "You can write your question now. It is kept until the on-device model is available."
    }

    private func hint(for starter: Starter) -> String {
        switch starter.id {
        case "files", "meeting", "compare": "Puts a starter in the message box and shows what to add or attach. Nothing is sent until you press Return."
        default: "Puts a starter question in the message box. Nothing is sent until you press Return."
        }
    }

    private func choose(_ starter: Starter) {
        switch starter.id {
        case "files":
            if library.hasSearchableContent {
                guidance = nil
                controller.prefill("What do my files say about the project budget and who approved it?")
            } else {
                guidance = .addFiles
            }
        case "meeting":
            controller.prefill("Summarize the attached meeting notes into decisions and next steps.")
            guidance = controller.attachments.isEmpty ? .attachNotes : nil
        case "compare":
            controller.beginComparison()
            guidance = controller.attachments.count == 2 ? nil : .chooseTwo
        case "explain":
            guidance = nil
            controller.prefill("Explain how compound interest works in plain language, with a small example.")
        default:
            guidance = nil
            controller.prefill("Draft a polite two-paragraph email asking a colleague to move our meeting to Thursday afternoon.")
        }
    }

    private func guidanceCard(_ guidance: Guidance) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            switch guidance {
            case .addFiles:
                Text("Add your files first")
                    .font(.dmSection)
                Text(library.isEmpty
                     ? "My files is empty. Add a folder or files, then ask about them in normal chat."
                     : "None of the files in My files can be searched right now. Check My files to see why.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                Button("Open My files") { navigation.section = .files }
                    .buttonStyle(.borderedProminent)
            case .attachNotes:
                Text("Attach the meeting notes")
                    .font(.dmSection)
                Text("Attach a TXT, Markdown or PDF file with the notes, or paste the notes into the message box.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                Button("Attach files…") { AttachActions.chooseAndAttach(to: controller) }
                    .buttonStyle(.borderedProminent)
            case .chooseTwo:
                Text("Choose two documents")
                    .font(.dmSection)
                Text("A comparison takes exactly two TXT, Markdown or PDF files. DeskMate reads them on your Mac and cites the right one.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                Button("Choose two files…") { AttachActions.chooseAndAttach(to: controller) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.l)
        .dmSurface(radius: DS.Radius.surface)
        .accessibilityElement(children: .contain)
    }
}
