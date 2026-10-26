import BrowsemiumCore
import BrowsemiumData
@testable import BrowsemiumUI
import Foundation
import Security
import Testing

private final class PolicyKeychain: KeychainAPI, @unchecked Sendable {
    private(set) var values: [String: Data] = [:]
    func store(service: String, account: String, data: Data) -> OSStatus {
        values[account] = data
        return errSecSuccess
    }
    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        guard let data = values[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }
    func delete(service: String, account: String) -> OSStatus {
        values[account] = nil
        return errSecSuccess
    }
    func exists(service: String, account: String) -> Bool { values[account] != nil }
}

@Suite @MainActor
struct CredentialImportPolicyTests {
    private func makeModel() -> (BrowserWindowModel, PolicyKeychain) {
        let backend = PolicyKeychain()
        let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine(), keychain: KeychainStore(api: backend)))
        return (model, backend)
    }

    @Test
    func anImportedLoginIsSavedWhenNothingIsThereYet() throws {
        let (model, backend) = makeModel()
        let outcome = model.importCredential(host: "fixture.example", username: "fixture-user", password: "fixture-only")
        #expect(outcome == .accepted)
        let saved = try #require(model.environment.savedCredentialRepository.all().first)
        #expect(backend.values[saved.keychainAccount] == Data("fixture-only".utf8))
    }

    @Test
    func anImportNeverOverwritesAnExistingSavedPassword() throws {
        let (model, backend) = makeModel()
        #expect(model.saveCredential(host: "fixture.example", username: "fixture-user", password: "kept-by-the-user"))
        let saved = try #require(model.environment.savedCredentialRepository.all().first)

        let outcome = model.importCredential(host: "fixture.example", username: "fixture-user", password: "from-the-import")

        #expect(outcome == .duplicate, "An existing host and username is reported as already saved")
        #expect(backend.values[saved.keychainAccount] == Data("kept-by-the-user".utf8))
        #expect(try model.environment.savedCredentialRepository.all().count == 1)
    }

    @Test
    func aDifferentUsernameOnTheSameHostIsAnotherLogin() throws {
        let (model, _) = makeModel()
        #expect(model.importCredential(host: "fixture.example", username: "first", password: "one") == .accepted)
        #expect(model.importCredential(host: "fixture.example", username: "second", password: "two") == .accepted)
        #expect(try model.environment.savedCredentialRepository.all().count == 2)
    }

    @Test
    func theSameLoginInAnotherProfileIsNotADuplicate() throws {
        let (model, _) = makeModel()
        let other = try #require(model.createProfile(named: "Other", switchToIt: false))
        #expect(model.importCredential(host: "fixture.example", username: "u", password: "one") == .accepted)
        #expect(model.importCredential(host: "fixture.example", username: "u", password: "two", profile: other) == .accepted)
    }

    @Test
    func theCSVImportAlsoKeepsWhatIsAlreadySaved() throws {
        let (model, backend) = makeModel()
        #expect(model.saveCredential(host: "fixture.example", username: "fixture-user", password: "kept-by-the-user"))
        let saved = try #require(model.environment.savedCredentialRepository.all().first)
        let target = PasswordCSVImportTarget.existing(model.activeProfile)
        let credential = ChromeLogin(url: URL(string: "https://fixture.example")!, username: "fixture-user", password: "from-the-csv")

        #expect(try target.importCredentials([credential], using: model) == 0, "Nothing new was saved")
        #expect(backend.values[saved.keychainAccount] == Data("kept-by-the-user".utf8))
    }

    @Test
    func importedPasswordOutcomesReportAlreadySavedNotAWriteFailure() {
        var report = BrowserImportReport()
        report.record(.password, ordinal: 1, stage: .transfer, outcome: .accepted, reason: .preparedForTransfer)
        report.record(.password, ordinal: 2, stage: .transfer, outcome: .accepted, reason: .preparedForTransfer)
        report.completeTransfer(.password, outcomes: [.accepted, .duplicate], reasonFor: BrowserImportReport.passwordReason)
        let persisted = report.items.filter { $0.stage == .persistence }
        #expect(persisted.map(\.reason) == [.imported, .alreadyPresent])
    }
}
