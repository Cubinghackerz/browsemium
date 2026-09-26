import BrowsemiumCore
@testable import BrowsemiumUI
import BrowsemiumEngineKit
import Foundation
import Testing

@MainActor
private func committedModel(
    engine: StubEngine,
    url: String = "https://news.example/story"
) -> (BrowserWindowModel, TabID) {
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    let tabID = model.session.activeTabID ?? TabID()
    // The picker only arms on a live tab, and the real engine's navigate()
    // is what makes one live; the stub needs the same fact set explicitly.
    engine.liveTabs.insert(tabID)
    engine.emit(.committed(URL(string: url)), for: tabID)
    return (model, tabID)
}

@Test @MainActor
func hidingAnElementSavesAHostScopedRule() {
    let engine = StubEngine()
    let (model, tabID) = committedModel(engine: engine)

    model.beginElementHiding()
    #expect(model.isPickingElement)
    #expect(engine.pickingTabs == [tabID])

    engine.emit(.elementPicked(ElementPick(selector: "#promo", label: "div#promo", matchCount: 1)), for: tabID)
    #expect(model.pendingElementPick?.selector == "#promo")
    #expect(model.isSiteShieldPresented)

    model.confirmElementHiding()

    #expect(model.pendingElementPick == nil)
    let rules = model.cosmeticRules(for: "news.example")
    #expect(rules.map(\.selector) == ["#promo"])
    #expect(engine.cosmeticRules["news.example"]?.contains("#promo") == true)
}

@Test @MainActor
func cancellingAPickSavesNothing() {
    let engine = StubEngine()
    let (model, tabID) = committedModel(engine: engine)

    model.beginElementHiding()
    engine.emit(.elementPickCancelled, for: tabID)

    #expect(model.isPickingElement == false)
    #expect(model.pendingElementPick == nil)
    #expect(model.cosmeticRules(for: "news.example").isEmpty)
}

@Test @MainActor
func aPrivateWindowHidesWithoutPersisting() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    // Private mode swaps in its own tab, so the page is committed after it.
    model.enterPrivateMode()
    let tabID = model.session.activeTabID ?? TabID()
    engine.liveTabs.insert(tabID)
    engine.emit(.committed(URL(string: "https://news.example/story")), for: tabID)

    model.beginElementHiding()
    engine.emit(.elementPicked(ElementPick(selector: "#promo", label: "div#promo", matchCount: 1)), for: tabID)
    model.confirmElementHiding()

    // The rule works for this window and is not written anywhere: the
    // repository behind the model still has nothing.
    #expect(model.cosmeticRules(for: "news.example").map(\.selector) == ["#promo"])
    #expect(engine.cosmeticRules["news.example"]?.contains("#promo") == true)
    #expect(model.statusMessage == "Element hidden for this private window")
}

@Test @MainActor
func removingARuleShowsTheElementAgain() {
    let engine = StubEngine()
    let (model, tabID) = committedModel(engine: engine)
    model.beginElementHiding()
    engine.emit(.elementPicked(ElementPick(selector: "#promo", label: "div#promo", matchCount: 1)), for: tabID)
    model.confirmElementHiding()
    let rule = model.cosmeticRules(for: "news.example").first

    model.removeCosmeticRule(rule!)

    #expect(model.cosmeticRules(for: "news.example").isEmpty)
    #expect(engine.cosmeticRules["news.example"] == nil)
    #expect(model.statusMessage == "Element shown again")
}

@Test @MainActor
func disablingARuleRemovesItsCSSButKeepsTheRule() {
    let engine = StubEngine()
    let (model, tabID) = committedModel(engine: engine)
    model.beginElementHiding()
    engine.emit(.elementPicked(ElementPick(selector: "#promo", label: "div#promo", matchCount: 1)), for: tabID)
    model.confirmElementHiding()
    let rule = model.cosmeticRules(for: "news.example").first

    model.setCosmeticRuleEnabled(rule!, enabled: false)

    #expect(model.cosmeticRules(for: "news.example").count == 1)
    #expect(model.cosmeticRules(for: "news.example").first?.isEnabled == false)
    #expect(engine.cosmeticRules["news.example"] == nil)
}

@Test @MainActor
func pickingWithoutAPageExplainsItself() {
    let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))

    model.beginElementHiding()

    #expect(model.isPickingElement == false)
    #expect(model.statusMessage == "No page to pick an element from.")
}
