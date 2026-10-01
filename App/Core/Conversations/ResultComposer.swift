import Foundation

/// Turns what the model filled in into Markdown. Every heading, table and marker is written here, in code.
///
/// Rules this type enforces:
/// - Text from the model is flattened to one line and its Markdown structure is escaped, so it cannot add headings,
///   lists, tables, links or HTML of its own.
/// - A source tag survives only if the material really carried it. Tags are renumbered `[S1]`, `[S2]`... in order of
///   first use, and the excerpts they stand for are listed under "Sources", apart from the generated text.
/// - A task's owner or due date appears only when those words occur in the conversation. Otherwise the cell says
///   "Not specified". A task whose evidence is not found word for word in the conversation is left out and counted.
public enum ResultComposer {
    public static let notSpecified = "Not specified"
    public static let incompleteNote = "*This result reached the length limit and may be incomplete.*"
    public static let noneIdentified = "*None identified in the conversation.*"
    public static let maxTasks = 10
    /// Longest excerpt quoted under Sources before it is shortened with an ellipsis.
    public static let maxQuotedCharacters = 280

    public struct Composed: Equatable, Sendable {
        public var markdown: String
        /// Tasks that were left out because their evidence was not in the conversation.
        public var droppedTasks: Int
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"\[\s*R\d+(?:\s*[,;]\s*R\d+)*\s*\]"#)
    private static let idPattern = try! NSRegularExpression(pattern: #"R\d+"#)

    // MARK: Entry point

    public static func compose(_ payload: ResultPayload, material: ResultMaterial, conversationTitle: String, hitLimit: Bool) -> Composed {
        var cited = CitedLabels(known: Set(material.sources.map(\.label)))
        var lines: [String]
        var dropped = 0
        switch payload {
        case .brief(let draft):
            lines = briefLines(draft, title: conversationTitle, cited: &cited)
        case .tasks(let draft):
            let result = taskLines(draft, material: material, title: conversationTitle, cited: &cited)
            lines = result.lines
            dropped = result.dropped
        }
        if dropped > 0 {
            lines += ["", "*\(dropped) \(dropped == 1 ? "task was" : "tasks were") left out because \(dropped == 1 ? "its" : "their") evidence could not be found in the conversation.*"]
        }
        if hitLimit { lines += ["", incompleteNote] }
        lines += sourceLines(cited: cited, material: material)
        return Composed(markdown: lines.joined(separator: "\n") + "\n", droppedTasks: dropped)
    }

    // MARK: Brief

    private static func briefLines(_ draft: BriefDraft, title: String, cited: inout CitedLabels) -> [String] {
        var lines = ["# Brief: \(heading(title))", ""]
        let summary = inline(draft.summary, cited: &cited, escapePipes: false)
        lines += ["## Summary", "", summary.isEmpty ? noneIdentified : summary, ""]
        for (name, items) in [("Decisions", draft.decisions), ("Open questions", draft.openQuestions), ("Next steps", draft.nextSteps)] {
            lines += ["## \(name)", ""]
            let bullets = items.map { inline($0, cited: &cited, escapePipes: false) }.filter { !$0.isEmpty }
            lines += bullets.isEmpty ? [noneIdentified] : bullets.map { "- \($0)" }
            lines.append("")
        }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: Tasks

    private static func taskLines(_ draft: TaskListDraft, material: ResultMaterial, title: String, cited: inout CitedLabels) -> (lines: [String], dropped: Int) {
        var lines = ["# Tasks: \(heading(title))", ""]
        let haystack = ResultGrounding.normalize(stripTags(material.text))
        var rows: [String] = []
        var seen = Set<String>()
        var dropped = 0
        for task in draft.tasks.prefix(maxTasks) {
            // Checked before anything is rendered, so a left-out task cites nothing under Sources.
            guard !stripTags(task.task).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ResultGrounding.contains(haystack: haystack, phrase: stripTags(task.evidence))
            else {
                dropped += 1
                continue
            }
            guard seen.insert(ResultGrounding.normalize(stripTags(task.task))).inserted else { continue }
            let name = inline(task.task, cited: &cited, escapePipes: true)
            let owner = grounded(task.owner, haystack: haystack)
            let due = grounded(task.dueDate, haystack: haystack)
            let quote = inline(task.evidence, cited: &cited, escapePipes: true)
            rows.append("| \(name) | \(cell(owner)) | \(cell(due)) | \(quote) |")
        }
        if rows.isEmpty {
            lines.append("*No tasks were found in the conversation.*")
        } else {
            lines += ["| Task | Owner | Due date | Evidence |", "| --- | --- | --- | --- |"]
            lines += rows
        }
        return (lines, dropped)
    }

    /// The owner or due date as it appears in the conversation, else "Not specified". Never a guess.
    static func grounded(_ value: String, haystack: String) -> String {
        var cleaned = stripTags(value).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["by ", "due ", "on ", "before ", "owner: ", "assigned to "] where cleaned.lowercased().hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !cleaned.isEmpty, ResultGrounding.contains(haystack: haystack, phrase: cleaned) else { return notSpecified }
        return cleaned
    }

    /// A cell that may be a grounded value: escaped, never empty.
    private static func cell(_ text: String) -> String {
        let escaped = line(text, escapePipes: true)
        return escaped.isEmpty ? notSpecified : escaped
    }

    // MARK: Text from the model

    /// Tags the material really had, in order of first use.
    struct CitedLabels {
        let known: Set<String>
        var order: [String] = []

        init(known: Set<String>) { self.known = known }

        mutating func use(_ label: String) -> String? {
            guard known.contains(label) else { return nil }
            if !order.contains(label) { order.append(label) }
            return "S\(order.firstIndex(of: label)! + 1)"
        }
    }

    /// Escapes the model's words and re-inserts only the tags that the material really carried.
    static func inline(_ text: String, cited: inout CitedLabels, escapePipes: Bool) -> String {
        let nsText = text as NSString
        var output = ""
        var cursor = 0
        var droppedTag = false
        for match in tagPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            output += escape(nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), escapePipes: escapePipes)
            cursor = match.range.location + match.range.length
            let body = nsText.substring(with: match.range)
            let labels = idPattern.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length))
                .map { (body as NSString).substring(with: $0.range) }
            let shown = labels.compactMap { cited.use($0) }
            if !shown.isEmpty {
                if !output.isEmpty, !output.hasSuffix(" ") { output += " " }
                output += "[" + shown.joined(separator: ", ") + "]"
            } else {
                droppedTag = true
            }
        }
        output += escape(nsText.substring(from: cursor), escapePipes: escapePipes)
        if droppedTag {
            // A tag that was not real is gone: close the gap it left (double spaces, a space before punctuation).
            output = output.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
        }
        return structural(DocumentComparison.bullet(output))
    }

    static func stripTags(_ text: String) -> String {
        tagPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Makes Markdown characters literal: no links or images (brackets), HTML (angle brackets), code spans, quotes or,
    /// inside a table, pipes. Line breaks become spaces. Emphasis characters stay: they cannot change the structure.
    static func escape(_ text: String, escapePipes: Bool) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "`": out += "\\`"
            case "[": out += "\\["
            case "]": out += "\\]"
            case "<": out += "\\<"
            case ">": out += "\\>"
            case "|": out += escapePipes ? "\\|" : "|"
            case _ where character.isNewline: out += " "
            default: out.append(character)
            }
        }
        return out
    }

    /// A line that would start a heading or a list is made literal. Applied to a whole line, after escaping.
    static func structural(_ line: String) -> String {
        guard let first = line.first else { return line }
        if "#-+*".contains(first) { return "\\" + line }
        if first.isNumber, let end = line.firstIndex(where: { $0 == "." || $0 == ")" }), line[line.startIndex..<end].allSatisfy(\.isNumber) {
            var escaped = line
            escaped.insert("\\", at: end)
            return escaped
        }
        return line
    }

    /// One escaped, flattened line for a cell, a heading or a quote.
    static func line(_ text: String, escapePipes: Bool) -> String {
        structural(DocumentComparison.bullet(escape(text, escapePipes: escapePipes)))
    }

    /// The conversation title as part of a heading.
    static func heading(_ title: String) -> String {
        let flat = line(title, escapePipes: false)
        return flat.isEmpty ? "Conversation" : flat
    }

    // MARK: Sources

    private static func sourceLines(cited: CitedLabels, material: ResultMaterial) -> [String] {
        guard !cited.order.isEmpty else { return [] }
        let byLabel = Dictionary(material.sources.map { ($0.label, $0.citation) }, uniquingKeysWith: { first, _ in first })
        var lines = ["", "## Sources", "", "*Excerpts the conversation's answers cited. They are not part of the generated text above.*", ""]
        for (offset, label) in cited.order.enumerated() {
            guard let citation = byLabel[label] else { continue }
            lines.append("- [S\(offset + 1)] \(line(citation.title, escapePipes: false))")
            var quote = DocumentComparison.bullet(citation.excerpt)
            if quote.count > maxQuotedCharacters { quote = String(quote.prefix(maxQuotedCharacters)).trimmingCharacters(in: .whitespaces) + "…" }
            lines.append("  > \(line(quote, escapePipes: false))")
        }
        return lines
    }
}

/// Checks that words from the model really occur in the conversation.
public enum ResultGrounding {
    /// Lowercase words separated by single spaces, with a space at each end, so a phrase matches whole words only.
    public static func normalize(_ text: String) -> String {
        let words = text.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .split(separator: " ")
            .map { String($0) }
        return " " + words.joined(separator: " ") + " "
    }

    /// True when `phrase` (non-empty after normalising) occurs in `haystack` as whole words in the same order.
    public static func contains(haystack: String, phrase: String) -> Bool {
        let needle = normalize(phrase)
        guard needle != "  ", needle.trimmingCharacters(in: .whitespaces).count >= 2 else { return false }
        return haystack.contains(needle)
    }
}
