import Foundation

/// The turns of a reopened conversation that are given back to the model, and how many older ones are left out.
public struct HistorySelection: Equatable, Sendable {
    /// The most recent finished turns that fit, oldest first.
    public var kept: [ConversationTurn]
    /// Older finished turns that are still visible in the transcript but are not in the model's memory.
    public var omittedCount: Int

    public init(kept: [ConversationTurn], omittedCount: Int) {
        self.kept = kept
        self.omittedCount = omittedCount
    }
}

/// Decides how much of a reopened conversation the model gets to remember. Nothing visible is ever removed from the
/// transcript; only the model's memory is limited, and the person is told when older turns are not in it.
public enum HistoryBudget {
    /// Framing the model adds around each restored question and answer.
    public static let turnOverheadTokens = 24

    /// Room kept free for the next question and its answer beyond the reply reserve, so a follow-up is not refused as
    /// "conversation full" the moment the chat is reopened: at least 512 tokens, or an eighth of the window.
    public static func followUpHeadroom(contextSize: Int) -> Int {
        max(512, contextSize / 8)
    }

    /// The largest the session may be after restoring: the window minus the reply reserve and the follow-up headroom.
    public static func sessionLimit(contextSize: Int) -> Int {
        contextSize - ContextBudget.responseReserve(contextSize: contextSize) - followUpHeadroom(contextSize: contextSize)
    }

    /// Tokens available for restored turns, after the fixed instructions and tool definitions.
    public static func availableTokens(contextSize: Int, baselineTokens: Int) -> Int {
        max(0, sessionLimit(contextSize: contextSize) - baselineTokens)
    }

    /// The most recent turns that fit in `availableTokens`. The kept turns are always a contiguous run that ends with
    /// the newest turn: if one turn does not fit, nothing older is kept either, so the memory never has a gap.
    public static func select(_ turns: [ConversationTurn], availableTokens: Int, meter: any TokenMeter) async -> HistorySelection {
        var used = 0
        var start = turns.count
        for index in turns.indices.reversed() {
            let cost = await meter.tokens(in: turns[index].prompt) + meter.tokens(in: turns[index].response) + turnOverheadTokens
            if used + cost > availableTokens { break }
            used += cost
            start = index
        }
        return HistorySelection(kept: Array(turns[start...]), omittedCount: start)
    }

    /// The finished turns of a visible conversation: a question followed by a complete answer. A stopped or failed
    /// answer is not remembered, as in a live chat. Citation tags are removed from the remembered answers: their labels
    /// belonged to an earlier run and would mean something else now, and the model must not cite what it was not given.
    public static func turns(from messages: [ChatMessage]) -> [ConversationTurn] {
        finishedTurns(from: messages).map(\.turn)
    }

    /// A finished turn with the id of the question that started it, so the transcript can say where memory begins.
    public struct FinishedTurn: Equatable, Sendable {
        public var questionID: UUID
        public var turn: ConversationTurn
    }

    public static func finishedTurns(from messages: [ChatMessage]) -> [FinishedTurn] {
        var turns: [FinishedTurn] = []
        var index = 0
        while index + 1 < messages.count {
            let question = messages[index]
            let answer = messages[index + 1]
            if question.role == .user, answer.role == .assistant, answer.status == .complete {
                let text = CitationValidator.ground(answer.text, given: [:], consulted: 0).text
                turns.append(FinishedTurn(questionID: question.id, turn: ConversationTurn(prompt: question.text, response: text)))
                index += 2
            } else {
                index += 1
            }
        }
        return turns
    }
}

/// Rebuilds a model session for a reopened conversation.
public enum HistoryRestore {
    /// Gives the engine the most recent turns that fit, using its real context measurement, and returns how many were
    /// kept. The first choice is made from per-turn token counts. It is then checked against the measured session, one
    /// older turn at a time, so a restored session always leaves room for the reply reserve and a follow-up.
    @MainActor
    public static func run(engine: any ConversationEngine, turns: [ConversationTurn], meter: any TokenMeter) async -> Int {
        engine.reset(history: [])
        guard !turns.isEmpty else { return 0 }
        let base = await engine.contextUsage(adding: "")
        let available = HistoryBudget.availableTokens(contextSize: base.contextSize, baselineTokens: base.baselineTokens)
        var kept = await HistoryBudget.select(turns, availableTokens: available, meter: meter).kept
        let limit = HistoryBudget.sessionLimit(contextSize: base.contextSize)
        while !kept.isEmpty {
            engine.reset(history: kept)
            let usage = await engine.contextUsage(adding: "")
            if usage.sessionTokens <= limit { return kept.count }
            kept.removeFirst()
        }
        engine.reset(history: [])
        return 0
    }
}
