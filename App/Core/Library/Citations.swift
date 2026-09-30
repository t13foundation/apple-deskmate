import Foundation
import Synchronization

/// An excerpt exactly as the model received it, with everything needed to show and inspect it.
public struct SourceCitation: Codable, Identifiable, Equatable, Sendable {
    public enum Origin: String, Codable, Equatable, Sendable {
        /// Found by searching My files.
        case library
        /// Attached to the question or picked for a comparison.
        case attachment
    }

    /// The label the model cites, e.g. "S3".
    public var id: String
    public var chunkID: String
    public var fileID: String
    public var fileName: String
    /// "Page 3" or "Section: Budget".
    public var location: String?
    /// The text the model was given. If it was cut to fit, `truncated` is true and the text says so.
    public var excerpt: String
    public var truncated: Bool
    public var origin: Origin

    public init(id: String, chunkID: String, fileID: String, fileName: String, location: String?, excerpt: String, truncated: Bool, origin: Origin) {
        self.id = id
        self.chunkID = chunkID
        self.fileID = fileID
        self.fileName = fileName
        self.location = location
        self.excerpt = excerpt
        self.truncated = truncated
        self.origin = origin
    }

    /// File name with position, e.g. "lumen-plan-v1.md · Section: Budget".
    public var title: String {
        location.map { "\(fileName) · \($0)" } ?? fileName
    }
}

/// An answer after its citations were checked against the excerpts the model actually received.
public struct GroundedAnswer: Equatable, Sendable {
    /// The answer text; citations that matched nothing are removed.
    public var text: String
    /// Cited excerpts that really were given to the model, in order of first mention.
    public var sources: [SourceCitation]
    /// IDs the model cited that were never given to it. They are removed and never shown as sources.
    public var removedCitations: [String]
    /// How many excerpts the model was given for this answer, cited or not.
    public var consultedCount: Int
    /// For a document comparison: every excerpt the extraction stages read, in reading order. This is the material the
    /// answer was built from, not a per-fact citation, so it is kept apart from `sources`.
    public var comparedMaterial: [SourceCitation]

    public init(text: String, sources: [SourceCitation] = [], removedCitations: [String] = [], consultedCount: Int = 0, comparedMaterial: [SourceCitation] = []) {
        self.text = text
        self.sources = sources
        self.removedCitations = removedCitations
        self.consultedCount = consultedCount
        self.comparedMaterial = comparedMaterial
    }
}

public enum CitationValidator {
    // "[S3]" or "[S1, S2]". Nothing else counts as a citation.
    private static let pattern = try! NSRegularExpression(pattern: #"\[\s*S\d+(?:\s*[,;]\s*S\d+)*\s*\]"#)
    private static let identifier = try! NSRegularExpression(pattern: #"S\d+"#)

    /// Keeps only citations whose ID was really given to the model. Unknown IDs are removed from the text
    /// and reported; they are never turned into sources.
    public static func ground(_ text: String, given: [String: SourceCitation], consulted: Int) -> GroundedAnswer {
        let nsText = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var output = ""
        var cursor = 0
        var cited: [String] = []
        var removed: [String] = []

        for match in matches {
            output += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length

            let body = nsText.substring(with: match.range)
            let ids = identifier.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length))
                .map { (body as NSString).substring(with: $0.range) }
            let valid = ids.filter { given[$0] != nil }
            for id in ids where given[id] == nil && !removed.contains(id) { removed.append(id) }
            for id in valid where !cited.contains(id) { cited.append(id) }

            if valid.count == ids.count {
                output += body
            } else if !valid.isEmpty {
                output += "[" + valid.joined(separator: ", ") + "]"
            } else if output.hasSuffix(" ") {
                // Drop the space that preceded the removed citation.
                output.removeLast()
            }
        }
        output += nsText.substring(from: cursor)

        return GroundedAnswer(
            text: output,
            sources: cited.compactMap { given[$0] },
            removedCitations: removed,
            consultedCount: consulted
        )
    }
}

/// What one search call did, for headless evidence. Held in memory for the current question only; never written anywhere.
public struct SearchTrace: Equatable, Sendable {
    public var query: String
    public var given: [String]
    public var omittedCount: Int
    public var budgetTokens: Int
    public var usedTokens: Int
    public var candidateCount: Int
}

/// Remembers which excerpts were given to the model in this conversation and under which label.
/// A chunk keeps the same label for the whole conversation, so "[S2]" never means two different excerpts.
public final class SourceLedger: Sendable {
    private struct State {
        var nextNumber = 1
        var labelByChunk: [String: String] = [:]
        var given: [String: SourceCitation] = [:]
        var consultedThisTurn = 0
        var comparedThisTurn: [SourceCitation] = []
        var searchesThisTurn = 0
        var traces: [SearchTrace] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// The stable label for a chunk, assigned on first use.
    public func label(forChunk chunkID: String) -> String {
        state.withLock { state in
            if let existing = state.labelByChunk[chunkID] { return existing }
            let label = "S\(state.nextNumber)"
            state.nextNumber += 1
            state.labelByChunk[chunkID] = label
            return label
        }
    }

    public func beginTurn() {
        state.withLock {
            $0.consultedThisTurn = 0
            $0.comparedThisTurn = []
            $0.searchesThisTurn = 0
            $0.traces = []
        }
    }

    public func recordTrace(_ trace: SearchTrace) {
        state.withLock { $0.traces.append(trace) }
    }

    public var traces: [SearchTrace] {
        state.withLock { $0.traces }
    }

    /// Records an excerpt at the moment it is handed to the model. Only recorded excerpts can ever be cited.
    public func recordGiven(_ citation: SourceCitation) {
        state.withLock {
            $0.given[citation.id] = citation
            $0.consultedThisTurn += 1
        }
    }

    /// Records an excerpt given to a comparison stage. It can be cited like any given excerpt and is also listed as
    /// compared material for this turn, once.
    public func recordCompared(_ citation: SourceCitation) {
        recordGiven(citation)
        state.withLock { state in
            if !state.comparedThisTurn.contains(where: { $0.id == citation.id }) { state.comparedThisTurn.append(citation) }
        }
    }

    /// Counts a search call in this turn and returns the new total.
    public func registerSearch() -> Int {
        state.withLock {
            $0.searchesThisTurn += 1
            return $0.searchesThisTurn
        }
    }

    public func givenCitation(for label: String) -> SourceCitation? {
        state.withLock { $0.given[label] }
    }

    public var givenLabels: Set<String> {
        state.withLock { Set($0.given.keys) }
    }

    public func ground(_ text: String) -> GroundedAnswer {
        let snapshot = state.withLock { ($0.given, $0.consultedThisTurn, $0.comparedThisTurn) }
        var grounded = CitationValidator.ground(text, given: snapshot.0, consulted: snapshot.1)
        grounded.comparedMaterial = snapshot.2
        return grounded
    }

    /// The model session was rebuilt, so earlier excerpts are no longer in its context and cannot be cited.
    /// Labels stay reserved so they are never reused for something else.
    public func dropGiven() {
        state.withLock {
            $0.given = [:]
            $0.consultedThisTurn = 0
            $0.comparedThisTurn = []
        }
    }

    /// New chat.
    public func reset() {
        state.withLock { $0 = State() }
    }
}
