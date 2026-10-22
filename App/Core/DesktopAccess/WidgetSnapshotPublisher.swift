import DeskMateShared
import Foundation
import Observation

/// Keeps the widget's snapshot in step with the app. It watches only generic state: whether the model is ready, how
/// the latest task ended, and which saved conversation is newest (by its opaque ID). It never reads a title, a prompt,
/// an answer or a file name, and it does nothing while an answer is being written, so the widget never shows live
/// progress. Reloading the widget is the caller's closure, so this type has no WidgetKit dependency and is testable.
@MainActor
public final class WidgetSnapshotPublisher {
    private let controller: ConversationController
    private let history: ConversationHistory
    private let store: WidgetSnapshotStore
    private let now: () -> Date
    private let reload: () -> Void

    private var latestTask: WidgetSnapshot.LatestTask
    private var wasBusy = false
    private var published: WidgetSnapshot?
    private var started = false

    public init(
        controller: ConversationController,
        history: ConversationHistory,
        store: WidgetSnapshotStore,
        now: @escaping () -> Date = Date.init,
        reload: @escaping () -> Void
    ) {
        self.controller = controller
        self.history = history
        self.store = store
        self.now = now
        self.reload = reload
        // The state the widget already shows survives a restart; it is replaced at the next finished task.
        let previous = store.read()
        self.latestTask = previous?.latestTask ?? .none
        self.published = previous
    }

    /// Starts watching. Safe to call more than once.
    public func start() {
        guard !started else { return }
        started = true
        history.onRemoval { [weak self] removal in self?.handle(removal) }
        publishIfChanged()
        arm()
    }

    // MARK: Observation

    private func arm() {
        withObservationTracking {
            observeInputs()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.publishIfChanged()
                self.arm()
            }
        }
    }

    /// Reads exactly what the snapshot depends on. While an answer is being written only the phase is read, so a
    /// streaming reply does not wake this type for every update.
    private func observeInputs() {
        _ = history.isLoaded
        _ = history.summaries
        _ = controller.readiness
        _ = controller.phase
        if !controller.isBusy {
            _ = controller.messages.last?.status
            _ = controller.failure
        }
    }

    // MARK: Publishing

    /// Conversation removal: the pointer must not outlive the conversation. Clearing everything deletes the snapshot
    /// file at once; the change that follows writes a fresh generic one with no pointer and no task state.
    func handle(_ removal: HistoryRemoval) {
        switch removal {
        case .conversation:
            publishIfChanged()
        case .everything:
            latestTask = .none
            published = nil
            if store.remove() { reload() }
        }
    }

    /// Writes the snapshot when something the widget shows has changed. Tests call this directly.
    func publishIfChanged() {
        // Before the list is read, an empty history would wrongly erase a valid pointer.
        guard history.isLoaded else { return }
        if controller.isBusy {
            wasBusy = true
            return
        }
        if wasBusy {
            wasBusy = false
            if let finished = finishedTask() { latestTask = finished }
        }
        let newest = history.summaries.first?.id
        let candidate = WidgetSnapshot(
            readiness: controller.readiness.isReady ? .ready : .needsAttention,
            updatedAt: now(),
            hasConversations: newest != nil,
            lastConversationID: newest,
            latestTask: latestTask
        )
        guard !Self.sameState(candidate, published) else { return }
        if store.write(candidate) {
            published = candidate
            reload()
        }
    }

    private func finishedTask() -> WidgetSnapshot.LatestTask? {
        if let last = controller.messages.last, last.role == .assistant {
            switch last.status {
            case .complete: return .answered
            case .stopped: return .stopped
            case .failed: return .failed
            case .streaming: return nil
            }
        }
        // A refused question never reached the model; it is still a task that did not produce an answer.
        return controller.failure == nil ? nil : .failed
    }

    /// Everything except the time: the widget is reloaded only for a meaningful change.
    private static func sameState(_ a: WidgetSnapshot, _ b: WidgetSnapshot?) -> Bool {
        guard let b else { return false }
        return a.readiness == b.readiness
            && a.hasConversations == b.hasConversations
            && a.lastConversationID == b.lastConversationID
            && a.latestTask == b.latestTask
    }
}
