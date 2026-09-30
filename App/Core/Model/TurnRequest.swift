import Foundation

/// Everything the person asked in one send: the question and any files attached to it.
public struct TurnRequest: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// A normal question. Attached files, if any, are read as part of the question.
        case ask
        /// Compare exactly two attached documents.
        case compare
    }

    public var question: String
    public var attachments: [Attachment]
    public var mode: Mode

    public init(question: String, attachments: [Attachment] = [], mode: Mode = .ask) {
        self.question = question
        self.attachments = attachments
        self.mode = mode
    }
}

/// A partial result while a turn runs.
public struct TurnUpdate: Equatable, Sendable {
    /// The complete answer text so far (not a delta).
    public var text: String
    /// What DeskMate is doing while no text arrives, e.g. "Searching your files…". Nil when just writing.
    public var activity: String?

    public init(text: String, activity: String? = nil) {
        self.text = text
        self.activity = activity
    }
}

public enum TurnPreparation: Equatable, Sendable {
    case ready
    /// The turn cannot run. Nothing was sent to the model and the question stays in the composer.
    case refused(ChatFailure)
}

public extension ConversationEngine {
    /// Default for engines without files: measure the question alone against the context budget.
    func prepareTurn(_ request: TurnRequest, history: [ConversationTurn]) async -> TurnPreparation {
        let usage = await contextUsage(adding: request.question)
        if let failure = ChatFailure.context(ContextBudget.decide(usage)) {
            return .refused(failure)
        }
        return .ready
    }

    func streamTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnUpdate, any Error> {
        let replies = streamReply(to: request.question)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await text in replies {
                        continuation.yield(TurnUpdate(text: text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Default: no sources, the answer is used as written.
    func grounding(forAnswer text: String) -> GroundedAnswer? { nil }
}
