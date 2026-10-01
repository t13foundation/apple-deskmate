import Testing
import Foundation
@testable import DeskMateCore

@MainActor
@Suite struct ConversationPersistenceTests {
    private struct Rig {
        let store: TempStore
        let history: ConversationHistory
        let engine: ScriptedEngine
        let controller: ConversationController
    }

    private func rig(store: TempStore = TempStore(), engine: ScriptedEngine = ScriptedEngine()) -> Rig {
        let history = ConversationHistory(storage: store.storage)
        return Rig(store: store, history: history, engine: engine, controller: ConversationController(engine: engine, history: history))
    }

    private func ask(_ rig: Rig, _ question: String, answer: String) async {
        rig.engine.behaviors = [.chunks([answer])]
        rig.controller.draft = question
        rig.controller.send()
        await rig.controller.waitUntilIdle()
    }

    // MARK: Saving and resuming

    @Test func aFinishedTurnIsSavedAndReopensAfterARestart() async throws {
        let first = rig()
        defer { first.store.remove() }
        await ask(first, "What is a budget?", answer: "A plan for money.")
        await first.history.waitForWrites()
        let id = first.controller.conversationID

        // A restart: a new history, engine and controller over the same folder.
        let second = rig(store: first.store)
        await second.history.load()
        #expect(second.history.summaries.map(\.id) == [id])
        #expect(second.history.summaries.first?.title == "What is a budget?")
        await second.controller.open(id)
        await second.controller.waitForRestore()
        #expect(second.controller.messages.map(\.text) == ["What is a budget?", "A plan for money."])
        #expect(second.controller.messages.allSatisfy { $0.status == .complete })
        #expect(second.engine.resets.last?.map(\.prompt) == ["What is a budget?"], "the model is given the finished turn back")
        #expect(second.controller.omittedFromMemory == 0)
        #expect(second.controller.memoryBoundaryID == nil)
    }

    @Test func aFollowUpAfterRestartWorksAndIsSavedToTheSameConversation() async throws {
        let first = rig()
        defer { first.store.remove() }
        await ask(first, "Q1", answer: "A1")
        await first.history.waitForWrites()
        let id = first.controller.conversationID

        let second = rig(store: first.store)
        await second.history.load()
        await second.controller.open(id)
        await ask(second, "Q2", answer: "A2")
        await second.history.waitForWrites()
        #expect(second.engine.prompts == ["Q2"])
        #expect(second.controller.conversationID == id)
        guard case .loaded(let record) = first.store.storage.load(id) else {
            Issue.record("record should load")
            return
        }
        #expect(record.messages.map(\.text) == ["Q1", "A1", "Q2", "A2"])
        #expect(second.history.summaries.count == 1)
    }

    @Test func olderTurnsLeftOutOfModelMemoryAreCountedAndMarkedButStayVisible() async throws {
        let first = rig()
        defer { first.store.remove() }
        for index in 1...3 { await ask(first, "Q\(index)", answer: "A\(index)") }
        await first.history.waitForWrites()
        let id = first.controller.conversationID

        let second = rig(store: first.store)
        second.engine.restoreKeeps = 2
        await second.history.load()
        await second.controller.open(id)
        await second.controller.waitForRestore()
        #expect(second.controller.messages.count == 6, "every message is still visible")
        #expect(second.controller.omittedFromMemory == 1)
        let questions = second.controller.messages.filter { $0.role == .user }
        #expect(second.controller.memoryBoundaryID == questions[1].id, "memory starts at the second question")
        #expect(second.engine.resets.last?.map(\.prompt) == ["Q2", "Q3"])
    }

    @Test func aRestoredSessionThatDoesNotFitDropsOlderTurnsUsingTheMeasuredSize() async throws {
        let first = rig()
        defer { first.store.remove() }
        for index in 1...2 { await ask(first, "Q\(index)", answer: "A\(index)") }
        await first.history.waitForWrites()
        let id = first.controller.conversationID

        let second = rig(store: first.store)
        // Every measurement says the session is already over the limit, so nothing can be restored.
        second.engine.usage = ContextUsage(sessionTokens: 3_900, baselineTokens: 120, promptTokens: 0, contextSize: 4096, isExact: true)
        await second.history.load()
        await second.controller.open(id)
        await second.controller.waitForRestore()
        #expect(second.controller.omittedFromMemory == 2)
        #expect(second.controller.memoryBoundaryID == nil, "with nothing remembered the note goes after the last message")
        #expect(second.engine.resets.last?.isEmpty == true)
        #expect(second.controller.messages.count == 4)
    }

