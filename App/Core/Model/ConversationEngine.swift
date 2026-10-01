import Foundation

/// The seam between the conversation logic and a real language-model session.
/// The only production implementation is `SystemModelEngine` (Apple's on-device model).
/// Test doubles exist only in the test target; the app has no mock inference path.
@MainActor
public protocol ConversationEngine: AnyObject {
    /// Current system readiness. Cheap; safe to call often.
    func readiness() -> ModelReadinessSnapshot

    /// Measures what sending `prompt` would consume, without sending it.
    func contextUsage(adding prompt: String) async -> ContextUsage

    /// Streams the reply. Each element is the complete answer text so far (not a delta).
    /// Cancelling the consuming task cancels generation.
    func streamReply(to prompt: String) -> AsyncThrowingStream<String, any Error>

    /// Starts a fresh model context, optionally restoring finished turns.
    /// Used by New chat (empty history) and after a stopped or failed turn (completed turns only).
    func reset(history: [ConversationTurn])

    /// Optional latency optimisation. Must not send any content.
    func prewarm()

    /// Checks that a turn (question plus attached files) fits the context before anything is sent.
    /// `history` is the finished turns, so an engine can rebuild its context if the library changed.
    func prepareTurn(_ request: TurnRequest, history: [ConversationTurn]) async -> TurnPreparation

    /// Runs a prepared turn. Each update carries the complete answer so far.
    func streamTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnUpdate, any Error>

    /// Checks the citations in an answer against the excerpts the model really received.
    /// Nil when the engine has no sources.
    func grounding(forAnswer text: String) -> GroundedAnswer?

    /// Starts a fresh model context from the finished turns of a reopened conversation, keeping the most recent turns
    /// that fit the context budget. Returns how many turns were kept (the newest ones); older ones are not remembered.
    func restoreHistory(_ turns: [ConversationTurn]) async -> Int

    /// Creates a brief or a task list from the visible conversation in a separate one-shot session, so the chat's own
    /// context is not touched. Refuses, without sending anything, a conversation that does not fit.
    func makeResult(_ request: ResultRequest) async throws -> ResultOutcome

    /// Stop: ends every pending approval and abandons any request in flight, so nothing waiting can still be sent.
    func stopToolActivity()
}

public extension ConversationEngine {
    func prewarm() {}

    /// Default: an engine with no connected services has nothing to stop.
    func stopToolActivity() {}

    /// Default: the budget check with the conservative estimator.
    func restoreHistory(_ turns: [ConversationTurn]) async -> Int {
        await HistoryRestore.run(engine: self, turns: turns, meter: EstimatingMeter())
    }

    /// Default: an engine with no structured generation cannot make a result, and says so.
    func makeResult(_ request: ResultRequest) async throws -> ResultOutcome {
        .refused(ChatFailure(
            kind: .other,
            title: "This engine can’t create results",
            message: "Briefs and task lists need the on-device model.",
            actions: [],
            code: "resultUnsupported"
        ))
    }
}
