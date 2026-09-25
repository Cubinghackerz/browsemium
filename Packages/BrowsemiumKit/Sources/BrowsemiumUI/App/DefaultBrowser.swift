import AppKit
import Foundation

/// Registers Browsemium as a candidate for http/https links and reports
/// whether it currently is the system default.
@MainActor
enum DefaultBrowser {
    /// The running bundle's identifier. Hardcoding it meant a second edition —
    /// or any renamed build — could never register or recognise itself.
    static var bundleIdentifier: String? {
        Bundle.main.bundleIdentifier
    }

    static var isDefault: Bool {
        guard let bundleIdentifier else { return false }
        for scheme in ["http", "https"] {
            guard let url = URL(string: "\(scheme)://example.com"),
                let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: url),
                let handler = Bundle(url: handlerURL)?.bundleIdentifier,
                handler == bundleIdentifier else {
                return false
            }
        }
        return true
    }

    /// Requests each scheme through the consent-aware macOS API. macOS may
    /// show a system confirmation sheet before applying the change.
    static func requestDefault() async -> Bool {
        guard bundleIdentifier != nil else { return false }
        let appURL = Bundle.main.bundleURL
        for scheme in ["http", "https"] {
            let failed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                NSWorkspace.shared.setDefaultApplication(
                    at: appURL,
                    toOpenURLsWithScheme: scheme
                ) { error in
                    continuation.resume(returning: error != nil)
                }
            }
            if failed { return false }
        }
        return isDefault
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
