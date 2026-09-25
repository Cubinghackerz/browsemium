import BrowsemiumCore
import BrowsemiumEngine
import Foundation
import Testing
import BrowsemiumEngineKit

private let resolver = NavigationResolver()

@Test
func trimsSpacesAroundDomain() throws {
    let request = try resolver.resolve("  example.com/path?q=swift  \n")
    #expect(request.url.absoluteString == "https://example.com/path?q=swift")
}

@Test
func unicodeQueryUsesSearchURL() throws {
    let request = try resolver.resolve("café browser")
    let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
    #expect(components.host == "www.google.com")
    #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == "café browser")
}

@Test
func localhostPortPreservesPath() throws {
    let request = try resolver.resolve("localhost:8080/settings?tab=privacy")
    #expect(request.url.absoluteString == "https://localhost:8080/settings?tab=privacy")
}

@Test
func explicitHTTPSIsPreserved() throws {
    let request = try resolver.resolve("HTTPS://example.com/secure")
    #expect(request.url.scheme?.lowercased() == "https")
    #expect(request.url.host == "example.com")
    #expect(request.url.path == "/secure")
}

@Test(arguments: ["javascript:alert(1)", "data:text/plain,hello", "file:///tmp/file"])
func blockedSchemes(_ value: String) {
    do {
        _ = try resolver.resolve(value)
        Issue.record("Expected a blocked scheme error")
    } catch let error as BrowsemiumError {
        guard case .blockedScheme = error else {
            Issue.record("Expected blockedScheme, got \(error)")
            return
        }
    } catch {
        Issue.record(error)
    }
}

@Test
func credentialsAreRejected() {
    do {
        _ = try resolver.resolve("https://user:secret@example.com")
        Issue.record("Expected credentials to be rejected")
    } catch let error as BrowsemiumError {
        #expect(error == .credentialsNotAllowed)
    } catch {
        Issue.record(error)
    }

    #expect(throws: Error.self) {
        try resolver.resolve("user:secret@example.com")
    }
}

@Test
func emptyInputIsRejected() {
    do {
        _ = try resolver.resolve(" \n\t ")
        Issue.record("Expected empty input to be rejected")
    } catch let error as BrowsemiumError {
        #expect(error == .emptyNavigationInput)
    } catch {
        Issue.record(error)
    }
}

@Test
func resolveDetailFlagsSearches() throws {
    let search = try resolver.resolveDetail("what is ai")
    #expect(search.isSearch)
    #expect(search.request.url.host == "www.google.com")

    let direct = try resolver.resolveDetail("https://example.com/path")
    #expect(!direct.isSearch)
    #expect(direct.request.url.host == "example.com")
}

@Test
func malformedExplicitSchemeIsRejected() {
    do {
        _ = try resolver.resolve("https://")
        Issue.record("Expected malformed URL")
    } catch let error as BrowsemiumError {
        guard case .malformedURL = error else {
            Issue.record("Expected malformedURL, got \(error)")
            return
        }
    } catch {
        Issue.record(error)
    }
}
