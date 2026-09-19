import WebKit

/// Keeps one idle `WKWebView` ready so a new tab does not pay the WebKit
/// content-process start-up cost on its first navigation. That cost is real —
/// the first load in a fresh process is measurably slower than the second —
/// and Safari-style browsers avoid it the same way.
///
/// The pool holds at most one spare and gives it up under memory pressure,
/// so it cannot quietly become a memory leak.
@MainActor
public final class WarmWebViewPool {
    private let factory: WebViewFactory
    private var spare: WKWebView?
    private var isEnabled = true

    public init(factory: WebViewFactory) {
        self.factory = factory
    }

    /// Creates the spare if one is not already waiting. Safe to call often.
    public func prepare(store: WebViewFactory.Store = .persistent) {
        guard isEnabled, spare == nil, store == .persistent else { return }
        spare = factory.makeWebView(store: store)
    }

    /// Hands the warm view to a tab, or nil when none is ready.
    public func take() -> WKWebView? {
        guard let view = spare else { return nil }
        spare = nil
        return view
    }

    /// Drops the spare entirely. Called when memory is tight.
    public func release() {
        spare?.stopLoading()
        spare?.removeFromSuperview()
        spare = nil
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            release()
        }
    }

    public var hasSpare: Bool {
        spare != nil
    }
}
