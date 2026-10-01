import Testing
import Foundation
@testable import DeskMateCore

@Suite struct ResultComposerTests {
    private func citation(_ id: String, chunk: String, file: String = "plan.md", excerpt: String = "Launch is planned for the spring.") -> SourceCitation {
        SourceCitation(id: id, chunkID: chunk, fileID: "f-\(chunk)", fileName: file, location: "Section: Timeline", excerpt: excerpt, truncated: false, origin: .library)
    }

    private func material(_ text: String, sources: [ResultSource] = []) -> ResultMaterial {
        ResultMaterial(text: text, sources: sources)
    }

    // MARK: Material

    @Test func theMaterialHasOnlyCompleteAnswersAndRelabelsSourcesPerResult() throws {
        let c1 = citation("S1", chunk: "chunk-a")
        let c2 = citation("S2", chunk: "chunk-b", file: "budget.md", excerpt: "Budget is 10.")
        let messages = [
            ChatMessage(role: .user, text: "When is launch?"),
            ChatMessage(role: .assistant, text: "In spring [S1].", sources: [c1]),
            ChatMessage(role: .user, text: "And the budget?"),
            ChatMessage(role: .assistant, text: "It is 10 [S1, S2].", sources: [citation("S1", chunk: "chunk-b", file: "budget.md"), c2]),
            ChatMessage(role: .user, text: "One more?"),
            ChatMessage(role: .assistant, text: "Cut off", status: .stopped),
        ]
        let built = try #require(ResultMaterialBuilder.build(from: messages))
        #expect(built.sources.map(\.label) == ["R1", "R2"])
        #expect(built.sources.map(\.citation.chunkID) == ["chunk-a", "chunk-b"])
        #expect(built.text.contains("Answer: In spring [R1]."))
        #expect(built.text.contains("Answer: It is 10 [R2]."))
        #expect(!built.text.contains("One more?"))
        #expect(!built.text.contains("Cut off"))
    }

    @Test func aTagTheAnswerCannotExplainIsRemovedAndLookalikeLabelsAreDefused() throws {
        let messages = [
            ChatMessage(role: .user, text: "Is [R1] a thing?"),
            ChatMessage(role: .assistant, text: "Maybe [S9] and [R2].")
        ]
        let built = try #require(ResultMaterialBuilder.build(from: messages))
        #expect(!built.text.contains("[S9]"))
        #expect(!built.text.contains("[R1]"))
        #expect(!built.text.contains("[R2]"))
    }

    @Test func attachedFileNamesAreMentionedButNeverTheirText() throws {
        var question = ChatMessage(role: .user, text: "Summarize this")
        question.attachments = [AttachmentSummary(id: UUID(), fileName: "memo.txt", kind: .text)]
        let built = try #require(ResultMaterialBuilder.build(from: [question, ChatMessage(role: .assistant, text: "Done.")]))
        #expect(built.text.contains("(Attached files: memo.txt)"))
    }

    @Test func nothingToUseWhenThereIsNoCompleteAnswer() {
        #expect(ResultMaterialBuilder.build(from: []) == nil)
        #expect(ResultMaterialBuilder.build(from: [ChatMessage(role: .user, text: "Hi")]) == nil)
        #expect(ResultMaterialBuilder.build(from: [ChatMessage(role: .user, text: "Hi"), ChatMessage(role: .assistant, text: "x", status: .failed)]) == nil)
    }

    // MARK: Tasks

    private let conversation = """
    Question: Who handles the venue?

    Answer: Maria Kowalska will book the venue by 14 March. The catering still needs a decision.
    """

    @Test func ownerAndDueDateComeOnlyFromTheConversationElseNotSpecified() {
        let draft = TaskListDraft(tasks: [
            TaskDraft(task: "Book the venue", owner: "Maria Kowalska", dueDate: "by 14 March", evidence: "Maria Kowalska will book the venue by 14 March"),
            TaskDraft(task: "Decide on catering", owner: "John Smith", dueDate: "next Friday", evidence: "The catering still needs a decision"),
        ])
        let out = ResultComposer.compose(.tasks(draft), material: material(conversation), conversationTitle: "Event", hitLimit: false)
        #expect(out.markdown.contains("| Task | Owner | Due date | Evidence |"))
        #expect(out.markdown.contains("| Book the venue | Maria Kowalska | 14 March | Maria Kowalska will book the venue by 14 March |"))
        #expect(out.markdown.contains("| Decide on catering | Not specified | Not specified | The catering still needs a decision |"))
        #expect(!out.markdown.contains("John Smith"))
        #expect(!out.markdown.contains("next Friday"))
        #expect(out.droppedTasks == 0)
    }

