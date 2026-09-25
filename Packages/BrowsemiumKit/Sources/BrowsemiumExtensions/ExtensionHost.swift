import BrowsemiumCore
import Foundation
import WebKit

/// Hosts `WKWebExtension` contexts for one profile.
///
/// Everything an extension can see or do is bridged through
/// `ExtensionHostBridging`, so extension `tabs.*` calls take the same path as
/// a user clicking the strip. Extensions are loaded from the on-disk store;
/// enablement is per profile, and the controller's configuration is keyed by
/// the profile's data-store identifier so extension storage never leaks
/// between profiles.
///
/// Honest limits, mirrored in Settings: WebKit extensions cannot intercept
/// requests (first-party blocking stays on `WKContentRuleList`) and there is
/// no devtools API surface. Toolbar action buttons and their popovers are
/// hosted, and each button can be pinned or hidden per profile.
@available(macOS 15.4, *)
@MainActor
public final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    public let controller: WKWebExtensionController

    /// Loaded contexts, keyed by the store's extension id.
    public private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Why an extension failed to load, keyed by store id.
    public private(set) var loadErrors: [String: String] = [:]
    /// Names and versions WebKit reported after loading, keyed by store id.
    /// ZIPs and appex bundles have no readable manifest on disk, so these
    /// backfill the registry once WebKit has parsed them.
    public private(set) var displayNames: [String: String] = [:]
    public private(set) var displayVersions: [String: String] = [:]

    public weak var bridge: (any ExtensionHostBridging)?
    public weak var permissionPrompter: (any ExtensionPermissionPrompting)?
    /// Shows action popovers. Set by the toolbar while it is on screen.
    public weak var actionPresenter: (any ExtensionActionPopupPresenting)?

    /// The toolbar action each loaded extension exposes, keyed by store id,
    /// refreshed whenever WebKit reports a change or a load finishes.
    public private(set) var actions: [String: WKWebExtension.Action] = [:]
    /// Fired when the action set or an action's state changes, so the
    /// toolbar can redraw its buttons.
    public var onActionsChanged: (@MainActor () -> Void)?

    private let windowAdapter = ExtensionWindowAdapter()
    private var tabAdapters: [TabID: ExtensionTabAdapter] = [:]
    private var didReportWindow = false

    public init(profileIdentifier: UUID) {
        controller = WKWebExtensionController(
            configuration: WKWebExtensionController.Configuration(identifier: profileIdentifier)
        )
        super.init()
        controller.delegate = self
        windowAdapter.host = self
    }

    // MARK: - Loading

    public func load(_ item: InstalledExtension) async {
        unload(id: item.id)
        do {
            let webExtension: WKWebExtension
            switch item.payload {
            case .appExtension:
                guard let bundle = Bundle(url: item.resourceURL) else {
                    throw ExtensionStore.InstallError.unsupportedSource(item.resourceURL.lastPathComponent)
                }
                webExtension = try await WKWebExtension(appExtensionBundle: bundle)
            case .directory, .zip:
                webExtension = try await WKWebExtension(resourceBaseURL: item.resourceURL)
            }
            let context = WKWebExtensionContext(for: webExtension)
            try controller.load(context)
            contexts[item.id] = context
            loadErrors[item.id] = nil
            // Popup pages message the background the moment they open. If the
            // service worker has not been started, Chrome extensions show their
            // own "menu had trouble loading" page. Wake it now, and again
            // before each toolbar click.
            wakeBackground(of: context)
            if let name = webExtension.displayName {
                displayNames[item.id] = name
            }
            displayVersions[item.id] = webExtension.displayVersion ?? webExtension.version ?? ""
            refreshActions()
            reportWindowIfNeeded()
        } catch {
            loadErrors[item.id] = error.localizedDescription
        }
    }

    // MARK: - Actions (toolbar buttons)

    /// Whether the extension's manifest declares a toolbar action. WebKit
    /// hands back a default action even when there is none in the manifest;
    /// showing a button for it would give the user a control that does
    /// nothing.
    public func declaresAction(_ extensionID: String) -> Bool {
        guard let webExtension = contexts[extensionID]?.webExtension else { return false }
        let manifest = webExtension.manifest
        return manifest["action"] != nil || manifest["browser_action"] != nil
    }

    /// The action an extension exposes for a tab, or its default action.
    public func action(for extensionID: String, tabID: TabID?) -> WKWebExtension.Action? {
        guard declaresAction(extensionID), let context = contexts[extensionID] else { return nil }
        if let tabID, let adapter = tabAdapters[tabID], let tabAction = context.action(for: adapter) {
            return tabAction
        }
        return context.action(for: nil)
    }

    /// Runs the extension's action — the same path as a toolbar click.
    public func performAction(for extensionID: String, tabID: TabID?) {
        guard let context = contexts[extensionID] else { return }
        let run = {
            if let tabID, let adapter = self.tabAdapters[tabID] {
                context.performAction(for: adapter)
            } else {
                context.performAction(for: nil)
            }
        }
        context.loadBackgroundContent { _ in
            Task { @MainActor in run() }
        }
    }

    private func wakeBackground(of context: WKWebExtensionContext) {
        context.loadBackgroundContent { _ in }
    }

    /// Extension-supplied context-menu items for its action. Fetched on
    /// demand: WebKit says the items change dynamically.
    public func actionMenuItems(for extensionID: String, tabID: TabID?) -> [NSMenuItem] {
        action(for: extensionID, tabID: tabID)?.menuItems ?? []
    }

    public func optionsPageURL(for extensionID: String) -> URL? {
        contexts[extensionID]?.optionsPageURL
    }

    public func extensionID(for context: WKWebExtensionContext) -> String? {
        contexts.first { $0.value === context }?.key
    }

    /// Rebuilds the cached action set from the loaded contexts.
    public func refreshActions() {
        for (id, context) in contexts {
            if let action = context.action(for: nil) {
                actions[id] = action
            } else {
                actions[id] = nil
            }
        }
        actions = actions.filter { contexts[$0.key] != nil }
        onActionsChanged?()
    }

    public func unload(id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        actions[id] = nil
        onActionsChanged?()
    }

    public func unloadAll() {
        for id in Array(contexts.keys) {
            unload(id: id)
        }
    }

    // MARK: - Strip notifications

    /// Tells WebKit the window exists. Sent once, before any tab change.
    private func reportWindowIfNeeded() {
        guard !didReportWindow, !contexts.isEmpty else { return }
        didReportWindow = true
        controller.didOpenWindow(windowAdapter)
    }

    /// The strip changed: tabs opened, closed, or re-ordered. WebKit keeps
    /// its own view of the tabs, so it has to be told.
    public func stripDidChange(closedTabID: TabID? = nil, activatedTabID: TabID? = nil, previousTabID: TabID? = nil) {
        reportWindowIfNeeded()
        if let closedTabID, let adapter = tabAdapters[closedTabID] {
            controller.didCloseTab(adapter)
            tabAdapters[closedTabID] = nil
        }
        if let activatedTabID, let adapter = tabAdapters[activatedTabID] {
            controller.didActivateTab(adapter, previousActiveTab: previousTabID.flatMap { tabAdapters[$0] })
        }
    }

    // MARK: - Tab adapters

    /// Adapters for the current strip, refreshed from the model's snapshot.
    /// WebKit compares tabs by object identity, so adapters are cached per
    /// tab id and only their snapshot is updated.
    func tabAdaptersForWindow() -> [ExtensionTabAdapter] {
        guard let bridge else { return [] }
        let snapshots = bridge.extensionTabSnapshots()
        let liveIDs = Set(snapshots.map(\.id))
        for (tabID, _) in tabAdapters where !liveIDs.contains(tabID) {
            tabAdapters[tabID] = nil
        }
        return snapshots.map { snapshot in
            if let existing = tabAdapters[snapshot.id] {
                existing.snapshot = snapshot
                return existing
            }
            let adapter = ExtensionTabAdapter(snapshot: snapshot)
            adapter.host = self
            tabAdapters[snapshot.id] = adapter
            return adapter
        }
    }

    func adapter(for tabID: TabID) -> ExtensionTabAdapter? {
        tabAdapters[tabID]
    }

    func isPrivateSession() -> Bool {
        bridge?.extensionIsPrivateSession() ?? false
    }

    // MARK: - WKWebExtensionControllerDelegate

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        bridge == nil ? [] : [windowAdapter]
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        bridge == nil ? nil : windowAdapter
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        // Browsemium keeps one window per tab set; extensions get a tab
        // instead of a second window, and the error says so honestly.
        completionHandler(nil, ExtensionHostError.newWindowsUnsupported)
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let bridge else {
            completionHandler(nil, ExtensionHostError.noWindow)
            return
        }
        let tabID = bridge.extensionCreateTab(url: configuration.url, active: configuration.shouldBeActive)
        guard let tabID, let adapter = tabAdapters[tabID] ?? tabAdaptersForWindow().first(where: { $0.tabID == tabID }) else {
            completionHandler(nil, ExtensionHostError.noWindow)
            return
        }
        completionHandler(adapter, nil)
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // Options pages open as ordinary tabs, like any other page.
        if let url = extensionContext.optionsPageURL,
           bridge?.extensionCreateTab(url: url, active: true) != nil {
            completionHandler(nil)
        } else {
            completionHandler(ExtensionHostError.optionsPageUnavailable)
        }
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        guard let id = extensionID(for: context) else { return }
        actions[id] = action
        onActionsChanged?()
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // Both a toolbar click on a popup action and the extension calling
        // `action.openPopup()` land here; the toolbar shows the preloaded
        // popover anchored to the button.
        guard let presenter = actionPresenter else {
            completionHandler(ExtensionHostError.noActionPopupHost)
            return
        }
        presenter.presentActionPopup(action, completion: completionHandler)
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let extensionID = contexts.first { $0.value === extensionContext }?.key ?? ""
        let name = displayNames[extensionID] ?? extensionID
        let request = ExtensionPermissionRequest(
            extensionID: extensionID,
            extensionName: name,
            kind: .apiPermissions(permissions.map(\.rawValue).sorted())
        )
        Task { @MainActor in
            let granted = await permissionPrompter?.promptForExtensionPermissions(request) ?? false
            completionHandler(granted ? permissions : [], nil)
        }
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let extensionID = contexts.first { $0.value === extensionContext }?.key ?? ""
        let name = displayNames[extensionID] ?? extensionID
        let request = ExtensionPermissionRequest(
            extensionID: extensionID,
            extensionName: name,
            kind: .hostAccess(urls.map(\.host).compactMap { $0 }.sorted())
        )
        Task { @MainActor in
            let granted = await permissionPrompter?.promptForExtensionPermissions(request) ?? false
            completionHandler(granted ? urls : [], nil)
        }
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let extensionID = contexts.first { $0.value === extensionContext }?.key ?? ""
        let name = displayNames[extensionID] ?? extensionID
        let request = ExtensionPermissionRequest(
            extensionID: extensionID,
            extensionName: name,
            kind: .hostAccess(matchPatterns.map(\.description).sorted())
        )
        Task { @MainActor in
            let granted = await permissionPrompter?.promptForExtensionPermissions(request) ?? false
            completionHandler(granted ? matchPatterns : [], nil)
        }
    }
}

