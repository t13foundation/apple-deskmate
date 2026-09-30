import Testing
import FoundationModels
@testable import DeskMateCore

@MainActor
@Suite struct ConversationControllerTests {
    private func make() -> (ConversationController, ScriptedEngine) {
        let engine = ScriptedEngine()
        return (ConversationController(engine: engine), engine)
    }

    // MARK: Empty input and readiness

    @Test func emptyOrWhitespaceInputCannotBeSent() async {
        let (controller, engine) = make()
        #expect(!controller.canSend)
        controller.draft = "  \n "
        #expect(!controller.canSend)
        controller.send()
        await controller.waitUntilIdle()
        #expect(controller.messages.isEmpty)
        #expect(engine.prompts.isEmpty)
    }

    @Test func unavailableModelKeepsTheDraftAndNeverCallsTheEngine() async {
        let (controller, engine) = make()
        engine.snapshot.availability = .unavailable(.appleIntelligenceNotEnabled)
        controller.refreshReadiness()
        controller.draft = "What is a budget?"
        #expect(!controller.canSend)
        controller.send()
        await controller.waitUntilIdle()
        #expect(controller.draft == "What is a budget?")
        #expect(controller.messages.isEmpty)
        #expect(engine.prompts.isEmpty)
        #expect(controller.readinessNudge == 1)
        #expect(controller.readiness == .appleIntelligenceOff)
    }

    // MARK: Streaming and follow-ups

    @Test func streamedAnswerFillsTheAssistantMessageAndClearsTheDraft() async {
        let (controller, engine) = make()
        engine.behaviors = [.chunks(["Hel", "Hello", "Hello there"])]
        controller.draft = "  Say hello  "
        controller.send()
        await controller.waitUntilIdle()
        #expect(controller.draft.isEmpty)
        #expect(controller.messages.map(\.role) == [.user, .assistant])
        #expect(controller.messages[0].text == "Say hello")
        #expect(controller.messages[1].text == "Hello there")
        #expect(controller.messages[1].status == .complete)
        #expect(controller.phase == .idle)
        #expect(controller.failure == nil)
    }

    @Test func followUpStaysInTheSameSessionWithoutResettingContext() async {
        let (controller, engine) = make()
        engine.behaviors = [.chunks(["A1"]), .chunks(["A2"])]
        controller.draft = "Q1"
        controller.send()
        await controller.waitUntilIdle()
        controller.draft = "And a follow-up?"
        controller.send()
        await controller.waitUntilIdle()
        #expect(engine.prompts == ["Q1", "And a follow-up?"])
        #expect(engine.resets.isEmpty, "a successful follow-up must not reset model context")
        #expect(controller.messages.map(\.text) == ["Q1", "A1", "And a follow-up?", "A2"])
    }

    @Test func newChatClearsMessagesDraftFailureAndModelContext() async {
        let (controller, engine) = make()
        controller.draft = "Q1"
        controller.send()
        await controller.waitUntilIdle()
        controller.draft = "half-typed"
        controller.newChat()
        #expect(controller.messages.isEmpty)
        #expect(controller.draft.isEmpty)
        #expect(controller.failure == nil)
        #expect(engine.resets.last == [], "New chat must start an empty model session")
        // the next question does not carry the previous turn
        controller.draft = "Q2"
        controller.send()
        await controller.waitUntilIdle()
        #expect(controller.messages.map(\.text).first == "Q2")
    }

    // MARK: Cancellation

    @Test func stopKeepsQuestionAndMarksPartialAnswerStopped() async {
        let (controller, engine) = make()
        engine.behaviors = [.manual]
        controller.draft = "Explain inflation"
        controller.send()
        await waitUntil { controller.phase == .generating && engine.manual != nil }
        engine.manual?.yield("Inflation is")
        await waitUntil { controller.messages.last?.text == "Inflation is" }

        controller.cancel()
        await controller.waitUntilIdle()

        #expect(controller.phase == .idle)
        #expect(controller.messages.count == 2)
        #expect(controller.messages[0].text == "Explain inflation")
        #expect(controller.messages[0].status == .complete)
        #expect(controller.messages[1].text == "Inflation is")
        #expect(controller.messages[1].status == .stopped)
        #expect(controller.canRetry)
        // model context is rebuilt from finished turns only (none here)
        #expect(engine.resets.last == [])
    }

    @Test func stopBeforeAnyTextStillKeepsTheQuestion() async {
        let (controller, engine) = make()
        engine.behaviors = [.manual]
        controller.draft = "Long question"
        controller.send()
        await waitUntil { controller.phase == .generating }
        controller.cancel()
        await controller.waitUntilIdle()
        #expect(controller.messages.map(\.text) == ["Long question", ""])
        #expect(controller.messages.last?.status == .stopped)
    }

