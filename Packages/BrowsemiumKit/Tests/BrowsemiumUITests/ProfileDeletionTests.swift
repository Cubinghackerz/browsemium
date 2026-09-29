import BrowsemiumCore
import BrowsemiumData
import BrowsemiumUI
import Foundation
import Security
import Testing

private final class ProfileDeletionKeychain: KeychainAPI, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private(set) var reads = 0

    func store(service: String, account: String, data: Data) -> OSStatus {
        values["\(service)|\(account)"] = data
        return errSecSuccess
    }

    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        reads += 1
        guard let value = values["\(service)|\(account)"] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, value)
    }

    func delete(service: String, account: String) -> OSStatus {
        values["\(service)|\(account)"] = nil
        return errSecSuccess
    }

    func exists(service: String, account: String) -> Bool {
        values["\(service)|\(account)"] != nil
    }
}

@Test @MainActor
func openingSettingsCanCheckLegacyProviderKeyWithoutReadingIt() throws {
    let backend = ProfileDeletionKeychain()
    let keychain = KeychainStore(service: "legacy-provider-check", api: backend)
    try keychain.setSecret("fixture-only", account: "provider.\(AIProviderID.openAI.rawValue)")
    let environment = BrowserEnvironment.inMemory(keychain: keychain)

    let scoped = environment.providerCredentialAccount(.openAI)
    #expect(environment.hasProviderCredential(.openAI))
    #expect(backend.reads == 0, "Drawing Settings must use attributes only")
    #expect(try !keychain.hasSecret(account: scoped))

    #expect(environment.providerCredentialAccountForUse(.openAI) == scoped)
    #expect(backend.reads == 1, "Only actual provider use may read the legacy secret")
    #expect(try keychain.hasSecret(account: scoped))
}

@Test @MainActor
func savingCredentialToImportProfileDoesNotLeakIntoActiveProfile() throws {
    let backend = ProfileDeletionKeychain()
    let keychain = KeychainStore(service: "profile-scoped-import", api: backend)
    let environment = BrowserEnvironment.inMemory(keychain: keychain)
    let model = BrowserWindowModel(environment: environment)
    let activeProfile = model.activeProfile
    let importProfile = try #require(model.createProfile(named: "Imported", switchToIt: false))

    #expect(model.saveCredential(
        host: "example.com",
        username: "person",
        password: "fixture-only",
        profile: importProfile
    ))
    #expect(try environment.savedCredentialRepository.all().isEmpty)

    let importedCredentials = try SavedCredentialRepository(
        database: environment.profileStore.database(for: importProfile)
    ).all()
    let imported = try #require(importedCredentials.first)
    #expect(imported.host == "example.com")
    #expect(try keychain.secret(account: imported.keychainAccount) == "fixture-only")
    #expect(model.activeProfile.id == activeProfile.id)
}

@Test @MainActor
func deletingProfileRemovesStoreSecretsAndRegistryOnlyAfterSuccess() async throws {
    let engine = StubEngine()
    let backend = ProfileDeletionKeychain()
    let keychain = KeychainStore(service: "profile-deletion-success", api: backend)
    let environment = BrowserEnvironment.inMemory(engine: engine, keychain: keychain)
    let model = BrowserWindowModel(environment: environment)
    let target = try #require(model.createProfile(named: "Disposable", switchToIt: false))

    let database = try environment.profileStore.database(for: target)
    let credential = try SavedCredentialRepository(database: database)
        .save(host: "example.com", username: "person")
    let providerAccount = "profile.\(target.id.uuidString).provider.\(AIProviderID.openAI.rawValue)"
    try keychain.setSecret("password", account: credential.keychainAccount)
    try keychain.setSecret("provider-key", account: providerAccount)

    await model.deleteProfile(target)

    #expect(engine.removedProfileDataStores == [target.dataStoreUUID])
    #expect(try !keychain.hasSecret(account: credential.keychainAccount))
    #expect(try !keychain.hasSecret(account: providerAccount))
    #expect(!model.profiles.contains(where: { $0.id == target.id }))
    #expect(model.statusMessage == "Deleted Disposable")
}

@Test @MainActor
func failedStoreRemovalKeepsProfileForRetry() async throws {
    let engine = StubEngine()
    engine.profileDataStoreRemovalError = BrowsemiumError.databaseFailure("store busy")
    let environment = BrowserEnvironment.inMemory(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    let target = try #require(model.createProfile(named: "Retry Me", switchToIt: false))

    await model.deleteProfile(target)

    #expect(model.profiles.contains(where: { $0.id == target.id }))
    #expect(model.statusMessage?.contains("kept so you can retry") == true)
}

@Test @MainActor
func deletingActiveProfileSwitchesToFallbackBeforeStoreRemoval() async throws {
    let engine = StubEngine()
    let environment = BrowserEnvironment.inMemory(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    let originalID = model.activeProfile.id
    let target = try #require(model.createProfile(named: "Temporary"))
    #expect(model.activeProfile.id == target.id)

    await model.deleteProfile(target)

    #expect(model.activeProfile.id == originalID)
    #expect(engine.removedProfileDataStores == [target.dataStoreUUID])
    #expect(!model.profiles.contains(where: { $0.id == target.id }))
}
