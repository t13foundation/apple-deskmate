import Foundation
import Observation

/// What was removed from history. Delivered to observers (such as the desktop widget package) so anything derived
/// from a conversation, like a pointer for a widget, goes away with it.
public enum HistoryRemoval: Equatable, Sendable {
    case conversation(UUID)
    /// Clear history: every conversation was removed.
    case everything
}

/// The saved conversations: the Recent list, saving, deleting and clearing.
///
/// Every disk operation runs in order on one background task, so a delete can never be overtaken by an earlier save,
/// and a conversation that was deleted is not written again by a late save. Reads wait for pending writes first.
///
/// Hook for the widget and panel package: call `onRemoval(_:)` once. The handler runs on the main actor, immediately
/// when a conversation is deleted or history is cleared, before the files are gone, with what was removed. It is the
/// only place a widget pointer to a conversation needs to be cleared. Nothing here ever touches the person's own files.
@MainActor
@Observable
public final class ConversationHistory {
    /// Newest first. Always current in memory; the files follow.
    public private(set) var summaries: [ConversationSummary] = []
    /// Plain-language notices about files that were set aside. Dismissed by the person.
    public private(set) var notices: [String] = []
    public private(set) var isLoaded = false
    /// Files that Clear history could not remove, from the last time it ran.
    public private(set) var lastClearFailures = 0

    @ObservationIgnored private let storage: ConversationStorage
    @ObservationIgnored private var removalHandlers: [@MainActor (HistoryRemoval) -> Void] = []
    @ObservationIgnored private var deleted = Set<UUID>()
    @ObservationIgnored private var cleared = false
    @ObservationIgnored private let queue: DiskQueue

    public init(storage: ConversationStorage) {
        self.storage = storage
        self.queue = DiskQueue(storage: storage)
    }

    public static func standard() -> ConversationHistory {
        ConversationHistory(storage: .standard())
    }

    // MARK: Hook for later packages

    /// Registers a handler for deletions. See the type documentation.
    public func onRemoval(_ handler: @escaping @MainActor (HistoryRemoval) -> Void) {
        removalHandlers.append(handler)
    }

    // MARK: Loading

    /// Reads the Recent list. Files that cannot be read are moved aside and reported in `notices`.
    public func load() async {
        var listing = await queue.run { $0.list() }
        guard !isLoaded else { return }
        isLoaded = true
        // Clear history ran while the list was being read: what was read is gone.
        if cleared { listing = ConversationStorage.Listing(summaries: [], setAside: []) }
        // Whatever was saved or deleted while the list was being read wins over the list.
        var merged = Dictionary(listing.summaries.filter { !deleted.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for summary in summaries { merged[summary.id] = summary }
        summaries = Self.sorted(Array(merged.values))
        notices += listing.setAside.map(Self.notice(for:))
    }

    public enum Opened: Equatable, Sendable {
        case record(ConversationRecord)
        /// The file is gone or could not be read; the Recent list and notices are already updated.
        case unavailable
    }

    /// Reads one conversation. A file that cannot be read is moved aside, its row disappears and a notice explains.
    public func open(_ id: UUID) async -> Opened {
        let result = await queue.run { $0.load(id) }
        switch result {
        case .loaded(let record):
            return .record(record)
        case .missing:
            summaries.removeAll { $0.id == id }
            return .unavailable
        case .setAside(let aside):
            summaries.removeAll { $0.id == id }
            notices.append(Self.notice(for: aside))
            return .unavailable
        }
    }

    // MARK: Saving

    /// Updates the Recent list at once and writes the file in order, atomically. A conversation that was deleted is
    /// not written again.
    public func save(_ record: ConversationRecord) {
        guard !deleted.contains(record.id) else { return }
        let summary = ConversationSummary(record)
        if let index = summaries.firstIndex(where: { $0.id == record.id }) {
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
        summaries = Self.sorted(summaries)
        queue.enqueue { storage in
            do { try storage.save(record) } catch {
                // Nothing to report from here: the previous complete file is still in place. The next save tries again.
            }
        }
    }

    // MARK: Removing

    /// Deletes one conversation. Its summary leaves the list at once.
    public func delete(_ id: UUID) {
        deleted.insert(id)
        summaries.removeAll { $0.id == id }
        removalHandlers.forEach { $0(.conversation(id)) }
        queue.enqueue { $0.delete(id) }
    }

    /// Clear history: removes every conversation record, the index and any set-aside copies. Never touches the
    /// person's own files or the library.
    public func clearAll() {
        deleted.formUnion(summaries.map(\.id))
        summaries = []
        notices = []
        cleared = true
        removalHandlers.forEach { $0(.everything) }
        // Queued now, not from a task, so a conversation saved right after Clear history is never swept up by it.
        queue.enqueue { [weak self] storage in
            let failures = storage.deleteAll()
            Task { @MainActor in self?.lastClearFailures = failures }
        }
    }

    /// True when `id` was deleted in this run, so a late save must be dropped.
    public func wasDeleted(_ id: UUID) -> Bool { deleted.contains(id) }

    public func dismissNotices() {
        notices = []
    }

    /// Waits until every queued write has finished. For tests and for quitting.
    public func waitForWrites() async {
        await queue.run { _ in }
    }

    // MARK: Helpers

    private static func sorted(_ summaries: [ConversationSummary]) -> [ConversationSummary] {
        summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func notice(for aside: ConversationStorage.SetAside) -> String {
        switch aside.reason {
        case .unreadable:
            return "One saved conversation could not be read, so DeskMate moved it aside in its Conversations folder. Your other conversations are not affected."
        case .newerVersion:
            return "One saved conversation was written by a newer version of DeskMate, so this version left it aside unchanged. Your other conversations are not affected."
        }
    }
}

/// Runs disk work one item at a time, in the order it was queued, off the main actor.
final class DiskQueue: Sendable {
    private let continuation: AsyncStream<@Sendable (ConversationStorage) -> Void>.Continuation

    init(storage: ConversationStorage) {
        let (stream, continuation) = AsyncStream<@Sendable (ConversationStorage) -> Void>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        Task.detached(priority: .utility) {
            for await work in stream { work(storage) }
        }
    }

    deinit {
        continuation.finish()
    }

    func enqueue(_ body: @escaping @Sendable (ConversationStorage) -> Void) {
        continuation.yield(body)
    }

    /// Queues `body` behind everything already queued and returns its result.
    func run<T: Sendable>(_ body: @escaping @Sendable (ConversationStorage) -> T) async -> T {
        await withCheckedContinuation { resume in
            enqueue { storage in resume.resume(returning: body(storage)) }
        }
    }
}
