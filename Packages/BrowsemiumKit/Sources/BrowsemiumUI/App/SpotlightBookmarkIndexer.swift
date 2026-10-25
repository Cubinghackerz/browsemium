import BrowsemiumCore
import BrowsemiumData
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// One bookmark as Spotlight receives it. No page text, no history.
public struct SpotlightItem: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let url: URL
    public let host: String
}

/// The seam over `CSSearchableIndex`, so tests can watch what would be sent.
public protocol SearchableIndexing: Sendable {
    func index(_ items: [SpotlightItem], domain: String) async throws
    func deleteAll(domain: String) async throws
}

/// Used by in-memory environments (tests, previews) so they never touch the
/// real Spotlight index, whose domain is shared across the whole machine.
public struct NullSearchableIndex: SearchableIndexing {
    public init() {}
    public func index(_ items: [SpotlightItem], domain: String) async throws {}
    public func deleteAll(domain: String) async throws {}
}

public struct SystemSearchableIndex: SearchableIndexing {
    public init() {}

    public func index(_ items: [SpotlightItem], domain: String) async throws {
        let searchable = items.map { item -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .url)
            attributes.title = item.title
            attributes.contentDescription = item.host
            attributes.url = item.url
            let result = CSSearchableItem(uniqueIdentifier: item.identifier, domainIdentifier: domain, attributeSet: attributes)
            result.expirationDate = .distantFuture
            return result
        }
        try await CSSearchableIndex.default().indexSearchableItems(searchable)
    }

    public func deleteAll(domain: String) async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
    }
}

/// Keeps Spotlight's copy of the active profile's bookmarks equal to what
/// Settings allows. Every reconcile clears Browsemium's domain first and then,
/// only if the feature is on, adds the eligible bookmarks, so turning it off,
/// switching profile, removing a bookmark or clearing data all leave nothing
/// behind. Spotlight never gets a bookmark the person has not saved from an
/// ordinary window.
@MainActor
public final class SpotlightBookmarkIndexer {
    private weak var environment: BrowserEnvironment?
    var index: any SearchableIndexing
    private var generation = 0
    private(set) var lastItems: [SpotlightItem] = []
    /// Whether this run has cleared the domain at least once, so leftovers
    /// from a crash or an older run never outlive a switched-off setting.
    private var hasSynced = false

    init(environment: BrowserEnvironment, index: any SearchableIndexing = SystemSearchableIndex()) {
        self.environment = environment
        self.index = index
    }

    /// The items the current settings and bookmarks allow. Pure of side effects.
    public static func items(for bookmarks: [Bookmark], enabled: Bool) -> [SpotlightItem] {
        guard enabled else { return [] }
        return bookmarks
            .filter { SpotlightPolicy.isEligible(url: $0.url, creationEligible: $0.isSpotlightEligible) }
            .prefix(SpotlightPolicy.maxItems)
            .map { bookmark in
                let host = bookmark.url.host ?? ""
                return SpotlightItem(
                    identifier: bookmark.id.uuidString,
                    title: bookmark.title.isEmpty ? host : bookmark.title,
                    url: bookmark.url,
                    host: host
                )
            }
    }

    /// Replaces Spotlight's copy with what is allowed now. A later call
    /// supersedes an earlier one that is still running. Nothing is sent when
    /// the allowed set has not changed since the last sync, so calling this
    /// on every bookmark refresh costs no Spotlight traffic.
    @discardableResult
    public func reconcile() -> Task<Void, Never> {
        let enabled = environment?.loadSettings().indexBookmarksInSpotlight ?? false
        let bookmarks = enabled ? ((try? environment?.bookmarkRepository.all()) ?? []) : []
        let items = Self.items(for: bookmarks, enabled: enabled)
        if hasSynced, items == lastItems { return Task {} }
        hasSynced = true
        generation += 1
        let mine = generation
        lastItems = items
        let index = index
        return Task { [weak self] in
            do {
                try await index.deleteAll(domain: SpotlightPolicy.domainIdentifier)
                guard !items.isEmpty, self?.generation == mine else { return }
                try await index.index(items, domain: SpotlightPolicy.domainIdentifier)
            } catch {
                // Spotlight being unavailable must never affect browsing.
            }
        }
    }

    /// The address a Spotlight result stands for, or nil. The identifier must
    /// name a bookmark that still exists, is still eligible, and the feature
    /// must still be on, so a stale or forged activity opens nothing.
    public func resolve(identifier: String) -> URL? {
        guard environment?.loadSettings().indexBookmarksInSpotlight == true,
              let id = UUID(uuidString: identifier),
              let bookmark = ((try? environment?.bookmarkRepository.all()) ?? []).first(where: { $0.id == id }),
              SpotlightPolicy.isEligible(url: bookmark.url, creationEligible: bookmark.isSpotlightEligible) else { return nil }
        return bookmark.url
    }
}
