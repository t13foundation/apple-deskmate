import Foundation
import Security

/// Storage for connection tokens. The only place a token is ever persisted is an implementation of this protocol.
public protocol ConnectionSecretStore: Sendable {
    func token(for connectionID: UUID) throws -> String?
    func setToken(_ token: String, for connectionID: UUID) throws
    func deleteToken(for connectionID: UUID) throws
}

public struct SecretStoreError: Error, Sendable, Equatable {
    public let status: Int32

    /// Describes the failure without any secret value.
    public var message: String {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            "The Keychain did not allow access to the token (code \(status)). Unlock your Mac or allow DeskMate in Keychain Access."
        case errSecMissingEntitlement:
            "This build of DeskMate is not allowed to use the Keychain (code \(status))."
        default:
            "The Keychain could not complete the request (code \(status))."
        }
    }
}

/// Stores Bearer tokens as generic passwords in the macOS Keychain, one item per connection id.
/// Items are device-only and available only while the Mac is unlocked.
public struct KeychainSecretStore: ConnectionSecretStore {
    public let service: String

    public init(service: String = "com.t13foundation.DeskMate.mcp-connection") {
        self.service = service
    }

    private func baseQuery(_ id: UUID, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    public func token(for connectionID: UUID) throws -> String? {
        for dataProtection in [true, false] {
            var query = baseQuery(connectionID, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
                return text
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw SecretStoreError(status: status)
            }
        }
        return nil
    }

    public func setToken(_ token: String, for connectionID: UUID) throws {
        let data = Data(token.utf8)
        var lastStatus: Int32 = errSecSuccess
        for dataProtection in [true, false] {
            let query = baseQuery(connectionID, dataProtection: dataProtection)
            let update: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                add[kSecAttrLabel as String] = "DeskMate MCP connection token"
                status = SecItemAdd(add as CFDictionary, nil)
            }
            if status == errSecSuccess {
                // Never leave a copy behind in the other keychain.
                if dataProtection { _ = SecItemDelete(baseQuery(connectionID, dataProtection: false) as CFDictionary) }
                return
            }
            lastStatus = status
            guard status == errSecMissingEntitlement else { break }
        }
        throw SecretStoreError(status: lastStatus)
    }

    public func deleteToken(for connectionID: UUID) throws {
        var failure: Int32?
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(connectionID, dataProtection: dataProtection) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                failure = status
            }
        }
        if let failure { throw SecretStoreError(status: failure) }
    }
}

/// Keeps tokens in memory only. For tests and previews; it never touches disk.
public final class InMemorySecretStore: ConnectionSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]

    public init() {}

    public var storedIDs: Set<UUID> {
        lock.withLock { Set(tokens.keys) }
    }

    public func token(for connectionID: UUID) throws -> String? {
        lock.withLock { tokens[connectionID] }
    }

    public func setToken(_ token: String, for connectionID: UUID) throws {
        lock.withLock { tokens[connectionID] = token }
    }

    public func deleteToken(for connectionID: UUID) throws {
        _ = lock.withLock { tokens.removeValue(forKey: connectionID) }
    }
}
