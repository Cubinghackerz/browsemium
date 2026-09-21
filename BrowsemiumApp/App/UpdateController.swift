import AppKit
import Foundation
import Sparkle
import SwiftUI

enum UpdatePhase: Equatable {
    case idle
    case checking
    case required
    case downloading
    case extracting
    case installing
    case failed(String)
}

/// Coordinates Sparkle's signed update feed with Browsemium's mandatory
/// update gate. The update driver deliberately has no dismiss or skip path:
/// once a valid release is found, the user must install it before browsing.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private(set) var isConfigured: Bool
    private(set) var lastMessage: String?
    private(set) var phase: UpdatePhase = .idle
    private(set) var pendingVersion: String?
    private(set) var pendingTitle: String?
    private(set) var downloadProgress: Double?

    private var updater: SPUUpdater?
    private var userDriver: MandatoryUpdateUserDriver?
    private var launchCheckStarted = false
    private var manualCheckInProgress = false
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0
    private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?

    private static let placeholderKey = "REPLACE_WITH_EDDSA_PUBLIC_KEY"

    override init() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let requiresSignedFeed = Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool ?? false
        let verifiesBeforeExtraction = Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool ?? false

        isConfigured = feedURL.hasPrefix("https://")
            && !publicKey.isEmpty
            && publicKey != Self.placeholderKey
            && requiresSignedFeed
            && verifiesBeforeExtraction

        super.init()

        guard isConfigured else { return }

        let driver = MandatoryUpdateUserDriver()
        userDriver = driver
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: self
        )
        self.updater = updater
        driver.controller = self

        do {
            try updater.start()
        } catch {
            lastMessage = "Browsemium could not start its signed update service: \(error.localizedDescription)"
        }
    }

    var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Browsemium \(version) (\(build))"
    }

    var isUpdateRequired: Bool {
        pendingVersion != nil
    }

    var statusDescription: String {
        switch phase {
        case .idle:
            return ""
        case .checking:
            return "Checking for a signed release…"
        case .required:
            return "Install this update to continue browsing."
        case .downloading:
            return "Downloading the signed update…"
        case .extracting:
            return "Preparing the update…"
        case .installing:
            return "Restarting Browsemium with the update…"
        case .failed(let message):
            return message
        }
    }

    func checkForUpdatesOnLaunch() {
        guard isConfigured, let updater, !launchCheckStarted else { return }
        launchCheckStarted = true
        manualCheckInProgress = false
        lastMessage = nil
        phase = .checking
        updater.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        guard isConfigured, let updater else {
            lastMessage = "Signed updates are not configured in this build. A notarized release with the Sparkle feed and EdDSA key is required."
            return
        }
        manualCheckInProgress = true
        lastMessage = nil
        phase = .checking
        updater.checkForUpdates()
    }

    func installMandatoryUpdate() {
        guard let pendingInstallReply else { return }
        self.pendingInstallReply = nil
        manualCheckInProgress = false
        phase = .downloading
        pendingInstallReply(.install)
    }

    func retryMandatoryUpdate() {
        guard isConfigured, let updater, pendingVersion != nil else { return }
        pendingInstallReply = nil
        manualCheckInProgress = false
        lastMessage = nil
        phase = .checking
        updater.checkForUpdatesInBackground()
    }

    func updateWasFound(
        _ item: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        if item.isInformationOnlyUpdate {
            pendingVersion = nil
            pendingTitle = nil
            phase = .idle
            reply(.dismiss)
            lastMessage = "Browsemium found release information, but there is no installable update in the feed."
            return
        }

        pendingVersion = item.versionString
        pendingTitle = item.title
        pendingInstallReply = reply
        downloadProgress = state.stage == .downloaded ? 1 : nil
        phase = .required
    }

    func beginManualCheck(cancellation: @escaping () -> Void) {
        manualCheckInProgress = true
        phase = .checking
        // The custom UI has no cancel action. Keep the handler only so the
        // updater can still be cancelled if Sparkle aborts the session.
        _ = cancellation
    }

    func updateNotFound(error: Error, acknowledgement: @escaping () -> Void) {
        // A check that finds nothing must also lift the mandatory gate:
        // otherwise the overlay sat on screen with a spinner, no status text,
        // and no way to retry.
        clearPendingUpdate()
        if manualCheckInProgress {
            manualCheckInProgress = false
            presentAlert(
                title: "Browsemium is up to date",
                message: error.localizedDescription
            )
        }
        acknowledgement()
    }

    private func clearPendingUpdate() {
        phase = .idle
        downloadProgress = nil
        pendingVersion = nil
        pendingTitle = nil
        pendingInstallReply = nil
    }

    func updateError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let message = "The update could not be completed. \(error.localizedDescription)"
        if pendingVersion != nil {
            phase = .failed(message)
            pendingInstallReply = nil
        } else {
            phase = .idle
            lastMessage = message
            if manualCheckInProgress {
                manualCheckInProgress = false
                presentAlert(title: "Update check failed", message: error.localizedDescription)
            }
        }
        acknowledgement()
    }

    func releaseNotesFailed(_ error: Error) {
        lastMessage = "Release notes could not be downloaded: \(error.localizedDescription)"
    }

    func beginDownload() {
        expectedContentLength = 0
        receivedContentLength = 0
        downloadProgress = nil
        phase = .downloading
    }

    func receiveExpectedContentLength(_ length: UInt64) {
        expectedContentLength = length
        updateDownloadProgress()
    }

    func receiveData(length: UInt64) {
        receivedContentLength += length
        updateDownloadProgress()
    }

    func beginExtraction() {
        downloadProgress = 0
        phase = .extracting
    }

    func receiveExtractionProgress(_ progress: Double) {
        downloadProgress = min(max(progress, 0), 1)
    }

    func updateReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = .installing
        downloadProgress = 1
        // The user already approved the mandatory update before download. Do
        // not introduce a second dismissible prompt after it is ready.
        reply(.install)
    }

    func updateInstalling() {
        phase = .installing
        downloadProgress = 1
    }

    func updateInstalled(acknowledgement: @escaping () -> Void) {
        phase = .idle
        pendingVersion = nil
        pendingTitle = nil
        pendingInstallReply = nil
        downloadProgress = nil
        acknowledgement()
    }

    private func updateDownloadProgress() {
        guard expectedContentLength > 0 else {
            downloadProgress = nil
            return
        }
        downloadProgress = min(max(Double(receivedContentLength) / Double(expectedContentLength), 0), 1)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: SPUUpdaterDelegate

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // Nothing to install, so there is nothing to gate: a pending update
        // that the feed no longer offers must release the overlay instead of
        // leaving it spinning with no status text and no retry.
        if pendingVersion != nil {
            clearPendingUpdate()
        } else {
            phase = .idle
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        if pendingVersion != nil {
            clearPendingUpdate()
        } else {
            phase = .idle
        }
    }
}

/// A small Sparkle user driver that feeds progress into the SwiftUI update
/// gate. It intentionally exposes only one decision: install the verified
/// release.
@MainActor
private final class MandatoryUpdateUserDriver: NSObject, SPUUserDriver {
    weak var controller: UpdateController?

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Keep automatic checks on, but do not send a system profile to the
        // update feed. Browsemium only needs the signed appcast response.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        controller?.beginManualCheck(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        controller?.updateWasFound(appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        controller?.releaseNotesFailed(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller?.updateNotFound(error: error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller?.updateError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        controller?.beginDownload()
        _ = cancellation
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        controller?.receiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        controller?.receiveData(length: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        controller?.beginExtraction()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        controller?.receiveExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller?.updateReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        controller?.updateInstalling()
        _ = applicationTerminated
        _ = retryTerminatingApplication
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        controller?.updateInstalled(acknowledgement: acknowledgement)
        _ = relaunched
    }

    func dismissUpdateInstallation() {}

    func showUpdateInFocus() {}
}
