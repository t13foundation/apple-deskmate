import Foundation

/// English tokenizer for the local index: lowercase, number-aware, small stop list, conservative stemming.
public enum Tokenizer {
    static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can", "did", "do", "does", "for", "from",
        "had", "has", "have", "how", "i", "if", "in", "into", "is", "it", "its", "me", "my", "of", "on", "or", "our",
        "please", "so", "than", "that", "the", "their", "them", "then", "there", "these", "they", "this", "those",
        "to", "was", "we", "were", "what", "when", "where", "which", "who", "whom", "why", "will", "with", "would",
        "you", "your", "about", "tell", "show", "find", "give", "file", "files", "document", "documents",
    ]

    public static func tokens(_ text: String, dropStopWords: Bool = true) -> [String] {
        // "48,000" and "3.5" stay one token ("48000", "3_5"): digit separators must not split numbers.
        let scalars = Array(text.lowercased().unicodeScalars)
        var result: [String] = []
        var current = String.UnicodeScalarView()

        func flush() {
            guard !current.isEmpty else { return }
            let word = String(current)
            current = String.UnicodeScalarView()
            if dropStopWords && stopWords.contains(word) { return }
            result.append(stem(word))
        }

        for (index, scalar) in scalars.enumerated() {
            let betweenDigits = index > 0 && index + 1 < scalars.count && isDigit(scalars[index - 1]) && isDigit(scalars[index + 1])
            if betweenDigits && scalar == "," {
                continue
            } else if betweenDigits && scalar == "." {
                current.append("_")
            } else if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    /// Very light English stemming so "budgets" matches "budget" and "approved" matches "approve".
    static func stem(_ word: String) -> String {
        guard word.count > 3, word.allSatisfy({ $0.isLetter }) else { return word }
        var w = word
        if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("sses") { return String(w.dropLast(2)) }
        if w.hasSuffix("ing"), w.count > 5 { w = String(w.dropLast(3)) }
        else if w.hasSuffix("ed"), w.count > 4 { w = String(w.dropLast(2)) }
        else if w.hasSuffix("es"), w.count > 4, ["s", "x", "z", "ch", "sh"].contains(where: { String(w.dropLast(2)).hasSuffix($0) }) { w = String(w.dropLast(2)) }
        else if w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") { w = String(w.dropLast(1)) }
        // Undo a doubled consonant left by "-ing/-ed" ("planned" -> "plann" -> "plan") and drop a silent e.
        if w.count > 3, let last = w.last, w.dropLast().last == last, !"aeiouls".contains(last) { w.removeLast() }
        if w.hasSuffix("e"), w.count > 3 { w.removeLast() }
        return w
    }
}

public struct ScoredChunk: Equatable, Sendable {
    public var chunk: SourceChunk
    public var score: Double
}

/// A small BM25 index over chunks. No embeddings, no external service. Immutable once built.
public struct SearchIndex: Sendable {
    private let chunks: [SourceChunk]
    private let termFrequencies: [[String: Int]]
    private let lengths: [Int]
    private let documentFrequency: [String: Int]
    private let averageLength: Double

    private static let k1 = 1.2
    private static let b = 0.75
    /// File names and headings describe the content, so they count extra.
    private static let metadataWeight = 2

    public static let empty = SearchIndex(chunks: [])

    public init(chunks: [SourceChunk]) {
        self.chunks = chunks
        var frequencies: [[String: Int]] = []
        var lengths: [Int] = []
        var df: [String: Int] = [:]
        frequencies.reserveCapacity(chunks.count)
        for chunk in chunks {
            var tf: [String: Int] = [:]
            var length = 0
            for token in Tokenizer.tokens(chunk.text) {
                tf[token, default: 0] += 1
                length += 1
            }
            let metadata = Tokenizer.tokens(Self.metadataText(chunk))
            for token in metadata {
                tf[token, default: 0] += Self.metadataWeight
                length += Self.metadataWeight
            }
            for term in tf.keys { df[term, default: 0] += 1 }
            frequencies.append(tf)
            lengths.append(length)
        }
        self.termFrequencies = frequencies
        self.lengths = lengths
        self.documentFrequency = df
        self.averageLength = chunks.isEmpty ? 0 : Double(lengths.reduce(0, +)) / Double(chunks.count)
    }

    private static func metadataText(_ chunk: SourceChunk) -> String {
        let name = (chunk.fileName as NSString).deletingPathExtension
        return name + " " + (chunk.section ?? "")
    }

    public var chunkCount: Int { chunks.count }
    public var isEmpty: Bool { chunks.isEmpty }
    public var allChunks: [SourceChunk] { chunks }

    /// Ranked chunks that match at least one query term. Ranking finds fragments; it does not judge meaning.
    public func search(_ query: String, limit: Int, allowing allowed: ((SourceChunk) -> Bool)? = nil) -> [ScoredChunk] {
        let terms = Array(Set(Tokenizer.tokens(query)))
        guard !terms.isEmpty, !chunks.isEmpty, limit > 0 else { return [] }
        let count = Double(chunks.count)
        var scored: [ScoredChunk] = []
        for index in chunks.indices {
            if let allowed, !allowed(chunks[index]) { continue }
            let tf = termFrequencies[index]
            var score = 0.0
            for term in terms {
                guard let frequency = tf[term], let df = documentFrequency[term] else { continue }
                let idf = log(1 + (count - Double(df) + 0.5) / (Double(df) + 0.5))
                let f = Double(frequency)
                let normalization = 1 - Self.b + Self.b * Double(lengths[index]) / max(averageLength, 1)
                score += idf * (f * (Self.k1 + 1)) / (f + Self.k1 * normalization)
            }
            if score > 0 { scored.append(ScoredChunk(chunk: chunks[index], score: score)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.chunk.fileID != rhs.chunk.fileID { return lhs.chunk.fileID < rhs.chunk.fileID }
            return lhs.chunk.ordinal < rhs.chunk.ordinal
        }
        return Array(scored.prefix(limit))
    }
}
