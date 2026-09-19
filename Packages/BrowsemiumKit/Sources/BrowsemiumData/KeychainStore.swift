import BrowsemiumCore
import Foundation
import Security

public protocol KeychainAPI: Sendable {
    func store(service: String, account: String, data: Data) -> OSStatus
    func read(service: String, account: String) -> (status: OSStatus, data: Data?)
    func delete(service: String, account: String) -> OSStatus
    /// Checks for an item without decrypting it. Asking only for attributes
    /// does not require the secret, so macOS shows no permission prompt.
    func exists(service: String, account: String) -> Bool
}

public struct SystemKeychain: KeychainAPI {
    public init() {}

    public func store(service: String, account: String, data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    public func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func delete(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }

    public func exists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
}

public struct KeychainStore: Sendable {
    public enum KeychainError: Error, LocalizedError, Equatable {
        case emptySecret
        case storeFailed(Int32)
        case readFailed(Int32)
        case deleteFailed(Int32)
        case invalidStoredData

        public var errorDescription: String? {
            switch self {
            case .emptySecret:
                "Enter a credential before saving."
            case .storeFailed(let status):
                "The credential could not be saved to the keychain (status \(status))."
            case .readFailed(let status):
                "The credential could not be read from the keychain (status \(status))."
            case .deleteFailed(let status):
                "The credential could not be removed from the keychain (status \(status))."
            case .invalidStoredData:
                "The stored credential is not readable."
            }
        }
    }

    public static let defaultService = "com.browsemium.browser"

    private let api: any KeychainAPI
    private let service: String

    public init(service: String = KeychainStore.defaultService, api: any KeychainAPI = SystemKeychain()) {
        self.service = service
        self.api = api
    }

    public func setSecret(_ secret: String, account: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainError.emptySecret
        }
        let status = api.store(service: service, account: account, data: Data(trimmed.utf8))
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    public func secret(account: String) throws -> String? {
        let result = api.read(service: service, account: account)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data else { return nil }
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidStoredData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.readFailed(result.status)
        }
    }

    /// Uses an attributes-only lookup so simply opening Settings never asks
    /// macOS for permission to read a stored secret.
    public func hasSecret(account: String) throws -> Bool {
        api.exists(service: service, account: account)
    }

    public func deleteSecret(account: String) throws {
        let status = api.delete(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}
