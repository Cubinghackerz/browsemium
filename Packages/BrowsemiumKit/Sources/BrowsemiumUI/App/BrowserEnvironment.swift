import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import Foundation

@MainActor
public final class BrowserEnvironment {
    public let database: AppDatabase
    public let runtime: BrowserRuntimeController
    public let settingsRepository: SettingsRepository
    public let sessionRepository: BrowserSessionRepository
    public let historyRepository: HistoryRepository
    public let bookmarkRepository: BookmarkRepository
    public let downloadRepository: DownloadRepository
    public let permissionRepository: PermissionRepository
    public let closedTabRepository: ClosedTabRepository
    public let savedCredentialRepository: SavedCredentialRepository
    public let privacyDataManager: PrivacyDataManager
    public let maintenance: DatabaseMaintenance
    public let keychain: KeychainStore

    public init(database: AppDatabase) throws {
        self.database = database
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
    }

    public static func live() throws -> BrowserEnvironment {
        let directory = try applicationSupportDirectory()
        let databaseURL = directory.appendingPathComponent("browsemium.sqlite")
        let database = try AppDatabase(path: databaseURL.path)
        return try BrowserEnvironment(database: database)
    }

    public static func inMemory() -> BrowserEnvironment {
        do {
            let database = try AppDatabase.inMemory()
            return try BrowserEnvironment(database: database)
        } catch {
            fatalError("Browsemium could not create its in-memory database: \(error)")
        }
    }

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
