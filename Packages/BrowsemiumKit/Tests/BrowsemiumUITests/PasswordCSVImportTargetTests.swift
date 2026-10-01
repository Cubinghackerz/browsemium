import BrowsemiumCore
import BrowsemiumData
@testable import BrowsemiumUI
import Foundation
import Security
import Testing

private final class CSVImportKeychain: KeychainAPI, @unchecked Sendable {
    private(set) var values: [String: Data] = [:]
    private(set) var reads = 0
    func store(service: String, account: String, data: Data) -> OSStatus {
        values[account] = data
        return errSecSuccess
    }
    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        reads += 1
        return (errSecItemNotFound, nil)
    }
    func delete(service: String, account: String) -> OSStatus { errSecSuccess }
    func exists(service: String, account: String) -> Bool { values[account] != nil }
}

@Suite @MainActor
struct PasswordCSVImportTargetTests {
    @Test(arguments: [
        ("name,url,username,password", "Fixture,https://fixture.example,fixture-user,fixture-only"),
        ("url,username,password,httpRealm,formActionOrigin", "https://fixture.example,fixture-user,fixture-only,,"),
        ("Title,URL,Username,Password,Notes", "Fixture,https://fixture.example,fixture-user,fixture-only,")
    ])
    func browserCSVImportsToTheSelectedProfileWithoutAnySecretRead(headers: String, row: String) throws {
        let backend = CSVImportKeychain()
        let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine(), keychain: KeychainStore(api: backend)))
        let chosenProfile = model.activeProfile
        let target = PasswordCSVImportTarget(destination: .currentProfile,
            currentProfile: chosenProfile, newProfileName: "")
        let csv = try BrowserPasswordCSV(data: Data("\(headers)\r\n\(row)\r\n".utf8))
        let credentials = try csv.credentials(using: #require(csv.suggestedMap))
        _ = try #require(model.createProfile(named: "Other"))
        #expect(target.displayName == chosenProfile.name)
        let count = try target.importCredentials(credentials, using: model)
        #expect(count == 1)
        #expect(backend.reads == 0)
        #expect(try model.environment.savedCredentialRepository.all().isEmpty)
        let repository = SavedCredentialRepository(database: try model.environment.profileStore.database(for: chosenProfile))
        let saved = try #require(repository.all().first)
        #expect(backend.values[saved.keychainAccount] == Data("fixture-only".utf8))
        _ = try target.importCredentials(credentials, using: model)
        #expect(try repository.all().count == 1, "Repeat CSV import updates the same credential")
        #expect(backend.values.count == 1)
    }

    @Test
    func aNewDestinationIsCreatedOnlyAtConfirmation() throws {
        let backend = CSVImportKeychain()
        let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine(), keychain: KeychainStore(api: backend)))
        let before = model.profiles.count
        let target = PasswordCSVImportTarget(destination: .newProfile,
            currentProfile: model.activeProfile, newProfileName: "  Chrome import  ")
        #expect(target.displayName == "Chrome import")
        #expect(model.profiles.count == before)
        #expect(try target.importCredentials([], using: model) == 0)
        #expect(model.profiles.count == before)
        let credential = ChromeLogin(url: URL(string: "https://fixture.example")!, username: "fixture-user", password: "fixture-only")
        #expect(try target.importCredentials([credential], using: model) == 1)
        #expect(model.profiles.count == before + 1)
        #expect(model.activeProfile.name == "Chrome import")
        #expect(backend.reads == 0)
        #expect(try model.environment.savedCredentialRepository.all().count == 1)
    }

    @Test
    func importedPasswordsKeepLeadingAndTrailingWhitespace() throws {
        let backend = CSVImportKeychain()
        let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine(), keychain: KeychainStore(api: backend)))
        let target = PasswordCSVImportTarget.existing(model.activeProfile)
        let password = "  fixture-only\t "
        let csv = try BrowserPasswordCSV(data: BrowserPasswordCSV.export([
            ChromeLogin(url: URL(string: "https://fixture.example")!, username: "fixture-user", password: password)
        ]))
        let credentials = try csv.credentials(using: #require(csv.suggestedMap))
        #expect(try target.importCredentials(credentials, using: model) == 1)
        let saved = try #require(model.environment.savedCredentialRepository.all().first)
        #expect(backend.values[saved.keychainAccount] == Data(password.utf8))
    }

    @Test
    func unavailableDestinationsFailBeforeAnyWrite() {
        let backend = CSVImportKeychain()
        let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine(), keychain: KeychainStore(api: backend)))
        let target = PasswordCSVImportTarget.existing(BrowserProfile(name: "Missing"))
        let credential = ChromeLogin(url: URL(string: "https://fixture.example")!, username: "fixture-user", password: "fixture-only")
        #expect(throws: PasswordCSVImportTarget.ImportError.self) {
            _ = try target.importCredentials([credential], using: model)
        }
        #expect(backend.values.isEmpty)
        #expect(backend.reads == 0)
    }
}
