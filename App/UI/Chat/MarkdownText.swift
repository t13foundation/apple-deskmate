import DeskMateCore
import SwiftUI

/// Selectable Markdown answer. Consecutive prose, list and code blocks are merged into one `Text` so selection
/// works across paragraphs and lists; a pipe table is its own native view between those runs.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            let segments = MarkdownStyler.segments(markdown)
            ForEach(segments.indices, id: \.self) { index in
                switch segments[index] {
                case .text(let text):
                    Text(text)
                        .lineSpacing(DS.Spacing.xs)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                case .table(let table):
                    MarkdownTableView(table: table)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A Markdown table. In a wide column it is an aligned grid with a header row; in a narrow column it becomes one
/// card per row (first cell as the title, then "column: value" lines), so nothing is clipped or scrolled sideways.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    @State private var width: CGFloat = .infinity

    /// Wide enough for the grid: the stacked-card threshold, and at least a readable width for every column.
    private var useGrid: Bool {
        width >= max(DS.Layout.tableStackedWidth, CGFloat(table.columnCount) * DS.Layout.tableMinColumnWidth)
    }

    var body: some View {
        Group {
            if useGrid { grid } else { stacked }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityRepresentation {
            VStack(alignment: .leading) {
                ForEach(table.rows.indices, id: \.self) { row in
                    Text(table.accessibilityLabel(forRow: row))
                }
            }
        }
    }

    // MARK: Wide

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], header: true)
                }
            }
            ForEach(table.rows.indices, id: \.self) { row in
                Divider()
                GridRow {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        cell(table.rows[row][column], header: false)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .dmSurface(radius: DS.Radius.control)
    }

    private func cell(_ content: AttributedString, header: Bool) -> some View {
        Text(MarkdownStyler.inline(content, size: header ? DS.FontSize.caption : DS.FontSize.body, weight: header ? .semibold : .regular))
            .textSelection(.enabled)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(header ? Color.dmSubtleFill : Color.clear)
    }

    // MARK: Narrow

    private var stacked: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ForEach(table.rows.indices, id: \.self) { row in
                card(table.rows[row])
            }
        }
    }

    private func card(_ cells: [AttributedString]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if let title = cells.first, !title.characters.isEmpty {
                Text(MarkdownStyler.inline(title, size: DS.FontSize.body, weight: .semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(cells.enumerated()).dropFirst(), id: \.offset) { column, value in
                if !value.characters.isEmpty {
                    Text(MarkdownStyler.labelled(table.header[column], value))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dmSurface(radius: DS.Radius.control)
    }
}

enum MarkdownStyler {
    enum Segment {
        case text(AttributedString)
        case table(MarkdownTable)
    }

    private static let bodySize = DS.FontSize.body
    /// Monospaced text is set one step down (12 on 14) so it does not look larger than the prose around it.
    private static let codeSize = DS.FontSize.caption
    private static let codeBackground = Color.dmSubtleFill

    /// Splits an answer into runs of styled text and tables, in order.
    static func segments(_ markdown: String) -> [Segment] {
        var segments: [Segment] = []
        var run: [MarkdownBlock] = []

        func flushRun() {
            if !run.isEmpty { segments.append(.text(attributed(run))) }
            run = []
        }

        for block in MarkdownParser.blocks(from: markdown) {
            if case .table(let table) = block.kind {
                flushRun()
                segments.append(.table(table))
            } else {
                run.append(block)
            }
        }
        flushRun()
        return segments
    }

    /// The styled text of a table cell.
    static func inline(_ content: AttributedString, size: CGFloat, weight: Font.Weight) -> AttributedString {
        var styled = content
        styleInline(&styled, size: size, weight: weight)
        return styled
    }

    /// "Column: value" for the stacked table layout; the column name is secondary. No name, just the value.
    static func labelled(_ name: AttributedString, _ value: AttributedString) -> AttributedString {
        var output = AttributedString()
        if !name.characters.isEmpty {
            var label = AttributedString(String(name.characters) + ": ")
            label.font = .system(size: DS.FontSize.caption, weight: .semibold)
            label.foregroundColor = .secondary
            output.append(label)
        }
        output.append(inline(value, size: bodySize, weight: .regular))
        return output
    }

    static func attributed(_ blocks: [MarkdownBlock]) -> AttributedString {
        var output = AttributedString()
        var previous: MarkdownBlock.Kind?
        for block in blocks {
            if let previous {
                output.append(separator(from: previous, to: block.kind))
            }
            output.append(render(block))
            previous = block.kind
        }
        return output
    }

    static func attributed(_ markdown: String) -> AttributedString {
        attributed(MarkdownParser.blocks(from: markdown))
    }

    // MARK: Separators

    private static func separator(from previous: MarkdownBlock.Kind, to next: MarkdownBlock.Kind) -> AttributedString {
        switch (previous, next) {
        case (.listItem, .listItem):
            return AttributedString("\n")
        case (.tableCell(let rowA, _), .tableCell(let rowB, _)):
            if rowA == rowB {
                var cell = AttributedString("   |   ")
                cell.foregroundColor = .secondary
                cell.font = .system(size: bodySize)
                return cell
            }
            return AttributedString("\n")
        default:
            // A paragraph break: end the line, then a short empty line for breathing room.
            var gap = AttributedString("\n")
            var small = AttributedString("\n")
            gap.font = .system(size: bodySize)
            small.font = .system(size: DS.Spacing.s)
            gap.append(small)
            return gap
        }
    }

    // MARK: Blocks

    private static func render(_ block: MarkdownBlock) -> AttributedString {
        var content = block.content
        switch block.kind {
        case .paragraph, .tableCell:
            styleInline(&content, size: bodySize, weight: .regular)
            return content

        case .table:
            // Tables are separate views (see `segments`); this only keeps the switch exhaustive.
            return AttributedString()

        case .heading(let level):
            let size = level <= 2 ? DS.FontSize.section : bodySize
            styleInline(&content, size: size, weight: .semibold)
            return content

        case .listItem(let ordinal, let depth):
            styleInline(&content, size: bodySize, weight: .regular)
            let indent = String(repeating: "     ", count: max(depth - 1, 0))
            var marker = AttributedString(indent + (ordinal.map { "\($0)." } ?? "•") + "  ")
            marker.font = .system(size: bodySize, weight: .medium)
            marker.foregroundColor = .secondary
            marker.append(content)
            return marker

        case .codeBlock:
            var code = AttributedString(String(content.characters))
            code.font = .system(size: codeSize, design: .monospaced)
            code.backgroundColor = codeBackground
            return code

        case .quote:
            styleInline(&content, size: bodySize, weight: .regular)
            content.foregroundColor = .secondary
            var bar = AttributedString("▎ ")
            bar.foregroundColor = Color.dmBrandText
            bar.font = .system(size: bodySize)
            bar.append(content)
            return bar
        }
    }

    /// Converts Markdown emphasis into concrete fonts and removes the Markdown-only attributes.
    private static func styleInline(_ content: inout AttributedString, size: CGFloat, weight: Font.Weight) {
        let spans = content.runs.map { ($0.range, $0.inlinePresentationIntent) }
        for (range, intent) in spans {
            let intent = intent ?? []
            var font = Font.system(size: size, weight: weight)
            if intent.contains(.stronglyEmphasized) { font = Font.system(size: size, weight: .semibold) }
            if intent.contains(.emphasized) { font = font.italic() }
            if intent.contains(.code) {
                font = .system(size: codeSize, design: .monospaced)
                content[range].backgroundColor = codeBackground
            }
            if intent.contains(.strikethrough) { content[range].strikethroughStyle = .single }
            content[range].font = font
            content[range].inlinePresentationIntent = nil
        }
    }
}
