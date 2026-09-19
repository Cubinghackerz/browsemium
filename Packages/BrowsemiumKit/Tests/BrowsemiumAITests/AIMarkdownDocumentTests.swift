import BrowsemiumAI
import Testing

@Test
func documentRetainsSource() {
    let document = AIMarkdownDocument(source: "**Browsemium**")
    #expect(document.source == "**Browsemium**")
}
