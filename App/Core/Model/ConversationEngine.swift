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
}

public extension ConversationEngine {
    func prewarm() {}
}
