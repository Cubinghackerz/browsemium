import BrowsemiumCore
import BrowsemiumEngine
import BrowsemiumEngineKit
import Foundation
import Testing

@MainActor
private func makeRuntime() -> TabRuntime {
    TabRuntime(tabID: TabID(), isPrivate: true, factory: WebViewFactory(),
               captureService: ContentCaptureService(), downloadCoordinator: DownloadCoordinator())
}

@Test @MainActor
func failedNavigationKeepsCommittedPageActive() {
    let runtime = makeRuntime()
    let page = URL(string: "https://fixture.example/page")!
    runtime.report(.committed(page))
    runtime.report(.finished(title: "Fixture", url: page))
    runtime.report(.startedLoading(URL(string: "https://offline.example")))
    runtime.report(.failed("The Internet connection appears to be offline."))

    #expect(runtime.lifecycle == .active)
    #expect(runtime.lastCommittedURL == page)
    runtime.report(.crashed)
    #expect(runtime.lifecycle == .crashed)
}

@Test @MainActor
func contentProcessTerminationStillMarksRuntimeCrashed() {
    let runtime = makeRuntime()
    runtime.report(.finished(title: "Fixture", url: URL(string: "https://fixture.example")))
    runtime.report(.crashed)
    #expect(runtime.lifecycle == .crashed)
}

@Test @MainActor
func firstNavigationFailureLeavesMetadataOnly() {
    let runtime = makeRuntime()
    runtime.report(.startedLoading(URL(string: "https://offline.example")))
    runtime.report(.failed("Offline"))
    #expect(runtime.lifecycle == .metadataOnly)
}
