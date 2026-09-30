import DeskMateCore
import SwiftUI

/// First-run and new-chat surface. Starter prompts only fill the composer; nothing is sent until the person presses Return.
/// Starters that need files guide the person to add or attach them first.
///
/// The content sits in the shared reading column, slightly above the vertical centre: a title, one supporting
/// line and the three design-system starters as equal compact tiles.
struct EmptyStateView: View {
    let controller: ConversationController
    @Environment(LibraryStore.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(AttachPicker.self) private var picker

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
        let detail: String
    }

    /// The document starters from the design system, shown as tiles.
    private let tiles: [Starter] = [
        Starter(id: "files", symbol: "folder", title: "Ask about my files", detail: "Search your added files"),
        Starter(id: "meeting", symbol: "list.bullet.rectangle", title: "Summarize a meeting", detail: "Paste notes, get a brief"),
        Starter(id: "compare", symbol: "rectangle.split.2x1", title: "Compare documents", detail: "Pick two files"),
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

                    // Three tiles in a row when they fit on one line each; stacked when the window is narrow.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DS.Spacing.s) { tileButtons }
                        VStack(spacing: DS.Spacing.s) { tileButtons }
                    }

                    if let guidance = activeGuidance {
                        guidanceNotice(guidance)
                    }
                }
                .dmReadingColumn()
                .dmEmptyStateAnchor(height: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New chat")
        .dmAnimation(value: guidance)
    }

    private var tileButtons: some View {
        ForEach(tiles) { starter in
            Button {
                choose(starter)
            } label: {
                StarterTile(symbol: starter.symbol, title: starter.title, detail: starter.detail)
            }
            .buttonStyle(DMTileButtonStyle())
            .accessibilityLabel("\(starter.title). \(starter.detail)")
            .accessibilityHint(hint(for: starter))
        }
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
        "Puts a starter in the message box and shows what to add or attach. Nothing is sent until you press Return."
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
        default:
            break
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
                Button("Attach files…") { picker.chooseAndAttach(to: controller) }
                    .buttonStyle(.borderedProminent)
            }
        case .chooseTwo:
            DMNotice(
                symbol: "rectangle.split.2x1",
                tint: .dmAccent,
                title: "Choose two documents",
                message: "A comparison takes exactly two TXT, Markdown or PDF files. DeskMate reads them on your Mac and cites the right one."
            ) {
                Button("Choose two files…") { picker.chooseAndAttach(to: controller) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
