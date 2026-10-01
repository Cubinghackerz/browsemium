import Foundation

public extension BrowserImportSource {
    /// Launch Services identity for the installed macOS browser app. Looking
    /// up this identifier detects the app only; it does not read its profile.
    var applicationBundleIdentifier: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .arc: "company.thebrowser.Browser"
        case .dia: "company.thebrowser.dia"
        case .helium: "net.imput.helium"
        case .opera: "com.operasoftware.Opera"
        case .chromium: "org.chromium.Chromium"
        case .firefox: "org.mozilla.firefox"
        case .safari: "com.apple.Safari"
        }
    }
}

/// Pure mapping from Launch Services results to the importers we support.
/// Keeping this separate makes browser detection testable without inspecting
/// the current Mac's applications or user data.
public enum BrowserApplicationDiscovery {
    public static func installedSources(
        in bundleIdentifiers: Set<String>
    ) -> [BrowserImportSource] {
        BrowserImportSource.allCases.filter {
            bundleIdentifiers.contains($0.applicationBundleIdentifier)
        }
    }
}
