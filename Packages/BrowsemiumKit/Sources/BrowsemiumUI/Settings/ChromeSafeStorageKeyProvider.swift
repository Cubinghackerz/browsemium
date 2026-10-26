import BrowsemiumData
import Foundation
import BrowsemiumEngineKit

/// Reads a Chromium source key only for an explicit import. By default it never
/// asks macOS to authorize the read. `ImportKeyAccess` sets
/// `allowsAuthorizationPrompt` only after the person pressed Continue on the
/// consent sheet; it then makes one interactive read and never retries.
struct ChromeSafeStorageKeyProvider: BrowserCredentialKeyProviding {
    let keychain: KeychainStore
    var allowsAuthorizationPrompt = false

    func safeStorageKey(for source: BrowserImportSource) throws -> Data? {
        // Every Chromium-family browser shares the scheme but each stores its
        // key under its own keychain item.
        guard let service = source.safeStorageService else { return nil }
        let password: String
        do {
            guard let value = try keychain.secretWithoutInteraction(service: service), !value.isEmpty else {
                throw BrowserDataImporter.ImportError.credentialsLocked(source.displayName)
            }
            password = value
        } catch is KeychainStore.KeychainError {
            guard allowsAuthorizationPrompt else {
                throw BrowserDataImporter.ImportError.credentialsLocked(source.displayName)
            }
            do {
                guard let value = try keychain.secret(service: service), !value.isEmpty else {
                    throw BrowserDataImporter.ImportError.credentialsLocked(source.displayName)
                }
                password = value
            } catch is KeychainStore.KeychainError {
                throw BrowserDataImporter.ImportError.credentialsLocked(source.displayName)
            }
        }
        return try ChromeCredentialCrypto.derivedKey(safeStoragePassword: password)
    }
}
