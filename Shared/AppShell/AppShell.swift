import AppKit
import BrowsemiumUI
import Foundation
import SwiftUI

/// App-lifetime work shared by both editions. The only thing here is the
/// promise the settings screen makes: "Clear history when Browsemium quits".
@MainActor
final class BrowsemiumAppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the environment exists. Weak: the app owns it.
    weak var environment: BrowserEnvironment?

    override init() {
        super.init()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.runTerminationTasks()
    }
}

/// A deliberately non-dismissible update gate. It lives above the browser
/// window so the app never leaves a stale, half-blocking Sparkle alert behind.
@MainActor
struct MandatoryUpdateOverlay: View {
    private let updates: UpdateController

    init(updates: UpdateController) {
        self.updates = updates
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.44)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.browsemiumSelection))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Update required")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.browsemiumPrimary)
                        Text(updateName)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.browsemiumSecondary)
                            .lineLimit(2)
                    }
                }

                Text("A signed Browsemium update is ready. Install it before continuing so your browser stays secure and supported.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if updates.phase != .required {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if case .failed = updates.phase {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(Color.browsemiumWarning)
                            } else if let progress = updates.downloadProgress {
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)
                                    .tint(Color.browsemiumAccent)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(updates.statusDescription)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.browsemiumTertiary)
                        }

                        if case .failed = updates.phase {
                            BrowsemiumPrimaryButton("Retry update") {
                                updates.retryMandatoryUpdate()
                            }
                        }
                    }
                } else {
                    BrowsemiumPrimaryButton("Update now") {
                        updates.installMandatoryUpdate()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 440, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
                    .fill(Color.browsemiumRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
                    .stroke(Color.browsemiumBorderStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.24), radius: 26, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(20)
    }

    private var updateName: String {
        if let version = updates.pendingVersion {
            return "Browsemium \(version)"
        }
        return updates.pendingTitle ?? "A new Browsemium release"
    }
}

/// Gives each window its own model. The first window owns session persistence;
/// extra windows are ephemeral so two windows cannot clobber the saved session.
@MainActor
@Observable
final class BrowserWindowRegistry {
    private var hasPrimary = false

    init() {}

    func claimPrimary() -> Bool {
        if hasPrimary { return false }
        hasPrimary = true
        return true
    }
}

/// Menu commands route to the focused window's model, so ⌘T and friends act on
/// the window the user is looking at. Shared by both editions.
@MainActor
struct BrowserCommands: Commands {
    let updates: UpdateController
    @FocusedValue(\.browserModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model == nil)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button("Close Tab") { model?.closeTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model == nil)
            Button("Reopen Closed Tab") { model?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model == nil)
        }

        CommandMenu("Navigate") {
            Button("Focus Address") { model?.focusAddress() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model == nil)
            Button("Reload") { model?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model == nil)
            Button("Stop") { model?.stopLoading() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model == nil)
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model == nil)
        }

        CommandMenu("Page") {
            Button("Find on Page…") { model?.showFindBar() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button("Show Reader") { model?.toggleReaderMode() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model == nil)
            Divider()
            Button("Zoom In") { model?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model == nil)
            Button("Zoom Out") { model?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model == nil)
            Button("Actual Size") { model?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button("Save as PDF…") { model?.savePageAsPDF() }
                .disabled(model == nil)
            Button("Save Screenshot…") { model?.savePageScreenshot() }
                .disabled(model == nil)
            Divider()
            Button("Picture in Picture") { model?.togglePictureInPicture() }
                .disabled(model == nil)
            Divider()
            Button("Print…") { model?.printPage() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model == nil)
        }

        CommandMenu("View") {
            Button("Commands") { model?.toggleCommandPalette() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model == nil)
            Button(model?.isAIDockVisible == true ? "Hide Assistant" : "Show Assistant") {
                model?.toggleAIDock()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(model == nil)
            Button(model?.isBookmarksBarVisible == true ? "Hide Bookmarks Bar" : "Show Bookmarks Bar") {
                model?.toggleBookmarksBar()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(model == nil)
        }

        CommandMenu("Library") {
            Button("Bookmark This Page") { model?.toggleBookmark() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button("History") { model?.openPanel(.history) }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(model == nil)
            Button("Bookmarks") { model?.openPanel(.bookmarks) }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Downloads") { model?.openPanel(.downloads) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(model == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model?.openPanel(.settings) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(model == nil)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.isConfigured)
        }

        CommandGroup(replacing: .help) {
            Button("Browsemium Help") {
                model?.newTab(url: URL(string: "https://github.com/Cubinghackerz/browsemium"))
            }
            .disabled(model == nil)
        }
    }
}
