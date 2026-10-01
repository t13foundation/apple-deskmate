import DeskMateCore
import Foundation

/// Command-line evidence for saved conversations, always on the real on-device model and a throwaway folder.
///
/// `--brief "<text>"` and `--tasks "<text>"`: seeds a saved conversation whose one answer is the given text, reopens
/// it through the same code the app uses, creates the result with guided generation and prints the Markdown.
/// `--resume-demo`: seeds a long synthetic conversation, simulates a restart (new history, engine and controller),
/// prints how much of it the model was given back, and asks one real follow-up.
///
/// The conversations are synthetic. Nothing is written outside a temporary folder that is deleted afterwards.
@MainActor
enum HeadlessConversations {
    private static func makeFolder() -> TempFolder { TempFolder() }

    private final class TempFolder {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deskmate-headless-\(UUID().uuidString)", isDirectory: true)
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static func message(_ role: StoredMessage.Role, _ text: String, at offset: Double) -> StoredMessage {
        StoredMessage(id: UUID(), role: role, text: text, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offset), status: .complete)
    }

    private static func requireModel(_ engine: SystemModelEngine) -> Bool {
        let snapshot = engine.readiness()
        guard snapshot.readiness.isReady else {
            print(ModelDiagnostics.report(snapshot: snapshot))
            print("\nNot running: the on-device model is not ready. Nothing was produced.")
            return false
        }
        return true
    }

    // MARK: Result

    static func result(kind: ResultKind, text: String) async -> Int32 {
        let engine = SystemModelEngine()
        guard requireModel(engine) else { return 3 }
        let folder = makeFolder()
        let storage = ConversationStorage(directory: folder.url.appendingPathComponent("Conversations", isDirectory: true))
        let record = ConversationRecord(
            id: UUID(),
            title: "Synthetic conversation",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            messages: [message(.user, "Please explain the situation.", at: 0), message(.assistant, text, at: 1)]
        )
        do { try storage.save(record) } catch {
            print("error: could not write the temporary conversation: \(error.localizedDescription)")
            return 1
        }

        let history = ConversationHistory(storage: storage)
        await history.load()
        let controller = ConversationController(engine: engine, history: history)
        await controller.open(record.id)
        await controller.waitForRestore()
        print("engine: SystemLanguageModel.default (real on-device inference)")
        print("conversation: reopened from disk, \(controller.messages.count) messages")
        print("can create result: \(controller.canCreateResult)")

        let start = ContinuousClock.now
        controller.createResult(kind)
        await controller.waitUntilIdle()
        let elapsed = ContinuousClock.now - start

        guard let created = controller.results.first else {
            if let failure = controller.resultFailure {
                print("Result was not created: \(failure.title) [\(failure.code)]")
                print(failure.message)
            } else {
                print("Result was not created.")
            }
            return 1
        }
        await history.waitForWrites()
        let saved: Bool
        if case .loaded(let reloaded) = storage.load(record.id) { saved = reloaded.results.first?.markdown == created.markdown } else { saved = false }
        print("total: \(seconds(elapsed)) s")
        print("saved with the conversation and read back from disk: \(saved)")
        print("--- \(kind.title.lowercased()) (Markdown, as rendered by code from the model's structured output) ---")
        print(created.markdown)
        return saved ? 0 : 1
    }

    // MARK: Resume

