import Foundation
import Testing
@testable import BrowsemiumEngine

@Test
func chromeWebStoreGetsPreferredLanguageWhenMissing() throws {
    let original = try #require(URL(string: "https://chromewebstore.google.com/detail/example?id=1#reviews"))
    let rewritten = try #require(NavigationCompatibility.chromeWebStoreURL(
        from: original,
        preferredLanguages: ["en_AU"]
    ))
    let components = try #require(URLComponents(url: rewritten, resolvingAgainstBaseURL: false))
    #expect(components.queryItems?.first(where: { $0.name == "id" })?.value == "1")
    #expect(components.queryItems?.first(where: { $0.name == "hl" })?.value == "en-AU")
    #expect(components.fragment == "reviews")
}

@Test
func chromeWebStorePreservesExplicitLanguage() throws {
    let original = try #require(URL(string: "https://chromewebstore.google.com/?hl=eu"))
    #expect(NavigationCompatibility.chromeWebStoreURL(
        from: original,
        preferredLanguages: ["en-US"]
    ) == nil)
}

@Test(arguments: [
    "https://example.com/?q=extensions",
    "http://chromewebstore.google.com/",
    "https://chromewebstore.google.com/?HL=eu"
])
func chromeWebStoreRewriteDoesNotTouchUnsupportedURLs(_ value: String) throws {
    let url = try #require(URL(string: value))
    #expect(NavigationCompatibility.chromeWebStoreURL(
        from: url,
        preferredLanguages: []
    ) == nil)
}
