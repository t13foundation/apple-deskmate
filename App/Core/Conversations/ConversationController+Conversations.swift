import Foundation

/// Saving, reopening and deleting conversations, and making results from them.
extension ConversationController {
    // MARK: Saving

    /// Saves the conversation as it is on screen. A message that is still streaming is saved as stopped, with the text
    /// shown so far. A conversation with no messages left is removed instead of leaving an empty record.
    func persist() {
        guard let history else { return }
        guard !messages.isEmpty else {
            if isSaved {
                history.delete(conversationID)
                conversationID = UUID()
                createdAt = Date()
                isSaved = false
                results = []
            }
            return
        }
        isSaved = true
        history.save(ConversationRecord(
            id: conversationID,
            title: conversationTitle,
            createdAt: createdAt,
            updatedAt: Date(),
            messages: messages.map(StoredMessage.init),
            results: results
        ))
    }

    /// Before the screen moves to another conversation: whatever is still streaming is settled as stopped and saved.
    func settleForDeparture() {
        generation?.cancel()
        for message in messages where message.status == .streaming {
            update(message.id) { $0.status = .stopped }
        }
        persist()
    }

    // MARK: Reopening

    /// Shows a saved conversation and gives the model back the most recent finished turns that fit its context.
    /// A follow-up waits for that to finish. If the file cannot be read, it is moved aside, a notice appears in the
    /// history and the screen stays as it was.
    public func open(_ id: UUID) async {
        guard let history else { return }
        if id == conversationID, hasConversation { return }
        guard case .record(let record) = await history.open(id) else { return }

        settleForDeparture()
        let carriedDraft = draft
        let carriedAttachments = attachments
        let carriedComparing = isComparing
        resetConversation()
        draft = carriedDraft
        attachments = carriedAttachments
        isComparing = carriedComparing

        conversationID = record.id
        createdAt = record.createdAt
        isSaved = true
        messages = record.messages.map(\.chatMessage)
        results = record.results

        let finished = HistoryBudget.finishedTurns(from: messages)
        let epoch = self.epoch
        restoring = Task { [weak self] in
            guard let self else { return }
            let kept = await engine.restoreHistory(finished.map(\.turn))
            guard epoch == self.epoch else { return }
            turns = finished.suffix(kept).map(\.turn)
            omittedFromMemory = finished.count - kept
            // The question where memory starts. Nil with turns left out means none is remembered: the note goes last.
            memoryBoundaryID = omittedFromMemory > 0 && omittedFromMemory < finished.count ? finished[omittedFromMemory].questionID : nil
        }
        refreshReadiness()
        focusRequest += 1
    }

    /// Waits for a reopened conversation's model memory to be rebuilt. For tests.
    public func waitForRestore() async {
        await restoring?.value
    }

    // MARK: Deleting

    /// Deletes one saved conversation. If it is the one on screen, the screen becomes a new chat; the draft and files
    /// being prepared are kept. Nothing outside DeskMate's own conversation records is touched.
    public func deleteConversation(_ id: UUID) {
        guard let history else { return }
        if id == conversationID { leaveWithoutSaving() }
        history.delete(id)
    }

    /// Clear history: removes every saved conversation and anything derived from them. The screen becomes a new chat.
    /// Never touches the library or the person's files.
    public func clearHistory() {
        guard let history else { return }
        leaveWithoutSaving()
        history.clearAll()
    }

    private func leaveWithoutSaving() {
        let carriedDraft = draft
        let carriedAttachments = attachments
        let carriedComparing = isComparing
        resetConversation()
        draft = carriedDraft
        attachments = carriedAttachments
        isComparing = carriedComparing
    }

    // MARK: Results

    public var canCreateResult: Bool {
        !isBusy && readiness.isReady && messages.contains { $0.role == .assistant && $0.status == .complete }
    }

    /// Makes a brief or a task list from the visible conversation. The result opens in the result sheet and is saved
    /// with the conversation. The chat's own model context is not used or changed.
    public func createResult(_ kind: ResultKind) {
        guard !isBusy else { return }
        refreshReadiness()
        guard readiness.isReady else {
            readinessNudge += 1
            return
        }
        resultFailure = nil
        guard let material = ResultMaterialBuilder.build(from: messages) else {
            resultFailure = ResultBudget.nothingToUse(kind: kind)
            return
        }
        failure = nil
        phase = .creatingResult
        resultInProgress = kind
        activity = kind.progressTitle
        let epoch = self.epoch
        let title = conversationTitle
        generation = Task { [weak self] in
            await self?.runResult(kind, material: material, title: title, epoch: epoch)
        }
    }

    private func runResult(_ kind: ResultKind, material: ResultMaterial, title: String, epoch: UUID) async {
        var created: StoredResult?
        var problem: ChatFailure?
        do {
            let outcome = try await engine.makeResult(ResultRequest(kind: kind, material: material))
            switch outcome {
            case .refused(let refusal):
                problem = refusal
            case .generated(let payload, let hitLimit):
                let composed = ResultComposer.compose(payload, material: material, conversationTitle: title, hitLimit: hitLimit)
                created = StoredResult(kind: kind, markdown: composed.markdown)
            }
        } catch {
            if !(Task.isCancelled || error is CancellationError) {
                problem = ResultBudget.failure(kind: kind, error: error)
            }
        }
        guard epoch == self.epoch else { return }
        if !Task.isCancelled, let created {
            results.append(created)
            presentedResultID = created.id
            persist()
        } else if !Task.isCancelled {
            resultFailure = problem
        }
        resultInProgress = nil
        activity = nil
        phase = .idle
    }

    public func result(_ id: UUID) -> StoredResult? {
        results.first { $0.id == id }
    }

    /// Stores the person's edit of a result with the conversation.
    public func updateResult(_ id: UUID, markdown: String) {
        guard let index = results.firstIndex(where: { $0.id == id }), results[index].markdown != markdown else { return }
        results[index].markdown = markdown
        results[index].updatedAt = Date()
        persist()
    }

    public func deleteResult(_ id: UUID) {
        if presentedResultID == id { presentedResultID = nil }
        results.removeAll { $0.id == id }
        persist()
    }

    public func dismissResultFailure() {
        resultFailure = nil
    }
}
