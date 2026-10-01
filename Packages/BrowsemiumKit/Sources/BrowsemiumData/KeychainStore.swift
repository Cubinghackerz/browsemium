import BrowsemiumCore
import Foundation
import Security

public protocol KeychainAPI: Sendable {
    func store(service: String, account: String, data: Data) -> OSStatus
    func read(service: String, account: String) -> (status: OSStatus, data: Data?)
    /// Never opens authentication UI. A nil account means service-only lookup.
    func readWithoutInteraction(service: String, account: String?) -> (status: OSStatus, data: Data?)
    func delete(service: String, account: String) -> OSStatus
    /// Checks for an item without decrypting it. Asking only for attributes
    /// does not require the secret, so macOS shows no permission prompt.
    func exists(service: String, account: String) -> Bool
}

public extension KeychainAPI {
    /// Old/custom backends must fail closed, not fall back to an interactive read.
    func readWithoutInteraction(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        (errSecInteractionNotAllowed, nil)
    }
}

public struct SystemKeychain: KeychainAPI {
    public init() {}

    public func store(service: String, account: String, data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Updating in place preserves an existing password if the write is
        // denied. Delete-then-add could erase it before the replacement lands.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        if updateStatus != errSecItemNotFound { return updateStatus }

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

    public func readWithoutInteraction(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        let query = NoninteractiveKeychainQuery.make(service: service, account: account)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
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
        try storeSecret(trimmed, account: account)
    }

    /// Password bytes are significant: whitespace must not be normalized away.
    public func setPassword(_ password: String, account: String) throws {
        try storeSecret(password, account: account)
    }

    private func storeSecret(_ value: String, account: String) throws {
        guard !value.isEmpty else {
            throw KeychainError.emptySecret
        }
        let status = api.store(service: service, account: account, data: Data(value.utf8))
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

    /// Reads a secret stored by another application, e.g. Chrome's
    /// "Chrome Safe Storage" key. macOS will ask the user to authorise this.
    public func secret(service: String) throws -> String? {
        let result = api.read(service: service, account: "")
        switch result.status {
        case errSecSuccess:
            guard let data = result.data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            // Some items are stored without an account, so fall back to a
            // service-only lookup.
            return try serviceOnlySecret(service: service)
        default:
            throw KeychainError.readFailed(result.status)
        }
    }

    private func serviceOnlySecret(service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.readFailed(status)
        }
    }

    /// Explicit import only. Inaccessible source keys fail without an OS dialog;
    /// service-only fallback is allowed only for a genuinely missing account.
    public func secretWithoutInteraction(service: String) throws -> String? {
        var result = api.readWithoutInteraction(service: service, account: "")
        if result.status == errSecItemNotFound {
            result = api.readWithoutInteraction(service: service, account: nil)
        }
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

    /// Attributes only: drawing Settings does not decrypt stored credentials.
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
