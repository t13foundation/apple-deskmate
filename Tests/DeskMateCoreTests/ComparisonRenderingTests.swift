import Testing
@testable import DeskMateCore

/// The pairing result is rendered by code from the facts, so a fact cannot move to the other document's column.
@Suite struct ComparisonRenderingTests {
    private let factsA = [
        DocumentFact(id: "A1", topic: "Launch", statement: "Launch is 14 June 2026.", excerptID: "S3"),
        DocumentFact(id: "A2", topic: "Offices", statement: "Only the Lisbon office is covered.", excerptID: "S1"),
        DocumentFact(id: "A3", topic: "Privacy", statement: "The privacy review has no owner.", excerptID: nil),
    ]
    private let factsB = [
        DocumentFact(id: "B1", topic: "Launch", statement: "Launch is 28 July 2026.", excerptID: "S7"),
        DocumentFact(id: "B2", topic: "Budget", statement: "The budget was raised after the Brightway quote.", excerptID: "S9"),
        DocumentFact(id: "B3", topic: "Privacy", statement: "Nadia Okafor owns the privacy review.", excerptID: "S6"),
    ]

    private func render(_ pairing: FactPairing) -> (markdown: String, droppedReferences: Int) {
        DocumentComparison.render(pairing, factsA: factsA, factsB: factsB, nameA: "plan-v1.md", nameB: "plan-v2.md")
    }

    @Test func cellsShowOnlyTheirOwnDocumentsFactsWithTheirOwnExcerpts() {
        let rendered = render(FactPairing(
            rows: [PairedRow(topic: "Launch | date", aFacts: ["A1"], bFacts: ["B1"], relation: .differ)],
            questions: ["Who approves the launch?"]
        ))
        #expect(rendered.markdown.hasPrefix("""
        | Topic | plan-v1.md | plan-v2.md |
        | --- | --- | --- |
        | Launch \\| date | Launch is 14 June 2026. [S3] | Launch is 28 July 2026. [S7] |
        """))
        #expect(rendered.markdown.contains("### Questions to resolve\n\n- Who approves the launch?"))
        #expect(rendered.droppedReferences == 0)
    }

    @Test func aFactOfTheOtherDocumentOrAnUnknownIDIsDroppedAndCounted() {
        let rendered = render(FactPairing(
            // B2 (the v2-only budget reason) is listed on the A side, A1 on the B side, A9 and "budget" exist nowhere.
            rows: [PairedRow(topic: "Launch", aFacts: ["A1", "B2", "A9"], bFacts: ["B1", "A1", "budget"], relation: .differ)],
            questions: []
        ))
        #expect(rendered.droppedReferences == 4)
        let row = rendered.markdown.split(separator: "\n").first { $0.hasPrefix("| Launch") }.map(String.init) ?? ""
        #expect(row == "| Launch | Launch is 14 June 2026. [S3] | Launch is 28 July 2026. [S7] |")
        #expect(!row.contains("Brightway"))
        #expect(DocumentComparison.droppedReferenceNote(4)?.contains("4 references") == true)
        #expect(DocumentComparison.droppedReferenceNote(1)?.contains("1 reference ") == true)
        #expect(DocumentComparison.droppedReferenceNote(0) == nil)
    }

    @Test func gapsAreComputedFromFactsNoRowPairsAndCapped() {
        let rendered = render(FactPairing(
            rows: [
                PairedRow(topic: "Launch", aFacts: ["A1"], bFacts: ["B1"], relation: .differ),
                PairedRow(topic: "Budget", aFacts: [], bFacts: ["B2"], relation: .onlyB),
            ],
            questions: []
        ))
        // B2 comes from a one-sided row; A2, A3 and B3 were never paired. The fact without an excerpt is marked uncited.
        #expect(rendered.markdown.contains("""
        ### Gaps

        - Only in plan-v2.md: The budget was raised after the Brightway quote. [S9]
        - Only in plan-v1.md: Only the Lisbon office is covered. [S1]
        - Only in plan-v1.md: The privacy review has no owner. (uncited)
        - Only in plan-v2.md: Nadia Okafor owns the privacy review. [S6]
        """))
        #expect(!rendered.markdown.contains("| Budget |"))

        let many = (1...9).map { DocumentFact(id: "A\($0)", topic: "T", statement: "Fact \($0).", excerptID: "S1") }
        let capped = DocumentComparison.render(FactPairing(rows: [], questions: []), factsA: many, factsB: [], nameA: "a.md", nameB: "b.md")
        #expect(capped.markdown.contains("- Only in a.md: Fact 6. [S1]"))
        #expect(!capped.markdown.contains("Fact 7."))
        #expect(capped.markdown.hasSuffix("- and 3 more"))
    }

    @Test func aFactPairedInATableRowIsNotAlsoAGap() {
        let rendered = render(FactPairing(
            rows: [
                PairedRow(topic: "Launch", aFacts: ["A1"], bFacts: ["B1"], relation: .agree),
                PairedRow(topic: "Launch again", aFacts: ["A1"], bFacts: [], relation: .onlyA),
            ],
            questions: []
        ))
        #expect(!rendered.markdown.contains("Only in plan-v1.md: Launch is 14 June 2026."))
    }

    @Test func excerptIDsAreCheckedAgainstTheLabelsOfTheWindow() {
        let generated = [
            ExtractedFact(topic: "Launch [S9]", statement: "Launch is 14 June 2026. [S3]", excerptID: "s3"),
            ExtractedFact(topic: "Budget", statement: "Budget is 48,000 euros.", excerptID: "S9"),
            ExtractedFact(topic: "Empty", statement: "  ", excerptID: "S1"),
        ]
        let notes = DocumentComparison.notes(from: generated, validLabels: ["S1", "S2", "S3"])
        #expect(notes == [
            FactNote(topic: "Launch", statement: "Launch is 14 June 2026.", excerptID: "S3"),
            FactNote(topic: "Budget", statement: "Budget is 48,000 euros.", excerptID: nil),
        ])
        let dedup = DocumentComparison.deduplicated(notes + [FactNote(topic: "x", statement: "launch is 14 June 2026", excerptID: "S1")])
        #expect(dedup.count == 2)
        #expect(DocumentComparison.numbered(dedup, prefix: "B").map(\.id) == ["B1", "B2"])
    }

    @Test func theColumnsAreNamedAfterTheirFilesAndKeepEscaping() {
        let rendered = DocumentComparison.render(
            FactPairing(rows: [PairedRow(topic: "Launch", aFacts: ["A1"], bFacts: ["B1"], relation: .differ)], questions: []),
            factsA: factsA, factsB: factsB, nameA: "lumen-plan-v1.md", nameB: "plan | v2\n.md"
        )
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
