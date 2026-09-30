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
        /// A GitHub-style pipe table, parsed from the source lines. See `MarkdownTable`.
        case table(MarkdownTable)
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

/// A GitHub-style table: one header row and body rows padded or cut to the header's column count.
/// Cells keep inline Markdown (bold, code, `[S#]` citations); links are removed like everywhere else.
public struct MarkdownTable: Equatable, Sendable {
    public var header: [AttributedString]
    public var rows: [[AttributedString]]

    public init(header: [AttributedString], rows: [[AttributedString]]) {
        self.header = header
        self.rows = rows
    }

    public var columnCount: Int { header.count }

    /// One spoken line per body row: "Topic, file A: …, file B: …". Empty cells are left out.
    public func accessibilityLabel(forRow index: Int) -> String {
        guard rows.indices.contains(index) else { return "" }
        let row = rows[index]
        var parts: [String] = []
        if let first = row.first, !String(first.characters).isEmpty {
            parts.append(String(first.characters))
        }
        for column in 1..<max(columnCount, 1) where row.indices.contains(column) {
            let value = String(row[column].characters)
            guard !value.isEmpty else { continue }
            let name = String(header[column].characters)
            parts.append(name.isEmpty ? value : "\(name): \(value)")
        }
        return parts.joined(separator: ", ")
    }

    /// Plain text of the whole table (tab-separated), for `MarkdownBlock.plainText`.
    var plainText: String {
        ([header] + rows).map { $0.map { String($0.characters) }.joined(separator: "\t") }.joined(separator: "\n")
    }
}

public enum MarkdownParser {
    /// Parses possibly incomplete Markdown (streaming) into blocks. Never throws; falls back to plain text.
    /// Pipe tables are recognised from the source lines first (outside code fences); everything else goes
    /// through the system Markdown parser.
    public static func blocks(from markdown: String) -> [MarkdownBlock] {
        guard !markdown.isEmpty else { return [] }
        var result: [MarkdownBlock] = []
        for segment in segments(of: markdown) {
            switch segment {
            case .text(let text): result += textBlocks(from: text)
            case .table(let table):
                result.append(MarkdownBlock(kind: .table(table), content: AttributedString(table.plainText)))
            }
        }
        return result
    }

    // MARK: Tables

    private enum Segment {
        case text(String)
        case table(MarkdownTable)
    }

    private static func segments(of markdown: String) -> [Segment] {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard markdown.contains("|") else { return [.text(markdown)] }

        var segments: [Segment] = []
        var pending: [String] = []
        var inFence = false
        var index = 0

        func flushText() {
            if !pending.isEmpty { segments.append(.text(pending.joined(separator: "\n"))) }
            pending = []
        }

        while index < lines.count {
            let line = lines[index]
            if isFence(line) {
                inFence.toggle()
                pending.append(line)
                index += 1
                continue
            }
            if !inFence, index + 1 < lines.count, let table = table(startingAt: index, in: lines) {
                flushText()
                segments.append(.table(table.table))
                index = table.next
                continue
            }
            pending.append(line)
            index += 1
        }
        flushText()
        return segments
    }

    private static func isFence(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func isTableCandidate(_ line: String) -> Bool {
        line.contains("|") && !line.hasPrefix("    ") && !line.hasPrefix("\t")
    }

    /// A table is a pipe row, a delimiter row of the same width (`| --- | :---: |`), then pipe rows until a blank or pipe-less line.
    private static func table(startingAt start: Int, in lines: [String]) -> (table: MarkdownTable, next: Int)? {
        guard isTableCandidate(lines[start]), isTableCandidate(lines[start + 1]) else { return nil }
        let headerCells = splitRow(lines[start])
        let delimiterCells = splitRow(lines[start + 1])
        guard !headerCells.isEmpty, headerCells.count == delimiterCells.count,
              delimiterCells.allSatisfy(isDelimiterCell) else { return nil }

        var rows: [[AttributedString]] = []
        var next = start + 2
        while next < lines.count, isTableCandidate(lines[next]), !isFence(lines[next]) {
            var cells = splitRow(lines[next]).map(inlineCell)
            if cells.count > headerCells.count { cells = Array(cells.prefix(headerCells.count)) }
            while cells.count < headerCells.count { cells.append(AttributedString()) }
            rows.append(cells)
            next += 1
        }
        return (MarkdownTable(header: headerCells.map(inlineCell), rows: rows), next)
    }

    private static func isDelimiterCell(_ cell: String) -> Bool {
        var body = Substring(cell)
        if body.hasPrefix(":") { body = body.dropFirst() }
        if body.hasSuffix(":") { body = body.dropLast() }
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    /// Splits a pipe row into trimmed cells. A backslash-escaped pipe stays a literal pipe inside the cell;
    /// one leading and one trailing delimiter pipe are optional.
    static func splitRow(_ line: String) -> [String] {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|") { text = text.dropFirst() }
        var cells: [String] = []
        var current = ""
        var endedOnDelimiter = false
        var iterator = text.makeIterator()
        var carried: Character?
        while let character = carried ?? iterator.next() {
            carried = nil
            endedOnDelimiter = false
            if character == "\\" {
                if let following = iterator.next() {
                    if following == "|" { current.append("|") } else { current.append(character); carried = following }
                } else {
                    current.append(character)
                }
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                endedOnDelimiter = true
            } else {
                current.append(character)
            }
        }
        if !endedOnDelimiter { cells.append(current.trimmingCharacters(in: .whitespaces)) }
        return cells
    }

    private static func inlineCell(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let source = text
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        var cell = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        cell.link = nil
        return cell
    }

    // MARK: Everything else

    private static func textBlocks(from markdown: String) -> [MarkdownBlock] {
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
