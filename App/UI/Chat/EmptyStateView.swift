import DeskMateCore
import SwiftUI

/// First-run and new-chat surface. Starter prompts only fill the composer; nothing is sent until the person presses Return.
/// Starters that need files guide the person to add or attach them first.
///
/// The content sits in the shared reading column, slightly above the vertical centre: a title, one supporting
/// line, three equal-width starter tiles and two quieter general starters.
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

    /// The document starters from the design system, shown as tiles.
    private let tiles: [Starter] = [
        Starter(id: "files", symbol: "folder", title: "Ask about my files"),
        Starter(id: "meeting", symbol: "list.bullet.rectangle", title: "Summarize a meeting"),
        Starter(id: "compare", symbol: "rectangle.split.2x1", title: "Compare documents"),
    ]

    /// General questions that need no files.
    private let quickStarters: [Starter] = [
        Starter(id: "explain", symbol: "lightbulb", title: "Explain something simply"),
        Starter(id: "email", symbol: "envelope", title: "Draft a short email"),
    ]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: DS.Spacing.xl) {
                    DMEmptyHeader(
                        symbol: "sparkle",
                        title: "What would you like to work on?",
                        subtitle: subtitle
                    )

                    HStack(spacing: DS.Spacing.s) {
                        ForEach(tiles) { starter in
                            Button {
                                choose(starter)
                            } label: {
                                tile(starter)
                            }
                            .buttonStyle(DMTileButtonStyle())
                            .accessibilityLabel(starter.title)
                            .accessibilityHint(hint(for: starter))
                        }
                    }

                    HStack(spacing: DS.Spacing.m) {
                        Text("Or try")
                            .font(.dmCaption)
                            .foregroundStyle(.secondary)
                        ForEach(quickStarters) { starter in
                            Button {
                                choose(starter)
                            } label: {
                                Label(starter.title, systemImage: starter.symbol)
                                    .font(.dmCaption)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(starter.title)
                            .accessibilityHint(hint(for: starter))
                        }
                    }

                    if let guidance = activeGuidance {
                        guidanceNotice(guidance)
                    }
                }
                .dmReadingColumn()
                .padding(.vertical, DS.Spacing.xl)
                // Lifts the content above the exact centre so it reads as anchored near the top.
                .padding(.bottom, DS.Spacing.xxl * 2)
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New chat")
        .dmAnimation(value: guidance)
    }

    private func tile(_ starter: Starter) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Image(systemName: starter.symbol)
                .font(.dmSection)
                .foregroundStyle(Color.dmAccent)
                .accessibilityHidden(true)
            Text(starter.title)
                .font(.dmBody)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, minHeight: DS.Layout.tileMinHeight, alignment: .topLeading)
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
            ? "Ask in English. Answers are written on your Mac by Apple’s on-device model."
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

    @ViewBuilder private func guidanceNotice(_ guidance: Guidance) -> some View {
        switch guidance {
        case .addFiles:
            DMNotice(
                symbol: "folder.badge.plus",
                tint: .dmAccent,
                title: "Add your files first",
                message: library.isEmpty
                    ? "My files is empty. Add a folder or files, then ask about them in normal chat."
                    : "None of the files in My files can be searched right now. Check My files to see why."
            ) {
                Button("Open My files") { navigation.section = .files }
                    .buttonStyle(.borderedProminent)
            }
        case .attachNotes:
            DMNotice(
                symbol: "paperclip",
                tint: .dmAccent,
                title: "Attach the meeting notes",
                message: "Attach a TXT, Markdown or PDF file with the notes, or paste the notes into the message box."
            ) {
                Button("Attach files…") { AttachActions.chooseAndAttach(to: controller) }
                    .buttonStyle(.borderedProminent)
            }
        case .chooseTwo:
            DMNotice(
                symbol: "rectangle.split.2x1",
                tint: .dmAccent,
                title: "Choose two documents",
                message: "A comparison takes exactly two TXT, Markdown or PDF files. DeskMate reads them on your Mac and cites the right one."
            ) {
                Button("Choose two files…") { AttachActions.chooseAndAttach(to: controller) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
