import Foundation
import Observation

/// Owns the current conversation: visible messages, the composer draft, streaming, cancellation and
/// the model context. One instance backs one conversation window; persistence is added by a later package.
///
/// Rules this type enforces:
/// - A question is never lost: it stays in the transcript (or the composer) after Stop or any failure.
/// - Earlier turns are never truncated silently; too much text is refused with an explanation.
/// - Only finished turns are kept in model context; a stopped or failed turn is excluded and can be retried.
@MainActor
@Observable
public final class ConversationController {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Measuring the context budget; the message has not been sent yet.
        case preparing
        case generating
    }

    public private(set) var messages: [ChatMessage] = []
    /// Composer text. Lives here so no failure or state change can discard it.
    public var draft: String = ""
    public private(set) var phase: Phase = .idle
    public private(set) var failure: ChatFailure?
    public private(set) var snapshot: ModelReadinessSnapshot
    /// Increments whenever the composer should take keyboard focus.
    public private(set) var focusRequest = 0
    /// Increments when the person tries to send while the model is unavailable, so the UI can draw attention.
    public private(set) var readinessNudge = 0

    @ObservationIgnored private let engine: any ConversationEngine
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var turns: [ConversationTurn] = []
    @ObservationIgnored private var epoch = UUID()

    public init(engine: any ConversationEngine) {
        self.engine = engine
        self.snapshot = engine.readiness()
    }

    // MARK: Derived state

    public var readiness: ModelReadiness { snapshot.readiness }
    public var isBusy: Bool { phase != .idle }
    public var isGenerating: Bool { phase != .idle }
    public var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var canSend: Bool { !trimmedDraft.isEmpty && !isBusy && readiness.isReady }
    public var hasConversation: Bool { !messages.isEmpty }

    /// Sidebar title: the first question, shortened.
    public var conversationTitle: String {
        guard let first = messages.first(where: { $0.role == .user }) else { return "New chat" }
        let line = first.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? first.text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
    }

    /// The last assistant message when it ended stopped or failed, with the question that produced it.
    private var unfinishedTurn: (question: ChatMessage, answer: ChatMessage)? {
        guard messages.count >= 2,
              let answer = messages.last, answer.role == .assistant,
              answer.status == .stopped || answer.status == .failed,
              case let question = messages[messages.count - 2], question.role == .user
        else { return nil }
        return (question, answer)
    }

    public var canRetry: Bool { !isBusy && unfinishedTurn != nil }

    // MARK: Readiness

    public func refreshReadiness() {
        snapshot = engine.readiness()
    }

    public func prewarmIfReady() {
        refreshReadiness()
        if readiness.isReady { engine.prewarm() }
    }

    // MARK: Sending

    public func send() {
        guard !isBusy else { return }
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        start(prompt: text, reusing: nil)
    }

    public func retry() {
        guard !isBusy, let turn = unfinishedTurn else { return }
        start(prompt: turn.question.text, reusing: turn.question.id)
    }

    private func start(prompt: String, reusing existingQuestionID: UUID?) {
        refreshReadiness()
        guard readiness.isReady else {
            // The readiness banner explains the state; the draft stays untouched.
            readinessNudge += 1
            return
        }
        failure = nil
        phase = .preparing
        let epoch = self.epoch
        generation = Task { [weak self] in
            await self?.runTurn(prompt: prompt, reusing: existingQuestionID, epoch: epoch)
        }
    }

    private func runTurn(prompt: String, reusing existingQuestionID: UUID?, epoch: UUID) async {
        let usage = await engine.contextUsage(adding: prompt)
        guard epoch == self.epoch else { return }
        if Task.isCancelled {
            phase = .idle
            return
        }
        if let contextFailure = ChatFailure.context(ContextBudget.decide(usage)) {
            failure = contextFailure
            phase = .idle
            return
        }

        if existingQuestionID != nil {
            // Retrying: drop the stopped/failed answer, keep the question.
            if let last = messages.last, last.role == .assistant { messages.removeLast() }
        } else {
            messages.append(ChatMessage(role: .user, text: prompt))
            if trimmedDraft == prompt { draft = "" }
        }
        let answer = ChatMessage(role: .assistant, text: "", status: .streaming)
        messages.append(answer)
        phase = .generating

        var latest = ""
        do {
            for try await text in engine.streamReply(to: prompt) {
                guard epoch == self.epoch else { return }
                latest = text
                update(answer.id) { $0.text = text }
            }
        } catch {
            guard epoch == self.epoch else { return }
            if Task.isCancelled || error is CancellationError {
                finishStopped(answer.id, partial: latest)
            } else {
                finishFailed(answer.id, partial: latest, error: error)
            }
            return
        }
        guard epoch == self.epoch else { return }
        if Task.isCancelled {
            finishStopped(answer.id, partial: latest)
        } else if latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishFailed(answer.id, partial: latest, error: EmptyResponse())
        } else {
            update(answer.id) { $0.status = .complete }
            turns.append(ConversationTurn(prompt: prompt, response: latest))
            phase = .idle
        }
    }

    private struct EmptyResponse: Error {}

    private func finishStopped(_ id: UUID, partial: String) {
        update(id) {
            $0.text = partial
            $0.status = .stopped
        }
        engine.reset(history: turns)
        phase = .idle
        focusRequest += 1
    }

    private func finishFailed(_ id: UUID, partial: String, error: any Error) {
        update(id) {
            $0.text = partial
            $0.status = .failed
        }
        failure = error is EmptyResponse ? .generic(code: "emptyResponse") : .from(error: error)
        engine.reset(history: turns)
        phase = .idle
    }

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    // MARK: Cancelling

    /// Stops generation. The question stays, the partial answer is kept and marked as stopped.
    public func cancel() {
        guard isBusy else { return }
        generation?.cancel()
    }

    // MARK: New chat and editing

    /// Clears the visible conversation and the model context.
    /// With `keepingQuestion`, the question that did not fit (or failed) is moved into the new composer.
    public func newChat(keepingQuestion: Bool = false) {
        var carried = ""
        if keepingQuestion {
            carried = draft.isEmpty ? (unfinishedTurn?.question.text ?? "") : draft
        }
        generation?.cancel()
        generation = nil
        epoch = UUID()
        messages = []
        turns = []
        failure = nil
        phase = .idle
        draft = carried
        engine.reset(history: [])
        refreshReadiness()
        focusRequest += 1
    }

    /// Moves the last unfinished question back into the composer so it can be reworded.
    /// Existing composer text is kept below it, never overwritten.
    public func editLastQuestion() {
        guard !isBusy, let turn = unfinishedTurn else { return }
        messages.removeLast(2)
        draft = draft.isEmpty ? turn.question.text : turn.question.text + "\n\n" + draft
        failure = nil
        focusRequest += 1
    }

    public func dismissFailure() {
        failure = nil
    }

    /// Runs a failure action. `openSystemSettings` is handled by the UI layer.
    public func perform(_ action: ChatFailureAction) {
        switch action {
        case .retry: retry()
        case .editQuestion: editLastQuestion()
        case .newChat: newChat()
        case .newChatKeepingQuestion: newChat(keepingQuestion: true)
        case .checkAgain:
            refreshReadiness()
            if readiness.isReady { failure = nil }
        case .openSystemSettings: break
        }
    }

    /// Fills the composer without sending, e.g. for starter prompts. Never replaces text the person typed.
    public func prefill(_ text: String) {
        draft = draft.isEmpty ? text : draft + "\n\n" + text
        focusRequest += 1
    }

    // MARK: Testing support

    /// Waits for the current generation task to finish.
    public func waitUntilIdle() async {
        await generation?.value
    }
}
