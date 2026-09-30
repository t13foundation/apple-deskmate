import Testing
@testable import DeskMateCore

/// The guided comparison result is rendered by code, so the layout and the citation rules do not depend on the model.
@Suite struct ComparisonRenderingTests {
    private func citation(_ id: String, file: String) -> SourceCitation {
        SourceCitation(id: id, chunkID: "c-\(id)", fileID: file, fileName: file, location: nil, excerpt: "text", truncated: false, origin: .attachment)
    }

    private var citationsA: [String: SourceCitation] { ["S1": citation("S1", file: "a.md"), "S2": citation("S2", file: "a.md")] }
    private var citationsB: [String: SourceCitation] { ["S3": citation("S3", file: "b.md")] }

    @Test func rendersTableThenGapsThenQuestionsAndEscapesCells() {
        let result = ComparisonResult(
            rows: [ComparisonRow(topic: "Offices | sites", documentA: "Berlin |\n Lisbon [S1]", documentB: "Berlin [S3]")],
            gaps: ["Only A names an owner [S2]"],
            questions: ["Who approves the budget?"]
        )
        let rendered = DocumentComparison.render(result, citationsA: citationsA, citationsB: citationsB)
        #expect(rendered.markdown == """
        | Topic | Document A | Document B |
        | --- | --- | --- |
        | Offices \\| sites | Berlin \\| Lisbon [S1] | Berlin [S3] |

        ### Gaps

        - Only A names an owner [S2]

        ### Questions to resolve

        - Who approves the budget?
        """)
        #expect(rendered.removedCitations.isEmpty)
    }

    @Test func citationsMustBelongToTheirOwnDocument() {
        let result = ComparisonResult(
            rows: [ComparisonRow(topic: "Launch", documentA: "14 June [S1, S3]", documentB: "28 July [S1] [S9]")],
            gaps: [], questions: []
        )
        let rendered = DocumentComparison.render(result, citationsA: citationsA, citationsB: citationsB)
        #expect(rendered.markdown.contains("| Launch | 14 June [S1] | 28 July |"))
        #expect(rendered.removedCitations.sorted() == ["S1", "S3", "S9"])
        #expect(DocumentComparison.removedCitationNote(rendered.removedCitations)?.contains("S9") == true)
        #expect(DocumentComparison.removedCitationNote([]) == nil)
    }
}
