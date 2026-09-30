import AppKit
import DeskMateCore
import SwiftUI

/// The source drawer: the exact excerpt the model received, with its file name and page or section.
struct SourceViewer: View {
    let navigation: AppNavigation
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            if let citation = navigation.viewedCitation {
                content(for: citation)
            } else {
                Text("Select a source under an answer to see the excerpt.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                    .padding(DS.Spacing.l)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func content(for citation: SourceCitation) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Source \(citation.id)")
                    .font(.dmCaption.weight(.semibold))
                    .foregroundStyle(Color.dmAccent)
                Spacer(minLength: 0)
                Button {
                    navigation.closeViewer()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close")
                .accessibilityLabel("Close source")
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(citation.fileName)
                    .font(.dmSection)
                    .textSelection(.enabled)
                if let location = citation.location {
                    Text(location)
                        .font(.dmBody)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Text(citation.origin == .attachment
                 ? "The exact text DeskMate read from the file you attached."
                 : "The exact text DeskMate found in your files and gave to the model.")
                .font(.dmCaption)
                .foregroundStyle(.secondary)

            if citation.truncated {
                Label("This excerpt was too long for the chat and was cut where marked.", systemImage: "scissors")
                    .font(.dmCaption)
                    .foregroundStyle(Color.dmWarning)
            }

            ScrollView {
                Text(citation.excerpt)
                    .font(.dmBody)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.m)
            }
            .dmSurface(radius: DS.Radius.control)
            .accessibilityLabel("Excerpt from \(citation.title)")

            revealSection(for: citation)
        }
        .padding(DS.Spacing.l)
    }

    @ViewBuilder private func revealSection(for citation: SourceCitation) -> some View {
        if citation.origin == .attachment {
            Text("Attached files are read once for one question and are not kept.")
                .font(.dmCaption)
                .foregroundStyle(.secondary)
        } else if let url = library.revealURL(forFileID: citation.fileID) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Show in Finder", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
        } else {
            Text("DeskMate no longer has access to this file, so it can’t be opened from here. The excerpt above is what the model received.")
                .font(.dmCaption)
                .foregroundStyle(.secondary)
        }
    }
}
