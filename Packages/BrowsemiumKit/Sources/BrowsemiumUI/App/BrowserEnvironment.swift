import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import Foundation

@MainActor
public final class BrowserEnvironment {
    public let rootDatabase: AppDatabase
    public let profileStore: ProfileStore
    public private(set) var activeProfile: BrowserProfile
    public private(set) var database: AppDatabase

    public let runtime: BrowserRuntimeController
    public private(set) var settingsRepository: SettingsRepository
    public private(set) var sessionRepository: BrowserSessionRepository
    public private(set) var historyRepository: HistoryRepository
    public private(set) var bookmarkRepository: BookmarkRepository
    public private(set) var downloadRepository: DownloadRepository
    public private(set) var permissionRepository: PermissionRepository
    public private(set) var closedTabRepository: ClosedTabRepository
    public private(set) var savedCredentialRepository: SavedCredentialRepository
    public private(set) var privacyDataManager: PrivacyDataManager
    public private(set) var maintenance: DatabaseMaintenance
    public let keychain: KeychainStore

    public init(rootDatabase: AppDatabase, profileStore: ProfileStore, activeProfile: BrowserProfile) throws {
        self.rootDatabase = rootDatabase
        self.profileStore = profileStore
        self.activeProfile = activeProfile
        database = try profileStore.database(for: activeProfile)
        runtime = BrowserRuntimeController()
        settingsRepository = SettingsRepository(database: database)
        sessionRepository = BrowserSessionRepository(database: database)
        historyRepository = HistoryRepository(database: database)
        bookmarkRepository = BookmarkRepository(database: database)
        downloadRepository = DownloadRepository(database: database)
        permissionRepository = PermissionRepository(database: database)
        closedTabRepository = ClosedTabRepository(database: database)
        savedCredentialRepository = SavedCredentialRepository(database: database)
        privacyDataManager = PrivacyDataManager(database: database)
        maintenance = DatabaseMaintenance(database: database)
        keychain = KeychainStore()
        WebViewFactory.dataStoreIdentifier = activeProfile.dataStoreUUID
    }

    public static func live() throws -> BrowserEnvironment {
        let directory = try applicationSupportDirectory()
        let databaseURL = directory.appendingPathComponent("browsemium.sqlite")
        let rootDatabase = try AppDatabase(path: databaseURL.path)
        // Done before any web view exists, so WebKit never has to ask macOS for
        // permission to read its WebCrypto key. Ad-hoc builds only.
        WebCryptoKeychainItem.claimForAdHocBuilds()
        let profileStore = ProfileStore(
            root: rootDatabase,
            directory: directory.appendingPathComponent("profiles", isDirectory: true)
        )
        try profileStore.splitIfNeeded()
        let profiles = try profileStore.profiles()
        guard let active = profiles.max(by: { $0.lastUsedAt < $1.lastUsedAt }) else {
            throw BrowsemiumError.databaseFailure("No browser profile could be created.")
        }
        return try BrowserEnvironment(rootDatabase: rootDatabase, profileStore: profileStore, activeProfile: active)
    }

    public static func inMemory() -> BrowserEnvironment {
        do {
            let rootDatabase = try AppDatabase.inMemory()
            let profileStore = ProfileStore(
                root: rootDatabase,
                directory: URL(fileURLWithPath: "/dev/null"),
                isMemory: true
            )
            try profileStore.splitIfNeeded()
            guard let profile = try profileStore.profiles().first else {
                fatalError("Browsemium could not create an in-memory profile.")
            }
            return try BrowserEnvironment(rootDatabase: rootDatabase, profileStore: profileStore, activeProfile: profile)
        } catch {
            fatalError("Browsemium could not create its in-memory database: \(error)")
        }
    }

    // MARK: - Profiles

    /// Keychain account for an AI provider credential, scoped to the active
    /// profile so two profiles can hold different keys for the same provider.
    /// A key saved by a pre-profiles build is migrated on first use.
    public func providerCredentialAccount(_ provider: AIProviderID) -> String {
        let scoped = "profile.\(activeProfile.id.uuidString).provider.\(provider.rawValue)"
        let legacy = "provider.\(provider.rawValue)"
        if (try? keychain.hasSecret(account: scoped)) != true,
           let value = try? keychain.secret(account: legacy),
           !value.isEmpty {
            try? keychain.setSecret(value, account: scoped)
            try? keychain.deleteSecret(account: legacy)
        }
        return scoped
    }

    public var profiles: [BrowserProfile] {
        (try? profileStore.profiles()) ?? [activeProfile]
    }

    /// Points every repository at the profile's database and hands its WebKit
    /// data store to new web views. Callers must tear the runtime down and
    /// rebuild the window's session around this.
    public func activate(_ profile: BrowserProfile) throws {
        database = try profileStore.database(for: profile)
        activeProfile = profile
        settingsRepository = SettingsRepository(database: database)
        sessionRepository = BrowserSessionRepository(database: database)
        historyRepository = HistoryRepository(database: database)
        bookmarkRepository = BookmarkRepository(database: database)
        downloadRepository = DownloadRepository(database: database)
        permissionRepository = PermissionRepository(database: database)
        closedTabRepository = ClosedTabRepository(database: database)
        savedCredentialRepository = SavedCredentialRepository(database: database)
        privacyDataManager = PrivacyDataManager(database: database)
        maintenance = DatabaseMaintenance(database: database)
        WebViewFactory.dataStoreIdentifier = profile.dataStoreUUID
        try? profileStore.touch(id: profile.id)
    }

    public func createProfile(name: String) throws -> BrowserProfile {
        try profileStore.create(name: name)
    }

    public func renameProfile(_ profile: BrowserProfile, to name: String) throws {
        try profileStore.rename(id: profile.id, to: name)
        if profile.id == activeProfile.id {
            activeProfile = BrowserProfile(
                id: profile.id,
                name: name,
                createdAt: profile.createdAt,
                lastUsedAt: profile.lastUsedAt,
                dataStoreUUID: profile.dataStoreUUID
            )
        }
    }

    public func deleteProfile(_ profile: BrowserProfile) throws {
        try profileStore.delete(id: profile.id)
    }

    // MARK: - Settings

    public func loadSettings() -> BrowserSettings {
        (try? settingsRepository.load()) ?? BrowserSettings()
    }

    public func saveSettings(_ settings: BrowserSettings) {
        try? settingsRepository.save(settings)
    }

    public func runMaintenance() {
        let settings = loadSettings()
        _ = try? maintenance.run(settings: settings)
    }

    private static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Browsemium", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
