import Foundation

/// Reads and writes the widget snapshot as one small JSON file in the App Group container.
/// Every failure degrades quietly: no container means "no snapshot", never a crash and never a guess.
public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "widget-snapshot.json"

    private let directory: URL?

    /// A store rooted at a directory. Tests use a temporary one; the app and widget use `appGroup()`.
    public init(directory: URL?) {
        self.directory = directory
    }

    /// The store in the App Group container named by the bundle's `DeskMateAppGroupIdentifier`, or one with no
    /// location when the build has no group (an ad-hoc build) or the system does not grant the container.
    public static func appGroup(bundle: Bundle = .main) -> WidgetSnapshotStore {
        guard let identifier = bundle.object(forInfoDictionaryKey: DeskMateShared.appGroupInfoKey) as? String,
              !identifier.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else { return WidgetSnapshotStore(directory: nil) }
        return WidgetSnapshotStore(directory: container)
    }

    public var isAvailable: Bool { directory != nil }

    private var fileURL: URL? { directory?.appending(path: Self.fileName, directoryHint: .notDirectory) }

    /// The stored snapshot, or nil when there is none, it cannot be read, or it was written by a newer version.
    public func read() -> WidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    /// Returns whether the snapshot was written. False when there is no container or the write failed.
    @discardableResult
    public func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let fileURL, let data = try? Self.encode(snapshot) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Removes the snapshot, for example when history is cleared and nothing should remain.
    @discardableResult
    public func remove() -> Bool {
        guard let fileURL else { return false }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return !FileManager.default.fileExists(atPath: fileURL.path)
        }
    }

    /// The exact bytes that are stored. Public so a test can inspect them.
    public static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(snapshot)
    }
}
