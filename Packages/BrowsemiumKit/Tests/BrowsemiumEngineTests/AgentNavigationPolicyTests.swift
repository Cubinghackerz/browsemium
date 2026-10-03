import Foundation
import Testing
@testable import BrowsemiumEngine

@Suite("Agent navigation policy")
struct AgentNavigationPolicyTests {
    private func decide(
        _ urlText: String?,
        main: Bool = true,
        newWindow: Bool = false,
        download: Bool = false,
        access: Bool = true,
        allow: Bool = true
    ) -> AgentNavigationPolicy.Decision {
        AgentNavigationPolicy.decide(
            url: urlText.flatMap { URL(string: $0) },
            isMainFrame: main,
            opensNewWindow: newWindow,
            isDownload: download,
            agentAccess: access,
            authorize: { _ in allow }
        )
    }

    @Test func aGrantedMainFrameNavigationIsAllowed() {
        #expect(decide("https://fixture.test/a") == .allow)
    }

    @Test func anUngrantedMainFrameNavigationIsCancelled() {
        #expect(decide("https://evil.test/", allow: false) == .cancel)
    }

    @Test(arguments: [
        "javascript:alert(1)", "file:///etc/hosts", "data:text/html,hi", "blob:https://fixture.test/x",
        "ftp://fixture.test/", "mailto:a@b.test", "tel:123", "itms-apps://x", "x-apple.systempreferences:", "about:config"
    ])
    func nonWebSchemesAreCancelledEvenWhenAuthorized(url: String) {
        #expect(decide(url) == .cancel)
        #expect(decide(url, main: false) == .cancel)
        #expect(decide(url, access: false) == .cancel)
    }

    @Test func aboutBlankIsTheOnlyAboutPageAllowed() {
        #expect(decide("about:blank") == .allow)
        #expect(decide("about:srcdoc", main: false) == .allow)
        #expect(decide("about:blank#x") == .cancel)
    }

    @Test func popupsAndDownloadsAreNeverAllowed() {
        #expect(decide("https://fixture.test/", newWindow: true) == .cancel)
        #expect(decide("https://fixture.test/", download: true) == .cancel)
        #expect(decide("https://fixture.test/", newWindow: true, access: false) == .cancel)
    }

    @Test func aMissingURLIsCancelled() {
        #expect(decide(nil) == .cancel)
    }

    @Test func embeddedFramesAreNotJudgedByTheTopLevelGrant() {
        #expect(decide("https://ads.test/frame", main: false, allow: false) == .allow)
    }

    @Test func whileThePersonIsInControlOnlySchemesAreChecked() {
        #expect(decide("https://anywhere.test/", access: false, allow: false) == .allow)
        #expect(decide("javascript:1", access: false) == .cancel)
    }
}
