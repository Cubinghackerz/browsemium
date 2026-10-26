import BrowsemiumCore
@testable import BrowsemiumData
@testable import BrowsemiumUI
import Foundation
import Security
import Testing

private final class ConsentKeychainSpy: KeychainAPI, @unchecked Sendable {
    var silentStatus: OSStatus = errSecInteractionNotAllowed
    var interactiveStatus: OSStatus = errSecSuccess
    private(set) var silentServices: [String] = []
    private(set) var interactiveServices: [String] = []

    func store(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
    func delete(service: String, account: String) -> OSStatus { errSecSuccess }
    func exists(service: String, account: String) -> Bool { true }
    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        interactiveServices.append(service)
        return (interactiveStatus, interactiveStatus == errSecSuccess ? Data("fixture-only".utf8) : nil)
    }
    func readWithoutInteraction(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        silentServices.append(service)
        return (silentStatus, silentStatus == errSecSuccess ? Data("fixture-only".utf8) : nil)
    }
}

private func preview(_ source: BrowserImportSource, logins: Int = 1, cookies: Int = 1) -> BrowserImportPreview {
    BrowserImportPreview(
        source: source, bookmarks: [], visits: [], folders: [],
        credentials: (0..<logins).map { .init(url: URL(string: "https://fixture\($0).example")!, username: "fixture-user") },
        cookieCount: cookies, extensionIDs: [], searchEngine: nil, notImportable: []
    )
}

private func options(passwords: Bool = true, cookies: Bool = true) -> BrowserImportOptions {
    var value = BrowserImportOptions()
    value.includesPasswords = passwords
    value.includesCookies = cookies
    return value
}

@Suite
struct ImportKeyAccessTests {
    @Test
    func nothingIsReadWhenNoSecretIsSelected() {
        let spy = ConsentKeychainSpy()
        let keychain = KeychainStore(api: spy)
        let plan = ImportKeyAccess.plan(for: [(preview(.chrome), options(passwords: false, cookies: false))], keychain: keychain, consented: false)
        #expect(spy.silentServices.isEmpty && spy.interactiveServices.isEmpty)
        #expect(plan.needsConsent.isEmpty && plan.providers.isEmpty && plan.skipped.isEmpty)
    }

    @Test
    func nothingIsReadWhenTheSourceHasNoSecretsToMove() {
        let spy = ConsentKeychainSpy()
        let plan = ImportKeyAccess.plan(for: [(preview(.chrome, logins: 0, cookies: 0), options())], keychain: KeychainStore(api: spy), consented: false)
        #expect(spy.silentServices.isEmpty && spy.interactiveServices.isEmpty)
        #expect(plan.needsConsent.isEmpty)
    }

    @Test(arguments: [BrowserImportSource.firefox, .safari])
    func firefoxAndSafariNeverReadABrowserKey(source: BrowserImportSource) {
        let spy = ConsentKeychainSpy()
        let plan = ImportKeyAccess.plan(for: [(preview(source), options())], keychain: KeychainStore(api: spy), consented: true)
        #expect(spy.silentServices.isEmpty && spy.interactiveServices.isEmpty)
        #expect(plan.needsConsent.isEmpty && plan.skipped.isEmpty)
    }

    @Test
    func anAccessibleKeyIsUsedWithoutAskingAnyone() {
        let spy = ConsentKeychainSpy()
        spy.silentStatus = errSecSuccess
        let plan = ImportKeyAccess.plan(for: [(preview(.chrome), options())], keychain: KeychainStore(api: spy), consented: false)
        #expect(plan.providers[.chrome] != nil)
        #expect(plan.needsConsent.isEmpty)
        #expect(spy.interactiveServices.isEmpty)
    }

    @Test
    func aLockedKeyAsksForConsentAndReadsNothingInteractivelyUntilGiven() {
        let spy = ConsentKeychainSpy()
        let plan = ImportKeyAccess.plan(for: [(preview(.chrome), options())], keychain: KeychainStore(api: spy), consented: false)
        #expect(plan.needsConsent == [.chrome])
        #expect(plan.providers.isEmpty)
        #expect(spy.interactiveServices.isEmpty, "The macOS prompt only follows the person's own Continue")
    }

    @Test
    func consentReadsEachBrowsersKeyExactlyOnceAcrossProfiles() {
        let spy = ConsentKeychainSpy()
        let chosen = [(preview(.chrome), options()), (preview(.chrome, logins: 3), options()), (preview(.brave), options())]
        let plan = ImportKeyAccess.plan(for: chosen, keychain: KeychainStore(api: spy), consented: true)
        #expect(spy.interactiveServices.sorted() == ["Brave Safe Storage", "Chrome Safe Storage"])
        #expect(plan.providers[.chrome] != nil && plan.providers[.brave] != nil)
        #expect(plan.needsConsent.isEmpty)
    }

    @Test(arguments: [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed])
    func denyingTheMacOSPromptSkipsSecretsAndKeepsEverythingElse(status: OSStatus) {
        let spy = ConsentKeychainSpy()
        spy.interactiveStatus = status
        let plan = ImportKeyAccess.plan(for: [(preview(.chrome), options())], keychain: KeychainStore(api: spy), consented: true)
        #expect(plan.providers.isEmpty)
        #expect(plan.skipped[.chrome] == .declined)
        #expect(spy.interactiveServices == ["Chrome Safe Storage"], "No retry after a denial")
        let stripped = ImportKeyAccess.withoutSecrets(options())
        #expect(!stripped.includesPasswords && !stripped.includesCookies)
        #expect(stripped.includesBookmarks && stripped.includesHistory)
    }

    @Test
    func aMissingKeyIsNotAskedAboutAndIsReportedAsNotFound() {
        let spy = ConsentKeychainSpy()
        spy.silentStatus = errSecItemNotFound
        let plan = ImportKeyAccess.plan(for: [(preview(.chrome), options())], keychain: KeychainStore(api: spy), consented: true)
        #expect(spy.interactiveServices.isEmpty)
        #expect(plan.skipped[.chrome] == .notFound)
        #expect(plan.needsConsent.isEmpty)
    }

    @Test
    func theDefaultProviderStillNeverAllowsAPrompt() throws {
        let spy = ConsentKeychainSpy()
        let provider = ChromeSafeStorageKeyProvider(keychain: KeychainStore(api: spy))
        #expect(throws: BrowserDataImporter.ImportError.self) { _ = try provider.safeStorageKey(for: .chrome) }
        #expect(spy.interactiveServices.isEmpty)
    }
}
