import BrowsemiumCore
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import SwiftUI

@main
struct BrowsemiumApp: App {
    /// Property initializers run in declaration order, so this must sit above
    /// `environment`: it is the earliest Swift-visible point in the process
    /// (dyld time still precedes it).
    private let launchClockStart: Void = LaunchMetrics.mark(.processStart)

    @State private var environment = BrowsemiumApp.makeEnvironment()
    @State private var updates = UpdateController()
    @State private var windowRegistry = BrowserWindowRegistry()
    @NSApplicationDelegateAdaptor(BrowsemiumAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            BrowsemiumWindowRoot(
                environment: environment,
                registry: windowRegistry,
                updates: updates,
                initialURLs: Self.commandLineURLs
            )
            .onAppear {
                appDelegate.environment = environment
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            BrowserCommands(updates: updates)
        }
    }

    private static func makeEnvironment() -> BrowserEnvironment? {
        let environment = try? BrowserEnvironment.live()
        LaunchMetrics.mark(.environmentReady)
        return environment
    }

    /// Used by the repeatable memory benchmark and by command-line launches
    /// from scripts. Normal Finder launches have no URL arguments, so this
    /// does not change ordinary startup behavior.
    private static let commandLineURLs: [URL] = ProcessInfo.processInfo.arguments.dropFirst().compactMap { argument in
        guard !argument.hasPrefix("-"),
              let url = URL(string: argument),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}

@MainActor
private struct BrowsemiumWindowRoot: View {
    let environment: BrowserEnvironment?
    let registry: BrowserWindowRegistry
    let updates: UpdateController
    let initialURLs: [URL]

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
        .overlay {
            if updates.isUpdateRequired {
                MandatoryUpdateOverlay(updates: updates)
            }
        }
        .task {
            updates.checkForUpdatesOnLaunch()
        }
        .onAppear {
            guard model == nil, let environment else { return }
            let created = BrowserWindowModel(environment: environment)
            created.persistsSession = registry.claimPrimary()
            model = created

            guard !initialURLs.isEmpty else { return }
            for (index, url) in initialURLs.enumerated() {
                if index == 0 {
                    created.open(url)
                } else {
                    _ = created.newTab(url: url)
                }
            }
        }
    }
}
