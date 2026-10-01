import DeskMateCore
import SwiftUI

/// Collapsible sources under an answer. Only excerpts the model really received can appear here;
/// a click opens the exact excerpt in the source drawer.
///
/// Three kinds of evidence stay apart. Sources and cited service results are what the answer cites with a tag that
/// resolved. "Retrieved for this answer (not cited)" lists what DeskMate gave the model in this turn that the answer
/// does not cite: it backs no claim and is never shown as a citation. Compared material is what a comparison read.
struct CitationsView: View {
    let message: ChatMessage
    /// Saved lines of earlier answers by result label, for a cited "[M#]" that an earlier answer retrieved.
    var earlierSummaries: [String: String] = [:]
    @Environment(AppNavigation.self) private var navigation
    @State private var expanded = false
    @State private var materialExpanded = false
    @State private var servicesExpanded = false
    @State private var retrievedExpanded = false

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
                                row(citation, kind: "Cited")
                            }
                        }
                        .padding(.top, DS.Spacing.xs)
                    }
                    .font(.dmCaption)
                } else if message.consultedCount > 0, message.comparedMaterial.isEmpty {
                    Label("DeskMate searched your files, but this answer doesn’t cite any of them.", systemImage: "magnifyingglass")
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                }
                if !citedResults.isEmpty {
                    citedServiceResults
                }
                if retrievedCount > 0 {
                    retrievedNotCited
                }
                if !message.comparedMaterial.isEmpty {
                    comparedMaterial
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
        !message.sources.isEmpty || message.consultedCount > 0 || !message.comparedMaterial.isEmpty || !message.removedCitations.isEmpty
            || !toolItems.isEmpty || !message.retrievedSources.isEmpty
    }

    private var toolItems: [ToolResultItem] {
        // Only an answer that can mention a result or made a call has any to list.
        guard message.role == .assistant, message.text.contains("[M") || message.usedServices || !message.toolSources.isEmpty || !message.retrievedToolSources.isEmpty else { return [] }
        return message.toolResultItems(earlierSummaries: earlierSummaries)
    }

    private var citedResults: [ToolResultItem] { toolItems.filter { $0.kind == .cited } }
    private var retrievedResults: [ToolResultItem] { toolItems.filter { $0.kind == .retrieved } }
    private var retrievedCount: Int { message.retrievedSources.count + retrievedResults.count }

    /// Results a connected service returned that the answer cites. Shown whether or not this answer made a call itself.
    private var citedServiceResults: some View {
        let items = citedResults
        let title = "Service results, \(items.count)"
        return DMDisclosure(
            isExpanded: $servicesExpanded,
            label: title,
            hint: "Shows the results a connected service returned that this answer cites"
        ) {
            Label("Service results (\(items.count))", systemImage: "network")
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                ForEach(items) { item in
                    ToolResultRow(item: item)
                }
            }
            .padding(.top, DS.Spacing.xs)
        }
        .font(.dmCaption)
    }

    /// What DeskMate gave the model for this answer and the answer does not cite. It is here so a result the model used
    /// without a tag can still be inspected. These are not citations and no claim in the answer is attributed to them.
    private var retrievedNotCited: some View {
        let title = "Retrieved for this answer (not cited), \(retrievedCount)"
        return DMDisclosure(
            isExpanded: $retrievedExpanded,
            label: title,
            hint: "Shows what DeskMate gave the model for this answer that the answer does not cite"
        ) {
            Label("Retrieved for this answer (not cited) (\(retrievedCount))", systemImage: "tray")
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("The model was given these for this answer. The answer does not cite them, so none of its statements is attributed to them.")
                    .font(.dmCaption)
                    .foregroundStyle(.tertiary)
                ForEach(retrievedResults) { item in
                    ToolResultRow(item: item)
                }
                ForEach(message.retrievedSources) { citation in
                    row(citation, kind: "Retrieved, not cited")
                }
            }
            .padding(.top, DS.Spacing.xs)
        }
        .font(.dmCaption)
    }

    /// The excerpts a comparison was built from, grouped by file. Kept apart from "Sources" because they were read,
    /// not cited for individual facts.
    private var comparedMaterial: some View {
        let title = DocumentComparison.comparedMaterialTitle(message.comparedMaterial)
        return DMDisclosure(
            isExpanded: $materialExpanded,
            label: title,
            hint: "Shows the excerpts DeskMate read to compare the documents"
        ) {
            Label(title, systemImage: "doc.on.doc")
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                ForEach(DocumentComparison.groupedByFile(message.comparedMaterial), id: \.fileName) { group in
                    Text(group.fileName)
                        .font(.dmCaption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, DS.Spacing.xs)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.excerpts) { citation in
                        row(citation, kind: "Compared")
                    }
                }
            }
            .padding(.top, DS.Spacing.xs)
        }
        .font(.dmCaption)
    }

    private func row(_ citation: SourceCitation, kind: String) -> some View {
        Button {
            navigation.show(citation)
        } label: {
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                Text(citation.id)
                    .font(.dmCaption.weight(.semibold))
                    .foregroundStyle(Color.dmBrandText)
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
        .accessibilityLabel(spokenLabel(for: citation, kind: kind))
        .accessibilityValue(citation.excerpt)
        .accessibilityHint("Shows the excerpt")
    }

    /// "Cited, S1, lumen-security-review.pdf, Page 1": the kind, the label and the source. The body is the value.
    private func spokenLabel(for citation: SourceCitation, kind: String) -> String {
        "\(kind), \(DocumentComparison.spokenLabel(for: citation))"
    }
}
