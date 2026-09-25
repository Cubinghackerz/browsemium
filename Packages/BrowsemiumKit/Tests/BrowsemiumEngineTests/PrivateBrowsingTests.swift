import BrowsemiumCore
import BrowsemiumEngine
import Foundation
import Testing
import BrowsemiumEngineKit
import WebKit

// MARK: - Private browsing reaches the engine

@Test @MainActor
func privateBrowsingModeIsOffByDefault() {
    let controller = BrowserRuntimeController()
    #expect(controller.isPrivateBrowsingEnabled == false)
}

@Test @MainActor
func privateBrowsingModeCreatesEphemeralRuntimes() {
    let controller = BrowserRuntimeController()
    controller.setPrivateBrowsing(true)

    // Creating a runtime through the public engine surface must respect the
    // mode: a private session that keeps writing to the profile's persistent
    // store is not private at all.
    let tabID = TabID()
    _ = controller.runtime(for: tabID)
    #expect(controller.isPrivateRuntime(tabID: tabID))
}

@Test @MainActor
func leavingPrivateBrowsingDropsEveryWebViewAndStartsClean() {
    let controller = BrowserRuntimeController()
    controller.setPrivateBrowsing(true)
    let privateTab = TabID()
    _ = controller.runtime(for: privateTab)
    #expect(controller.isPrivateRuntime(tabID: privateTab))

    controller.setPrivateBrowsing(false)

    // Switching modes drops every web view: a persistent view must never be
    // reused in a private session, or the reverse. The private runtime is
    // gone, and new runtimes are persistent again.
    #expect(controller.isPrivateRuntime(tabID: privateTab) == false)
    let normalTab = TabID()
    _ = controller.runtime(for: normalTab)
    #expect(controller.isPrivateRuntime(tabID: normalTab) == false)
}

@Test @MainActor
func tearingDownForProfileSwitchDropsPrivateRuntimesToo() {
    let controller = BrowserRuntimeController()
    controller.setPrivateBrowsing(true)
    let tabID = TabID()
    _ = controller.runtime(for: tabID)

    controller.teardownForProfileSwitch()

    #expect(controller.isPrivateRuntime(tabID: tabID) == false)
}

// MARK: - Private views carry no extension code

@Test @MainActor
func ephemeralWebViewsNeverCarryExtensions() throws {
    let configuration = WebViewFactory().makeConfiguration(store: .ephemeral)
    if #available(macOS 15.4, *) {
        #expect(configuration.webExtensionController == nil)
    }
    #expect(configuration.websiteDataStore.isPersistent == false)
}

@Test @MainActor
func persistentWebViewsKeepThePersistentStore() throws {
    let configuration = WebViewFactory().makeConfiguration(store: .persistent)
    #expect(configuration.websiteDataStore.isPersistent)
}

// MARK: - The protection level reaches real web views

@Test @MainActor
func strictProtectionHardensNewWebViews() throws {
    WebViewFactory.protectionLevel = .standard
    defer { WebViewFactory.protectionLevel = .standard }

    let balanced = WebViewFactory().makeConfiguration(store: .persistent)
    WebViewFactory.protectionLevel = .strict
    let strict = WebViewFactory().makeConfiguration(store: .persistent)

    let balancedPreferences = try #require(balanced.defaultWebpagePreferences)
    let strictPreferences = try #require(strict.defaultWebpagePreferences)

    if #available(macOS 26.4, *) {
        #expect(balancedPreferences.securityRestrictionMode == WKSecurityRestrictionMode.none)
        #expect(strictPreferences.securityRestrictionMode == .maximizeCompatibility)
    }
    if #available(macOS 27.0, *) {
        #expect(balancedPreferences.globalPrivacyControlEnabled == false)
        #expect(strictPreferences.globalPrivacyControlEnabled == true)
    }
}

@Test @MainActor
func changingTheLevelUpdatesTabsThatAreAlreadyOpen() {
    WebViewFactory.protectionLevel = .standard
    defer { WebViewFactory.protectionLevel = .standard }

    let controller = BrowserRuntimeController()
    let tabID = TabID()
    let runtime = controller.runtime(for: tabID)
    let webView = runtime.ensureWebView()

    controller.apply(BrowserSettings(protectionLevel: .strict))

    #expect(runtime.protectionLevel == .strict)
    if #available(macOS 26.4, *) {
        #expect(webView.configuration.defaultWebpagePreferences?.securityRestrictionMode == .maximizeCompatibility)
    }

    controller.apply(BrowserSettings(protectionLevel: .standard))

    #expect(runtime.protectionLevel == .standard)
    if #available(macOS 26.4, *) {
        let mode = webView.configuration.defaultWebpagePreferences?.securityRestrictionMode
        #expect(mode == WKSecurityRestrictionMode.none)
    }
}

@Test @MainActor
func newTabsFollowTheProtectionLevelInEffect() {
    WebViewFactory.protectionLevel = .standard
    defer { WebViewFactory.protectionLevel = .standard }

    let controller = BrowserRuntimeController()
    controller.apply(BrowserSettings(protectionLevel: .strict))
    let strictView = controller.runtime(for: TabID()).ensureWebView()

    if #available(macOS 26.4, *) {
        #expect(strictView.configuration.defaultWebpagePreferences?.securityRestrictionMode == .maximizeCompatibility)
    }

    controller.apply(BrowserSettings(protectionLevel: .standard))
    let balancedView = controller.runtime(for: TabID()).ensureWebView()
    if #available(macOS 26.4, *) {
        let mode = balancedView.configuration.defaultWebpagePreferences?.securityRestrictionMode
        #expect(mode == WKSecurityRestrictionMode.none)
    }
}

@Test @MainActor
func aPausedHostDoesNotPauseAnotherHost() {
    let controller = BrowserRuntimeController()
    let pausedTab = TabID()
    let otherTab = TabID()
    _ = controller.runtime(for: pausedTab)
    _ = controller.runtime(for: otherTab)

    controller.replacePausedBlockingHosts(["Paused.Example"])
    controller.setContentRulesPaused(tabID: pausedTab, paused: true)

    #expect(controller.isBlockingPaused(host: "paused.example"))
    #expect(controller.isBlockingPaused(host: "other.example") == false)
    #expect(controller.isBlockingPaused(host: "Paused.Example"))
}

@Test @MainActor
func turningBlockingOffStopsTheContentRules() {
    WebViewFactory.protectionLevel = .standard
    defer { WebViewFactory.protectionLevel = .standard }

    let controller = BrowserRuntimeController()
    let tabID = TabID()
    _ = controller.runtime(for: tabID).ensureWebView()

    controller.apply(BrowserSettings(protectionLevel: .standard))
    #expect(controller.blocking != .inactive)

    controller.apply(BrowserSettings(protectionLevel: .off))
    #expect(controller.protectionLevel == .off)
    #expect(controller.blocking == .inactive)
}
