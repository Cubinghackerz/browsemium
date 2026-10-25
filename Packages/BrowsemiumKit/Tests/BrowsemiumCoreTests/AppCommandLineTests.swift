import BrowsemiumCore
import Foundation
import Testing

@Test
func theToolBuildsTheSameLinksTheAppParses() {
    #expect(AppCommandLine.interpret(["open", "https://example.com/a?b=1"]) == .send(AppURLCommand.open(URL(string: "https://example.com/a?b=1")!).url))
    #expect(AppCommandLine.interpret(["search", "swift", "actors"]) == .send(AppURLCommand.search("swift actors").url))
    #expect(AppCommandLine.interpret(["space", "Reading", "List"]) == .send(AppURLCommand.switchSpace(name: "Reading List").url))
}

@Test
func badRequestsFailHereWithAMessageAndAStatus() {
    func failure(_ arguments: [String]) -> (String, Int32)? {
        if case .failure(let message, let status) = AppCommandLine.interpret(arguments) { return (message, status) }
        return nil
    }
    #expect(failure([])?.1 == 64)
    #expect(failure(["bogus"])?.1 == 64)
    #expect(failure(["open"])?.1 == 64)
    #expect(failure(["open", "a", "b"])?.1 == 64)
    #expect(failure(["search"])?.1 == 64)
    #expect(failure(["space"])?.1 == 64)
    // Not a web address, or one the app would refuse.
    #expect(failure(["open", "javascript:alert(1)"])?.1 == 65)
    #expect(failure(["open", "file:///etc/passwd"])?.1 == 65)
    #expect(failure(["open", "https://user:pw@example.com/"])?.1 == 65)
    #expect(failure(["search", String(repeating: "a", count: 2_001)])?.1 == 65)
}

@Test
func helpAndVersionPrintAndSucceed() {
    for flag in ["--help", "-h", "help"] {
        if case .info(let text) = AppCommandLine.interpret([flag]) { #expect(text.contains("only navigate")) } else { Issue.record("no help for \(flag)") }
    }
    #expect(AppCommandLine.interpret(["--version"]) == .info("browsemium-ctl \(AppCommandLine.version)"))
}

@Test
func theUsageDocumentsNoCommandBeyondNavigation() {
    for word in ["ask", "grant", "private", "delete", "export", "read"] {
        #expect(!AppCommandLine.usage.contains("\n  \(word) "))
    }
}
