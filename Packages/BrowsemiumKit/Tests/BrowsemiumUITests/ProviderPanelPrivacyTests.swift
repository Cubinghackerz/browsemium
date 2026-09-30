@testable import BrowsemiumUI
import Foundation
import Testing
import WebKit

@Test @MainActor
func privateProviderPanelsUseEphemeralStorage() {
    let panel = ProviderPanelController()
    panel.configureStorage(isPrivate: true, profileIdentifier: UUID())
    let configuration = panel.makeConfiguration()
    #expect(!configuration.websiteDataStore.isPersistent)
    if #available(macOS 15.4, *) {
        #expect(configuration.webExtensionController == nil)
    }
}

@Test @MainActor
func providerPanelsUseTheirOwnProfileIdentifier() {
    let panel = ProviderPanelController()
    let profileID = UUID()
    panel.configureStorage(isPrivate: false, profileIdentifier: profileID)
    let configuration = panel.makeConfiguration()
    #expect(configuration.websiteDataStore.isPersistent)
    #expect(configuration.websiteDataStore.identifier == profileID)
}
