import DeskMateCore
import SwiftUI

/// Collapsible sources under an answer. Only excerpts the model really received can appear here;
/// a click opens the exact excerpt in the source drawer.
struct CitationsView: View {
    let message: ChatMessage
    @Environment(AppNavigation.self) private var navigation
    @State private var expanded = false

    var body: some View {
        if message.status != .streaming, hasContent {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if !message.sources.isEmpty {
                    // The label belongs to the toggle only. A label on a container replaced every source row with
                    // "Sources, 1" for accessibility, so each row below is its own labelled element.
                    let count = message.sources.count
                    DMDisclosure(
                        isExpanded: $expanded,
                        label: "Sources, \(count) \(count == 1 ? "file" : "files")",
                        hint: "Shows where this answer came from"
                    ) {
                        Label("Sources (\(count))", systemImage: "text.quote")
                            .font(.dmCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } content: {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            ForEach(message.sources) { citation in
                                row(citation)
                            }
                        }
                        .padding(.top, DS.Spacing.xs)
                    }
                    .font(.dmCaption)
                } else if message.consultedCount > 0 {
                    Label("DeskMate searched your files, but this answer doesn’t cite any of them.", systemImage: "magnifyingglass")
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                }
                if !message.removedCitations.isEmpty {
                    Label("Removed \(message.removedCitations.count == 1 ? "a reference" : "\(message.removedCitations.count) references") to an excerpt DeskMate never gave the model (\(message.removedCitations.joined(separator: ", "))).", systemImage: "exclamationmark.triangle")
                        .font(.dmCaption)
                        .foregroundStyle(Color.dmWarning)
                }
            }
        }
    }

    private var hasContent: Bool {
        !message.sources.isEmpty || message.consultedCount > 0 || !message.removedCitations.isEmpty
    }

    private func row(_ citation: SourceCitation) -> some View {
        Button {
            navigation.show(citation)
        } label: {
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                Text(citation.id)
                    .font(.dmCaption.weight(.semibold))
                    .foregroundStyle(Color.dmAccent)
                    .frame(minWidth: DS.Spacing.xl, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(citation.title)
                        .font(.dmCaption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(citation.excerpt)
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel(for: citation))
        .accessibilityHint("Shows the excerpt")
    }

    /// "S1, lumen-security-review.pdf, Page 1".
    private func spokenLabel(for citation: SourceCitation) -> String {
        [citation.id, citation.fileName, citation.location].compactMap { $0 }.joined(separator: ", ")
    }
}