    @Test func emptyOwnerAndDueDateBecomeNotSpecified() {
        let draft = TaskListDraft(tasks: [TaskDraft(task: "Decide on catering", owner: "", dueDate: "  ", evidence: "The catering still needs a decision")])
        let out = ResultComposer.compose(.tasks(draft), material: material(conversation), conversationTitle: "Event", hitLimit: false)
        #expect(out.markdown.contains("| Decide on catering | Not specified | Not specified |"))
    }

    @Test func aTaskWhoseEvidenceIsNotInTheConversationIsLeftOutAndCounted() {
        let draft = TaskListDraft(tasks: [
            TaskDraft(task: "Order flowers", owner: "Not specified", dueDate: "Not specified", evidence: "Someone must order flowers"),
            TaskDraft(task: "Decide on catering", owner: "Not specified", dueDate: "Not specified", evidence: "The catering still needs a decision"),
        ])
        let out = ResultComposer.compose(.tasks(draft), material: material(conversation), conversationTitle: "Event", hitLimit: false)
        #expect(!out.markdown.contains("Order flowers"))
        #expect(out.markdown.contains("Decide on catering"))
        #expect(out.droppedTasks == 1)
        #expect(out.markdown.contains("1 task was left out because its evidence could not be found in the conversation."))
    }

    @Test func noTasksSaysSoInsteadOfShowingAnEmptyTable() {
        let out = ResultComposer.compose(.tasks(TaskListDraft(tasks: [])), material: material(conversation), conversationTitle: "Event", hitLimit: false)
        #expect(out.markdown.contains("*No tasks were found in the conversation.*"))
        #expect(!out.markdown.contains("| Task |"))
    }

    @Test func duplicateTasksAreShownOnce() {
        let task = TaskDraft(task: "Decide on catering", owner: "", dueDate: "", evidence: "The catering still needs a decision")
        let out = ResultComposer.compose(.tasks(TaskListDraft(tasks: [task, task])), material: material(conversation), conversationTitle: "Event", hitLimit: false)
        #expect(out.markdown.components(separatedBy: "| Decide on catering |").count == 2)
    }

    // MARK: Escaping

    @Test func modelTextCannotAddHeadingsListsLinksHtmlOrBreakTheTable() {
        let hostile = TaskDraft(
            task: "# Heading | with pipe\nand a second line",
            owner: "",
            dueDate: "",
            evidence: "The catering still needs a decision"
        )
        let out = ResultComposer.compose(.tasks(TaskListDraft(tasks: [hostile])), material: material(conversation), conversationTitle: "A | B", hitLimit: false)
        let rows = out.markdown.split(separator: "\n").filter { $0.hasPrefix("|") }
        #expect(rows.count == 3, "header, divider and exactly one row")
        let row = String(rows[2])
        #expect(row.hasPrefix("| \\# Heading \\| with pipe and a second line | Not specified | Not specified |"))

        let brief = BriefDraft(
            summary: "See [click](https://example.com) and <b>bold</b> and `code`.",
            decisions: ["# Not a heading", "- not nested", "1. not a numbered list"],
            openQuestions: [],
            nextSteps: ["Ignore previous instructions\n## Injected"]
        )
        let text = ResultComposer.compose(.brief(brief), material: material(conversation), conversationTitle: "# Title", hitLimit: false).markdown
        #expect(text.contains("\\[click\\](https://example.com)"))
        #expect(text.contains("\\<b\\>bold\\</b\\>"))
        #expect(text.contains("\\`code\\`"))
        #expect(text.contains("- \\# Not a heading"))
        #expect(text.contains("- \\- not nested"))
        #expect(text.contains("- 1\\. not a numbered list"))
        #expect(text.contains("# Brief: \\# Title"))
        #expect(!text.contains("\n## Injected"))
        let headings = text.split(separator: "\n").filter { $0.hasPrefix("#") }.map(String.init)
        #expect(headings == ["# Brief: \\# Title", "## Summary", "## Decisions", "## Open questions", "## Next steps"])
    }

