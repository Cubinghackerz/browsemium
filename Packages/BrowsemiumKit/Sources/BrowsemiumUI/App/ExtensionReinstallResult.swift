import Foundation

/// What happened to one extension offered for reinstall after an import.
public struct ExtensionReinstallResult: Equatable, Sendable {
    public let id: String
    public let name: String?
    /// Closed wording that never contains a path. Nil when it installed.
    public let failure: String?

    public init(id: String, name: String?, failure: String?) {
        self.id = id
        self.name = name
        self.failure = failure
    }

    public var isInstalled: Bool { failure == nil }
}

extension Array where Element == ExtensionReinstallResult {
    /// One sentence for the status line.
    public var summary: String {
        let installed = filter(\.isInstalled).count
        let failed = count - installed
        var parts: [String] = []
        if installed > 0 {
            parts.append("\(installed) extension\(installed == 1 ? "" : "s") installed, disabled until you enable them")
        }
        if failed > 0 {
            parts.append("\(failed) could not be installed")
        }
        guard !parts.isEmpty else { return "No extensions were installed." }
        var reasons: [String] = []
        for reason in compactMap(\.failure) where !reasons.contains(reason) { reasons.append(reason) }
        return parts.joined(separator: "; ") + "." + (reasons.isEmpty ? "" : " " + reasons.joined(separator: " "))
    }
}
