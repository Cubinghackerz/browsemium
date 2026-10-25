import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import Security
import Testing

private final class OfferKeychain: KeychainAPI, @unchecked Sendable {
    private(set) var values: [String: Data] = [:]
    private(set) var reads = 0

    func store(service: String, account: String, data: Data) -> OSStatus {
        values["\(service)|\(account)"] = data
        return errSecSuccess
    }

    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        reads += 1
        guard let value = values["\(service)|\(account)"] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, value)
    }

    func delete(service: String, account: String) -> OSStatus {
        values["\(service)|\(account)"] = nil
        return errSecSuccess
    }

    func exists(service: String, account: String) -> Bool { values["\(service)|\(account)"] != nil }
}

@MainActor
private func makeModel() -> (BrowserWindowModel, StubEngine, OfferKeychain) {
    let engine = StubEngine()
    let backend = OfferKeychain()
    let keychain = KeychainStore(service: "password-offer-tests", api: backend)
    let model = BrowserWindowModel(environment: .inMemory(engine: engine, keychain: keychain))
    return (model, engine, backend)
}

private let candidate = SignInCandidate(host: "example.com", username: "ann@example.com", password: "correct horse")

@Test @MainActor
func aSignInOffersToSaveAndNothingIsStoredUntilTheyAgree() throws {
    let (model, engine, keychain) = makeModel()
    let tab = model.session.activeTabID!

    engine.emit(.signInFormSubmitted(candidate), for: tab)

    let offer = try #require(model.passwordOffer)
    #expect(offer.host == "example.com")
    #expect(offer.username == "ann@example.com")
    #expect(!String(describing: offer).contains("correct horse"))
    #expect(try model.environment.savedCredentialRepository.all().isEmpty)
    #expect(keychain.values.isEmpty)

    model.savePasswordOffer()

    #expect(model.passwordOffer == nil)
    let saved = try #require(try model.environment.savedCredentialRepository.all().first)
    #expect(saved.host == "example.com")
    #expect(saved.username == "ann@example.com")
    #expect(keychain.values.values.contains(Data("correct horse".utf8)))
}

@Test @MainActor
func decliningRemembersTheAnswerForThisSession() {
    let (model, engine, _) = makeModel()
    let tab = model.session.activeTabID!
    engine.emit(.signInFormSubmitted(candidate), for: tab)
    model.declinePasswordOffer()
    #expect(model.passwordOffer == nil)

    engine.emit(.signInFormSubmitted(candidate), for: tab)
    #expect(model.passwordOffer == nil)

    // A different account on the same site is a different question.
    engine.emit(.signInFormSubmitted(SignInCandidate(host: "example.com", username: "bob", password: "pw")), for: tab)
    #expect(model.passwordOffer?.username == "bob")
}

@Test @MainActor
func nothingIsOfferedInPrivateWindowsFromBackgroundTabsOrForSavedAccounts() throws {
    // Background tab.
    let (model, engine, _) = makeModel()
    let first = model.session.activeTabID!
    let background = model.newTab(url: nil)
    model.selectTab(first)
    engine.emit(.signInFormSubmitted(candidate), for: background)
    #expect(model.passwordOffer == nil)

    // Already saved: no offer and no Keychain read to compare.
    let (saved, savedEngine, savedKeychain) = makeModel()
    _ = saved.saveCredential(host: "example.com", username: "ann@example.com", password: "old")
    let readsBefore = savedKeychain.reads
    savedEngine.emit(.signInFormSubmitted(candidate), for: saved.session.activeTabID!)
    #expect(saved.passwordOffer == nil)
    #expect(savedKeychain.reads == readsBefore)

    // Private window.
    let (privateModel, privateEngine, _) = makeModel()
    privateModel.enterPrivateMode()
    privateEngine.emit(.signInFormSubmitted(candidate), for: privateModel.session.activeTabID!)
    #expect(privateModel.passwordOffer == nil)
}

@Test @MainActor
func closingTheTabOrEnteringPrivateModeDropsAPendingOffer() {
    let (model, engine, _) = makeModel()
    let tab = model.session.activeTabID!
    _ = model.newTab(url: nil)
    model.selectTab(tab)
    engine.emit(.signInFormSubmitted(candidate), for: tab)
    #expect(model.passwordOffer != nil)
    model.closeTab(tab)
    #expect(model.passwordOffer == nil)

    let (other, otherEngine, _) = makeModel()
    otherEngine.emit(.signInFormSubmitted(candidate), for: other.session.activeTabID!)
    #expect(other.passwordOffer != nil)
    other.enterPrivateMode()
    #expect(other.passwordOffer == nil)
}
