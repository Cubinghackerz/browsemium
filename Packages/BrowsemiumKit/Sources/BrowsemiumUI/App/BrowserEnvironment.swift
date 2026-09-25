import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import BrowsemiumEngineKit
import BrowsemiumExtensions
import Foundation
import BrowsemiumEngineKit

@MainActor
public final class BrowserEnvironment {
    public let rootDatabase: AppDatabase
    public let profileStore: ProfileStore
    public private(set) var activeProfile: BrowserProfile
    public private(set) var database: AppDatabase

    /// The web engine this window browses with. WebKit by default; the
    /// Chromium edition passes its own.
    public let engine: any BrowserEngine
    public private(set) var settingsRepository: SettingsRepository
    public private(set) var sessionRepository: BrowserSessionRepository
    public private(set) var historyRepository: HistoryRepository
    public private(set) var bookmarkRepository: BookmarkRepository
    public private(set) var downloadRepository: DownloadRepository
    public private(set) var permissionRepository: PermissionRepository
    public private(set) var closedTabRepository: ClosedTabRepository
    public private(set) var savedCredentialRepository: SavedCredentialRepository
    public private(set) var sitePreferenceRepository: SitePreferenceRepository
    public private(set) var conversationRepository: AIConversationRepository
    public private(set) var aiSkillRepository: AISkillRepository
    public private(set) var extensionRepository: ExtensionRepository
    public private(set) var privacyDataManager: PrivacyDataManager
    public private(set) var maintenance: DatabaseMaintenance
    /// The on-disk extension store. Files are shared between profiles; what
    /// each profile *loads* is decided by `extensionRepository`.
    public let extensionStore: ExtensionStore
    /// Downloads Chrome Web Store packages (beta). A `var` so tests can stub
    /// the network; the default hits Google's public update service.
    public var chromeWebStore: any ChromeWebStoreDownloading = ChromeWebStoreDownloader()
    /// Backing store for the extension host. Held untyped because stored
    /// properties cannot carry `@available`; use `extensionHost` instead.
    private var extensionHostStorage: AnyObject?
    public let keychain: KeychainStore

    /// The active profile's WebKit extension host. Nil on macOS < 15.4,
    /// where WebKit has no public extension API.
    @available(macOS 15.4, *)
    public var extensionHost: ExtensionHost? {
        extensionHostStorage as? ExtensionHost
    }

    public init(
        rootDatabase: AppDatabase,
        profileStore: ProfileStore,
        activeProfile: BrowserProfile,
        engine: (any BrowserEngine)? = nil,
        extensionStore: ExtensionStore? = nil,
        keychain: KeychainStore = KeychainStore()
    ) throws {
        self.rootDatabase = rootDatabase
        self.profileStore = profileStore
        self.activeProfile = activeProfile
        database = try profileStore.database(for: activeProfile)
        self.engine = engine ?? BrowserRuntimeController()
        settingsRepository = SettingsRepository(database: database)
        sessionRepository = BrowserSessionRepository(database: database)
        historyRepository = HistoryRepository(database: database)
        bookmarkRepository = BookmarkRepository(database: database)
        downloadRepository = DownloadRepository(database: database)
        permissionRepository = PermissionRepository(database: database)
        closedTabRepository = ClosedTabRepository(database: database)
        savedCredentialRepository = SavedCredentialRepository(database: database)
        sitePreferenceRepository = SitePreferenceRepository(database: database)
        conversationRepository = AIConversationRepository(database: database)
        aiSkillRepository = AISkillRepository(database: database)
        extensionRepository = ExtensionRepository(database: database)
        privacyDataManager = PrivacyDataManager(database: database)
        maintenance = DatabaseMaintenance(database: database)
        if let extensionStore {
            self.extensionStore = extensionStore
        } else {
            // Application Support is created on demand; if even that fails,
            // extensions still work for this run rather than crashing launch.
            let root = (try? ExtensionStore.defaultRootDirectory())
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("Browsemium/Extensions", isDirectory: true)
            self.extensionStore = ExtensionStore(rootDirectory: root)
        }
        self.keychain = keychain
        WebViewFactory.dataStoreIdentifier = activeProfile.dataStoreUUID
        rebuildExtensionHost()
    }

    public static func live(engine: (any BrowserEngine)? = nil) throws -> BrowserEnvironment {
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
        return try BrowserEnvironment(
            rootDatabase: rootDatabase,
            profileStore: profileStore,
            activeProfile: active,
            engine: engine
        )
    }

