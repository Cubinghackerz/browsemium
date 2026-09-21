import AppKit
import BrowsemiumCEF
import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation

/// One Chromium tab: the CEF browser, its Swift-side lifecycle, and the
/// translation between CEF's callbacks and the shared event vocabulary.
@MainActor
final class ChromiumTab: NSObject {
    let tabID: TabID
    private let cachePath: String
    private let permissionPrompter: (String, SitePermissionKind) async -> SitePermissionDecision

    private var browser: BrowsemiumCEFBrowser?
    private var pendingURL: URL?
    private var zoomLevel: Double = 0
    private(set) var lifecycle: TabLifecycle = .metadataOnly
    private(set) var audioState = TabAudioState(isPlaying: false, isMuted: false)
    private(set) var currentURL: URL?
    private(set) var title: String?

    var onEvent: ((TabRuntimeEvent) -> Void)?
    var onDownload: ((DownloadInfo) -> Void)?

    private var downloadIdentifiers: [String: UUID] = [:]

    init(
        tabID: TabID,
        cachePath: String,
        permissionPrompter: @escaping (String, SitePermissionKind) async -> SitePermissionDecision
    ) {
        self.tabID = tabID
        self.cachePath = cachePath
        self.permissionPrompter = permissionPrompter
        super.init()
    }

    var hasBrowser: Bool { browser != nil }
    var canGoBack: Bool { browser?.canGoBack ?? false }
    var canGoForward: Bool { browser?.canGoForward ?? false }
    var isLoading: Bool { browser?.isLoading ?? false }

    func attach(to host: NSView) {
        NSLog("[cef] ChromiumTab.attach tab=%@ host=%.0fx%.0f window=%@", tabID.rawValue.uuidString, host.bounds.width, host.bounds.height, host.window?.description ?? "nil")
        let browser = self.browser ?? BrowsemiumCEFBrowser(delegate: self, cachePath: cachePath)
        self.browser = browser
        browser.attach(to: host)
        browser.resize(toBounds: host.bounds)
        if let url = pendingURL {
            pendingURL = nil
            browser.loadURLString(url.absoluteString)
        }
    }

    func detach() {
        browser?.resize(toBounds: .zero)
    }

    func load(_ url: URL) {
        currentURL = url
        if let browser {
            browser.loadURLString(url.absoluteString)
        } else {
            pendingURL = url
        }
    }

    func goBack() { browser?.goBack() }
    func goForward() { browser?.goForward() }
    func reload() { browser?.reload() }
    func stopLoading() { browser?.stopLoading() }

    func setMuted(_ muted: Bool) {
        browser?.setMuted(muted)
        audioState = TabAudioState(
            isPlaying: muted ? false : audioState.isPlaying,
            isMuted: muted,
            isCapturingMedia: audioState.isCapturingMedia
        )
        onEvent?(.audioStateChanged(audioState))
    }

    func adjustZoom(by delta: CGFloat) {
        zoomLevel = min(max(zoomLevel + Double(delta) * 2, -3), 3)
        browser?.setZoomLevel(zoomLevel)
    }

    func resetZoom() {
        zoomLevel = 0
        browser?.setZoomLevel(0)
    }

    func printPage() {
        browser?.evaluateJavaScript("window.print()") { _, _ in }
    }

    func clearFindHighlight() {
        browser?.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges()") { _, _ in }
    }

    func find(_ query: String, forward: Bool) async -> FindOutcome {
        guard let browser else { return FindOutcome(found: false) }
        return await withCheckedContinuation { continuation in
            browser.findText(query, forward: forward) { matchCount, found in
                continuation.resume(returning: FindOutcome(found: found, matchCount: Int(matchCount)))
            }
        }
    }

    func evaluate(_ script: String) async throws -> Any? {
        guard let browser else {
            throw BrowsemiumError.webContentUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            browser.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: BrowsemiumError.captureFailed(error))
                } else {
                    // The completion runs on CEF's UI thread, which is the main
                    // thread, so the value never really crosses actors.
                    struct Box: @unchecked Sendable { let value: Any? }
                    continuation.resume(returning: Box(value: result).value)
                }
            }
        }
    }

    /// Destroys the browser, which takes its renderer process with it. This is
    /// what the memory saver relies on.
    func hibernate() {
        guard let browser else { return }
        browser.close()
        self.browser = nil
        setLifecycle(.hibernated)
    }

    func close() {
        browser?.close()
        browser = nil
    }

    private func setLifecycle(_ value: TabLifecycle) {
        guard lifecycle != value else { return }
        lifecycle = value
        onEvent?(.lifecycleChanged(value))
    }
}

// MARK: - BrowsemiumCEFBrowserDelegate

