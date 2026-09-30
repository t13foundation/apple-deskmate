import Foundation

/// Counts model tokens. The app uses the model's own tokenizer (macOS 26.4+); tests use the estimator.
public protocol TokenMeter: Sendable {
    func tokens(in text: String) async -> Int
}

/// Deliberately high estimate, used when exact counting is unavailable.
public struct EstimatingMeter: TokenMeter {
    public init() {}
    public func tokens(in text: String) async -> Int { ContextBudget.estimateTokens(text) }
}

public struct SelectedExcerpt: Equatable, Sendable {
    public var chunk: SourceChunk
    /// The text handed to the model. Equal to the chunk text unless it had to be cut.
    public var text: String
    public var truncated: Bool
    public var tokens: Int
}

public struct ExcerptSelection: Equatable, Sendable {
    public var excerpts: [SelectedExcerpt]
    /// Matching excerpts that did not fit. They were left out whole, never cut.
    public var omittedCount: Int
    public var usedTokens: Int
    public var budgetTokens: Int
}

/// Chooses which ranked excerpts fit into a token budget. Whole excerpts only: an excerpt is included in full or left out.
/// The one exception is the best match when even it does not fit; it is then cut at a sentence or line boundary,
/// marked as cut, and used only if enough of it remains to be meaningful.
public enum ExcerptSelector {
    public static let cutMarker = " […excerpt cut to fit]"
    /// Smallest cut excerpt that is still worth giving to the model.
    public static let minimumCutCharacters = 200

    public static func select(
        candidates: [SourceChunk],
        budgetTokens: Int,
        maxExcerpts: Int,
        overheadTokens: Int,
        meter: any TokenMeter
    ) async -> ExcerptSelection {
        var chosen: [SelectedExcerpt] = []
        var used = 0
        var omitted = 0

        for chunk in candidates {
            if chosen.count >= maxExcerpts {
                omitted += 1
                continue
            }
            let cost = await meter.tokens(in: chunk.text) + overheadTokens
            if used + cost <= budgetTokens {
                chosen.append(SelectedExcerpt(chunk: chunk, text: chunk.text, truncated: false, tokens: cost))
                used += cost
                continue
            }
            if chosen.isEmpty, let cut = await cutToFit(chunk, tokenBudget: budgetTokens - used - overheadTokens, meter: meter) {
                let tokens = await meter.tokens(in: cut) + overheadTokens
                chosen.append(SelectedExcerpt(chunk: chunk, text: cut, truncated: true, tokens: tokens))
                used += tokens
                continue
            }
            omitted += 1
        }
        return ExcerptSelection(excerpts: chosen, omittedCount: omitted, usedTokens: used, budgetTokens: budgetTokens)
    }

    /// Cuts at the last sentence end or line break that fits. Returns nil when too little would remain.
    static func cutToFit(_ chunk: SourceChunk, tokenBudget: Int, meter: any TokenMeter) async -> String? {
        guard tokenBudget > 0 else { return nil }
        var boundaries: [String.Index] = []
        var previous: Character?
        for index in chunk.text.indices {
            let character = chunk.text[index]
            if character == "\n" || (character.isWhitespace && previous.map { ".!?".contains($0) } == true) {
                boundaries.append(index)
            }
            previous = character
        }
        // Try the longest prefix first and walk back until it fits.
        for boundary in boundaries.reversed() {
            let prefix = String(chunk.text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard prefix.count >= minimumCutCharacters else { return nil }
            let candidate = prefix + cutMarker
            if await meter.tokens(in: candidate) <= tokenBudget { return candidate }
        }
        return nil
    }
}
