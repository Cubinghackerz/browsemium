import BrowsemiumCore
import Foundation
import Testing

@Suite("Agent origins and tasks")
struct AgentModelsTests {
    @Test(arguments: [
        ("https://example.com", "https://example.com"),
        ("https://EXAMPLE.com", "https://example.com"),
        ("https://example.com:443", "https://example.com"),
        ("http://example.com:80", "http://example.com"),
        ("https://example.com:8443", "https://example.com:8443"),
        ("https://example.com/path?q=1#frag", "https://example.com"),
        ("http://127.0.0.1:8080/x", "http://127.0.0.1:8080")
    ])
    func originsNormalizeToSchemeHostAndNonDefaultPort(input: String, expected: String) throws {
        let origin = try AgentOrigin(try #require(URL(string: input)))
        #expect(origin.description == expected)
    }

    @Test(arguments: [
        "ftp://example.com", "file:///etc/hosts", "javascript:alert(1)", "data:text/html,x",
        "blob:https://example.com/id", "https://user@example.com", "https://user:pw@example.com",
        "https://example.com.", "https://exa mple.com", "https://exa%6Dple.com", "https://-.", "https://",
        "about:blank", "https://example.com:0", "https://example.com:70000"
    ])
    func unusableOriginsAreRefused(input: String) {
        guard let url = URL(string: input) else { return }
        #expect(throws: AgentError.self) { _ = try AgentOrigin(url) }
    }

    @Test func ipv6OriginsRoundTripWithBrackets() throws {
        let origin = try AgentOrigin(string: "http://[::1]:8080")
        #expect(origin.description == "http://[::1]:8080")
        #expect(origin.host == "::1")
    }

    @Test func differentSpellingsOfOneHostAreEqual() throws {
        let a = try AgentOrigin(try #require(URL(string: "HTTPS://Example.COM:443/a")))
        let b = try AgentOrigin(try #require(URL(string: "https://example.com/b")))
        #expect(a == b)
        #expect(a != (try AgentOrigin(string: "http://example.com")))
        #expect(a != (try AgentOrigin(string: "https://www.example.com")))
    }

    @Test func decodingRequiresACanonicalOrigin() throws {
        let decoder = JSONDecoder()
        let ok = try decoder.decode([AgentOrigin].self, from: Data(#"["https://example.com"]"#.utf8))
        #expect(ok.first?.description == "https://example.com")
        for bad in [#"["https://example.com/"]"#, #"["https://EXAMPLE.com"]"#, #"["https://example.com:443"]"#,
                    #"["https://example.com/a"]"#, #"["javascript:1"]"#, #"[""]"#, #"["*.example.com"]"#] {
            #expect(throws: (any Error).self, "\(bad) should not decode") {
                _ = try decoder.decode([AgentOrigin].self, from: Data(bad.utf8))
            }
        }
    }

    @Test func encodingIsTheCanonicalString() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let origin = try AgentOrigin(string: "https://example.com:8443")
        let data = try encoder.encode([origin])
        #expect(String(decoding: data, as: UTF8.self) == #"["https://example.com:8443"]"#)
        #expect(try JSONDecoder().decode([AgentOrigin].self, from: data) == [origin])
    }

    private func task(
        title: String = "Book a table",
        client: String = "Claude",
        origins: Set<AgentOrigin>? = nil,
        capabilities: Set<AgentCapability> = [.read, .navigate]
    ) throws -> AgentTask {
        try AgentTask(
            clientID: UUID(),
            clientName: client,
            title: title,
            profileID: UUID(),
            dataStoreID: UUID(),
            origins: origins ?? [try AgentOrigin(string: "https://example.com")],
            capabilities: capabilities
        )
    }

    @Test func aTaskNeedsReadAndNavigateAndBetweenOneAndEightOrigins() throws {
        _ = try task()
        #expect(throws: AgentError.invalidArguments) { _ = try task(capabilities: [.read]) }
        #expect(throws: AgentError.invalidArguments) { _ = try task(capabilities: [.navigate]) }
        #expect(throws: AgentError.invalidArguments) { _ = try task(origins: []) }
        let nine = try Set((0..<9).map { try AgentOrigin(string: "https://h\($0).example.com") })
        #expect(throws: AgentError.invalidArguments) { _ = try task(origins: nine) }
        let eight = try Set((0..<8).map { try AgentOrigin(string: "https://h\($0).example.com") })
        _ = try task(origins: eight)
    }

    @Test func clientSuppliedTextCannotSpoofANativePrompt() throws {
        #expect(throws: AgentError.invalidArguments) { _ = try task(title: "   ") }
        #expect(throws: AgentError.invalidArguments) { _ = try task(title: "Pay\nApprove all") }
        #expect(throws: AgentError.invalidArguments) { _ = try task(client: "Safari\u{202E}") }
        #expect(throws: AgentError.invalidArguments) { _ = try task(client: "A\u{0007}B") }
        #expect(throws: AgentError.invalidArguments) { _ = try task(title: String(repeating: "t", count: 161)) }
        #expect(throws: AgentError.invalidArguments) { _ = try task(client: String(repeating: "c", count: 101)) }
        #expect(try task(title: "  Compare prices  ").title == "Compare prices")
    }

    @Test func eachTaskGetsItsOwnIdentityAndSpace() throws {
        let a = try task(), b = try task()
        #expect(a.id != b.id)
        #expect(a.spaceID != b.spaceID)
    }

    @Test func onlyLiveStatesHoldAuthority() {
        let live: [AgentTaskState] = [.waiting, .ready, .reading, .acting]
        let dead: [AgentTaskState] = [.paused, .finished, .stopped]
        #expect(live.allSatisfy { $0.hasAuthority })
        #expect(dead.allSatisfy { !$0.hasAuthority })
    }

    @Test func errorsNeverCarryPageText() {
        let all: [AgentError] = [.invalidArguments, .invalidOrigin, .denied, .declined, .expired, .busy,
                                 .staleElement, .sensitiveField, .tabLimit, .unavailable]
        #expect(all.allSatisfy { $0.errorDescription?.isEmpty == false })
    }
}