/// CEF runs these callbacks on the browser UI thread, which is the main thread
/// because the runtime pumps its own message loop. @preconcurrency lets the
/// @MainActor class satisfy a delegate protocol that predates concurrency
/// annotations.
extension ChromiumTab: @preconcurrency BrowsemiumCEFBrowserDelegate {
    func cefBrowserDidStartLoading(_ browser: BrowsemiumCEFBrowser) {
        setLifecycle(.loading)
        onEvent?(.startedLoading(currentURL))
    }

    func cefBrowser(_ browser: BrowsemiumCEFBrowser, didChangeURL url: String?) {
        guard let url, let parsed = URL(string: url) else { return }
        currentURL = parsed
        onEvent?(.committed(parsed))
    }

    func cefBrowser(_ browser: BrowsemiumCEFBrowser, didFinishLoadingURL url: String?) {
        if let url, let parsed = URL(string: url) {
            currentURL = parsed
        }
        setLifecycle(.active)
        onEvent?(.finished(title: browser.title, url: currentURL))
    }

    func cefBrowser(_ browser: BrowsemiumCEFBrowser, didFailLoadingWithMessage message: String) {
        onEvent?(.failed(message))
    }

    func cefBrowser(_ browser: BrowsemiumCEFBrowser, didChangeProgress progress: Double) {
        onEvent?(.progressChanged(progress))
    }

    func cefBrowser(_ browser: BrowsemiumCEFBrowser, didChangeTitle title: String?) {
        self.title = title
    }

    func cefBrowser(
        _ browser: BrowsemiumCEFBrowser,
        didChangeNavigationStateCanGoBack canGoBack: Bool,
        canGoForward: Bool,
        isLoading: Bool
    ) {
        if !isLoading, lifecycle == .loading {
            setLifecycle(.active)
        }
    }

    func cefBrowser(_ browser: BrowsemiumCEFBrowser, didChangeAudioStatePlaying playing: Bool, capturing: Bool) {
        let state = TabAudioState(
            isPlaying: audioState.isMuted ? false : playing,
            isMuted: audioState.isMuted,
            isCapturingMedia: capturing
        )
        guard state != audioState else { return }
        audioState = state
        onEvent?(.audioStateChanged(state))
    }

    func cefBrowser(_ browser: BrowsemiumCEFBrowser, didRequestNewWindowForURL url: String) {
        guard let parsed = URL(string: url) else { return }
        onEvent?(.requestedNewWindow(parsed))
    }

    func cefBrowserDidCrash(_ browser: BrowsemiumCEFBrowser) {
        setLifecycle(.crashed)
        onEvent?(.crashed)
    }

    func cefBrowserDidClose(_ browser: BrowsemiumCEFBrowser) {
        if lifecycle != .hibernated {
            setLifecycle(.metadataOnly)
        }
    }

    func cefBrowser(
        _ browser: BrowsemiumCEFBrowser,
        didStartDownloadWithIdentifier identifier: String,
        filename: String,
        destination: String?
    ) {
        let id = UUID()
        downloadIdentifiers[identifier] = id
        onEvent?(.downloadStarted(id))
        onDownload?(DownloadInfo(
            id: id,
            tabID: tabID,
            suggestedFilename: filename,
            destinationURL: destination.flatMap { URL(string: $0) },
            bytesReceived: 0,
            totalBytes: 0,
            isFinished: false,
            failureMessage: nil
        ))
    }

    func cefBrowser(
        _ browser: BrowsemiumCEFBrowser,
        didUpdateDownloadWithIdentifier identifier: String,
        receivedBytes: Int64,
        totalBytes: Int64,
        finished: Bool,
        failure: String?
    ) {
        guard let id = downloadIdentifiers[identifier] else { return }
        onDownload?(DownloadInfo(
            id: id,
            tabID: tabID,
            suggestedFilename: "",
            destinationURL: nil,
            bytesReceived: receivedBytes,
            totalBytes: totalBytes,
            isFinished: finished,
            failureMessage: failure
        ))
        if finished {
            if failure != nil {
                onEvent?(.downloadFailed(id, failure ?? "The download failed."))
            } else {
                onEvent?(.downloadFinished(id))
            }
        }
    }

    func cefBrowser(
        _ browser: BrowsemiumCEFBrowser,
        requestsMediaAccessForKind kind: String,
        origin: String,
        completion: @escaping (Bool) -> Void
    ) {
        let kinds: [SitePermissionKind]
        switch kind {
        case "camera": kinds = [.camera]
        case "microphone": kinds = [.microphone]
        default: kinds = [.camera, .microphone]
        }
        let prompter = permissionPrompter
        Task { @MainActor in
            for permissionKind in kinds {
                let decision = await prompter(origin, permissionKind)
                guard decision == .allow else {
                    completion(false)
                    return
                }
            }
            completion(true)
        }
    }
}
