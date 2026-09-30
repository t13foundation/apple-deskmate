import Foundation
import Testing
@testable import DeskMateCore

@Suite struct MarkdownBlocksTests {
    @Test func parsesHeadingParagraphListAndCode() {
        let source = """
        # Title

        Some **bold** text.

        1. First
        2. Second

        - Bullet

        ```
        let x = 1
        ```
        """
        let blocks = MarkdownParser.blocks(from: source)
        let kinds = blocks.map(\.kind)
        #expect(kinds.contains(.heading(level: 1)))
        #expect(kinds.contains(.paragraph))
        #expect(kinds.contains(.listItem(ordinal: 1, depth: 1)))
        #expect(kinds.contains(.listItem(ordinal: 2, depth: 1)))
        #expect(kinds.contains(.listItem(ordinal: nil, depth: 1)))
        let code = blocks.first { if case .codeBlock = $0.kind { true } else { false } }
        #expect(code?.plainText == "let x = 1")
    }

    @Test func linksAreRemovedSoInventedUrlsAreNotClickable() {
        let blocks = MarkdownParser.blocks(from: "See [the report](https://example.invalid/report) now.")
        #expect(blocks.count == 1)
        #expect(blocks[0].plainText == "See the report now.")
        #expect(blocks[0].content.runs.allSatisfy { $0.link == nil })
    }

    @Test func incompleteStreamingMarkdownDoesNotFail() {
        #expect(!MarkdownParser.blocks(from: "**unfinished bold").isEmpty)
        #expect(!MarkdownParser.blocks(from: "```\nunclosed code").isEmpty)
        #expect(MarkdownParser.blocks(from: "").isEmpty)
    }

    @Test func nestedListReportsDepth() {
        let blocks = MarkdownParser.blocks(from: "- A\n  - B\n")
        let depths = blocks.compactMap { block -> Int? in
            if case .listItem(_, let depth) = block.kind { depth } else { nil }
        }
        #expect(depths == [1, 2])
    }

    // MARK: Tables

    private func table(in blocks: [MarkdownBlock]) -> MarkdownTable? {
        for block in blocks { if case .table(let table) = block.kind { return table } }
        return nil
    }

    private func texts(_ cells: [AttributedString]) -> [String] { cells.map { String($0.characters) } }

    @Test func parsesTableWithHeaderSeparatorAndRows() {
        let source = """
        Comparison:

        | Topic | lumen-plan-v1.md | lumen-plan-v2.md |
        | --- | :---: | ---: |
        | Launch | **March** [S1] | April [S2] |
        | Owner | Ana [S3] | Ben [S4] |

        Done.
        """
        let blocks = MarkdownParser.blocks(from: source)
        let parsed = table(in: blocks)
        #expect(parsed != nil)
        #expect(texts(parsed?.header ?? []) == ["Topic", "lumen-plan-v1.md", "lumen-plan-v2.md"])
        #expect(parsed?.rows.count == 2)
        #expect(texts(parsed?.rows[0] ?? []) == ["Launch", "March [S1]", "April [S2]"])
        #expect(texts(parsed?.rows[1] ?? []) == ["Owner", "Ana [S3]", "Ben [S4]"])
        // Inline Markdown survives in a cell.
        let bold = parsed?.rows[0][1].runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold != nil)
        // Prose before and after stays prose, in order.
        #expect(blocks.first?.plainText == "Comparison:")
        #expect(blocks.last?.plainText == "Done.")
        #expect(blocks.count == 3)
    }

    @Test func escapedPipeStaysInsideTheCell() {
        let parsed = table(in: MarkdownParser.blocks(from: "| Key | Value |\n|---|---|\n| a \\| b | c |"))
        #expect(texts(parsed?.rows.first ?? []) == ["a | b", "c"])
    }

    @Test func raggedRowsArePaddedAndCutToTheHeaderWidth() {
        let parsed = table(in: MarkdownParser.blocks(from: "| A | B | C |\n| - | - | - |\n| 1 |\n| 1 | 2 | 3 | 4 |"))
        #expect(texts(parsed?.rows[0] ?? []) == ["1", "", ""])
        #expect(texts(parsed?.rows[1] ?? []) == ["1", "2", "3"])
    }

    @Test func rowsWithoutOuterPipesAreAccepted() {
        let parsed = table(in: MarkdownParser.blocks(from: "A | B\n--|--\n1 | 2"))
        #expect(texts(parsed?.header ?? []) == ["A", "B"])
        #expect(texts(parsed?.rows.first ?? []) == ["1", "2"])
    }

    @Test func pipeLinesThatAreNotTablesStayParagraphs() {
        // No delimiter row.
        #expect(table(in: MarkdownParser.blocks(from: "Use a | b to choose.\nThen continue.")) == nil)
        // Delimiter row of a different width.
        #expect(table(in: MarkdownParser.blocks(from: "| A | B |\n| --- |\n| 1 | 2 |")) == nil)
        // Delimiter row that is not dashes.
        #expect(table(in: MarkdownParser.blocks(from: "| A | B |\n| x | y |\n| 1 | 2 |")) == nil)
        let blocks = MarkdownParser.blocks(from: "Choose a | b")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
    }

    @Test func tableInsideCodeFenceIsNotParsed() {
        let source = "```\n| A | B |\n| - | - |\n| 1 | 2 |\n```"
        let blocks = MarkdownParser.blocks(from: source)
        #expect(table(in: blocks) == nil)
        #expect(blocks.contains { if case .codeBlock = $0.kind { true } else { false } })
    }

    @Test func tableEndsAtBlankLineAndPartialStreamingRowIsKept() {
        let blocks = MarkdownParser.blocks(from: "| A | B |\n| - | - |\n| 1 | 2 |\n\nafter | text\n\n| A | B |\n| - | - |\n| 3")
        let tables = blocks.compactMap { block -> MarkdownTable? in
            if case .table(let table) = block.kind { table } else { nil }
        }
        #expect(tables.count == 2)
        #expect(tables[0].rows.count == 1)
        #expect(texts(tables[1].rows[0]) == ["3", ""])
    }

    @Test func rowAccessibilityLabelNamesEachColumn() {
        let parsed = table(in: MarkdownParser.blocks(from: "| Topic | v1.md | v2.md |\n|-|-|-|\n| Launch | March [S1] | April [S2] |\n| Owner | Ana | |"))
        #expect(parsed?.accessibilityLabel(forRow: 0) == "Launch, v1.md: March [S1], v2.md: April [S2]")
        #expect(parsed?.accessibilityLabel(forRow: 1) == "Owner, v1.md: Ana")
        #expect(parsed?.accessibilityLabel(forRow: 9) == "")
    }
}
