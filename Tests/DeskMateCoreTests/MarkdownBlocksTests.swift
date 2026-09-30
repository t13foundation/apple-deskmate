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
}
