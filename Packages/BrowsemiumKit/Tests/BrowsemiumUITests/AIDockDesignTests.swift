import AppKit
import BrowsemiumCore
import Foundation
import SwiftUI
import Testing
@testable import BrowsemiumUI

@Suite @MainActor struct AIDockDesignTests {
    @Test func keyFieldHasRoomForItsTextAndFocusRing() {
        let host = NSHostingView(rootView: AIAPIKeyField(providerName: "ChatGPT", value: .constant("")).frame(width: 260))
        #expect(host.fittingSize.height >= 40)
    }

    @Test func reviewCannotStartWhileContextIsBeingPrepared() {
        #expect(!AIDockPresentation.reviewIsEnabled(canSend: true, isWorking: true))
        #expect(!AIDockPresentation.reviewIsEnabled(canSend: false, isWorking: false))
        #expect(AIDockPresentation.reviewIsEnabled(canSend: true, isWorking: false))
    }

    @Test func unavailablePagePromptDoesNotPromisePageContext() {
        #expect(AIDockPresentation.prompt(canUsePage: false) == "Ask a question…")
        #expect(AIDockPresentation.prompt(canUsePage: true) == "Ask a question about this page…")
    }

    @Test func regularWelcomeFitsMinimumDockTranscript() {
        let host = NSHostingView(rootView: AIDockWelcome(canUsePage: true, isWorking: false, run: { _ in })
            .frame(width: 360))
        #expect(host.fittingSize.height <= 280)
    }

    @Test func pageActionsExcludePrivateLockedUncommittedAndUnsupportedPages() throws {
        let engine = StubEngine()
        let model = BrowserWindowModel(environment: .inMemory(engine: engine))
        #expect(!AIDockPresentation.pageContextIsAvailable(in: model))
        let space = model.createGroup(named: "Locked fixture")
        let tab = model.newTab(url: URL(string: "https://fixture.invalid/article")!)
        engine.emit(.committed(URL(string: "https://fixture.invalid/article")!), for: tab)
        #expect(AIDockPresentation.pageContextIsAvailable(in: model))
        #expect(model.activeTab?.spaceID == space)
        model.setSpaceLocked(space, locked: true)
        #expect(model.isSpaceLocked(space))
        let lockedTabCanBeShared = model.canSharePageWithAI(tab)
        #expect(!lockedTabCanBeShared)
        let lockedContextIsAvailable = AIDockPresentation.pageContextIsAvailable(in: model)
        #expect(!lockedContextIsAvailable)
        model.setSpaceLocked(space, locked: false)
        model.enterPrivateMode()
        #expect(!AIDockPresentation.pageContextIsAvailable(in: model))
        let publicModel = BrowserWindowModel(environment: .inMemory(engine: engine))
        let unsupported = publicModel.newTab(url: URL(string: "about:blank")!)
        engine.emit(.committed(URL(string: "about:blank")!), for: unsupported)
        #expect(!AIDockPresentation.pageContextIsAvailable(in: publicModel))
    }

}
