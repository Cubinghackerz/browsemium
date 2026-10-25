import BrowsemiumCore
import BrowsemiumData
import Foundation
import Observation

/// Sends a site to its space, with a visible, reversible notice.
///
/// Scope is deliberately narrow: only a committed HTTP(S) navigation of the
/// *active, unpinned, ordinary* tab is routed. Private windows, previews,
/// background tabs and split view are left alone. Everything the coordinator
/// remembers (the rule list, a pending unlock, an undo) is resolved again at
/// the moment it is used, because the profile, the tab and the spaces may all
/// have changed since the notice appeared.
@MainActor
@Observable
public final class SpaceRouteCoordinator {
    public struct MovedNotice: Equatable, Sendable {
        public let tabID: TabID
        public let host: String
        public let fromSpaceID: SpaceID
        public let fromSpaceName: String
        public let fromFolderID: FolderID?
        public let toSpaceID: SpaceID
        public let toSpaceName: String
    }

    /// A route whose destination is locked. Nothing has moved: the person
    /// chooses between unlocking and leaving the tab where it is.
    public struct PendingUnlock: Equatable, Sendable {
        public let tabID: TabID
        public let host: String
        public let routeID: UUID
        public let toSpaceID: SpaceID
        public let toSpaceName: String
        fileprivate let generation: Int
    }

    public enum Notice: Equatable, Sendable {
        case moved(MovedNotice)
        case needsUnlock(PendingUnlock)
    }

    public private(set) var notice: Notice?
    public private(set) var routes: [SpaceRoute] = []

    @ObservationIgnored private weak var model: BrowserWindowModel?
    /// After an undo the tab stays where the person put it for as long as it
    /// remains on that host. Navigating elsewhere clears the exemption.
    @ObservationIgnored private var exemptHostByTab: [TabID: String] = [:]
    /// Bumped whenever pending work must be abandoned (profile switch, a new
    /// navigation in the same tab, a closed tab).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// How long the "moved" notice stays up. Long enough to read and undo.
    public static let noticeDuration: Duration = .seconds(10)

    public init() {}

    func attach(model: BrowserWindowModel) {
        self.model = model
        reload()
    }

    // MARK: - Rules

    /// Re-reads the active profile's rules. A read failure leaves routing
    /// off rather than guessing.
    func reload() {
        guard let model else { return }
        do {
            routes = try model.environment.spaceRouteRepository.routes()
        } catch {
            routes = []
            PersistenceFailureLog.record("space routes", error: error)
        }
    }

    /// The rule that names exactly this host, for the tab menu.
    public func exactRoute(forHost host: String) -> SpaceRoute? {
        routes.first { $0.host == host && !$0.includesSubdomains }
    }

    @discardableResult
    public func setRoute(host: String, includesSubdomains: Bool, to spaceID: SpaceID) -> Bool {
        guard let model else { return false }
        guard model.session.spaces.contains(where: { $0.id == spaceID }) else {
            model.statusMessage = "That space no longer exists."
            return false
        }
        do {
            let saved = try model.environment.spaceRouteRepository.save(
                host: host, includesSubdomains: includesSubdomains, spaceID: spaceID
            )
            reload()
            let name = model.session.spaces.first { $0.id == spaceID }?.name ?? "that space"
            model.statusMessage = "\(saved.host) will open in \(name)"
            return true
        } catch {
            model.statusMessage = error.localizedDescription
            return false
        }
    }

    public func removeRoute(_ route: SpaceRoute) {
        guard let model else { return }
        do {
            try model.environment.spaceRouteRepository.remove(id: route.id)
            reload()
            model.statusMessage = "\(route.host) no longer routes to a space"
        } catch {
            model.statusMessage = error.localizedDescription
        }
    }

    /// Applies the rule for the page the active tab is already showing, so
    /// "Always open in …" takes effect without a reload.
    public func routeActiveTabNow() {
        guard let model, let tabID = model.session.activeTabID,
              let url = model.tabURLs[tabID] else { return }
        evaluate(tabID: tabID, url: url)
    }

    // MARK: - Lifecycle hooks (small, called by the window model)

    func profileDidChange() {
        generation &+= 1
        cancelNotice()
        exemptHostByTab.removeAll()
        reload()
    }

    func tabDidClose(_ tabID: TabID) {
        exemptHostByTab[tabID] = nil
        switch notice {
        case .moved(let moved) where moved.tabID == tabID: cancelNotice()
        case .needsUnlock(let pending) where pending.tabID == tabID: generation &+= 1; cancelNotice()
        default: break
        }
    }

    func spaceDidDelete(_ spaceID: SpaceID) {
        guard let model else { return }
        do {
            try model.environment.spaceRouteRepository.removeRoutes(to: spaceID)
        } catch {
            PersistenceFailureLog.record("space routes", error: error)
        }
        reload()
        switch notice {
        case .moved(let moved) where moved.toSpaceID == spaceID || moved.fromSpaceID == spaceID: cancelNotice()
        case .needsUnlock(let pending) where pending.toSpaceID == spaceID: generation &+= 1; cancelNotice()
        default: break
        }
    }

