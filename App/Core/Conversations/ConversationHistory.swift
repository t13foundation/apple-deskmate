import Foundation
import Observation

/// What was removed from history. Delivered to observers (such as the desktop widget package) so anything derived
/// from a conversation, like a pointer for a widget, goes away with it.
public enum HistoryRemoval: Equatable, Sendable {
    case conversation(UUID)
    /// Clear history: every conversation was removed.
    case everything
}

/// Why the last attempt to write a conversation failed, as a category only. It never carries a path, a file name or any
/// conversation text, so it is safe to show and to announce.
public struct SaveProblem: Equatable, Sendable {
    /// Ordered by how specific the advice is; the lowest value is shown when several conversations are affected.
    public enum Category: Int, Comparable, Sendable {
        case permission = 0
        case diskFull = 1
        case other = 2

        public static func < (lhs: Category, rhs: Category) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let category: Category

    public init(category: Category) {
        self.category = category
    }

    public var title: String { "DeskMate couldn’t save this conversation on your Mac" }

    /// Always says that nothing the person did is lost while the app is open; adds a category-specific line when known.
    public var message: String {
        var text = "Your changes are kept while the app is open."
        switch category {
        case .permission: text += " DeskMate isn’t allowed to write to its folder on this Mac."
        case .diskFull: text += " There isn’t enough free space on this Mac."
        case .other: break
        }
        return text
    }

    /// Maps a write error to a category. Looks at the error and the errors underneath it.
    public static func category(of error: Error) -> Category {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileWriteVolumeReadOnly.rawValue: return .permission
            case CocoaError.fileWriteOutOfSpace.rawValue: return .diskFull
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(truncatingIfNeeded: nsError.code) {
            case EACCES, EPERM, EROFS: return .permission
            case ENOSPC, EDQUOT: return .diskFull
            default: break
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return category(of: underlying)
        }
        return .other
    }
}

/// Why one conversation could not be deleted. It never carries a path or conversation text.
public struct DeletionProblem: Equatable, Sendable {
    /// The conversation that is still on this Mac. Used by Try again.
    public let conversationID: UUID

    public init(conversationID: UUID) {
        self.conversationID = conversationID
    }

    public var message: String { "DeskMate couldn’t delete this conversation from your Mac." }
}

/// The saved conversations: the Recent list, saving, deleting and clearing.
///
/// Every disk operation runs in order on one background task, so a delete can never be overtaken by an earlier save,
/// and a conversation that was deleted is not written again by a late save. Reads wait for pending writes first.
///
/// A write that fails is never silent: the conversation stays in memory exactly as it is, `saveProblem` is set, and the
/// latest copy is kept (`unsavedIDs` names them) until a write succeeds. `retrySave()` and every later `save` try
/// again, always with the newest copy. `open(_:)` returns that newest copy too, so the edit survives a switch to another
/// conversation. The previous complete file is untouched by a failed write (files are replaced atomically).
///
/// Deleting reports the truth. `delete(_:)` returns true only once the file is gone; only then does the row leave the
/// list and `onRemoval` fire. A failure keeps the row, sets `deletionProblem` and leaves the conversation as it was.
///
/// Hook for the widget and panel package: call `onRemoval(_:)` once. The handler runs on the main actor, when a
/// conversation has really been deleted (after its file is gone) or history is cleared, with what was removed. It is the
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
    /// Set while at least one conversation could not be written. Clears when every pending write has succeeded.
    public private(set) var saveProblem: SaveProblem?
    /// The conversations whose latest state is in memory only because the last write failed.
    public private(set) var unsavedIDs: Set<UUID> = []
    /// Set when the last attempt to delete a conversation failed and its row is still listed. Cleared by a successful
    /// delete of that conversation, by dismissing, or by Clear history.
    public private(set) var deletionProblem: DeletionProblem?

    @ObservationIgnored private var unsaved: [UUID: ConversationRecord] = [:]
    /// The newest record handed to a write, per conversation, until a write of it succeeds. Retries and reopening use it.
    @ObservationIgnored private var newest: [UUID: ConversationRecord] = [:]
    @ObservationIgnored private var deleting = Set<UUID>()
    @ObservationIgnored private var failureCategories: [UUID: SaveProblem.Category] = [:]
    @ObservationIgnored private var latestWrite: [UUID: Int] = [:]
    @ObservationIgnored private var writeCounter = 0
    @ObservationIgnored private let outcomes = WriteOutcomes()
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
    /// When the newest state of the conversation exists only in memory because its last write failed, that newest
    /// state is returned (after every pending write has settled), not the older file.
    public func open(_ id: UUID) async -> Opened {
        // Queued behind every pending write, so their outcomes are known before anything is returned.
        let result = await queue.run { $0.load(id) }
        applyWriteOutcomes()
        if !deleted.contains(id), unsaved[id] != nil, let kept = newest[id] {
            return .record(kept)
        }
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
        write(record)
        // Every save also retries conversations that could not be written earlier, from their newest copy.
        retryUnsaved(except: record.id)
    }

