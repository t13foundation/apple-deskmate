import CryptoKit
import Foundation

/// Text pulled out of a file, before chunking.
public struct ExtractedDocument: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case text(String)
        case markdown(String)
        /// One string per PDF page, in order. Pages without a text layer are empty strings.
        case pages([String])
    }

    public var kind: FileKind
    public var body: Body
    public var pageCount: Int?
    /// Non-fatal remark, e.g. "2 of 10 pages have no text and were left out".
    public var note: String?

    public init(kind: FileKind, body: Body, pageCount: Int? = nil, note: String? = nil) {
        self.kind = kind
        self.body = body
        self.pageCount = pageCount
        self.note = note
    }
}

/// Splits extracted text into bounded chunks that keep file name, page or heading path, and a stable ID.
/// A chunk never spans two PDF pages or two Markdown sections, so its location is always accurate.
public enum Chunker {
    public static func chunks(
        for document: ExtractedDocument,
        fileID: String,
        fileName: String,
        relativePath: String,
        target: Int = LibraryLimits.targetChunkCharacters,
        maximum: Int = LibraryLimits.maxChunkCharacters
    ) -> [SourceChunk] {
        struct Group {
            var page: Int?
            var section: String?
            var text: String
            var lineJoined: Bool
        }

        var groups: [Group] = []
        switch document.body {
        case .text(let text):
            groups = [Group(page: nil, section: nil, text: text, lineJoined: false)]
        case .markdown(let text):
            groups = markdownGroups(text).map { Group(page: nil, section: $0.section, text: $0.text, lineJoined: false) }
        case .pages(let pages):
            groups = pages.enumerated().map { Group(page: $0.offset + 1, section: nil, text: $0.element, lineJoined: true) }
        }

        var output: [SourceChunk] = []
        for group in groups {
            let pieces = pack(text: group.text, byLines: group.lineJoined, target: target, maximum: maximum)
            for piece in pieces {
                let ordinal = output.count
                output.append(SourceChunk(
                    id: makeID(fileID: fileID, ordinal: ordinal, text: piece),
                    fileID: fileID,
                    fileName: fileName,
                    relativePath: relativePath,
                    ordinal: ordinal,
                    page: group.page,
                    section: group.section,
                    text: piece
                ))
            }
        }
        return output
    }

    /// Deterministic ID: the same file position and text always give the same ID; edited text gets a new one.
    static func makeID(fileID: String, ordinal: Int, text: String) -> String {
        let digest = SHA256.hash(data: Data("\(fileID)\u{1}\(ordinal)\u{1}\(text)".utf8))
        return "c" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Markdown sections

    struct MarkdownGroup { var section: String?; var text: String }

    static func markdownGroups(_ markdown: String) -> [MarkdownGroup] {
        var groups: [MarkdownGroup] = []
        var stack: [(level: Int, title: String)] = []
        var currentSection: String?
        var buffer: [String] = []
        var inFence = false

        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = []
            // A heading with nothing under it carries no answer; its title still shows in child section paths.
            let hasBody = text.split(separator: "\n", omittingEmptySubsequences: true).contains { !isHeadingLine(String($0)) }
            if hasBody { groups.append(MarkdownGroup(section: currentSection, text: text)) }
        }

        for line in normalizedNewlines(markdown).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                buffer.append(line)
                continue
            }
            if !inFence, let heading = parseHeading(line) {
                flush()
                while let last = stack.last, last.level >= heading.level { stack.removeLast() }
                stack.append(heading)
                currentSection = stack.map(\.title).joined(separator: " › ")
                buffer.append(line)
                continue
            }
            buffer.append(line)
        }
        flush()
        return groups
    }

    static func isHeadingLine(_ line: String) -> Bool { parseHeading(line) != nil }

    static func parseHeading(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        guard !title.isEmpty else { return nil }
        return (hashes.count, title)
    }

    // MARK: Packing

    static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Packs paragraphs (or lines, for PDF pages) into pieces of roughly `target` characters, never above `maximum`.
    static func pack(text: String, byLines: Bool, target: Int, maximum: Int) -> [String] {
        let normalized = normalizedNewlines(text)
        let units: [String]
        let joiner: String
        if byLines {
            units = normalized.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            joiner = "\n"
        } else {
            units = splitParagraphs(normalized)
            joiner = "\n\n"
        }

        var pieces: [String] = []
        var buffer = ""

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            buffer = ""
        }

        for unit in units {
            for part in splitToFit(unit, maximum: maximum) {
                if buffer.isEmpty {
                    buffer = part
                    continue
                }
                let combined = buffer.count + joiner.count + part.count
                // Keep growing while under the target, or while the buffer is still tiny and the maximum allows it.
                if combined <= target || (buffer.count < 300 && combined <= maximum) {
                    buffer += joiner + part
                } else {
                    flush()
                    buffer = part
                }
            }
        }
        flush()
        return pieces
    }

    private static func splitParagraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(String(line))
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
        return paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Splits one unit that is longer than `maximum` at line, sentence, then word boundaries.
    static func splitToFit(_ unit: String, maximum: Int) -> [String] {
        guard unit.count > maximum else { return [unit] }
        let lines = unit.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.count > 1 {
            return packPieces(lines.flatMap { splitToFit($0, maximum: maximum) }, joiner: "\n", maximum: maximum)
        }
        let sentences = splitSentences(unit)
        if sentences.count > 1 {
            return packPieces(sentences.flatMap { splitToFit($0, maximum: maximum) }, joiner: " ", maximum: maximum)
        }
        let words = unit.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if words.count > 1 {
            return packPieces(words.flatMap { hardSplit($0, maximum: maximum) }, joiner: " ", maximum: maximum)
        }
        return hardSplit(unit, maximum: maximum)
    }

    private static func packPieces(_ pieces: [String], joiner: String, maximum: Int) -> [String] {
        var out: [String] = []
        var buffer = ""
        for piece in pieces {
            if buffer.isEmpty {
                buffer = piece
            } else if buffer.count + joiner.count + piece.count <= maximum {
                buffer += joiner + piece
            } else {
                out.append(buffer)
                buffer = piece
            }
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isWhitespace, let previous, ".!?".contains(previous), !current.trimmingCharacters(in: .whitespaces).isEmpty {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    private static func hardSplit(_ text: String, maximum: Int) -> [String] {
        guard text.count > maximum else { return [text] }
        var out: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: maximum, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[index..<end]))
            index = end
        }
        return out
    }
}
