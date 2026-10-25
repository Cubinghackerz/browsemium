import BrowsemiumCore
import Foundation
import Testing

private func problem(_ css: String) -> SiteTweakProblem? {
    if case .failure(let problem) = SiteTweakValidator.validate(css: css) { return problem }
    return nil
}

@Test(arguments: [
    "body { background: #123; }",
    ".ad, [data-promo] { display: none !important; }",
    "a::after { content: \"\\201C quoted \\201D\"; }",
    "div { background: url(data:image/svg+xml;base64,AAAA) }",
    "div { background: url( 'data:image/png;base64,AAAA' ) }",
    "@media (prefers-color-scheme: dark) { body { filter: invert(1) } }",
    ".x { font: 14px/1.4 system-ui }",
    "/* url(https://evil.example) is only a comment */ p { margin: 0 }"
])
func ordinaryTweaksAreAccepted(css: String) {
    #expect(problem(css) == nil)
}

@Test(arguments: [
    "body { background: url(https://evil.example/x.png) }",
    "body { background: url('https://evil.example/x.png') }",
    "body { background: URL(\"//evil.example/x\") }",
    "body { background: url(  /relative/path.png  ) }",
    "@import url(https://evil.example/a.css);",
    "@import \"https://evil.example/a.css\";",
    "@IMPORT 'x.css';",
    "body { background: image-set(\"https://evil.example/a.png\" 1x) }",
    "body { background: -webkit-image-set(url(data:image/png;base64,AA) 1x, \"https://evil.example/b.png\" 2x) }",
    "body { cursor: url(https://evil.example/c.cur), auto }",
    "@font-face { font-family: x; src: url(https://evil.example/f.woff2) }",
    "a { content: src(\"https://evil.example\") }",
    // Escaped spellings of the same tokens.
    "body { background: u\\72l(https://evil.example/x.png) }",
    "body { background: \\75rl(https://evil.example/x.png) }",
    "body { background: \\000075\\72 l(https://evil.example/x.png) }",
    "@\\69mport url(x.css);",
    // A comment cannot split a token from its argument either.
    "body { background: url(/**/https://evil.example/x.png) }",
    // Mixed: one allowed data URL must not excuse a second, remote one.
    "a { background: url(data:image/png;base64,AA), url(https://evil.example/x) }"
])
func anythingThatCouldLoadFromTheNetworkIsRefused(css: String) {
    guard case .remoteLoad? = problem(css) else {
        Issue.record("accepted: \(css)")
        return
    }
}

@Test
func emptyAndOversizedTweaksAreRefused() {
    #expect(problem("") == .empty)
    #expect(problem("  \n\t ") == .empty)
    let huge = String(repeating: "a{}", count: SiteTweakValidator.maximumBytes)
    #expect(problem(huge) == .tooLarge(limit: SiteTweakValidator.maximumBytes))
}

@Test
func namesAreTrimmedDefaultedAndBounded() {
    #expect(SiteTweakValidator.validate(name: "  Dark header ") == .success("Dark header"))
    #expect(SiteTweakValidator.validate(name: "   ") == .success("Tweak"))
    #expect(SiteTweakValidator.validate(name: String(repeating: "n", count: 61)) == .failure(.nameTooLong))
}

@Test
func normalisingStripsCommentsDecodesEscapesAndFoldsCase() {
    #expect(SiteTweakValidator.normalise("A /* x */ B") == "a  b")
    #expect(SiteTweakValidator.normalise("\\75\\72\\6C") == "url")
    #expect(SiteTweakValidator.normalise("U\\52L(") == "url(")
    // An escape's optional trailing space is consumed, a lone backslash-char is that char.
    #expect(SiteTweakValidator.normalise("\\72 l") == "rl")
    #expect(SiteTweakValidator.normalise("\\g") == "g")
    // An unterminated comment swallows the rest, as CSS does.
    #expect(SiteTweakValidator.normalise("a /* b") == "a ")
}

@Test
func everyProblemHasAPlainMessage() {
    let problems: [SiteTweakProblem] = [.empty, .tooLarge(limit: 32768), .remoteLoad("url()"), .nameTooLong]
    for item in problems { #expect(item.message.hasSuffix(".")) }
}
