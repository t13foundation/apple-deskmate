import Testing
import Foundation
@testable import DeskMateCore

/// Costs one token per character, so budgets are easy to reason about. Test double for the token counter only.
private struct CharacterMeter: TokenMeter {
    func tokens(in text: String) async -> Int { text.count }
}

@Suite struct HistoryBudgetTests {
    private func turn(_ question: String, _ answer: String) -> ConversationTurn {
        ConversationTurn(prompt: question, response: answer)
    }

    @Test func theLimitLeavesTheReplyReserveAndFollowUpHeadroom() {
        // 4096 window: reserve 819, headroom 512.
        #expect(HistoryBudget.sessionLimit(contextSize: 4096) == 4096 - 819 - 512)
        #expect(HistoryBudget.availableTokens(contextSize: 4096, baselineTokens: 300) == 4096 - 819 - 512 - 300)
        #expect(HistoryBudget.availableTokens(contextSize: 4096, baselineTokens: 99_999) == 0)
    }

    @Test func theNewestTurnsThatFitAreKeptAndOlderOnesAreCounted() async {
        let turns = (1...5).map { turn("q\($0)", String(repeating: "a", count: 76)) } // 2 + 76 + 24 = 102 each
        let selection = await HistoryBudget.select(turns, availableTokens: 320, meter: CharacterMeter())
        #expect(selection.kept.map(\.prompt) == ["q3", "q4", "q5"])
        #expect(selection.omittedCount == 2)
    }

    @Test func everythingFitsWhenThereIsRoom() async {
        let turns = [turn("a", "b"), turn("c", "d")]
        let selection = await HistoryBudget.select(turns, availableTokens: 10_000, meter: CharacterMeter())
        #expect(selection.kept == turns)
        #expect(selection.omittedCount == 0)
    }

    @Test func aTurnThatDoesNotFitStopsTheSelectionSoMemoryNeverHasAGap() async {
        let small = turn("s", "s")
        let huge = turn("big", String(repeating: "x", count: 2_000))
        let selection = await HistoryBudget.select([small, huge, small], availableTokens: 500, meter: CharacterMeter())
        #expect(selection.kept == [small], "the small old turn is not kept without the turn after it")
        #expect(selection.omittedCount == 2)
    }

    @Test func nothingFitsWhenTheNewestTurnIsTooBig() async {
        let selection = await HistoryBudget.select([turn("q", String(repeating: "x", count: 900))], availableTokens: 100, meter: CharacterMeter())
        #expect(selection.kept.isEmpty)
        #expect(selection.omittedCount == 1)
    }

    @Test func onlyFinishedTurnsAreRememberedAndOldCitationTagsAreRemoved() {
        let q1 = ChatMessage(role: .user, text: "First?")
        let a1 = ChatMessage(role: .assistant, text: "The budget is 10 [S1] and tools are 5 [S2, S3].")
        let q2 = ChatMessage(role: .user, text: "Second?")
        let a2 = ChatMessage(role: .assistant, text: "Partial", status: .stopped)
        let q3 = ChatMessage(role: .user, text: "Third?")
        let a3 = ChatMessage(role: .assistant, text: "Third answer.")
        let finished = HistoryBudget.finishedTurns(from: [q1, a1, q2, a2, q3, a3])
        #expect(finished.map(\.questionID) == [q1.id, q3.id])
        #expect(finished[0].turn.response == "The budget is 10 and tools are 5.")
        #expect(HistoryBudget.turns(from: [q1, a1, q2, a2, q3, a3]).map(\.prompt) == ["First?", "Third?"])
    }

    @Test func aTrailingQuestionWithoutAnAnswerIsNotATurn() {
        let q = ChatMessage(role: .user, text: "Anyone there?")
        #expect(HistoryBudget.turns(from: [q]).isEmpty)
        #expect(HistoryBudget.turns(from: []).isEmpty)
    }
}
