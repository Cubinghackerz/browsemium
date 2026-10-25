import BrowsemiumCore
import Foundation
import Testing

@Test
func theCSSIsPulledFromAFencedBlockOrPlainCSS() {
    #expect(TweakAssistant.extractCSS(from: "Here you go:\n```css\n.ad { display: none }\n```\nEnjoy") == ".ad { display: none }")
    #expect(TweakAssistant.extractCSS(from: "```\nbody { margin: 0 }\n```") == "body { margin: 0 }")
    #expect(TweakAssistant.extractCSS(from: "```css\np { color: red }") == "p { color: red }")
    #expect(TweakAssistant.extractCSS(from: "p { color: red }") == "p { color: red }")
    #expect(TweakAssistant.extractCSS(from: "I cannot help with that.") == nil)
    #expect(TweakAssistant.extractCSS(from: "```css\n```") == nil)
}

@Test
func modelOutputGoesThroughTheSameValidatorAsHandWrittenCSS() throws {
    let hostile = try #require(TweakAssistant.extractCSS(from: "```css\na { background: url(https://evil.example/x) }\n```"))
    if case .success = SiteTweakValidator.validate(css: hostile) { Issue.record("a remote load must not pass") }
    let fine = try #require(TweakAssistant.extractCSS(from: "```css\n.promo { display: none !important }\n```"))
    if case .failure = SiteTweakValidator.validate(css: fine) { Issue.record("plain CSS must pass") }
}

@Test
func thePromptIsBoundedAndCarriesOnlyStructure() {
    let prompt = TweakAssistant.prompt(
        host: "news.example",
        description: String(repeating: "dark ", count: 200),
        outline: String(repeating: "div.x\n", count: 2_000)
    )
    #expect(prompt.contains("Page: news.example"))
    #expect(prompt.count < TweakAssistant.maximumOutlineCharacters + TweakAssistant.maximumDescriptionCharacters + 200)
    #expect(TweakAssistant.instructions.contains("url()"))
}

@Test
func theOutlineScriptIsFixedAndTextFree() {
    let script = TweakAssistant.outlineScript
    #expect(script.contains("el.children"))
    #expect(!script.contains("textContent"))
    #expect(!script.contains("innerText"))
    #expect(!script.contains("innerHTML"))
    #expect(!script.contains("value"))
}
