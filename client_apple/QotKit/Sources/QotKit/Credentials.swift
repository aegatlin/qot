import Foundation
import Security
import Synchronization

/// A signed-in session: which server and account, and its tokens.
public struct Credentials: Codable, Equatable, Sendable {
    public let server: URL
    public let userId: String
    public let email: String
    public var accessToken: String
    public let refreshToken: String

    public init(server: URL, userId: String, email: String, accessToken: String, refreshToken: String) {
        self.server = server
        self.userId = userId
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// Where credentials live: the Keychain on a device, memory in tests.
public protocol CredentialStore: Sendable {
    func load() throws -> Credentials?
    func save(_ credentials: Credentials) throws
    func delete() throws
}

public final class MemoryCredentialStore: CredentialStore {
    private let value: Mutex<Credentials?>

    public init(_ credentials: Credentials? = nil) {
        value = Mutex(credentials)
    }

    public func load() throws -> Credentials? { value.withLock { $0 } }
    public func save(_ credentials: Credentials) throws { value.withLock { $0 = credentials } }
    public func delete() throws { value.withLock { $0 = nil } }
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

/// Tokens in the Keychain, never in files. With an access group (the App
/// Group), the app's intents and widgets can read them too. Readable after
/// the first unlock, so a background sync can run while the phone is locked.
public struct KeychainCredentialStore: CredentialStore {
    let service: String
    let accessGroup: String?

    public init(service: String = "llc.abstractsyntax.qot", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "credentials",
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load() throws -> Credentials? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    public func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
