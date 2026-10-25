import BrowsemiumCore
import Foundation
import Testing

private func strip(_ string: String) -> String? {
    TrackingParameterStripper.stripped(URL(string: string)!)?.absoluteString
}

@Test(arguments: [
    ("https://example.com/a?utm_source=x&utm_medium=y", "https://example.com/a"),
    ("https://example.com/a?id=7&utm_campaign=z&page=2", "https://example.com/a?id=7&page=2"),
    ("https://example.com/?fbclid=AbC123", "https://example.com/"),
    ("https://example.com/?gclid=1&dclid=2&msclkid=3", "https://example.com/"),
    ("https://example.com/p?q=swift%20ui&igshid=abc", "https://example.com/p?q=swift%20ui"),
    ("https://example.com/p?UTM_Source=Mail&keep=1", "https://example.com/p?keep=1"),
    ("https://example.com/p?keep=1&_hsenc=x&_hsmi=y#section", "https://example.com/p?keep=1#section"),
    ("http://example.com/p?mc_eid=1&mc_cid=2&ref=newsletter", "http://example.com/p?ref=newsletter"),
    ("https://example.com/p?_ga=2.1.2&_gl=1*abc", "https://example.com/p"),
    ("https://example.com/p?a=1&&b=2&ttclid=9", "https://example.com/p?a=1&&b=2"),
    ("https://example.com/p?%75tm_source=encoded&keep=1", "https://example.com/p?keep=1")
])
func removesOnlyNamedTrackingParameters(input: String, expected: String) {
    #expect(strip(input) == expected)
}

@Test(arguments: [
    "https://example.com/",
    "https://example.com/a?id=7&page=2",
    "https://example.com/?utmost=1",
    "https://example.com/?my_utm_source=1",
    "https://example.com/?gclid_extra=1",
    "https://example.com/?ref=utm_source",
    "https://example.com/?q=fbclid",
    "ftp://example.com/?utm_source=x",
    "file:///tmp/a?utm_source=x",
    "mailto:someone@example.com?subject=utm_source"
])
func leavesEverythingElseUntouched(input: String) {
    #expect(strip(input) == nil)
}

@Test(arguments: [
    "https://idp.example/authorize?client_id=abc&redirect_uri=https%3A%2F%2Fapp.example%2Fcb%3Futm_source%3Dx&utm_source=y",
    "https://idp.example/oauth?response_type=code&utm_campaign=z",
    "https://sso.example/saml?SAMLRequest=abc&RelayState=https%3A%2F%2Fa&utm_source=x",
    "https://login.example/?code_challenge=xyz&gclid=1",
    "https://login.example/?id_token=abc&fbclid=1"
])
func signInFlowsAreNeverModified(input: String) {
    #expect(strip(input) == nil)
}

@Test
func strippingIsIdempotentAndKeepsOrderAndEncoding() throws {
    let input = "https://example.com/p?b=%C3%A9&utm_source=x&a=1+2&gclid=9&c="
    let once = try #require(strip(input))
    #expect(once == "https://example.com/p?b=%C3%A9&a=1+2&c=")
    #expect(strip(once) == nil)
}
