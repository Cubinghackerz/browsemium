import BrowsemiumCore
import BrowsemiumData
import Foundation

/// One row of "Pick up where you left off" on the start page.
struct PickUpRow: Identifiable, Equatable {
    enum Source: Equatable { case recentlyClosed, archived }

    let entry: ClosedTabEntry
    let source: Source
    var id: String { "\(source == .archived ? "a" : "c")-\(entry.id)" }
    var url: URL { entry.url! }

    var title: String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (entry.url?.host ?? "Untitled") : trimmed
    }

    var host: String { entry.url?.host ?? "" }
}

/// What the start page offers, kept apart from the view so it can be tested.
enum NewTabContent {
    /// The newest pages the person closed or that were put away, newest first.
    ///
    /// Entries without an address are dropped, as are repeats of the same
    /// address. `isEligible` decides by space: pages from locked spaces and
    /// from spaces with their own data never appear on another space's start
    /// page.
    static func pickUp(
        closed: [ClosedTabEntry],
        archived: [ClosedTabEntry],
        limit: Int = 4,
        isEligible: (SpaceID) -> Bool
    ) -> [PickUpRow] {
        let all = closed.map { PickUpRow(entry: $0, source: .recentlyClosed) }
            + archived.map { PickUpRow(entry: $0, source: .archived) }
        var seen = Set<String>()
        var rows: [PickUpRow] = []
        for row in all.sorted(by: { $0.entry.closedAt > $1.entry.closedAt }) {
            guard let url = row.entry.url, isEligible(row.entry.spaceID),
                  seen.insert(url.absoluteString).inserted else { continue }
            rows.append(row)
            if rows.count == limit { break }
        }
        return rows
    }

    /// Whether pages closed in `spaceID` may be offered on `active`'s start
    /// page. Locked spaces never are, spaces with their own data only on
    /// their own page, and a deleted space is treated as unknown and skipped.
    static func isEligible(_ spaceID: SpaceID, spaces: [BrowserSpace], active: SpaceID?) -> Bool {
        guard let space = spaces.first(where: { $0.id == spaceID }), !space.isLocked else { return false }
        return !space.hasSeparateData || spaceID == active
    }

    /// The single letter drawn when a site has no cached favicon.
    static func fallbackLetter(forHost host: String?) -> String {
        let name = (host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }) else { return "•" }
        return String(first).uppercased()
    }
}

/// A destination offered by the start page.
enum NewTabTarget: Equatable {
    case search(String)
    case site(URL)
    case pickUp(PickUpRow)
}

extension NewTabTarget {
    /// Routes through the same paths the address field uses, so tiles never
    /// duplicate resolver or reopen logic.
    @MainActor
    func perform(in model: BrowserWindowModel) {
        switch self {
        case .search(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            model.addressText = trimmed
            model.submitAddress()
        case .site(let url):
            model.open(url)
        case .pickUp(let row):
            // The start tab itself becomes the page, so no blank tab is left
            // behind. The entry leaves its list exactly as a reopen would.
            switch row.source {
            case .recentlyClosed: _ = try? model.environment.closedTabRepository.remove(id: row.entry.id)
            case .archived: _ = try? model.environment.archivedTabRepository.remove(id: row.entry.id)
            }
            model.open(row.url)
        }
    }
}