    public static func inMemory(
        engine: (any BrowserEngine)? = nil,
        extensionStore: ExtensionStore? = nil,
        keychain: KeychainStore = KeychainStore()
    ) -> BrowserEnvironment {
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
            return try BrowserEnvironment(
                rootDatabase: rootDatabase,
                profileStore: profileStore,
                activeProfile: profile,
                engine: engine,
                extensionStore: extensionStore,
                keychain: keychain
            )
        } catch {
            fatalError("Browsemium could not create its in-memory database: \(error)")
        }
    }

    // MARK: - Profiles

    /// Keychain account for an AI provider credential, scoped to the active
    /// profile so two profiles can hold different keys for the same provider.
    /// A key saved by a pre-profiles build is migrated on first use.
    public func providerCredentialAccount(_ provider: AIProviderID) -> String {
        let scoped = Self.providerCredentialAccount(provider, profileID: activeProfile.id)
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
        sitePreferenceRepository = SitePreferenceRepository(database: database)
        conversationRepository = AIConversationRepository(database: database)
        aiSkillRepository = AISkillRepository(database: database)
        extensionRepository = ExtensionRepository(database: database)
        privacyDataManager = PrivacyDataManager(database: database)
        maintenance = DatabaseMaintenance(database: database)
        WebViewFactory.dataStoreIdentifier = profile.dataStoreUUID
        rebuildExtensionHost()
        try? profileStore.touch(id: profile.id)
    }

    // MARK: - Extensions

    /// Builds the profile's extension host and attaches it to the web-view
    /// factory. Called on launch and after a profile switch: extension
    /// storage is keyed to the profile's data store, so a switch must never
    /// reuse the previous host.
    public func rebuildExtensionHost() {
        guard #available(macOS 15.4, *) else { return }
        extensionHost?.unloadAll()
        let host = ExtensionHost(profileIdentifier: activeProfile.dataStoreUUID)
        extensionHostStorage = host
        WebViewFactory.extensionController = host.controller
    }

    /// Loads every extension this profile has enabled, and unloads any that
    /// are no longer enabled — the registry is authoritative, so disabling an
    /// extension in Settings takes effect immediately instead of at relaunch.
    /// Extensions that fail to load keep their record and store the error for
    /// Settings to show.
    public func loadEnabledExtensions() async {
        guard #available(macOS 15.4, *) else { return }
        if extensionHost == nil {
            rebuildExtensionHost()
        }
        guard let host = extensionHost else { return }
        let records = (try? extensionRepository.all()) ?? []
        let enabledIDs = Set(records.filter(\.isEnabled).map(\.id))
        for id in host.contexts.keys where !enabledIDs.contains(id) {
            host.unload(id: id)
        }
        let installed = Dictionary(
            uniqueKeysWithValues: ((try? extensionStore.installed()) ?? []).map { ($0.id, $0) }
        )
        for record in records where record.isEnabled {
            guard let item = installed[record.id] else {
                try? extensionRepository.setLastError(id: record.id, message: "The extension's files are missing.")
                continue
            }
            await host.load(item)
            if let error = host.loadErrors[record.id] {
                try? extensionRepository.setLastError(id: record.id, message: error)
            } else {
                let name = host.displayNames[record.id] ?? record.name
                let version = host.displayVersions[record.id] ?? record.version
                if name != record.name || version != record.version {
                    _ = try? extensionRepository.upsert(id: record.id, name: name, version: version)
                }
                try? extensionRepository.setLastError(id: record.id, message: nil)
            }
        }
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

    public func deleteProfile(_ profile: BrowserProfile) async throws {
        let profileDatabase = try profileStore.database(for: profile)
        let credentialAccounts = try SavedCredentialRepository(database: profileDatabase)
            .all()
            .map(\.keychainAccount)
        let providerAccounts = AIProviderID.allCases.map {
            Self.providerCredentialAccount($0, profileID: profile.id)
        }

        try await engine.removeProfileDataStore(dataStoreIdentifier: profile.dataStoreUUID)
        for account in credentialAccounts + providerAccounts {
            try keychain.deleteSecret(account: account)
        }
        try profileStore.delete(id: profile.id)
    }

    private static func providerCredentialAccount(_ provider: AIProviderID, profileID: UUID) -> String {
        "profile.\(profileID.uuidString).provider.\(provider.rawValue)"
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

    /// Work that has to happen while the app is still alive. "Clear history
    /// when Browsemium quits" was stored and shown in Settings and onboarding
    /// but nothing ever read it, so the promise went unkept.
    public func runTerminationTasks() {
        guard loadSettings().clearOnQuit else { return }
        try? privacyDataManager.clear([.history, .closedTabs])
    }

    private static func applicationSupportDirectory() throws -> URL {
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--profile-dir=") }) {
            let path = String(argument.dropFirst("--profile-dir=".count))
            guard !path.isEmpty else {
                throw BrowsemiumError.databaseFailure("The requested profile directory is empty.")
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
        let directory = base.appendingPathComponent("Browsemium", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
