import BrowsemiumData
import Foundation
import BrowsemiumEngineKit

/// Supplies Chrome's password-encryption key.
///
/// The key lives in the login keychain as "Chrome Safe Storage". macOS asks the
/// user to authorise reading it the first time, which is why password import is
/// opt-in and everything else still imports when the user declines.
struct ChromeSafeStorageKeyProvider: BrowserCredentialKeyProviding {
    let keychain: KeychainStore

    func safeStorageKey(for source: BrowserImportSource) throws -> Data? {
        // Every Chromium-family browser shares the scheme but each stores its
        // key under its own keychain item.
        guard let service = source.safeStorageService else { return nil }
        guard let password = try keychain.secret(service: service), !password.isEmpty else {
            return nil
        }
        return try ChromeCredentialCrypto.derivedKey(safeStoragePassword: password)
    }
}