/// Failures the host reports back to WebKit, phrased for extension authors.
public enum ExtensionHostError: Swift.Error, LocalizedError {
    case noWindow
    case newWindowsUnsupported
    case optionsPageUnavailable
    case tabUnavailable
    case noActionPopupHost

    public var errorDescription: String? {
        switch self {
        case .noWindow:
            "Browsemium has no window available for this extension."
        case .newWindowsUnsupported:
            "Browsemium opens extension pages as tabs, not windows."
        case .optionsPageUnavailable:
            "This extension has no options page, or it could not be opened."
        case .tabUnavailable:
            "That tab is no longer open."
        case .noActionPopupHost:
            "The extension's toolbar button is not on screen to anchor its popup."
        }
    }
}

// MARK: - Tab adapter

@available(macOS 15.4, *)
@MainActor
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    let tabID: TabID
    var snapshot: ExtensionTabSnapshot
    weak var host: ExtensionHost?

    init(snapshot: ExtensionTabSnapshot) {
        self.tabID = snapshot.id
        self.snapshot = snapshot
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        host?.tabAdaptersForWindow().isEmpty == false ? host?.windowAdapterIfAvailable : nil
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        snapshot.index
    }

    func title(for context: WKWebExtensionContext) -> String? {
        snapshot.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        snapshot.url
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        snapshot.isPinned
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !snapshot.isLoading
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        snapshot.isActive
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        (host?.bridge as? ExtensionWebViewProviding)?.extensionWebView(for: tabID)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let bridge = host?.bridge, bridge.extensionActivateTab(tabID) else {
            completionHandler(ExtensionHostError.tabUnavailable)
            return
        }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let bridge = host?.bridge, bridge.extensionCloseTab(tabID) else {
            completionHandler(ExtensionHostError.tabUnavailable)
            return
        }
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let bridge = host?.bridge, bridge.extensionLoadURL(url, in: tabID) else {
            completionHandler(ExtensionHostError.tabUnavailable)
            return
        }
        completionHandler(nil)
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        // Pinning is a strip gesture; extensions may read it but not drive it.
        completionHandler(pinned == snapshot.isPinned ? nil : ExtensionHostError.tabUnavailable)
    }
}

/// The window model can expose its web views to extensions (screenshots and
/// scripting APIs) by conforming to this; without it, those APIs stay off.
@MainActor
public protocol ExtensionWebViewProviding: AnyObject {
    func extensionWebView(for tabID: TabID) -> WKWebView?
}

// MARK: - Window adapter

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    weak var host: ExtensionHost?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        host?.tabAdaptersForWindow() ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        host?.tabAdaptersForWindow().first { $0.snapshot.isActive }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        host?.isPrivateSession() ?? false
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        NSScreen.main?.frame ?? .zero
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        NSScreen.main?.visibleFrame ?? .zero
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
extension ExtensionHost {
    /// The single window adapter this host hands to extensions.
    var windowAdapterIfAvailable: any WKWebExtensionWindow {
        windowAdapter
    }
}
