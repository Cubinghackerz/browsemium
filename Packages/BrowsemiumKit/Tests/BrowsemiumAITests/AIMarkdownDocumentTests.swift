import BrowsemiumAI
import Testing

@Test
func documentRetainsSource() {
    let document = AIMarkdownDocument(source: "**Browsemium**")
    #expect(document.source == "**Browsemium**")
}

@Test(arguments: ["javascript:alert(1)", "file:///Applications", "data:text/html,fixture", "mailto:fixture@example.com", "x-apple.systempreferences:", "#fragment", "/relative"])
func answerLinksRejectNonWebDestinations(_ destination: String) {
    #expect(SafeMarkdownDocument.sanitizedURL(destination) == nil)
    let document = SafeMarkdownDocument(source: "[Fixture](\(destination))")
    #expect(document.links.isEmpty)
    #expect(document.plainText.contains("Fixture"))
}

@Test(arguments: ["https://example.com/fixture", "http://localhost:8791/fixture"])
func answerLinksRetainWebDestinations(_ destination: String) {
    #expect(SafeMarkdownDocument.sanitizedURL(destination) != nil)
    #expect(SafeMarkdownDocument(source: "[Fixture](\(destination))").links.count == 1)
}
