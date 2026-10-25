import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngineKit
import Foundation
import Observation
import UserNotifications

public protocol ChangeNotifying: Sendable {
    func requestAuthorization() async -> Bool
    func notify(title: String, body: String, identifier: String) async
}

public struct UserNotificationNotifier: ChangeNotifying {
    public init() {}

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func notify(title: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Tells the person when a page they chose to watch has changed.
///
/// It only runs while Browsemium is open, and says so. It never reads a
/// private window, never carries the browser's cookies, and keeps no page
/// text: only a hash and sentence fingerprints, so it can say what is new.
@MainActor
@Observable
public final class PageWatchController {
    public private(set) var watches: [PageWatch] = []
    /// A plain-language note about the last add or check, for Settings.
    public private(set) var notice: String?

    @ObservationIgnored private weak var environment: BrowserEnvironment?
    /// The active profile's repository; nil only if the environment is gone.
    private var repository: PageWatchRepository? { environment?.pageWatchRepository }

    private func requireRepository() throws -> PageWatchRepository {
        guard let repository else { throw BrowsemiumError.databaseFailure("Browsemium is closing.") }
        return repository
    }
    @ObservationIgnored var fetcher: any PageFetching = EphemeralPageFetcher()
    @ObservationIgnored var notifier: any ChangeNotifying = UserNotificationNotifier()
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var runsLoop = true

    /// How often a running app looks for watches that are due.
    public static let tickInterval: Duration = .seconds(5 * 60)

    init(environment: BrowserEnvironment) {
        self.environment = environment
        reload()
    }

    // Test seams.
    /// `runsLoop: false` keeps the background timer off so a test drives
    /// every check itself.
    public func configure(
        fetcher: any PageFetching,
        notifier: any ChangeNotifying,
        now: @escaping () -> Date = { Date() },
        runsLoop: Bool = false
    ) {
        self.fetcher = fetcher
        self.notifier = notifier
        self.now = now
        self.runsLoop = runsLoop
    }

    /// A different profile has its own watches.
    func profileDidChange() {
        stop()
        reload()
        start()
    }

    public func reload() {
        watches = (try? repository?.all()) ?? []
    }

    /// Starts watching a page. Returns a plain-language result.
    @discardableResult
    public func watch(url: URL, title: String, intervalMinutes: Int = PageWatchLimits.defaultIntervalMinutes) async -> String {
        do {
            let watch = try requireRepository().add(url: url, title: title, intervalMinutes: intervalMinutes, now: now())
            reload()
            let allowed = await notifier.requestAuthorization()
            let host = watch.url.host ?? "the page"
            let message = allowed
                ? "Watching \(host). You will be told when it changes, while Browsemium is open."
                : "Watching \(host), but notifications are off in System Settings, so you will not be told."
            notice = message
            // The first look records a baseline right away; the timer takes over after.
            await checkDue()
            start()
            return message
        } catch {
            let message = error.localizedDescription
            notice = message
            return message
        }
    }

    public func remove(_ watch: PageWatch) {
        do {
            try requireRepository().remove(id: watch.id)
            reload()
            if watches.isEmpty { stop() }
        } catch {
            notice = error.localizedDescription
        }
    }

    public func setInterval(_ minutes: Int, for watch: PageWatch) {
        do {
            try requireRepository().setInterval(minutes: minutes, id: watch.id)
            reload()
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: - Running

    /// Safe to call repeatedly; does nothing without watches.
    public func start() {
        guard runsLoop, loop == nil, !watches.isEmpty else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkDue()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Checks every watch whose time has come. One check at a time.
    public func checkDue() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        reload()
        for watch in PageWatchSchedule.due(watches, now: now()) {
            guard !Task.isCancelled else { return }
            await check(watch)
        }
        reload()
    }

    func check(_ original: PageWatch) async {
        var watch = original
        watch.lastCheckedAt = now()
        do {
            let page = try await fetcher.fetch(watch.url)
            guard Self.sameSite(page.finalURL, watch.url) else {
                try fail(&watch, "It redirected to another site, probably a sign-in.")
                return
            }
            if PageTextNormalizer.looksLikeSignIn(html: page.html) {
                try fail(&watch, "It asks for a sign-in. Watches only see what a signed-out visitor sees.")
                return
            }
            let text = PageTextNormalizer.visibleText(fromHTML: page.html)
            let hash = PageTextNormalizer.hash(text)
            let sentences = PageWatchDiff.sentenceHashes(text)
            var snippet: String?
            if let previous = watch.lastHash, previous != hash {
                snippet = PageWatchDiff.change(previous: watch.lastSentences, newText: text)
            }
            if snippet != nil { watch.lastChangedAt = now() }
            watch.lastHash = hash
            watch.lastSentences = sentences
            watch.consecutiveFailures = 0
            watch.lastProblem = nil
            try requireRepository().recordCheck(watch)
            if let snippet {
                await notifier.notify(
                    title: "Page changed",
                    body: "\(watch.title.isEmpty ? (watch.url.host ?? "A page") : watch.title): \(snippet)",
                    identifier: "page-watch-\(watch.id.uuidString)"
                )
            }
        } catch {
            try? fail(&watch, Self.describe(error))
        }
    }

    private func fail(_ watch: inout PageWatch, _ problem: String) throws {
        watch.consecutiveFailures += 1
        watch.lastProblem = watch.consecutiveFailures >= PageWatchLimits.maximumConsecutiveFailures
            ? problem + " Paused after repeated failures."
            : problem
        try requireRepository().recordCheck(watch)
    }

    private static func sameSite(_ a: URL, _ b: URL) -> Bool {
        guard let first = a.host, let second = b.host else { return false }
        return RegistrableDomain.of(host: first) == RegistrableDomain.of(host: second)
    }

    private static func describe(_ error: Error) -> String {
        switch error as? PageFetchError {
        case .notHTTPS: "Only https pages can be watched."
        case .badStatus(let code): "The site answered with status \(code)."
        case .notText: "That address is not a web page."
        case .tooLarge: "The page is too large to watch."
        case .network, .none: "Couldn't load the page."
        }
    }
}