    private static let topics: [(question: String, answer: String)] = [
        ("What should we check before booking a venue?", "Before booking a venue, check the capacity against your guest list, the accessibility of the entrance and restrooms, whether catering is allowed inside, the cancellation terms, and what the price includes. Ask for the total cost in writing, including cleaning and equipment. Visit the place once at the time of day your event will happen, because noise and parking often differ from what the photos suggest."),
        ("How do we split the budget?", "A common split for a small event is about forty percent for the venue, thirty percent for food and drinks, ten percent for equipment, ten percent for printed material and invitations, and ten percent kept as a reserve. Adjust the shares to your priorities, but keep the reserve: unexpected costs nearly always appear in the last two weeks."),
        ("What do we need for the invitations?", "Invitations should state the purpose, date, start and end time, address with a short note on how to arrive, a reply deadline, and a contact person. Send them at least three weeks ahead for a weekday evening event, and send one reminder a week before the reply deadline."),
        ("Who should speak at the opening?", "Choose one person who knows most guests and can keep to five minutes. A short welcome, one sentence on why everyone is there, and a clear pointer to what happens next works better than several speakers. Ask the speaker to rehearse once with the microphone you will really use."),
        ("What can go wrong with catering?", "The usual problems are late delivery, missing dietary options, and too little food at the start when everyone arrives together. Collect dietary needs with the reply, agree on a delivery time thirty minutes before doors open, and plan snacks that are available straight away."),
        ("How do we handle accessibility?", "Confirm step-free entry, a usable restroom, seating for people who cannot stand for long, and a quiet corner. Say in the invitation what is available, and name a person guests can ask. Test the route from the nearest stop yourself."),
        ("What should the schedule look like?", "Open the doors thirty minutes before the start. Keep the program to ninety minutes: welcome, one main item, a break, and a closing with the next steps. Leave the rest of the time for conversation, which is why people come in the first place."),
        ("Which equipment do we need?", "At minimum a microphone with a spare battery set, a projector or screen if there are slides, extension cables, a printed copy of the schedule, tape, a first aid kit, and name tags. Bring a laptop with the slides on it and a copy on a USB stick."),
        ("How do we collect feedback?", "Keep it to three questions on a card or a short form: what was useful, what was missing, and whether the person would come again. Hand it out during the closing and let people leave it at the exit. Send the digital link the next morning to those who did not."),
        ("Who is responsible for the venue booking?", "In this plan Maria Kowalska owns the venue booking and has to confirm it with the venue by 14 March. John Smith checks the accessibility questions and reports back the week before. The catering decision is still open and needs an owner."),
        ("What is still open?", "Three things are open: the catering supplier has not been chosen, the opening speaker has not confirmed, and the reply deadline for invitations is not fixed. The venue booking by Maria Kowalska by 14 March is the next firm step."),
    ]

    static func resumeDemo() async -> Int32 {
        let firstEngine = SystemModelEngine()
        guard requireModel(firstEngine) else { return 3 }
        let folder = makeFolder()
        let storage = ConversationStorage(directory: folder.url.appendingPathComponent("Conversations", isDirectory: true))

        // The earlier session: a long synthetic conversation saved to disk, then "closed".
        var messages: [StoredMessage] = []
        for (index, turn) in topics.enumerated() {
            messages.append(message(.user, turn.question, at: Double(index * 2)))
            messages.append(message(.assistant, turn.answer, at: Double(index * 2 + 1)))
        }
        let record = ConversationRecord(
            id: UUID(),
            title: topics[0].question,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            messages: messages
        )
        do { try storage.save(record) } catch {
            print("error: could not write the temporary conversation: \(error.localizedDescription)")
            return 1
        }
        print("seeded: \(topics.count) synthetic turns saved to a temporary folder, then \"restarted\"")

        // The restart: everything new, nothing shared with the session that wrote the file.
        let engine = SystemModelEngine()
        let history = ConversationHistory(storage: storage)
        await history.load()
        print("recent list after restart: \(history.summaries.map(\.title))")
        let controller = ConversationController(engine: engine, history: history)
        await controller.open(record.id)
        await controller.waitForRestore()
        let usage = await engine.contextUsage(adding: "")
        print("engine: SystemLanguageModel.default (real on-device inference), exact counting: \(usage.isExact)")
        print("visible messages after reopening: \(controller.messages.count)")
        print("turns given back to the model: \(topics.count - controller.omittedFromMemory) of \(topics.count) (older turns left out: \(controller.omittedFromMemory))")
        print("model memory note shown: \(controller.omittedFromMemory > 0)")
        print("session tokens after restore: \(usage.sessionTokens) of \(usage.contextSize) (limit for restored memory: \(HistoryBudget.sessionLimit(contextSize: usage.contextSize)))")

        let question = "Who owns the venue booking, and by which date?"
        controller.draft = question
        controller.send()
        await controller.waitUntilIdle()
        await history.waitForWrites()
        guard let answer = controller.messages.last, answer.role == .assistant else {
            print("No answer was produced.")
            return 1
        }
        print("--- follow-up: \(question) ---")
        print(answer.text)
        print("status: \(answer.status)")
        if let failure = controller.failure { print("failure: \(failure.title) [\(failure.code)]") }
        var saved = false
        if case .loaded(let reloaded) = storage.load(record.id) { saved = reloaded.messages.count == messages.count + 2 }
        print("follow-up saved to the same conversation: \(saved)")
        return answer.status == .complete && saved ? 0 : 1
    }

    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f", value)
    }
}
