import BrowsemiumData
import Foundation
import BrowsemiumEngineKit

/// Reads an already-accessible Chromium source key only after import selection.
/// Never asks macOS to authorize it; unavailable keys require the CSV route.
struct ChromeSafeStorageKeyProvider: BrowserCredentialKeyProviding {
    let keychain: KeychainStore

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
            throw BrowserDataImporter.ImportError.credentialsLocked(source.displayName)
        }
        return try ChromeCredentialCrypto.derivedKey(safeStoragePassword: password)
    }
}