    /// Called for every committed main-page navigation.
    func navigationCommitted(tabID: TabID, url: URL) {
        // A newer navigation in this tab invalidates a pending unlock for it.
        if case .needsUnlock(let pending) = notice, pending.tabID == tabID {
            generation &+= 1
            cancelNotice()
        }
        evaluate(tabID: tabID, url: url)
    }

    // MARK: - Decisions

    private func evaluate(tabID: TabID, url: URL) {
        guard let model, !routes.isEmpty,
              !model.session.isPrivate,
              model.peek?.tabID != tabID,
              model.session.activeTabID == tabID,
              let tab = model.session.tabs.first(where: { $0.id == tabID }),
              !tab.isPinned,
              let host = SpaceRouteHost.routableHost(of: url) else { return }
        if let exempt = exemptHostByTab[tabID] {
            if exempt == host { return }
            exemptHostByTab[tabID] = nil
        }
        guard let route = SpaceRouteMatcher.route(forHost: host, in: routes),
              route.spaceID != tab.spaceID,
              let target = model.session.spaces.first(where: { $0.id == route.spaceID }) else { return }
        guard !model.isSplitViewActive else {
            model.statusMessage = "\(host) opens in \(target.name). Close split view to move this tab."
            return
        }
        if target.isLocked, !model.isSpaceUnlocked(target.id) {
            cancelNotice()
            notice = .needsUnlock(PendingUnlock(
                tabID: tabID, host: host, routeID: route.id,
                toSpaceID: target.id, toSpaceName: target.name, generation: generation
            ))
            return
        }
        move(tab: tab, to: target, host: host)
    }

    private func move(tab: BrowserTab, to target: BrowserSpace, host: String) {
        guard let model else { return }
        let fromName = model.session.spaces.first { $0.id == tab.spaceID }?.name ?? "its space"
        let moved = MovedNotice(
            tabID: tab.id, host: host,
            fromSpaceID: tab.spaceID, fromSpaceName: fromName,
            fromFolderID: tab.folderID,
            toSpaceID: target.id, toSpaceName: target.name
        )
        model.moveTab(tab.id, toGroup: target.id)
        // `moveTab` is a no-op for a vanished space; only announce a move
        // that actually happened.
        guard model.session.tabs.first(where: { $0.id == tab.id })?.spaceID == target.id else { return }
        show(.moved(moved))
    }

    /// The person chose "Unlock and move". Authenticates first; the tab moves
    /// only after a current successful grant, and only if everything the
    /// notice described is still true.
    public func confirmUnlockAndMove() {
        guard case .needsUnlock(let pending) = notice, let model else { return }
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            let granted = await model.unlockSpace(pending.toSpaceID)
            guard self.generation == token, self.notice == .needsUnlock(pending) else { return }
            self.cancelNotice()
            guard granted else {
                model.statusMessage = "“\(pending.toSpaceName)” stayed locked"
                return
            }
            guard let tab = model.session.tabs.first(where: { $0.id == pending.tabID }),
                  model.session.activeTabID == pending.tabID,
                  !model.session.isPrivate,
                  !model.isSplitViewActive,
                  let url = model.tabURLs[pending.tabID],
                  SpaceRouteHost.routableHost(of: url) == pending.host,
                  let route = self.routes.first(where: { $0.id == pending.routeID }),
                  SpaceRouteMatcher.route(forHost: pending.host, in: self.routes)?.id == route.id,
                  let target = model.session.spaces.first(where: { $0.id == route.spaceID }),
                  target.id == pending.toSpaceID,
                  tab.spaceID != target.id else { return }
            self.move(tab: tab, to: target, host: pending.host)
        }
    }

    /// Reverses a routed move, but only if that is still safe and sensible.
    public func undo() {
        guard case .moved(let moved) = notice, let model else { return }
        cancelNotice()
        guard let tab = model.session.tabs.first(where: { $0.id == moved.tabID }),
              tab.spaceID == moved.toSpaceID else {
            model.statusMessage = "That tab has moved since, so nothing was changed."
            return
        }
        guard let origin = model.session.spaces.first(where: { $0.id == moved.fromSpaceID }) else {
            model.statusMessage = "“\(moved.fromSpaceName)” no longer exists, so the tab stays put."
            return
        }
        guard model.isSpaceUnlocked(origin.id) else {
            model.statusMessage = "“\(origin.name)” is locked. Unlock it, then move the tab back."
            return
        }
        exemptHostByTab[moved.tabID] = moved.host
        model.moveTab(moved.tabID, toGroup: origin.id)
        if let folderID = moved.fromFolderID, model.folder(folderID)?.spaceID == origin.id {
            model.assignTab(moved.tabID, toFolder: folderID)
        }
        model.statusMessage = "Moved back to \(origin.name)"
    }

    public func dismissNotice() {
        if case .needsUnlock = notice { generation &+= 1 }
        cancelNotice()
    }

    // MARK: - Notice plumbing

    private func show(_ next: Notice) {
        cancelNotice()
        notice = next
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func cancelNotice() {
        dismissTask?.cancel()
        dismissTask = nil
        notice = nil
    }
}
