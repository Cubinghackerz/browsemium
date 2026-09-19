import Foundation
import Sparkle
import SwiftUI

/// Wraps Sparkle so updates can be checked safely.
///
/// The updater only starts when the build actually carries a feed URL and an
/// EdDSA public key. Development builds do not, so the menu item explains what
/// is missing rather than pretending to check and failing silently.
@MainActor
@Observable
final class UpdateController {
    private(set) var isConfigured: Bool
    private(set) var lastMessage: String?

    private var controller: SPUStandardUpdaterController?

    private static let placeholderKey = "REPLACE_WITH_EDDSA_PUBLIC_KEY"

    init() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = feedURL.hasPrefix("https://")
            && !publicKey.isEmpty
            && publicKey != Self.placeholderKey

        guard isConfigured else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Browsemium \(version) (\(build))"
    }

    func checkForUpdates() {
        guard isConfigured, let controller else {
            lastMessage = "Updates are not configured in this build. Signing the release with a Sparkle feed URL and EdDSA key enables them — see Scripts/release/generate-appcast.sh."
            return
        }
        lastMessage = nil
        controller.checkForUpdates(nil)
    }
}
