import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import Testing

private final class FakeFetcher: PageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String: Result<FetchedPage, PageFetchError>] = [:]
    private(set) var fetched: [URL] = []

    func set(_ url: String, html: String, finalURL: String? = nil) {
        lock.withLock { pages[url] = .success(FetchedPage(finalURL: URL(string: finalURL ?? url)!, html: html)) }
    }
    func fail(_ url: String, _ error: PageFetchError) { lock.withLock { pages[url] = .failure(error) } }

    func fetch(_ url: URL) async throws -> FetchedPage {
        let result = lock.withLock { () -> Result<FetchedPage, PageFetchError>? in
            fetched.append(url)
            return pages[url.absoluteString]
        }
        switch result {
        case .success(let page): return page
        case .failure(let error): throw error
        case .none: throw PageFetchError.network
        }
    }
}

private final class FakeNotifier: ChangeNotifying, @unchecked Sendable {
    private let lock = NSLock()
    var allows = true
    private(set) var sent: [(title: String, body: String)] = []
    func requestAuthorization() async -> Bool { allows }
    func notify(title: String, body: String, identifier: String) async { lock.withLock { sent.append((title, body)) } }
}

private final class Clock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(minutes: Double) { date.addTimeInterval(minutes * 60) }
}

/// The controller holds its environment weakly (the environment owns it), so
/// tests keep each environment alive for the length of the run.
@MainActor private var liveEnvironments: [BrowserEnvironment] = []

@MainActor
private func make() -> (PageWatchController, FakeFetcher, FakeNotifier, Clock) {
    let environment = BrowserEnvironment.inMemory(engine: StubEngine())
    liveEnvironments.append(environment)
    let fetcher = FakeFetcher(), notifier = FakeNotifier(), clock = Clock()
    let controller = environment.pageWatches
    controller.configure(fetcher: fetcher, notifier: notifier, now: { clock.date })
    return (controller, fetcher, notifier, clock)
}

private let page = "https://shop.example/tickets"

@Test @MainActor
func theFirstCheckIsABaselineAndTheNextChangeNotifies() async throws {
    let (controller, fetcher, notifier, clock) = make()
    fetcher.set(page, html: "<p>Tickets are on sale now. Doors open at nine.</p>")
    _ = await controller.watch(url: URL(string: page)!, title: "Tickets")
    #expect(notifier.sent.isEmpty, "The first look only records what is there")
    #expect(controller.watches.first?.lastHash != nil)

    // Not due yet: no fetch, no alert.
    clock.advance(minutes: 10)
    await controller.checkDue()
    #expect(fetcher.fetched.count == 1)

    // Unchanged after the interval: checked, silent.
    clock.advance(minutes: 60)
    await controller.checkDue()
    #expect(fetcher.fetched.count == 2)
    #expect(notifier.sent.isEmpty)

    // A real change notifies once, quoting the new text.
    fetcher.set(page, html: "<p>Tickets are sold out for Saturday. Doors open at nine.</p>")
    clock.advance(minutes: 61)
    await controller.checkDue()
    #expect(notifier.sent.count == 1)
    #expect(notifier.sent.first?.body.contains("sold out for Saturday") == true)
    #expect(controller.watches.first?.lastChangedAt != nil)

    // The same page again: nothing new to say.
    clock.advance(minutes: 61)
    await controller.checkDue()
    #expect(notifier.sent.count == 1)
}

@Test @MainActor
func aSignInPageIsReportedAndNeverMistakenForAChange() async throws {
    let (controller, fetcher, notifier, clock) = make()
    fetcher.set(page, html: "<p>Order history for you today.</p>")
    _ = await controller.watch(url: URL(string: page)!, title: "Orders")
    fetcher.set(page, html: "<form><input type=\"password\"></form>")
    clock.advance(minutes: 61)
    await controller.checkDue()

    #expect(notifier.sent.isEmpty)
    #expect(controller.watches.first?.lastProblem?.contains("sign-in") == true)
    #expect(controller.watches.first?.consecutiveFailures == 1)

    // A redirect to another site is treated the same way.
    fetcher.set(page, html: "<p>Welcome back to somewhere else.</p>", finalURL: "https://accounts.other.example/login")
    clock.advance(minutes: 200)
    await controller.checkDue()
    #expect(controller.watches.first?.lastProblem?.contains("another site") == true)
    #expect(notifier.sent.isEmpty)
}

@Test @MainActor
func repeatedFailuresBackOffAndThenPause() async throws {
    let (controller, fetcher, _, clock) = make()
    fetcher.set(page, html: "<p>Something to watch on this page.</p>")
    _ = await controller.watch(url: URL(string: page)!, title: "T", intervalMinutes: 15)
    fetcher.fail(page, .network)

    var checks = fetcher.fetched.count
    for _ in 0..<PageWatchLimits.maximumConsecutiveFailures + 3 {
        clock.advance(minutes: 24 * 60)
        await controller.checkDue()
    }
    checks = fetcher.fetched.count - checks
    #expect(checks == PageWatchLimits.maximumConsecutiveFailures, "Stops asking once paused")
    #expect(controller.watches.first?.lastProblem?.contains("Paused") == true)

    // Choosing a new interval brings it back.
    controller.setInterval(60, for: try #require(controller.watches.first))
    fetcher.set(page, html: "<p>Something to watch on this page.</p>")
    clock.advance(minutes: 61)
    await controller.checkDue()
    #expect(controller.watches.first?.lastProblem == nil)
}

@Test @MainActor
func disabledNotificationsAreSaidOutLoud() async {
    let (controller, fetcher, notifier, _) = make()
    notifier.allows = false
    fetcher.set(page, html: "<p>Content content content here.</p>")
    let message = await controller.watch(url: URL(string: page)!, title: "T")
    #expect(message.contains("notifications are off"))
}

@Test @MainActor
func removingTheLastWatchStopsEverythingAndFragmentsDoNotDuplicate() async {
    let (controller, fetcher, _, _) = make()
    fetcher.set(page, html: "<p>Content content content here.</p>")
    _ = await controller.watch(url: URL(string: page + "#a")!, title: "T")
    _ = await controller.watch(url: URL(string: page + "#b")!, title: "T")
    #expect(controller.watches.count == 1)
    controller.remove(controller.watches[0])
    #expect(controller.watches.isEmpty)
}

@Test @MainActor
func privateWindowsAndHTTPPagesCannotStartAWatch() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    let tab = model.session.activeTabID!
    engine.emit(.committed(URL(string: "http://plain.example/")!), for: tab)
    model.watchActivePage()
    #expect(model.statusMessage?.contains("https") == true)

    model.enterPrivateMode()
    model.watchActivePage()
    #expect(model.statusMessage == "Pages are not watched from a private window.")
    #expect(model.environment.pageWatches.watches.isEmpty)
}
