import BrowsemiumCore
import Foundation

/// Layout data for the sidebar, kept apart from the views so it can be tested.

/// Pinned tabs sit in a grid of icon tiles above the list.
enum PinnedGrid {
    static let columns = 3

    /// The items split into rows of at most `columns`, in order.
    static func rows<T>(_ items: [T], columns: Int = PinnedGrid.columns) -> [[T]] {
        guard columns > 0, !items.isEmpty else { return [] }
        return stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0..<min($0 + columns, items.count)])
        }
    }
}

/// One space in the switcher row at the sidebar's foot.
struct SpaceSwitcherItem: Identifiable, Equatable {
    enum Glyph: Equatable {
        case lock
        case separateData

        var symbolName: String {
            switch self {
            case .lock: "lock.fill"
            case .separateData: "person.crop.square"
            }
        }
    }

    let id: SpaceID
    let name: String
    let colorHex: String?
    let isActive: Bool
    let isLocked: Bool
    let hasSeparateData: Bool

    /// A locked space shows the lock even when it also has its own data: the
    /// lock is the thing that changes what clicking does.
    var glyph: Glyph? {
        if isLocked { return .lock }
        if hasSeparateData { return .separateData }
        return nil
    }

    var accessibilityLabel: String {
        var label = "Space \(name)"
        if isLocked { label += ", locked" }
        if hasSeparateData { label += ", keeps its own cookies and logins" }
        if isActive { label += ", current" }
        return label
    }
}

enum SpaceSwitcher {
    static func items(spaces: [BrowserSpace], active: SpaceID) -> [SpaceSwitcherItem] {
        spaces.map {
            SpaceSwitcherItem(
                id: $0.id,
                name: $0.name,
                colorHex: $0.color,
                isActive: $0.id == active,
                isLocked: $0.isLocked,
                hasSeparateData: $0.hasSeparateData
            )
        }
    }

    /// The row is only worth showing when there is something to switch to,
    /// and never in a private window, which has one throwaway space.
    static func isVisible(spaceCount: Int, isPrivate: Bool) -> Bool {
        spaceCount > 1 && !isPrivate
    }
}
