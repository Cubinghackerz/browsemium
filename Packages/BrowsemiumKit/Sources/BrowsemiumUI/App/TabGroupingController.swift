import BrowsemiumAI
import BrowsemiumCore
import Foundation
import Observation

/// Suggests folders for the current space's loose tabs and applies the ones
/// the person keeps. Nothing runs on its own, and nothing changes until the
/// preview is confirmed.
@MainActor
@Observable
public final class TabGroupingController {
    public struct Row: Identifiable, Equatable {
        public let id: UUID
        public var name: String
        public var isIncluded: Bool
        public let tabs: [Member]

        public struct Member: Equatable, Identifiable {
            public let id: TabID
            public let title: String
            public let host: String?
        }
    }

    public enum Phase: Equatable {
        case idle
        case working
        case ready
        case failed(String)
    }

    public var isPresented = false
    public private(set) var phase: Phase = .idle
    public var rows: [Row] = []
    /// True when the suggestions came from the on-device model, false for
    /// the same-site fallback. The sheet says which, so nobody assumes more
    /// intelligence than was used.
    public private(set) var usedModel = false

    @ObservationIgnored private weak var model: BrowserWindowModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestedSpace: SpaceID?
    /// Injectable so tests drive both paths without a model.
    @ObservationIgnored public var modelGrouper: () -> (any TabGroupProposing)? = { AppleIntelligenceTabGrouper.makeIfAvailable() }

    func attach(model: BrowserWindowModel) { self.model = model }

    /// Starts a suggestion run for the active space.
    public func begin() {
        guard let model else { return }
        guard !model.session.isPrivate else {
            model.statusMessage = "Tab groups are not suggested in private windows."
            return
        }
        let candidates = Self.candidates(in: model)
        guard candidates.count >= 3 else {
            model.statusMessage = "Not enough loose tabs to suggest groups."
            return
        }
        task?.cancel()
        requestedSpace = model.session.activeSpaceID
        rows = []
        phase = .working
        usedModel = false
        isPresented = true
        let grouper = modelGrouper()
        task = Task { [weak self] in
            var proposals: [TabGroupProposal] = []
            var usedModel = false
            if let grouper {
                proposals = (try? await grouper.propose(candidates)) ?? []
                usedModel = !proposals.isEmpty
            }
            if proposals.isEmpty {
                proposals = DomainTabGrouper.proposals(for: candidates)
            }
            guard !Task.isCancelled else { return }
            self?.finish(proposals: proposals, candidates: candidates, usedModel: usedModel)
        }
    }

    private func finish(proposals: [TabGroupProposal], candidates: [TabGroupCandidate], usedModel: Bool) {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        rows = proposals.map { proposal in
            Row(
                id: proposal.id,
                name: proposal.name,
                isIncluded: true,
                tabs: proposal.tabIDs.compactMap { id in
                    byID[id].map { Row.Member(id: id, title: $0.title, host: $0.host) }
                }
            )
        }
        self.usedModel = usedModel
        phase = rows.isEmpty ? .failed("No groups stood out. Your tabs look unrelated.") : .ready
    }

    /// Creates a folder for each kept row. Tabs that changed since the
    /// suggestion (closed, pinned, filed elsewhere, moved space) are skipped.
    public func apply() {
        guard let model, phase == .ready else { return }
        guard model.session.activeSpaceID == requestedSpace else {
            model.statusMessage = "The space changed, so no groups were made."
            dismiss()
            return
        }
        var folders = 0
        var tabs = 0
        for row in rows where row.isIncluded {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let eligible = row.tabs.filter { member in
                model.session.tabs.first { $0.id == member.id }
                    .map { !$0.isPinned && $0.folderID == nil && $0.spaceID == requestedSpace } ?? false
            }
            guard eligible.count >= 2, !name.isEmpty else { continue }
            let folder = model.createFolder(named: name)
            for member in eligible { model.assignTab(member.id, toFolder: folder) }
            folders += 1
            tabs += eligible.count
        }
        model.statusMessage = folders == 0
            ? "No groups were made."
            : "Grouped \(tabs) tabs into \(folders) \(folders == 1 ? "folder" : "folders")"
        dismiss()
    }

    public func dismiss() {
        task?.cancel()
        task = nil
        isPresented = false
        phase = .idle
        rows = []
    }

    /// Loose tabs in the active space: not pinned, not already filed.
    static func candidates(in model: BrowserWindowModel) -> [TabGroupCandidate] {
        model.visibleTabs
            .filter { !$0.isPinned && $0.folderID == nil }
            .prefix(TabGrouping.maximumCandidates)
            .map { tab in
                let url = model.tabURLs[tab.id] ?? tab.lastCommittedURL
                return TabGroupCandidate(
                    id: tab.id,
                    title: tab.title.isEmpty ? (url?.host ?? "Untitled") : tab.title,
                    host: url.flatMap { SpaceRouteHost.routableHost(of: $0) }
                )
            }
    }
}
