import BrowsemiumCore
import Foundation
import Testing

private let work = SpaceID()
private let personal = SpaceID()

private func normalized(_ input: String, subdomains: Bool = false) -> String? {
    if case .success(let host) = SpaceRouteHost.normalize(input, includesSubdomains: subdomains) { return host }
    return nil
}

private func failure(_ input: String, subdomains: Bool = false) -> SpaceRouteHostError? {
    if case .failure(let error) = SpaceRouteHost.normalize(input, includesSubdomains: subdomains) { return error }
    return nil
}

@Test
func hostNormalizationLowercasesAndTrims() {
    #expect(normalized("  GitHub.COM ") == "github.com")
    #expect(normalized("github.com.") == "github.com")
    #expect(normalized("bücher.example") == "xn--bcher-kva.example")
}

@Test
func hostNormalizationRejectsEverythingAmbiguous() {
    #expect(failure("") == .empty)
    #expect(failure("   ") == .empty)
    #expect(failure("https://github.com") == .containsScheme)
    #expect(failure("github.com:8443") == .containsPort)
    #expect(failure("github.com/work") == .containsPath)
    #expect(failure("github.com?x=1") == .containsPath)
    #expect(failure("user@github.com") == .containsCredentials)
    #expect(failure("*.github.com") == .wildcard)
    #expect(failure("git*hub.com") == .wildcard)
    #expect(failure(".github.com") == .invalid)
    #expect(failure("github..com") == .invalid)
    #expect(failure("git hub.com") == .invalid)
    #expect(failure("-bad.example") == .invalid)
    #expect(failure("under_score.example") == .invalid)
}

@Test
func subdomainRulesNeedARegistrableDomain() {
    #expect(failure("com", subdomains: true) == .needsRegistrableDomain)
    #expect(normalized("com", subdomains: false) == "com")
    #expect(normalized("example.com", subdomains: true) == "example.com")
}

@Test
func exactRulesDoNotMatchSubdomainsOrSiblings() {
    let routes = [SpaceRoute(host: "github.com", spaceID: work)]
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://github.com/a")!, in: routes)?.spaceID == work)
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://gist.github.com/a")!, in: routes) == nil)
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://notgithub.com/")!, in: routes) == nil)
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://github.com.evil.example/")!, in: routes) == nil)
}

@Test
func subdomainRulesMatchOnLabelBoundariesOnly() {
    let routes = [SpaceRoute(host: "github.com", includesSubdomains: true, spaceID: work)]
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://gist.github.com/")!, in: routes)?.spaceID == work)
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://a.b.github.com/")!, in: routes)?.spaceID == work)
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://evilgithub.com/")!, in: routes) == nil)
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://github.com.evil.example/")!, in: routes) == nil)
}

@Test
func exactBeatsSubdomainAndLongerSuffixBeatsShorter() {
    let routes = [
        SpaceRoute(host: "example.com", includesSubdomains: true, spaceID: personal),
        SpaceRoute(host: "app.example.com", includesSubdomains: true, spaceID: work),
        SpaceRoute(host: "app.example.com", includesSubdomains: false, spaceID: personal)
    ]
    // Exact beats the subdomain rule for the same host.
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://app.example.com/")!, in: routes)?.spaceID == personal)
    // A longer subdomain suffix beats a shorter one.
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://x.app.example.com/")!, in: routes)?.spaceID == work)
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://www.example.com/")!, in: routes)?.spaceID == personal)
}

@Test
func equalRulesResolveByAgeNotByOrder() {
    let older = SpaceRoute(host: "example.com", spaceID: work, createdAt: Date(timeIntervalSince1970: 1))
    let newer = SpaceRoute(host: "example.com", spaceID: personal, createdAt: Date(timeIntervalSince1970: 2))
    let url = URL(string: "https://example.com/")!
    #expect(SpaceRouteMatcher.route(for: url, in: [newer, older])?.spaceID == work)
    #expect(SpaceRouteMatcher.route(for: url, in: [older, newer])?.spaceID == work)
}

@Test
func onlyOrdinaryHTTPPagesAreRoutable() {
    let routes = [SpaceRoute(host: "example.com", spaceID: work)]
    #expect(SpaceRouteMatcher.route(for: URL(string: "http://example.com/")!, in: routes) != nil)
    #expect(SpaceRouteMatcher.route(for: URL(string: "ftp://example.com/")!, in: routes) == nil)
    #expect(SpaceRouteMatcher.route(for: URL(string: "file:///tmp/example.com")!, in: routes) == nil)
    #expect(SpaceRouteMatcher.route(for: URL(string: "about:blank")!, in: routes) == nil)
    // Case and the absolute-name trailing dot do not defeat a rule.
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://EXAMPLE.com./")!, in: routes) != nil)
    // A port or credentials in the URL do not change which host it is.
    #expect(SpaceRouteMatcher.route(for: URL(string: "https://example.com:8443/")!, in: routes) != nil)
}
