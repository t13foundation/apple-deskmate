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

    /// Files attached to the question being written. Cleared when the question is sent.
    public private(set) var attachments: [Attachment] = []
    /// True while the person is preparing a two-document comparison.
    public private(set) var isComparing = false
    /// Why a file was not attached, in plain language.
    public private(set) var attachmentNotices: [String] = []
    /// What DeskMate is doing while the answer has not started, e.g. "Searching your files…".
    public private(set) var activity: String?
    public private(set) var isLoadingAttachments = false

    @ObservationIgnored private let engine: any ConversationEngine
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var turns: [ConversationTurn] = []
    @ObservationIgnored private var epoch = UUID()
    /// The request behind each question, so Retry and Edit restore its attached files.
    @ObservationIgnored private var requests: [UUID: TurnRequest] = [:]

    public init(engine: any ConversationEngine) {
        self.engine = engine
        self.snapshot = engine.readiness()
    }

    // MARK: Derived state

    public var readiness: ModelReadiness { snapshot.readiness }
    public var isBusy: Bool { phase != .idle }
    public var isGenerating: Bool { phase != .idle }
    public var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var canSend: Bool {
        !trimmedDraft.isEmpty && !isBusy && !isLoadingAttachments && readiness.isReady && (!isComparing || attachments.count == 2)
    }

    public nonisolated static let maxAttachments = LibraryLimits.maxAttachments
    /// A comparison takes exactly two documents; a question takes up to five files.
    public var attachmentLimit: Int { isComparing ? 2 : Self.maxAttachments }
    public var canAttachMore: Bool { !isBusy && !isLoadingAttachments && attachments.count < attachmentLimit }
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
        guard !isBusy, !isLoadingAttachments, !trimmedDraft.isEmpty, !isComparing || attachments.count == 2 else { return }
        let request = TurnRequest(question: trimmedDraft, attachments: attachments, mode: isComparing ? .compare : .ask)
        start(request, reusing: nil)
    }

    public func retry() {
        guard !isBusy, let turn = unfinishedTurn else { return }
        let request = requests[turn.question.id] ?? TurnRequest(question: turn.question.text)
        start(request, reusing: turn.question.id)
    }

    private func start(_ request: TurnRequest, reusing existingQuestionID: UUID?) {
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
            await self?.runTurn(request, reusing: existingQuestionID, epoch: epoch)
        }
    }

    private func runTurn(_ request: TurnRequest, reusing existingQuestionID: UUID?, epoch: UUID) async {
        let preparation = await engine.prepareTurn(request, history: turns)
        guard epoch == self.epoch else { return }
        if Task.isCancelled {
            phase = .idle
            return
        }
        if case .refused(let refusal) = preparation {
            // Nothing was sent. The question and its files stay in the composer.
            failure = refusal
            phase = .idle
            return
        }

        if existingQuestionID != nil {
            // Retrying: drop the stopped/failed answer, keep the question.
            if let last = messages.last, last.role == .assistant { messages.removeLast() }
        } else {
            let question = ChatMessage(role: .user, text: request.question, attachments: request.attachments.map(AttachmentSummary.init))
            messages.append(question)
            requests[question.id] = request
            if trimmedDraft == request.question { draft = "" }
            attachments = []
            isComparing = false
        }
        let answer = ChatMessage(role: .assistant, text: "", status: .streaming)
        messages.append(answer)
        phase = .generating

        var latest = ""
        do {
            for try await turnUpdate in engine.streamTurn(request) {
                guard epoch == self.epoch else { return }
                latest = turnUpdate.text
                activity = turnUpdate.activity
                update(answer.id) { $0.text = turnUpdate.text }
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
            let text = applyGrounding(to: answer.id, raw: latest, status: .complete)
            turns.append(ConversationTurn(prompt: request.question, response: text))
            activity = nil
            phase = .idle
        }
    }

    private struct EmptyResponse: Error {}

    /// Checks the answer's citations against the excerpts the model really received, removes unknown ones, and attaches
    /// the real sources to the message. Returns the text to keep as the answer.
    @discardableResult
    private func applyGrounding(to id: UUID, raw: String, status: ChatMessage.Status) -> String {
        let grounded = engine.grounding(forAnswer: raw)
        let text = grounded?.text ?? raw
        update(id) {
            $0.text = text
            $0.status = status
            $0.sources = grounded?.sources ?? []
            $0.removedCitations = grounded?.removedCitations ?? []
            $0.consultedCount = grounded?.consultedCount ?? 0
            $0.comparedMaterial = grounded?.comparedMaterial ?? []
        }
        return text
    }

    private func finishStopped(_ id: UUID, partial: String) {
        applyGrounding(to: id, raw: partial, status: .stopped)
        engine.reset(history: turns)
        activity = nil
        phase = .idle
        focusRequest += 1
    }

    private func finishFailed(_ id: UUID, partial: String, error: any Error) {
        applyGrounding(to: id, raw: partial, status: .failed)
        failure = error is EmptyResponse ? .generic(code: "emptyResponse") : .from(error: error)
        engine.reset(history: turns)
        activity = nil
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
        var carriedRequest: TurnRequest?
        if keepingQuestion {
            if draft.isEmpty, let unfinished = unfinishedTurn {
                carried = unfinished.question.text
                carriedRequest = requests[unfinished.question.id]
            } else {
                carried = draft
            }
        }
        generation?.cancel()
        generation = nil
        epoch = UUID()
        messages = []
        turns = []
        requests = [:]
        failure = nil
        activity = nil
        phase = .idle
        draft = carried
        if let carriedRequest {
            attachments = carriedRequest.attachments
            isComparing = carriedRequest.mode == .compare
        } else if !keepingQuestion {
            attachments = []
            isComparing = false
            attachmentNotices = []
        }
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
        if let request = requests.removeValue(forKey: turn.question.id), attachments.isEmpty {
            attachments = request.attachments
            isComparing = request.mode == .compare
        }
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

    // MARK: Attachments

    public nonisolated static let comparisonPrompt = "Compare these two documents. Show the differences in a table, then list the gaps and the questions I should resolve."

    /// Reads files the person picked and adds them to the question being written.
    /// Files are read whole, once, with the same format and size limits as My files.
    public func attach(urls: [URL]) async {
        guard !isBusy else { return }
        isLoadingAttachments = true
        defer { isLoadingAttachments = false }
        for url in urls {
            if attachments.count >= attachmentLimit {
                attachmentNotices.append(isComparing
                    ? "A comparison takes exactly two documents. “\(url.lastPathComponent)” was not attached."
                    : "You can attach up to \(Self.maxAttachments) files to one question. “\(url.lastPathComponent)” was not attached.")
                continue
            }
            let path = SourceAccess.canonicalPath(url)
            if attachments.contains(where: { $0.path == path }) {
                attachmentNotices.append("“\(url.lastPathComponent)” is already attached.")
                continue
            }
            let outcome = await Task.detached(priority: .userInitiated) { AttachmentLoader.load(url: url) }.value
            switch outcome {
            case .attached(let attachment):
                attachments.append(attachment)
            case .rejected(let fileName, let reason):
                attachmentNotices.append("“\(fileName)” was not attached. \(reason.explanation)")
            }
        }
    }

    public func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Drops all attached files and leaves comparison mode.
    public func clearAttachments() {
        attachments = []
        isComparing = false
    }

    public func dismissAttachmentNotices() {
        attachmentNotices = []
    }

    /// Switches the composer to comparing exactly two attached documents.
    public func beginComparison() {
        isComparing = true
        if attachments.count > 2 {
            attachmentNotices.append("A comparison takes exactly two documents, so only the first two attached files are used.")
            attachments = Array(attachments.prefix(2))
        }
        if trimmedDraft.isEmpty { draft = Self.comparisonPrompt }
        focusRequest += 1
    }

    public func endComparison() {
        isComparing = false
    }

    // MARK: Testing support

    /// Waits for the current generation task to finish.
    public func waitUntilIdle() async {
        await generation?.value
    }
}
