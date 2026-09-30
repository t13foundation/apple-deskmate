import DeskMateCore
import SwiftUI

/// Selectable Markdown answer. All blocks are merged into one `Text` so selection works across paragraphs,
/// lists and code, and VoiceOver reads the answer as one element.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        Text(MarkdownStyler.attributed(markdown))
            .lineSpacing(DS.Spacing.xs)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum MarkdownStyler {
    private static let bodySize = DS.FontSize.body
    /// Monospaced text is set one step down (12 on 14) so it does not look larger than the prose around it.
    private static let codeSize = DS.FontSize.caption
    private static let codeBackground = Color.dmSubtleFill

    static func attributed(_ markdown: String) -> AttributedString {
        let blocks = MarkdownParser.blocks(from: markdown)
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
            bar.foregroundColor = Color.dmAccent
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
