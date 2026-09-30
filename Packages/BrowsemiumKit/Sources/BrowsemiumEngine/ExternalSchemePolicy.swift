import Foundation

/// Pure navigation policy; scripts and redirects are not user activation.
public enum ExternalSchemePolicy {
    public enum Action: Sendable, Equatable {
        case open, block, allowInWebView
    }

    public static func evaluate(
        scheme: String, isUserActivated: Bool, isMainFrame: Bool = true
    ) -> Action {
        switch scheme.lowercased() {
        case "blob":
            return .allowInWebView
        case "data":
            return isMainFrame ? .block : .allowInWebView
        case "", "file", "javascript", "vbscript", "x-apple.systempreferences":
            return .block
        case "mailto", "tel", "sms", "facetime", "facetime-audio", "maps":
            return isUserActivated ? .open : .block
        default:
            return isUserActivated && isMainFrame ? .open : .block
        }
    }
}
