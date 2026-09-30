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
}

public extension ConversationEngine {
    func prewarm() {}
}
