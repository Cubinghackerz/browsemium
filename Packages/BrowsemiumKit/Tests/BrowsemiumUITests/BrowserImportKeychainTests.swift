import BrowsemiumCore
import BrowsemiumData
@testable import BrowsemiumUI
import Foundation
import Security
import Testing

private final class ImportKeychainSpy: KeychainAPI, @unchecked Sendable {
    private(set) var interactiveReads = 0
    private(set) var noninteractiveServices: [String] = []
    var status: OSStatus = errSecSuccess

    func store(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
    func delete(service: String, account: String) -> OSStatus { errSecSuccess }
    func exists(service: String, account: String) -> Bool { true }
    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        interactiveReads += 1
        return (errSecSuccess, Data("fixture-only".utf8))
    }
    func readWithoutInteraction(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        noninteractiveServices.append(service)
        return (status, status == errSecSuccess ? Data("fixture-only".utf8) : nil)
    }
}

@Suite
struct BrowserImportKeychainTests {
    @Test(arguments: BrowserImportSource.allCases.filter { $0.family == .chromium })
    func browserKeyReadsNeverAllowAnAuthorizationDialog(source: BrowserImportSource) throws {
        let backend = ImportKeychainSpy()
        let provider = ChromeSafeStorageKeyProvider(keychain: KeychainStore(api: backend))
        let key = try provider.safeStorageKey(for: source)
        #expect(key == (try ChromeCredentialCrypto.derivedKey(safeStoragePassword: "fixture-only")))
        #expect(backend.interactiveReads == 0)
        #expect(backend.noninteractiveServices == [source.safeStorageService!])
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecItemNotFound])
    func inaccessibleBrowserKeysOfferRecoveryWithoutRetryingInteractively(status: OSStatus) {
        let backend = ImportKeychainSpy()
        backend.status = status
        let provider = ChromeSafeStorageKeyProvider(keychain: KeychainStore(api: backend))
        #expect(throws: BrowserDataImporter.ImportError.self) {
            _ = try provider.safeStorageKey(for: .chrome)
        }
        #expect(backend.interactiveReads == 0)
        #expect(!backend.noninteractiveServices.isEmpty)
    }

    @Test(arguments: [BrowserImportSource.firefox, .safari])
    func nonChromiumSourcesNeverReadBrowserEncryptionKeys(source: BrowserImportSource) throws {
        let backend = ImportKeychainSpy()
        let provider = ChromeSafeStorageKeyProvider(keychain: KeychainStore(api: backend))
        #expect(try provider.safeStorageKey(for: source) == nil)
        #expect(backend.interactiveReads == 0)
        #expect(backend.noninteractiveServices.isEmpty)
    }
}