    @Test func stoppedAndFailedAnswersAreSavedAsShownButNotRememberedByTheModel() async throws {
        let first = rig()
        defer { first.store.remove() }
        await ask(first, "Q1", answer: "A1")
        first.engine.behaviors = [.failing(["Partial"], URLError(.badServerResponse))]
        first.controller.draft = "Q2"
        first.controller.send()
        await first.controller.waitUntilIdle()
        await first.history.waitForWrites()
        let id = first.controller.conversationID

        let second = rig(store: first.store)
        await second.history.load()
        await second.controller.open(id)
        await second.controller.waitForRestore()
        #expect(second.controller.messages.map(\.status) == [.complete, .complete, .complete, .failed])
        #expect(second.engine.resets.last?.map(\.prompt) == ["Q1"])
    }

    @Test func aStreamingAnswerIsSavedAsStoppedWhenTheConversationIsLeft() async throws {
        let first = rig()
        defer { first.store.remove() }
        first.engine.behaviors = [.manual]
        first.controller.draft = "Long one"
        first.controller.send()
        await waitUntil { first.engine.prompts.count == 1 }
        first.engine.manual?.yield("Half an ans")
        await waitUntil { first.controller.messages.last?.text == "Half an ans" }
        let id = first.controller.conversationID
        first.controller.newChat()
        await first.history.waitForWrites()
        guard case .loaded(let record) = first.store.storage.load(id) else {
            Issue.record("record should be saved")
            return
        }
        #expect(record.messages.last?.status == .stopped)
        #expect(record.messages.last?.text == "Half an ans")
    }

    // MARK: New chat, delete, clear

    @Test func newChatStartsANewRecordAndKeepsTheOldOne() async throws {
        let rig = rig()
        defer { rig.store.remove() }
        await ask(rig, "Q1", answer: "A1")
        let firstID = rig.controller.conversationID
        rig.controller.newChat()
        #expect(rig.controller.conversationID != firstID)
        #expect(rig.controller.messages.isEmpty)
        await ask(rig, "Q2", answer: "A2")
        await rig.history.waitForWrites()
        #expect(Set(rig.history.summaries.map(\.id)) == [firstID, rig.controller.conversationID])
        #expect(rig.history.summaries.count == 2)
    }

    @Test func anEmptyNewChatLeavesNoRecordBehind() async throws {
        let rig = rig()
        defer { rig.store.remove() }
        rig.controller.newChat()
        rig.controller.newChat()
        await rig.history.waitForWrites()
        #expect(rig.history.summaries.isEmpty)
        #expect(rig.store.names().isEmpty)
    }

    @Test func deletingTheOpenConversationResetsTheScreenAndKeepsTheDraft() async throws {
        let rig = rig()
        defer { rig.store.remove() }
        await ask(rig, "Q1", answer: "A1")
        let id = rig.controller.conversationID
        rig.controller.draft = "half-typed"
        rig.controller.deleteConversation(id)
        await rig.history.waitForWrites()
        #expect(rig.controller.messages.isEmpty)
        #expect(rig.controller.draft == "half-typed")
        #expect(rig.controller.conversationID != id)
        #expect(rig.history.summaries.isEmpty)
        #expect(rig.store.names().filter { $0 != "index.json" }.isEmpty)
        #expect(rig.store.storage.list().summaries.isEmpty)
    }

    @Test func deletingAnotherConversationLeavesTheOpenOneAlone() async throws {
        let rig = rig()
        defer { rig.store.remove() }
        await ask(rig, "Q1", answer: "A1")
        let firstID = rig.controller.conversationID
        rig.controller.newChat()
        await ask(rig, "Q2", answer: "A2")
        rig.controller.deleteConversation(firstID)
        await rig.history.waitForWrites()
        #expect(rig.controller.messages.map(\.text) == ["Q2", "A2"])
        #expect(rig.history.summaries.map(\.id) == [rig.controller.conversationID])
    }

    @Test func clearHistoryRemovesEverythingButNeverTheLibraryOrSourceFiles() async throws {
        let rig = rig()
        defer { rig.store.remove() }
        let source = rig.store.root.appendingPathComponent("report.txt")
        try FileManager.default.createDirectory(at: rig.store.root, withIntermediateDirectories: true)
        try Data("Source".utf8).write(to: source)
        var removals: [HistoryRemoval] = []
        rig.history.onRemoval { removals.append($0) }
        await ask(rig, "Q1", answer: "A1")
        rig.controller.newChat()
        await ask(rig, "Q2", answer: "A2")
        rig.controller.clearHistory()
        await rig.history.waitForWrites()
        #expect(removals == [.everything])
        #expect(rig.controller.messages.isEmpty)
        #expect(rig.history.summaries.isEmpty)
        #expect(rig.store.names().isEmpty)
        #expect(try String(contentsOf: source, encoding: .utf8) == "Source")
    }