    @Test func retryAfterStopResendsTheSameQuestionOnceAndKeepsEarlierTurns() async {
        let (controller, engine) = make()
        engine.behaviors = [.chunks(["First answer"]), .manual, .chunks(["Second answer"])]
        controller.draft = "First"
        controller.send()
        await controller.waitUntilIdle()
        controller.draft = "Second"
        controller.send()
        await waitUntil { controller.phase == .generating && engine.manual != nil }
        controller.cancel()
        await controller.waitUntilIdle()
        // stopped turn is excluded from model context; the finished turn is restored
        #expect(engine.resets.last == [ConversationTurn(prompt: "First", response: "First answer")])

        controller.retry()
        await controller.waitUntilIdle()
        #expect(engine.prompts == ["First", "Second", "Second"])
        #expect(controller.messages.map(\.text) == ["First", "First answer", "Second", "Second answer"])
        #expect(controller.messages.last?.status == .complete)
    }

    @Test func newChatWhileGeneratingIgnoresTheStaleStream() async {
        let (controller, engine) = make()
        engine.behaviors = [.manual]
        controller.draft = "Old question"
        controller.send()
        await waitUntil { controller.phase == .generating && engine.manual != nil }
        controller.newChat()
        engine.manual?.yield("late text from the old chat")
        engine.manual?.finish()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(controller.messages.isEmpty)
        #expect(controller.phase == .idle)
    }

    // MARK: Failures preserve input and explain the next step

    @Test func guardrailFailurePreservesQuestionAndAllowsEditing() async {
        let (controller, engine) = make()
        let error = LanguageModelSession.GenerationError.guardrailViolation(.init(debugDescription: "x"))
        engine.behaviors = [.failing([], error)]
        controller.draft = "A risky question"
        controller.send()
        await controller.waitUntilIdle()
        #expect(controller.failure?.kind == .guardrail)
        #expect(controller.messages.first?.text == "A risky question")
        #expect(controller.messages.last?.status == .failed)

        controller.perform(.editQuestion)
        #expect(controller.messages.isEmpty)
        #expect(controller.draft == "A risky question")
        #expect(controller.failure == nil)
    }

    @Test func editingNeverOverwritesNewlyTypedText() async {
        let (controller, engine) = make()
        engine.behaviors = [.failing([], LanguageModelSession.GenerationError.guardrailViolation(.init(debugDescription: "x")))]
        controller.draft = "Original"
        controller.send()
        await controller.waitUntilIdle()
        controller.draft = "Typed meanwhile"
        controller.editLastQuestion()
        #expect(controller.draft == "Original\n\nTyped meanwhile")
    }

    @Test func genericErrorKeepsPartialTextAndRetrySucceeds() async {
        struct Boom: Error {}
        let (controller, engine) = make()
        engine.behaviors = [.failing(["Partial"], Boom()), .chunks(["Recovered"])]
        controller.draft = "Question"
        controller.send()
        await controller.waitUntilIdle()
        #expect(controller.failure?.kind == .other)
        #expect(controller.messages.last?.text == "Partial")
        #expect(controller.messages.last?.status == .failed)

        controller.perform(.retry)
        await controller.waitUntilIdle()
        #expect(controller.failure == nil)
        #expect(controller.messages.map(\.text) == ["Question", "Recovered"])
    }

    @Test func emptyModelOutputIsAFailureNotASilentSuccess() async {
        let (controller, engine) = make()
        engine.behaviors = [.chunks([])]
        controller.draft = "Question"
        controller.send()
        await controller.waitUntilIdle()
        #expect(controller.failure?.code == "emptyResponse")
        #expect(controller.messages.last?.status == .failed)
    }

    @Test func contextLimitRefusesBeforeSendingAndKeepsTheDraft() async {
        let (controller, engine) = make()
        engine.usage = ContextUsage(sessionTokens: 3200, baselineTokens: 120, promptTokens: 400, contextSize: 4096, isExact: true)
        controller.draft = "One more question"
        controller.send()
        await controller.waitUntilIdle()
        #expect(controller.failure?.kind == .conversationFull)
        #expect(controller.draft == "One more question")
        #expect(controller.messages.isEmpty)
        #expect(engine.prompts.isEmpty)

        controller.perform(.newChatKeepingQuestion)
        #expect(controller.draft == "One more question")
        #expect(controller.messages.isEmpty)
        #expect(controller.failure == nil)
        #expect(engine.resets.last == [])
    }

    @Test func oversizedSingleMessageIsRefusedWithoutAnActionThatWouldDiscardIt() async {
        let (controller, engine) = make()
        engine.usage = ContextUsage(sessionTokens: 120, baselineTokens: 120, promptTokens: 5000, contextSize: 4096, isExact: true)
        controller.draft = String(repeating: "word ", count: 100)
        controller.send()
        await controller.waitUntilIdle()
        #expect(controller.failure?.kind == .promptTooLong)
        #expect(controller.draft.hasPrefix("word"))
        #expect(engine.prompts.isEmpty)
    }

    @Test func starterPrefillNeverReplacesTypedText() {
        let (controller, _) = make()
        controller.draft = "my text"
        controller.prefill("Starter")
        #expect(controller.draft == "my text\n\nStarter")
    }

    @Test func titleComesFromTheFirstQuestion() async {
        let (controller, _) = make()
        #expect(controller.conversationTitle == "New chat")
        controller.draft = "Plan my week\nwith details"
        controller.send()
        await controller.waitUntilIdle()
        #expect(controller.conversationTitle == "Plan my week")
    }
}
