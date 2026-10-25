import BrowsemiumCore
import Foundation
import Testing

@Suite("Spotlight and Handoff policy")
struct SystemIntegrationPolicyTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test func spotlightTakesOnlyOrdinaryWebBookmarks() {
        #expect(SpotlightPolicy.isEligible(url: url("https://example.com/a?b=1"), creationEligible: true))
        #expect(SpotlightPolicy.isEligible(url: url("http://example.com/"), creationEligible: true))
        #expect(!SpotlightPolicy.isEligible(url: url("https://example.com/"), creationEligible: false),
                "A bookmark saved from a private, locked or separate-data context")
        #expect(!SpotlightPolicy.isEligible(url: url("https://user:secret@example.com/"), creationEligible: true))
        #expect(!SpotlightPolicy.isEligible(url: url("file:///etc/hosts"), creationEligible: true))
        #expect(!SpotlightPolicy.isEligible(url: url("javascript:alert(1)"), creationEligible: true))
        #expect(!SpotlightPolicy.isEligible(url: url("about:blank"), creationEligible: true))
    }

    @Test func handoffOffersOnlyPlainHTTPSFromAnOrdinaryContext() {
        func share(_ text: String, priv: Bool = false, locked: Bool = false, separate: Bool = false) -> URL? {
            HandoffPolicy.shareableURL(url(text), isPrivate: priv, isSpaceLocked: locked, hasSeparateData: separate)
        }
        #expect(share("https://example.com/a?q=1")?.absoluteString == "https://example.com/a?q=1")
        #expect(share("https://example.com/a#section")?.absoluteString == "https://example.com/a", "The fragment is dropped")
        #expect(share("http://example.com/") == nil, "https only")
        #expect(share("https://u:p@example.com/") == nil)
        #expect(share("https://example.com/", priv: true) == nil)
        #expect(share("https://example.com/", locked: true) == nil)
        #expect(share("https://example.com/", separate: true) == nil)
        #expect(HandoffPolicy.shareableURL(nil, isPrivate: false, isSpaceLocked: false, hasSeparateData: false) == nil)
    }

    @Test func incomingHandoffMustBePlainHTTPS() {
        #expect(HandoffPolicy.isAcceptableIncoming(url("https://example.com/x")))
        #expect(!HandoffPolicy.isAcceptableIncoming(url("http://example.com/x")))
        #expect(!HandoffPolicy.isAcceptableIncoming(url("browsemium://open?url=https://example.com")))
        #expect(!HandoffPolicy.isAcceptableIncoming(url("https://u:p@example.com/")))
        #expect(!HandoffPolicy.isAcceptableIncoming(url("file:///tmp/x")))
        #expect(!HandoffPolicy.isAcceptableIncoming(nil))
    }

    @Test func settingsDefaultOffAndLegacyDataDecodes() throws {
        #expect(BrowserSettings().indexBookmarksInSpotlight == false)
        #expect(BrowserSettings().handoffActiveTab == false)
        let legacy = Data(#"{"searchEngineTemplate":"https://x/?q=%s"}"#.utf8)
        let decoded = try JSONDecoder().decode(BrowserSettings.self, from: legacy)
        #expect(decoded.indexBookmarksInSpotlight == false)
        #expect(decoded.handoffActiveTab == false)
        var on = BrowserSettings()
        on.indexBookmarksInSpotlight = true
        on.handoffActiveTab = true
        let round = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(on))
        #expect(round.indexBookmarksInSpotlight && round.handoffActiveTab)
    }
}
