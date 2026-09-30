import Foundation

/// One block of a Markdown answer. The UI turns blocks into one selectable styled text.
public struct MarkdownBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case listItem(ordinal: Int?, depth: Int)
        case codeBlock(language: String?)
        case quote
        case tableCell(row: Int, column: Int)
    }

    public var kind: Kind
    /// Inline content (bold, italic, inline code, strikethrough). Links are removed on purpose:
    /// the model may invent URLs and DeskMate never presents them as real sources.
    public var content: AttributedString

    public init(kind: Kind, content: AttributedString) {
        self.kind = kind
        self.content = content
    }

    public var plainText: String { String(content.characters) }
}

public enum MarkdownParser {
    /// Parses possibly incomplete Markdown (streaming) into blocks. Never throws; falls back to plain text.
    public static func blocks(from markdown: String) -> [MarkdownBlock] {
        guard !markdown.isEmpty else { return [] }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return [MarkdownBlock(kind: .paragraph, content: AttributedString(markdown))]
        }

        var blocks: [MarkdownBlock] = []
        var currentKey: Int?
        var currentKind: MarkdownBlock.Kind = .paragraph
        var currentContent = AttributedString()

        func flush() {
            if currentKey != nil {
                var content = currentContent
                content.presentationIntent = nil
                content.link = nil
                blocks.append(MarkdownBlock(kind: currentKind, content: content))
            }
            currentKey = nil
            currentContent = AttributedString()
        }

        for run in parsed.runs {
            let (key, kind) = classify(run.presentationIntent)
            if key != currentKey {
                flush()
                currentKey = key
                currentKind = kind
            }
            currentContent.append(AttributedString(parsed[run.range]))
        }
        flush()

        // Trim the trailing newline the parser keeps inside code blocks.
        return blocks.map { block in
            guard case .codeBlock = block.kind else { return block }
            var trimmed = block
            let text = String(block.content.characters)
            if text.hasSuffix("\n"), let last = block.content.characters.indices.last {
                trimmed.content.removeSubrange(last..<block.content.endIndex)
            }
            return trimmed
        }
    }

    /// Returns a grouping key (the innermost block identity) and the block kind.
    private static func classify(_ intent: PresentationIntent?) -> (Int, MarkdownBlock.Kind) {
        guard let intent else { return (-1, .paragraph) }
        let components = intent.components // innermost first
        let key = components.first?.identity ?? -1
        var depth = 0
        var ordered = false
        var sawParentList = false
        var ordinal: Int?
        var kind: MarkdownBlock.Kind?
        var isQuote = false
        var row: Int?
        var column: Int?

        for component in components {
            switch component.kind {
            case .header(let level): kind = kind ?? .heading(level: level)
            case .codeBlock(let language): kind = kind ?? .codeBlock(language: language)
            case .listItem(let value): ordinal = ordinal ?? value
            case .orderedList:
                depth += 1
                if !sawParentList { ordered = true; sawParentList = true }
            case .unorderedList:
                depth += 1
                sawParentList = true
            case .blockQuote: isQuote = true
            case .tableCell(let value): column = value
            case .tableRow(let value): row = value
            case .tableHeaderRow: row = row ?? 0
            default: break
            }
        }

        if let kind { return (key, kind) }
        if let column { return (key, .tableCell(row: row ?? 0, column: column)) }
        if let ordinal { return (key, .listItem(ordinal: ordered ? ordinal : nil, depth: max(depth, 1))) }
        if isQuote { return (key, .quote) }
        return (key, .paragraph)
    }
}
