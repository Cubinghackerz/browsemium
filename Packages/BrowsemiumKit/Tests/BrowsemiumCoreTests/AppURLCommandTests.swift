import BrowsemiumCore
import Foundation
import Testing

private func parse(_ string: String) -> Result<AppURLCommand, AppURLCommand.ParseError> {
    AppURLCommand.parse(URL(string: string)!)
}

@Test
func openSearchAndSpaceLinksParse() {
    #expect(parse("browsemium://open?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1") == .success(.open(URL(string: "https://example.com/a?b=1")!)))
    #expect(parse("browsemium://search?q=swift%20actors") == .success(.search("swift actors")))
    #expect(parse("browsemium://space?name=Work") == .success(.switchSpace(name: "Work")))
    #expect(parse("BROWSEMIUM://SEARCH?q=x") == .success(.search("x")))
}

@Test
func builtLinksParseBackToTheSameCommand() {
    let commands: [AppURLCommand] = [
        .open(URL(string: "https://example.com/path?x=1&y=two words#frag")!),
        .search("what is a monad? (really) & why"),
        .switchSpace(name: "Reading & Research")
    ]
    for command in commands {
        #expect(AppURLCommand.parse(command.url) == .success(command))
    }
}

@Test(arguments: [
    "browsemium://open?url=javascript%3Aalert(1)",
    "browsemium://open?url=file%3A%2F%2F%2Fetc%2Fpasswd",
    "browsemium://open?url=data%3Atext%2Fhtml%2C%3Cb%3E",
    "browsemium://open?url=about%3Ablank",
    "browsemium://open?url=https%3A%2F%2F",
    "browsemium://open?url=not%20a%20url",
    "browsemium://open?url=browsemium%3A%2F%2Fsearch%3Fq%3Dx"
])
func openOnlyAcceptsOrdinaryWebAddresses(link: String) {
    #expect(parse(link) == .failure(.invalidURL))
}

@Test
func addressesWithCredentialsAreRefused() {
    #expect(parse("browsemium://open?url=https%3A%2F%2Fuser%3Apw%40example.com%2F") == .failure(.credentialsNotAllowed))
}

@Test
func missingAndRepeatedParametersAreRefused() {
    #expect(parse("browsemium://open") == .failure(.missingParameter("url")))
    #expect(parse("browsemium://search") == .failure(.missingParameter("q")))
    #expect(parse("browsemium://search?q=") == .failure(.missingParameter("q")))
    #expect(parse("browsemium://search?q=%20%20") == .failure(.missingParameter("q")))
    #expect(parse("browsemium://space") == .failure(.missingParameter("name")))
    #expect(parse("browsemium://search?q=a&q=b") == .failure(.duplicateParameter("q")))
}

@Test
func everythingThatIsNotNavigationIsUnknown() {
    for command in ["private", "ask", "ai", "grant", "agent", "delete", "clear", "export", "settings", "read", "tabs"] {
        #expect(parse("browsemium://\(command)?x=1") == .failure(.unknownCommand(command)), "\(command) must not exist")
    }
    #expect(parse("https://example.com/") == .failure(.wrongScheme))
    #expect(parse("browsemium://") == .failure(.unknownCommand("")))
}

@Test
func oversizedLinksAndParametersAreRefused() {
    let long = String(repeating: "a", count: 9_000)
    #expect(parse("browsemium://search?q=\(long)") == .failure(.tooLong))
    let mid = String(repeating: "a", count: AppURLCommand.maximumSearchLength + 1)
    #expect(parse("browsemium://search?q=\(mid)") == .failure(.tooLongParameter("q")))
    let name = String(repeating: "n", count: AppURLCommand.maximumSpaceNameLength + 1)
    #expect(parse("browsemium://space?name=\(name)") == .failure(.tooLongParameter("name")))
}

@Test
func everyFailureHasAPlainMessage() {
    let failures: [AppURLCommand.ParseError] = [
        .wrongScheme, .tooLong, .unknownCommand("x"), .missingParameter("q"),
        .duplicateParameter("q"), .invalidURL, .credentialsNotAllowed, .tooLongParameter("q")
    ]
    for failure in failures { #expect(failure.message.hasSuffix(".")) }
}
