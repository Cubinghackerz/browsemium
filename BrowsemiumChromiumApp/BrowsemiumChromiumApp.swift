import AppKit
import BrowsemiumCEF
import BrowsemiumCore
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import SwiftUI

/// The Chromium edition's shell. It shares every view, repository and policy
/// with the WebKit edition; the only difference is which engine the window
/// hands its tabs to.
struct BrowsemiumChromiumApp: App {
    @State private var environment = BrowsemiumChromiumApp.makeEnvironment()
    @State private var updates = UpdateController()
    @State private var windowRegistry = BrowserWindowRegistry()
    @NSApplicationDelegateAdaptor(BrowsemiumAppDelegate.self) private var appDelegate

    init() {
        // Chromium has to be started before the first browser is created, and
        // after AppKit exists. The app's own init is the last such moment.
        do {
            try ChromiumRuntime.start()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ChromiumWindowRoot(
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

    /// Used by scripts and by the memory benchmark. A Finder launch has no URL
    /// arguments, so ordinary startup is unchanged.
    private static let commandLineURLs: [URL] = ProcessInfo.processInfo.arguments.dropFirst().compactMap { argument in
        guard !argument.hasPrefix("-"),
              let url = URL(string: argument),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private static func makeEnvironment() -> BrowserEnvironment? {
        let engine = ChromiumEngine()
        do {
            let environment = try BrowserEnvironment.live(engine: engine)
            engine.setProfileCachePath(ChromiumRuntime.profileCachePath(for: environment.activeProfile))
            return environment
        } catch {
            FileHandle.standardError.write(Data("Browsemium Chromium could not open its database: \(error)\n".utf8))
            return nil
        }
    }
}

@MainActor
private struct ChromiumWindowRoot: View {
    let environment: BrowserEnvironment?
    let registry: BrowserWindowRegistry
    let updates: UpdateController
    let initialURLs: [URL]

    @State private var model: BrowserWindowModel?

    var body: some View {
        Group {
            if let model {
                BrowsemiumAppView(model: model)
            } else {
                // The database could not be opened. Say so instead of showing a
                // window that silently forgets everything.
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                    Text("Browsemium Chromium could not open its browsing data.")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Quit and reopen the app. If it keeps happening, the profile folder may be damaged.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            NSLog("[app] root onAppear model=%@ env=%@ urls=%d",
                  model == nil ? "nil" : "set",
                  environment == nil ? "nil" : "set",
                  initialURLs.count)
            guard model == nil, let environment else { return }
            let created = BrowserWindowModel(environment: environment)
            created.persistsSession = registry.claimPrimary()
            if PrivateWindowRequest.shared.consume() {
                created.enterPrivateMode()
            }
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

/// Chromium lifecycle, wrapped so the app shell never imports CEF directly.
enum ChromiumRuntime {
    static let logName = "cef.log"

    static func start() throws {
        let support = try applicationSupportDirectory()
        let rootCache = support.appendingPathComponent("chromium", isDirectory: true)
        let cache = rootCache.appendingPathComponent("default", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        try BrowsemiumCEFRuntime.start(
            withRootCachePath: rootCache.path,
            cachePath: cache.path,
            userAgent: nil,
            logPath: support.appendingPathComponent(logName).path
        )
    }

    /// Each profile gets its own request context and therefore its own cookies,
    /// storage and cache. Chrome-runtime CEF requires the path to be a direct
    /// child of the root cache directory — a nested path fails profile
    /// creation and silently falls back to an in-memory profile.
    static func profileCachePath(for profile: BrowserProfile) -> String {
        let support = (try? applicationSupportDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let path = support
            .appendingPathComponent("chromium", isDirectory: true)
            .appendingPathComponent("Profile-\(profile.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path.path
    }

    /// Its own Application Support directory: the two editions never share a
    /// database, so one can be uninstalled without touching the other.
    static func applicationSupportDirectory() throws -> URL {
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--profile-dir=") }) {
            let path = String(argument.dropFirst("--profile-dir=".count))
            guard !path.isEmpty else {
                throw NSError(
                    domain: "BrowsemiumChromium",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The requested profile directory is empty."]
                )
            }
            let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("BrowsemiumChromium", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