    /// Tries again to write every conversation that could not be saved. The notice clears when they all succeed.
    public func retrySave() {
        retryUnsaved(except: nil)
    }

    private func retryUnsaved(except skipped: UUID?) {
        for id in Array(unsaved.keys) where id != skipped && !deleted.contains(id) {
            if let latest = newest[id] ?? unsaved[id] { write(latest) }
        }
    }

    /// True when the latest state of this conversation exists only in memory because its last write failed.
    public func isUnsaved(_ id: UUID) -> Bool { unsavedIDs.contains(id) }

    private func write(_ record: ConversationRecord) {
        writeCounter += 1
        let number = writeCounter
        latestWrite[record.id] = number
        newest[record.id] = record
        let outcomes = self.outcomes
        queue.enqueue { [weak self] storage in
            var category: SaveProblem.Category?
            do { try storage.save(record) } catch { category = SaveProblem.category(of: error) }
            outcomes.append(WriteOutcomes.Outcome(record: record, number: number, failure: category))
            Task { @MainActor in self?.applyWriteOutcomes() }
        }
    }

    /// Applies finished writes on the main actor. Only the newest write of each conversation counts.
    private func applyWriteOutcomes() {
        for outcome in outcomes.take() {
            let id = outcome.record.id
            // A conversation whose deletion is still in flight may yet stay, so its outcomes still count.
            guard !deleted.contains(id) || deleting.contains(id), latestWrite[id] == outcome.number else { continue }
            if let category = outcome.failure {
                unsaved[id] = outcome.record
                failureCategories[id] = category
            } else {
                unsaved[id] = nil
                newest[id] = nil
                failureCategories[id] = nil
            }
        }
        refreshSaveProblem()
    }

    private func refreshSaveProblem() {
        let ids = Set(unsaved.keys)
        if unsavedIDs != ids { unsavedIDs = ids }
        let problem = failureCategories.values.min().map(SaveProblem.init(category:))
        if saveProblem != problem { saveProblem = problem }
    }

    private func forgetUnsaved(_ id: UUID) {
        unsaved[id] = nil
        newest[id] = nil
        failureCategories[id] = nil
        latestWrite[id] = nil
    }

    // MARK: Removing

    /// Deletes one conversation and returns whether it is really gone.
    ///
    /// Late saves of this conversation are dropped from the moment this is called. On success the row leaves the list,
    /// `onRemoval` fires once and any kept unsaved copy is forgotten. On failure the file is still on this Mac, so the row
    /// stays, the conversation is saveable again and `deletionProblem` is set for the person to retry. A second call for
    /// a conversation already being deleted does nothing and returns false.
    @discardableResult
    public func delete(_ id: UUID) async -> Bool {
        guard !deleted.contains(id), !deleting.contains(id) else { return false }
        deleting.insert(id)
        deleted.insert(id)
        if deletionProblem?.conversationID == id { deletionProblem = nil }
        let gone = await queue.run { $0.delete(id) }
        deleting.remove(id)
        guard gone else {
            // Only when it is still listed; Clear history may have removed everything meanwhile.
            guard summaries.contains(where: { $0.id == id }) else { return false }
            deleted.remove(id)
            applyWriteOutcomes()
            deletionProblem = DeletionProblem(conversationID: id)
            return false
        }
        forgetUnsaved(id)
        refreshSaveProblem()
        summaries.removeAll { $0.id == id }
        if deletionProblem?.conversationID == id { deletionProblem = nil }
        removalHandlers.forEach { $0(.conversation(id)) }
        return true
    }

    /// Tries again to delete the conversation named by `deletionProblem`. Returns true when it is gone.
    @discardableResult
    public func retryDeletion() async -> Bool {
        guard let problem = deletionProblem else { return false }
        return await delete(problem.conversationID)
    }

    public func dismissDeletionProblem() {
        deletionProblem = nil
    }

    /// Clear history: removes every conversation record, the index and any set-aside copies. Never touches the
    /// person's own files or the library.
    public func clearAll() {
        deleted.formUnion(summaries.map(\.id))
        deleted.formUnion(unsaved.keys)
        unsaved = [:]
        newest = [:]
        deleting = []
        deletionProblem = nil
        failureCategories = [:]
        latestWrite = [:]
        refreshSaveProblem()
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
        applyWriteOutcomes()
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

/// Results of background writes, handed from the disk queue to the main actor.
final class WriteOutcomes: @unchecked Sendable {
    struct Outcome: Sendable {
        let record: ConversationRecord
        let number: Int
        /// Nil when the write succeeded.
        let failure: SaveProblem.Category?
    }

    private let lock = NSLock()
    private var items: [Outcome] = []

    func append(_ outcome: Outcome) {
        lock.lock()
        items.append(outcome)
        lock.unlock()
    }

    func take() -> [Outcome] {
        lock.lock()
        defer { lock.unlock() }
        let taken = items
        items = []
        return taken
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
