import Testing
import FoundationModels
@testable import DeskMateCore

/// Every generation has an explicit response cap, so a looping answer stops instead of filling the 4096-token window.
@Suite struct GenerationLimitTests {
    @Test @MainActor func chatRepliesAreCappedAtTheReserveThatTheBudgetKeepsFree() {
        let cap = ContextBudget.responseCap(contextSize: 4096)
        #expect(cap == 819)
        #expect(SystemModelEngine.chatOptions(cap: cap).maximumResponseTokens == 819)
    }

    @Test func finalComparisonCapIsWhatFitsAfterInstructionsAndPrompt() {
        // Room: 4096 - 300 - 1500 - 96 = 2200, bounded by the ceiling.
        #expect(DocumentComparison.finalResponseTokens(contextSize: 4096, instructionsTokens: 300, promptTokens: 1500) == DocumentComparison.maxFinalResponseTokens)
        // A large prompt leaves less: 4096 - 300 - 3000 - 96 = 700.
        let cap = DocumentComparison.finalResponseTokens(contextSize: 4096, instructionsTokens: 300, promptTokens: 3000)
        #expect(cap == 700)
        #expect(300 + 3000 + cap + DocumentComparison.framingTokens <= 4096)
        // Never below the minimum, so the model reports "too long" itself rather than getting a zero cap.
        #expect(DocumentComparison.finalResponseTokens(contextSize: 4096, instructionsTokens: 300, promptTokens: 3900) == DocumentComparison.minFinalResponseTokens)
    }

    @Test func aReplyAtItsCapIsTreatedAsCutOff() {
        #expect(ContextBudget.reachedLimit(responseTokens: 819, cap: 819))
        #expect(ContextBudget.reachedLimit(responseTokens: 805, cap: 819))
        #expect(!ContextBudget.reachedLimit(responseTokens: 400, cap: 819))
    }

    @Test func aCutOffComparisonIsNeverPresentedAsComplete() {
        #expect(DocumentComparison.incompleteNote(finalHitLimit: false, limitedNotes: []) == nil)
        let final = DocumentComparison.incompleteNote(finalHitLimit: true, limitedNotes: [])
        #expect(final?.contains("reached the length limit and may be incomplete") == true)
        let notes = DocumentComparison.incompleteNote(finalHitLimit: false, limitedNotes: ["plan-v1.md"])
        #expect(notes?.contains("plan-v1.md") == true)
    }

    @Test @MainActor func everyStageGetsItsOwnSessionWithOnlyItsOwnInstructions() {
        let model = SystemLanguageModel.default
        let first = SystemModelEngine.stageSession(model: model, instructions: DocumentComparison.extractionInstructions)
        let second = SystemModelEngine.stageSession(model: model, instructions: DocumentComparison.finalInstructions)
        #expect(first !== second)
        #expect(first.transcript.count == 1)
        #expect(second.transcript.count == 1)
        #expect(String(describing: first.transcript).contains("fact notes"))
        #expect(!String(describing: second.transcript).contains("fact notes"))
    }
}
