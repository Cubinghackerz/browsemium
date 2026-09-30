import BrowsemiumEngine
import Testing

@Suite struct ExternalSchemePolicyTests {
    @Test(arguments: ["file", "javascript", "vbscript", "x-apple.systempreferences", "", "FILE"])
    func dangerousSchemesNeverLaunch(scheme: String) {
        for activated in [false, true] {
            for mainFrame in [false, true] {
                #expect(ExternalSchemePolicy.evaluate(scheme: scheme, isUserActivated: activated, isMainFrame: mainFrame) == .block)
            }
        }
    }

    @Test(arguments: ["mailto", "tel", "sms", "facetime", "facetime-audio", "maps", "MAILTO"])
    func supportedAppsRequireClick(scheme: String) {
        for mainFrame in [false, true] {
            #expect(ExternalSchemePolicy.evaluate(scheme: scheme, isUserActivated: false, isMainFrame: mainFrame) == .block)
            #expect(ExternalSchemePolicy.evaluate(scheme: scheme, isUserActivated: true, isMainFrame: mainFrame) == .open)
        }
    }

    @Test(arguments: ["smb", "custom-app"])
    func unknownAppsRequireClickAndMainFrame(scheme: String) {
        for activated in [false, true] {
            for mainFrame in [false, true] {
                let expected: ExternalSchemePolicy.Action = activated && mainFrame ? .open : .block
                #expect(ExternalSchemePolicy.evaluate(scheme: scheme, isUserActivated: activated, isMainFrame: mainFrame) == expected)
            }
        }
    }

    @Test func webContentSchemesStayInsideWebKit() {
        for activated in [false, true] {
            for mainFrame in [false, true] {
                #expect(ExternalSchemePolicy.evaluate(scheme: "blob", isUserActivated: activated, isMainFrame: mainFrame) == .allowInWebView)
                #expect(ExternalSchemePolicy.evaluate(scheme: "data", isUserActivated: activated, isMainFrame: mainFrame) == (mainFrame ? .block : .allowInWebView))
            }
        }
    }
}
