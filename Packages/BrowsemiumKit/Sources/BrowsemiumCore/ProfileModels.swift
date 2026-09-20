import Foundation

/// A browser profile. Each profile owns an isolated WebKit data store
/// (cookies, logins, site storage) and its own database for bookmarks,
/// history, sessions, and saved credentials.
public struct BrowserProfile: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let lastUsedAt: Date
    /// Identifier handed to `WKWebsiteDataStore(forIdentifier:)`. Kept
    /// separate from `id` so a profile's storage can be reset without
    /// changing its identity.
    public let dataStoreUUID: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        dataStoreUUID: UUID = UUID()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.dataStoreUUID = dataStoreUUID
    }

    public var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "P" : letters.joined().uppercased()
    }
}
