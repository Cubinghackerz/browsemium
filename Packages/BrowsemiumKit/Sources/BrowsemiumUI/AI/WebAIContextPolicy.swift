import BrowsemiumCore
import Foundation
import BrowsemiumEngineKit

/// Defines what Browsemium captures automatically when a Web AI message is
/// sent. Images remain an explicit user action so a normal Send never opens a
/// provider image-upload path or sends a screenshot unexpectedly.
enum WebAIContextPolicy {
    static func automaticCaptureKinds(
        includePageContext: Bool,
        hasReadablePage: Bool,
        pageURL: URL?
    ) -> Set<CaptureKind> {
        guard includePageContext,
              !hasReadablePage,
              let scheme = pageURL?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return []
        }
        return [.readablePage]
    }
}
