import BrowsemiumCore
import BrowsemiumData
import Foundation
import Testing

/// Chrome writes user-visible profile names into "Local State". Without this,
/// every extra profile was offered as "Chrome — Profile 2".
@Test
func chromeLocalStateProvidesProfileDisplayNames() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-localstate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let payload: [String: Any] = [
        "profile": [
            "info_cache": [
                "Default": ["name": "Work"],
                "Profile 1": ["name": "Personal"],
                "Profile 2": ["name": ""]
            ]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try data.write(to: directory.appendingPathComponent("Local State"))

    let names = BrowserProfileLocator.chromiumDisplayNames(in: directory)
    #expect(names["Default"] == "Work")
    #expect(names["Profile 1"] == "Personal")
    #expect(names["Profile 2"] == nil)
}

@Test
func chromeLocalStateMissingFileYieldsNoNames() throws {
    let names = BrowserProfileLocator.chromiumDisplayNames(
        localStateURL: URL(fileURLWithPath: "/nonexistent/Local State")
    )
    #expect(names.isEmpty)
}

/// Firefox names profiles in profiles.ini; the folder names are hashes.
@Test
func firefoxProfilesIniProvidesProfileDisplayNames() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-profilesini-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let ini = """
    [Profile0]
    Name=default-release
    IsRelative=1
    Path=Profiles/abc123.default-release
    Default=1

    [Profile1]
    Name=Work
    IsRelative=1
    Path=Profiles/def456.work

    [General]
    Version=2
    """
    let url = directory.appendingPathComponent("profiles.ini")
    try ini.write(to: url, atomically: true, encoding: .utf8)

    let names = BrowserProfileLocator.firefoxDisplayNames(profilesIniURL: url)
    #expect(names["abc123.default-release"] == "default-release")
    #expect(names["def456.work"] == "Work")
    #expect(names.count == 2)
}

/// Importing into a new profile must land in that profile's database, not the
/// current one. This exercises the pieces the Settings flow composes.
@Test
func importIntoNewProfileLandsInThatProfilesDatabase() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-importprofile-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let root = try AppDatabase(path: directory.appendingPathComponent("root.sqlite").path)
    let store = ProfileStore(root: root, directory: directory.appendingPathComponent("profiles"))
    try store.splitIfNeeded()

    let personal = try #require(try store.profiles().first)
    let imported = try store.create(name: "Chrome — Work")

    // Write a bookmark through the imported profile's repositories.
    let importedDatabase = try store.database(for: imported)
    let importedBookmarks = BookmarkRepository(database: importedDatabase)
    try importedBookmarks.addMany([(url: URL(string: "https://work.example")!, title: "Work", folder: nil)])

    let personalDatabase = try store.database(for: personal)
    let personalBookmarks = BookmarkRepository(database: personalDatabase)

    #expect(try personalBookmarks.all().isEmpty)
    #expect(try importedBookmarks.all().count == 1)
    #expect(imported.name == "Chrome — Work")
}
