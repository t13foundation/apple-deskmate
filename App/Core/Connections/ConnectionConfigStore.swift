import Foundation

/// Persistence for the non-secret part of connections.
public protocol ConnectionConfigStore: Sendable {
    func load() throws -> ConnectionConfigLoad
    func save(_ connections: [MCPConnection]) throws
}

public struct ConnectionConfigLoad: Sendable, Equatable {
    public var connections: [MCPConnection]
    /// Set when the saved file could not be read and was set aside unchanged.
    public var notice: String?

    public init(connections: [MCPConnection], notice: String? = nil) {
        self.connections = connections
        self.notice = notice
    }
}

struct ConnectionConfigFile: Codable, Equatable {
    static let currentVersion = 1
    var version: Int
    var connections: [MCPConnection]
}

/// Reads and writes `Application Support/DeskMate/Connections/connections.json`.
/// The file holds names, addresses, enabled tool names and fingerprints. It never holds a token.
public struct FileConnectionConfigStore: ConnectionConfigStore {
    public let directory: URL

    public var fileURL: URL { directory.appending(path: "connections.json", directoryHint: .notDirectory) }

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "DeskMate", directoryHint: .isDirectory)
            .appending(path: "Connections", directoryHint: .isDirectory)
    }

    public static func standard() -> FileConnectionConfigStore {
        FileConnectionConfigStore(directory: defaultDirectory())
    }

    public func load() throws -> ConnectionConfigLoad {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return ConnectionConfigLoad(connections: []) }
        let data = try Data(contentsOf: fileURL)
        do {
            let file = try JSONDecoder().decode(ConnectionConfigFile.self, from: data)
            guard file.version <= ConnectionConfigFile.currentVersion else {
                return try setAside(reason: "They were saved by a newer version of DeskMate.")
            }
            return ConnectionConfigLoad(connections: file.connections.map(Self.bounded))
        } catch {
            return try setAside(reason: "The saved file could not be read.")
        }
    }

    public func save(_ connections: [MCPConnection]) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ConnectionConfigFile(version: ConnectionConfigFile.currentVersion, connections: connections))
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Keeps the unreadable file for the person instead of overwriting it.
    private func setAside(reason: String) throws -> ConnectionConfigLoad {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = directory.appending(path: "connections.unreadable-\(stamp).json", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: fileURL, to: aside)
        return ConnectionConfigLoad(
            connections: [],
            notice: "Your saved connections could not be loaded. \(reason) The file was kept as \(aside.lastPathComponent)."
        )
    }

    private static func bounded(_ connection: MCPConnection) -> MCPConnection {
        var result = connection
        result.name = MCPConnection.cleanedName(connection.name)
        result.enabledTools = Array(connection.enabledTools.prefix(ConnectionLimits().maxEnabledTools))
        return result
    }
}

/// Keeps configuration in memory. For tests and previews.
public final class InMemoryConnectionConfigStore: ConnectionConfigStore, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [MCPConnection]

    public init(_ connections: [MCPConnection] = []) {
        saved = connections
    }

    public var current: [MCPConnection] { lock.withLock { saved } }

    public func load() throws -> ConnectionConfigLoad {
        ConnectionConfigLoad(connections: lock.withLock { saved })
    }

    public func save(_ connections: [MCPConnection]) throws {
        lock.withLock { saved = connections }
    }
}
