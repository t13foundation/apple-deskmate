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
        let rendered = DocumentComparison.render(result, citationsA: citationsA, citationsB: citationsB, nameA: "a.md", nameB: "b.md")
        #expect(rendered.markdown == """
        | Topic | a.md | b.md |
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
        let rendered = DocumentComparison.render(result, citationsA: citationsA, citationsB: citationsB, nameA: "a.md", nameB: "b.md")
        #expect(rendered.markdown.contains("| Launch | 14 June [S1] | 28 July |"))
        #expect(rendered.removedCitations.sorted() == ["S1", "S3", "S9"])
        #expect(DocumentComparison.removedCitationNote(rendered.removedCitations)?.contains("S9") == true)
        #expect(DocumentComparison.removedCitationNote([]) == nil)
    }

    @Test func theColumnsAreNamedAfterTheirFilesAndKeepEscaping() {
        let result = ComparisonResult(rows: [ComparisonRow(topic: "Budget", documentA: "10", documentB: "12")], gaps: [], questions: [])
        let rendered = DocumentComparison.render(result, citationsA: [:], citationsB: [:], nameA: "lumen-plan-v1.md", nameB: "plan | v2\n.md")
        #expect(rendered.markdown.hasPrefix("| Topic | lumen-plan-v1.md | plan \\| v2 .md |\n| --- | --- | --- |"))
        #expect(!rendered.markdown.contains("Document A"))
    }
}

/// The excerpts read by a comparison are listed as compared material, apart from per-fact citations.
@Suite struct ComparedMaterialTests {
    private func citation(_ id: String, file: String, location: String?) -> SourceCitation {
        SourceCitation(id: id, chunkID: "c-\(id)", fileID: file, fileName: file, location: location, excerpt: "text \(id)", truncated: false, origin: .attachment)
    }

    @Test func materialIsExactlyWhatWasGivenAndCitationsStayApart() {
        let ledger = SourceLedger()
        ledger.beginTurn()
        let given = [
            citation("S1", file: "a.md", location: "Section: Budget"),
            citation("S2", file: "a.md", location: "Section: Team"),
            citation("S3", file: "b.md", location: "Section: Budget"),
        ]
        for item in given { ledger.recordCompared(item) }
        ledger.recordCompared(given[0]) // the same excerpt read twice is listed once

        let withoutIDs = ledger.ground("Both plans differ on budget.")
        #expect(withoutIDs.comparedMaterial == given)
        #expect(withoutIDs.sources.isEmpty)

        let withIDs = ledger.ground("Budget is higher [S3] [S7].")
        #expect(withIDs.sources.map(\.id) == ["S3"])
        #expect(withIDs.removedCitations == ["S7"])
        #expect(withIDs.comparedMaterial == given)

        ledger.beginTurn()
        #expect(ledger.ground("A later normal answer.").comparedMaterial.isEmpty)
    }

    @Test func materialIsLabelledDifferentlyFromSourcesAndGroupedByFile() {
        let material = [
            citation("S1", file: "a.md", location: "Section: Budget"),
            citation("S2", file: "b.md", location: nil),
            citation("S3", file: "a.md", location: "Section: Team"),
        ]
        let title = DocumentComparison.comparedMaterialTitle(material)
        #expect(title == "Compared material (2 files, 3 excerpts)")
        #expect(!title.contains("Sources"))
        #expect(DocumentComparison.comparedMaterialTitle([material[0]]) == "Compared material (1 file, 1 excerpt)")
        let groups = DocumentComparison.groupedByFile(material)
        #expect(groups.map(\.fileName) == ["a.md", "b.md"])
        #expect(groups[0].excerpts.map(\.id) == ["S1", "S3"])
        #expect(DocumentComparison.spokenLabel(for: material[0]) == "S1, a.md, Section: Budget")
        #expect(DocumentComparison.spokenLabel(for: material[1]) == "S2, b.md")
    }
}
