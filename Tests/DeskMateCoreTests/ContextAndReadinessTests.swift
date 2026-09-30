import Testing
import FoundationModels
@testable import DeskMateCore

@Suite struct ContextBudgetTests {
    private func usage(session: Int, baseline: Int = 120, prompt: Int, size: Int = 4096) -> ContextUsage {
        ContextUsage(sessionTokens: session, baselineTokens: baseline, promptTokens: prompt, contextSize: size, isExact: true)
    }

    @Test func reserveIsAtLeast512AndScalesWithWindow() {
        #expect(ContextBudget.responseReserve(contextSize: 4096) == 819)
        #expect(ContextBudget.responseReserve(contextSize: 1000) == 512)
    }

    @Test func shortMessageFits() {
        #expect(ContextBudget.decide(usage(session: 300, prompt: 50)) == .fits(remainingTokens: 4096 - 350))
    }

    @Test func messageThatCannotFitEvenInNewChatIsTooLong() {
        // limit = 4096 - 819 = 3277; baseline 120 + prompt 3200 > limit
        #expect(ContextBudget.decide(usage(session: 120, prompt: 3200)) == .promptTooLong)
    }

    @Test func messageThatFitsOnlyInNewChatMeansConversationFull() {
        // fresh chat would fit (120 + 500), but earlier turns already use 3000
        #expect(ContextBudget.decide(usage(session: 3000, prompt: 500)) == .conversationFull)
    }

    @Test func exactBoundaryFits() {
        let limit = 4096 - 819
        #expect(ContextBudget.decide(usage(session: 120, prompt: limit - 120)) == .fits(remainingTokens: 4096 - limit))
        #expect(ContextBudget.decide(usage(session: 120, prompt: limit - 119)) == .promptTooLong)
    }

    @Test func estimateErrsHigh() {
        #expect(ContextBudget.estimateTokens("") == 0)
        #expect(ContextBudget.estimateTokens("a") == 1)
        #expect(ContextBudget.estimateTokens(String(repeating: "a", count: 300)) == 100)
        // non-ASCII counts double
        #expect(ContextBudget.estimateTokens(String(repeating: "ą", count: 300)) == 200)
    }

    @Test func contextFailuresExplainNextStepAndNeverTruncate() throws {
        #expect(ChatFailure.context(.fits(remainingTokens: 10)) == nil)
        let full = try #require(ChatFailure.context(.conversationFull))
        #expect(full.actions == [.newChatKeepingQuestion])
        #expect(full.message.contains("new chat"))
        let long = try #require(ChatFailure.context(.promptTooLong))
        #expect(long.message.contains("won’t silently cut"))
    }
}

@Suite struct ReadinessTests {
    private func snapshot(_ availability: ModelAvailability, english: Bool = true) -> ModelReadinessSnapshot {
        ModelReadinessSnapshot(availability: availability, supportsEnglish: english, contextSize: 4096, hasExactTokenCounting: true)
    }

    @Test func mapsEveryUnavailableReasonToADistinctState() {
        #expect(snapshot(.available).readiness == .ready(contextSize: 4096))
        #expect(snapshot(.unavailable(.appleIntelligenceNotEnabled)).readiness == .appleIntelligenceOff)
        #expect(snapshot(.unavailable(.modelNotReady)).readiness == .modelNotReady)
        #expect(snapshot(.unavailable(.deviceNotEligible)).readiness == .deviceNotEligible)
        #expect(snapshot(.unavailable(.unknown)).readiness == .unknown)
    }

    @Test func availableModelWithoutEnglishIsNotReady() {
        #expect(snapshot(.available, english: false).readiness == .englishUnsupported)
        #expect(!snapshot(.available, english: false).readiness.isReady)
    }

    @Test func unavailableStatesExplainWhereToGoAndPromiseNoCloud() {
        let off = ModelReadiness.appleIntelligenceOff
        #expect(off.message.contains("System Settings"))
        #expect(off.suggestsSystemSettings)
        #expect(!ModelReadiness.modelNotReady.suggestsSystemSettings)
        #expect(ModelReadiness.deviceNotEligible.message.contains("doesn’t switch to a cloud model"))
    }
}

@Suite struct FailureMappingTests {
    private let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")

    private func failure(_ error: LanguageModelSession.GenerationError) -> ChatFailure {
        ChatFailure.from(error: error)
    }

    @Test func contextOverflowOffersNewChatKeepingTheQuestion() {
        let result = failure(.exceededContextWindowSize(context))
        #expect(result.kind == .conversationFull)
        #expect(result.actions == [.newChatKeepingQuestion])
    }

    @Test func guardrailOffersRewordingWithoutRetryLoop() {
        let result = failure(.guardrailViolation(context))
        #expect(result.kind == .guardrail)
        #expect(result.actions.contains(.editQuestion))
        #expect(!result.actions.contains(.retry))
    }

    @Test func unsupportedLanguageAsksForEnglish() {
        let result = failure(.unsupportedLanguageOrLocale(context))
        #expect(result.kind == .unsupportedLanguage)
        #expect(result.message.contains("English"))
    }

    @Test func transientErrorsOfferRetry() {
        #expect(failure(.rateLimited(context)).actions == [.retry])
        #expect(failure(.concurrentRequests(context)).actions == [.retry])
        #expect(failure(.assetsUnavailable(context)).actions.contains(.checkAgain))
    }

    @Test func unknownErrorsAreGenericWithRetryAndNoErrorText() {
        struct Boom: Error, CustomStringConvertible { var description: String { "secret prompt text" } }
        let result = ChatFailure.from(error: Boom())
        #expect(result.kind == .other)
        #expect(result.actions.contains(.retry))
        #expect(!result.message.contains("secret"))
        #expect(!result.code.contains("secret"))
    }

    @Test func everyGenerationFailureHasTitleAndMessage() {
        let all: [LanguageModelSession.GenerationError] = [
            .exceededContextWindowSize(context), .assetsUnavailable(context), .guardrailViolation(context),
            .unsupportedGuide(context), .unsupportedLanguageOrLocale(context), .decodingFailure(context),
            .rateLimited(context), .concurrentRequests(context),
        ]
        for error in all {
            let result = failure(error)
            #expect(!result.title.isEmpty && !result.message.isEmpty && !result.code.isEmpty)
        }
    }
}