    @Test func openingAnUnreadableConversationKeepsTheScreenAndWarns() async throws {
        let first = rig()
        defer { first.store.remove() }
        await ask(first, "Q1", answer: "A1")
        await first.history.waitForWrites()
        let broken = first.controller.conversationID
        first.controller.newChat()
        await ask(first, "Q2", answer: "A2")
        await first.history.waitForWrites()
        try Data("{ broken".utf8).write(to: first.store.storage.recordURL(broken))

        await first.controller.open(broken)
        #expect(first.controller.messages.map(\.text) == ["Q2", "A2"])
        #expect(first.history.notices.count == 1)
        #expect(first.history.summaries.count == 1)
    }

    // MARK: Results

    private func sampleBrief() -> ResultOutcome {
        .generated(.brief(BriefDraft(summary: "A plan for money.", decisions: [], openQuestions: [], nextSteps: [])), hitLimit: false)
    }

    @Test func aBriefIsCreatedPresentedAndSavedWithTheConversation() async throws {
        let rig = rig()
        defer { rig.store.remove() }
        await ask(rig, "What is a budget?", answer: "A plan for money.")
        rig.engine.resultOutcome = sampleBrief()
        #expect(rig.controller.canCreateResult)
        rig.controller.createResult(.brief)
        #expect(rig.controller.phase == .creatingResult)
        await rig.controller.waitUntilIdle()
        let result = try #require(rig.controller.results.first)
        #expect(result.kind == .brief)
        #expect(result.markdown.contains("# Brief: What is a budget?"))
        #expect(rig.controller.presentedResultID == result.id)
        #expect(rig.engine.resultRequests.first?.material.text.contains("Question: What is a budget?") == true)
        #expect(rig.engine.prompts == ["What is a budget?"], "the chat session itself was not used")

        rig.controller.updateResult(result.id, markdown: "# Edited\n")
        await rig.history.waitForWrites()
        guard case .loaded(let record) = rig.store.storage.load(rig.controller.conversationID) else {
            Issue.record("record should load")
            return
        }
        #expect(record.results.first?.markdown == "# Edited\n", "the edit is what is stored")
    }

    @Test func aResultReopensWithTheConversation() async throws {
        let first = rig()
        defer { first.store.remove() }
        await ask(first, "Q", answer: "A")
        first.engine.resultOutcome = sampleBrief()
        first.controller.createResult(.brief)
        await first.controller.waitUntilIdle()
        await first.history.waitForWrites()
        let id = first.controller.conversationID

        let second = rig(store: first.store)
        await second.history.load()
        await second.controller.open(id)
        #expect(second.controller.results.count == 1)
        second.controller.deleteResult(second.controller.results[0].id)
        await second.history.waitForWrites()
        guard case .loaded(let record) = first.store.storage.load(id) else {
            Issue.record("record should load")
            return
        }
        #expect(record.results.isEmpty)
    }

    @Test func aTooLongConversationIsRefusedClearlyAndNothingIsSaved() async throws {
        let rig = rig()
        defer { rig.store.remove() }
        await ask(rig, "Q", answer: "A")
        rig.engine.resultOutcome = .refused(ResultBudget.tooLong(kind: .tasks))
        rig.controller.createResult(.tasks)
        await rig.controller.waitUntilIdle()
        #expect(rig.controller.results.isEmpty)
        #expect(rig.controller.resultFailure?.code == "resultTooLong")
        #expect(rig.controller.phase == .idle)
        rig.controller.dismissResultFailure()
        #expect(rig.controller.resultFailure == nil)
    }

    @Test func aFailureWhileGeneratingShowsAFailureAndKeepsTheChatUsable() async throws {
        let rig = rig()
        defer { rig.store.remove() }
        await ask(rig, "Q", answer: "A")
        rig.engine.resultError = URLError(.timedOut)
        rig.controller.createResult(.brief)
        await rig.controller.waitUntilIdle()
        #expect(rig.controller.results.isEmpty)
        #expect(rig.controller.resultFailure != nil)
        #expect(rig.controller.phase == .idle)
        await ask(rig, "Q2", answer: "A2")
        #expect(rig.controller.messages.count == 4)
    }

    @Test func noResultCanBeCreatedWithoutACompleteAnswer() async throws {
        let rig = rig()
        defer { rig.store.remove() }
        #expect(!rig.controller.canCreateResult)
        rig.controller.createResult(.brief)
        #expect(rig.controller.resultFailure?.code == "resultNothingToUse")
        #expect(rig.engine.resultRequests.isEmpty)
    }
}
