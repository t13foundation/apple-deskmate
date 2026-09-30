import Foundation

/// How much of the model's context window a request would use.
public struct ContextUsage: Equatable, Sendable {
    /// Tokens already in the session (instructions, tool definitions and earlier turns).
    public var sessionTokens: Int
    /// Tokens of the fixed baseline alone (instructions and tools), i.e. what a fresh chat starts with.
    public var baselineTokens: Int
    /// Tokens of the new message.
    public var promptTokens: Int
    /// The model's real context size.
    public var contextSize: Int
    /// True when counts come from the model tokenizer (macOS 26.4+); otherwise they are conservative estimates.
    public var isExact: Bool

    public init(sessionTokens: Int, baselineTokens: Int, promptTokens: Int, contextSize: Int, isExact: Bool) {
        self.sessionTokens = sessionTokens
        self.baselineTokens = baselineTokens
        self.promptTokens = promptTokens
        self.contextSize = contextSize
        self.isExact = isExact
    }
}

public enum ContextDecision: Equatable, Sendable {
    /// The message and a reply of at least the reserve size fit.
    case fits(remainingTokens: Int)
    /// The message alone cannot fit even in a brand-new chat. The person must shorten it.
    case promptTooLong
    /// The message would fit in a new chat but not after the earlier turns. Never truncated silently.
    case conversationFull
}

/// Explicit context budget. DeskMate never drops earlier turns or cuts a message to make it fit.
public enum ContextBudget {
    /// Space kept free for the model's reply: at least 512 tokens, or a fifth of the window.
    public static func responseReserve(contextSize: Int) -> Int {
        max(512, contextSize / 5)
    }

    public static func decide(_ usage: ContextUsage) -> ContextDecision {
        let limit = usage.contextSize - responseReserve(contextSize: usage.contextSize)
        if usage.baselineTokens + usage.promptTokens > limit {
            return .promptTooLong
        }
        let total = usage.sessionTokens + usage.promptTokens
        if total > limit {
            return .conversationFull
        }
        return .fits(remainingTokens: usage.contextSize - total)
    }

    /// Conservative token estimate for English text when exact counting is unavailable.
    /// About three characters per token for ASCII; non-ASCII characters count double because
    /// they tokenize less efficiently. Deliberately errs high so we refuse early instead of failing late.
    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var weight = 0
        for scalar in text.unicodeScalars {
            weight += scalar.isASCII ? 1 : 2
        }
        return max(1, (weight + 2) / 3)
    }
}
