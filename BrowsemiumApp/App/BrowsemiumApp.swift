import BrowsemiumCore
import BrowsemiumUI
import SwiftUI

@main
struct BrowsemiumApp: App {
    @State private var environment = BrowsemiumApp.makeEnvironment()
    @State private var updates = UpdateController()
    @State private var windowRegistry = WindowRegistry()

    var body: some Scene {
        WindowGroup {
            BrowsemiumWindowRoot(environment: environment, registry: windowRegistry)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            BrowserCommands(updates: updates)
        }
    }

    private static func makeEnvironment() -> BrowserEnvironment? {
        try? BrowserEnvironment.live()
    }
}

/// Gives each window its own model. The first window owns session
/// persistence; extra windows are ephemeral so two windows cannot clobber the
/// saved session.
@MainActor
@Observable
final class WindowRegistry {
    private var hasPrimary = false

    func claimPrimary() -> Bool {
        if hasPrimary { return false }
        hasPrimary = true
        return true
    }
}

@MainActor
private struct BrowsemiumWindowRoot: View {
    let environment: BrowserEnvironment?
    let registry: WindowRegistry

    @State private var model: BrowserWindowModel?

    var body: some View {
        Group {
            if let model {
                BrowsemiumAppView(model: model)
            } else if environment == nil {
                // The database could not be opened; run from memory so the
                // window still works and say so.
                BrowsemiumAppView(model: BrowserWindowModel())
            } else {
                Color.browsemiumCanvas.ignoresSafeArea()
            }
        }
        .onAppear {
            guard model == nil, let environment else { return }
            let created = BrowserWindowModel(environment: environment)
            created.persistsSession = registry.claimPrimary()
            model = created
        }
    }
}

/// Menu commands route to the focused window's model, so ⌘T and friends act on
/// the window the user is looking at.
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