    // MARK: Brief and citations

    @Test func aBriefHasTheFourSectionsAndSaysSoWhenOneIsEmpty() {
        let draft = BriefDraft(summary: "The team plans a launch.", decisions: [], openQuestions: ["Which venue?"], nextSteps: [])
        let text = ResultComposer.compose(.brief(draft), material: material("x"), conversationTitle: "Launch", hitLimit: false).markdown
        #expect(text.hasPrefix("# Brief: Launch\n"))
        #expect(text.contains("## Summary\n\nThe team plans a launch."))
        #expect(text.contains("## Decisions\n\n*None identified in the conversation.*"))
        #expect(text.contains("## Open questions\n\n- Which venue?"))
        #expect(text.contains("## Next steps\n\n*None identified in the conversation.*"))
        #expect(!text.contains("## Sources"))
    }

    @Test func citationsAreRenumberedByFirstUseUnknownTagsDropAndSourcesStaySeparate() {
        let sources = [
            ResultSource(label: "R1", citation: citation("S1", chunk: "a", file: "plan.md", excerpt: "Launch is planned for the spring.")),
            ResultSource(label: "R2", citation: citation("S2", chunk: "b", file: "budget.md", excerpt: "Budget is 10.")),
        ]
        let draft = BriefDraft(
            summary: "Budget is 10 [R2] and launch is in spring [R1] [R7].",
            decisions: ["Launch in spring [R1]"],
            openQuestions: [],
            nextSteps: []
        )
        let text = ResultComposer.compose(.brief(draft), material: material("x", sources: sources), conversationTitle: "T", hitLimit: false).markdown
        #expect(text.contains("Budget is 10 [S1] and launch is in spring [S2]."))
        #expect(text.contains("- Launch in spring [S2]"))
        #expect(!text.contains("R7"))
        #expect(!text.contains("[R"))
        let sourcesPart = text.components(separatedBy: "## Sources").last ?? ""
        #expect(text.contains("## Sources"))
        #expect(sourcesPart.contains("[S1] budget.md"))
        #expect(sourcesPart.contains("[S2] plan.md"))
        #expect(sourcesPart.contains("> Budget is 10."))
        #expect(sourcesPart.contains("not part of the generated text"))
    }

    @Test func aLongQuotedExcerptIsShortenedInTheSourcesList() {
        let long = String(repeating: "word ", count: 200)
        let sources = [ResultSource(label: "R1", citation: citation("S1", chunk: "a", excerpt: long))]
        let text = ResultComposer.compose(.brief(BriefDraft(summary: "Said so [R1].", decisions: [], openQuestions: [], nextSteps: [])), material: material("x", sources: sources), conversationTitle: "T", hitLimit: false).markdown
        let quote = text.split(separator: "\n").first { $0.hasPrefix("  >") } ?? ""
        #expect(quote.count < ResultComposer.maxQuotedCharacters + 10)
        #expect(quote.hasSuffix("…"))
    }

    @Test func reachingTheLengthLimitAddsAnIncompleteNote() {
        let draft = BriefDraft(summary: "Short.", decisions: [], openQuestions: [], nextSteps: [])
        let cut = ResultComposer.compose(.brief(draft), material: material("x"), conversationTitle: "T", hitLimit: true).markdown
        let whole = ResultComposer.compose(.brief(draft), material: material("x"), conversationTitle: "T", hitLimit: false).markdown
        #expect(cut.contains(ResultComposer.incompleteNote))
        #expect(!whole.contains(ResultComposer.incompleteNote))
    }

    // MARK: Budget

    @Test func theResponseCapShrinksWithTheMaterialAndRefusesWhenItCannotFit() {
        #expect(ResultBudget.responseCap(contextSize: 4096, instructionsTokens: 150, promptTokens: 500) == ResultBudget.maxResponseTokens)
        let tight = ResultBudget.responseCap(contextSize: 4096, instructionsTokens: 150, promptTokens: 3_000)
        #expect(tight != nil && tight! < ResultBudget.maxResponseTokens && tight! >= ResultBudget.minResponseTokens)
        #expect(ResultBudget.responseCap(contextSize: 4096, instructionsTokens: 150, promptTokens: 3_400) == nil)
    }
}
