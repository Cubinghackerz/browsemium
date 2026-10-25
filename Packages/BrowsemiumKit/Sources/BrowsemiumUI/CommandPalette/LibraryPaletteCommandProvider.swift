import BrowsemiumCore
import BrowsemiumData
import Foundation

/// Pure row construction/ranking. Repository reads remain in the model so the
/// provider never opens stores or prompts for any secret.
enum LibraryPaletteCommandProvider {
    static func skills(_ skills: [AISkill]) -> [BrowserPaletteCommand] {
        skills.map { skill in
            BrowserPaletteCommand(id: "skill-\(skill.id.uuidString)", title: "Run Skill: \(skill.name)", shortcut: "",
                                  kind: .action, subtitle: String(skill.prompt.prefix(80)), command: .runAISkill(skill))
        }
    }

    static func ranked(_ commands: [BrowserPaletteCommand], query: String, limit: Int) -> [BrowserPaletteCommand] {
        commands.compactMap { command -> (BrowserPaletteCommand, Int)? in
            let best = [command.title, command.subtitle].compactMap { FuzzyMatcher.score(query: query, candidate: $0) }.max()
            guard let best else { return nil }
            return (command, best)
        }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static func history(_ visits: [HistoryVisit], query: String, session: BrowserSessionState,
                        tabURLs: [TabID: URL]) -> [BrowserPaletteCommand] {
        var seen = Set(session.tabs.compactMap { (tabURLs[$0.id] ?? $0.lastCommittedURL)?.absoluteString })
        return visits.compactMap { visit -> (BrowserPaletteCommand, Int)? in
            guard seen.insert(visit.url.absoluteString).inserted else { return nil }
            let title = visit.title.isEmpty ? (visit.url.host ?? visit.url.absoluteString) : visit.title
            let best = [title, visit.url.absoluteString].compactMap { FuzzyMatcher.score(query: query, candidate: $0) }.max()
            guard let best else { return nil }
            return (BrowserPaletteCommand(id: "history-\(visit.url.absoluteString)", title: title,
                shortcut: visit.url.host ?? "", kind: .history, subtitle: visit.url.host ?? visit.url.absoluteString,
                command: .openURLInNewTab(visit.url)), best)
        }.sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
    }

    static func bookmarks(_ bookmarks: [Bookmark]) -> [BrowserPaletteCommand] {
        bookmarks.map { bookmark in
            BrowserPaletteCommand(id: "bookmark-\(bookmark.url.absoluteString)",
                title: bookmark.title.isEmpty ? (bookmark.url.host ?? bookmark.url.absoluteString) : bookmark.title,
                shortcut: bookmark.url.host ?? "", kind: .bookmark, subtitle: bookmark.url.host ?? bookmark.url.absoluteString,
                command: .openURLInNewTab(bookmark.url))
        }
    }

    /// Page-text hits from the opt-in on-Mac index. Already FTS-ranked, so
    /// this only fuzzy-filters and dedupes against open tabs.
    static func pageTexts(_ entries: [PageTextEntry], query: String, session: BrowserSessionState,
                          tabURLs: [TabID: URL]) -> [BrowserPaletteCommand] {
        var seen = Set(session.tabs.compactMap { (tabURLs[$0.id] ?? $0.lastCommittedURL)?.absoluteString })
        return entries.compactMap { entry -> (BrowserPaletteCommand, Int)? in
            guard seen.insert(entry.url.absoluteString).inserted else { return nil }
            let title = entry.title.isEmpty ? (entry.url.host ?? entry.url.absoluteString) : entry.title
            let best = [title, entry.url.absoluteString, entry.snippet].compactMap {
                FuzzyMatcher.score(query: query, candidate: $0)
            }.max()
            guard let best else { return nil }
            return (BrowserPaletteCommand(id: "pagetext-\(entry.url.absoluteString)", title: title,
                shortcut: entry.url.host ?? "", kind: .pageText,
                subtitle: "Page text — \(entry.url.host ?? entry.url.absoluteString)",
                command: .openURLInNewTab(entry.url)), best)
        }.sorted { $0.1 > $1.1 }.prefix(4).map(\.0)
    }
}
