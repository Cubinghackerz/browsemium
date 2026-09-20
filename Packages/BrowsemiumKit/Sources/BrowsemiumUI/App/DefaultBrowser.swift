import AppKit
import Foundation

/// Registers Browsemium as a candidate for http/https links and reports
/// whether it currently is the system default.
enum DefaultBrowser {
    static let bundleIdentifier = "com.browsemium.browser"

    static var isDefault: Bool {
        for scheme in ["http", "https"] {
            guard let handler = LSCopyDefaultHandlerForURLScheme(scheme as CFString)?
                .takeRetainedValue() as String?,
                handler == bundleIdentifier else {
                return false
            }
        }
        return true
    }

    /// Asks LaunchServices to make Browsemium the handler for http and https.
    /// Returns false when the system refuses, in which case the caller should
    /// send the user to System Settings.
    @discardableResult
    static func requestDefault() -> Bool {
        var succeeded = true
        for scheme in ["http", "https"] {
            let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleIdentifier as CFString)
            if status != noErr {
                succeeded = false
            }
        }
        return succeeded && isDefault
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
