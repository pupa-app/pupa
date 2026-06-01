import Foundation
import Security

/// Per-backend secret storage. Today the only secret is the paired-device
/// token from [#163](https://github.com/*/issues/163)
/// Phase 3 — but Sign in with Apple's refresh token, future per-backend OAuth
/// state, etc. all fit the same `(backendID, kind) -> secret` shape.
public protocol BackendCredentialStore: Sendable {
    func setToken(_ token: String, for backendID: UUID) throws
    func token(for backendID: UUID) -> String?
    func removeToken(for backendID: UUID) throws
}

/// Real implementation. Stores tokens as `kSecClassGenericPassword` items
/// keyed by `(service, account)` where the account is the backend's UUID.
/// `kSecAttrAccessibleAfterFirstUnlock` so a chat session can keep running
/// after the device sleeps without re-prompting, but the secret stays
/// encrypted at rest on a locked device.
public struct KeychainCredentialStore: BackendCredentialStore {
    public let service: String

    public init(service: String = "com.pupa.backend-token") {
        self.service = service
    }

    public func setToken(_ token: String, for backendID: UUID) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encoding
        }
        let account = backendID.uuidString
        // `SecItemUpdate` won't insert; try update first, fall back to add.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.osStatus(updateStatus)
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.osStatus(addStatus)
        }
    }

    public func token(for backendID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backendID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    public func removeToken(for backendID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backendID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.osStatus(status)
        }
    }

    public enum KeychainError: Error, CustomStringConvertible {
        case encoding
        case osStatus(OSStatus)

        public var description: String {
            switch self {
            case .encoding: return "could not UTF-8 encode token"
            case .osStatus(let status): return "Keychain returned OSStatus \(status)"
            }
        }
    }
}

/// In-memory fallback used by unit tests so they don't have to set up an
/// access group or otherwise tickle the real Keychain. Backed by an actor
/// in spirit — guarded by a `NSLock` since the protocol is `Sendable` and
/// callers can hit it from multiple actors.
public final class InMemoryCredentialStore: BackendCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]

    public init() {}

    public func setToken(_ token: String, for backendID: UUID) throws {
        lock.withLock { tokens[backendID] = token }
    }

    public func token(for backendID: UUID) -> String? {
        lock.withLock { tokens[backendID] }
    }

    public func removeToken(for backendID: UUID) throws {
        lock.withLock { tokens.removeValue(forKey: backendID) }
    }
}
