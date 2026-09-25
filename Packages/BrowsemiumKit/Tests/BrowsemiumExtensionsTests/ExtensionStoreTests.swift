import BrowsemiumCore
import BrowsemiumExtensions
import Foundation
import Testing

// MARK: - Store fixtures

/// Builds a temporary extension source directory with a manifest, so store
/// tests never touch the user's real extension folder.
private func makeExtensionFolder(
    named name: String,
    manifest: String? = #"{"manifest_version":3,"name":"Fixture","version":"1.2.3"}"#
) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-ext-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let manifest {
        try manifest.data(using: .utf8)!.write(to: directory.appendingPathComponent("manifest.json"))
    }
    return directory
}

private func makeStore() throws -> ExtensionStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-store-\(UUID().uuidString)", isDirectory: true)
    return ExtensionStore(rootDirectory: root)
}

// MARK: - Store

@Test
func installingAnUnpackedFolderCopiesItIntoTheStore() throws {
    let source = try makeExtensionFolder(named: "My Extension")
    let store = try makeStore()

    let installed = try store.install(from: source)

    #expect(installed.payload == .directory)
    #expect(installed.name == "Fixture")
    #expect(installed.version == "1.2.3")
    #expect(FileManager.default.fileExists(
        atPath: installed.resourceURL.appendingPathComponent("manifest.json").path
    ))
    #expect(try store.installed().map(\.id) == [installed.id])
}

@Test
func installingAFolderWithoutAManifestFailsCleanly() throws {
    let source = try makeExtensionFolder(named: "Broken", manifest: nil)
    let store = try makeStore()

    #expect(throws: ExtensionStore.InstallError.missingManifest) {
        try store.install(from: source)
    }
    // The half-copied directory must not be left behind.
    #expect(try store.installed().isEmpty)
}

@Test
func installingAFileThatIsNotAnExtensionFailsCleanly() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("not-an-extension-\(UUID().uuidString).txt")
    try "hello".data(using: .utf8)!.write(to: file)
    let store = try makeStore()

    #expect(throws: ExtensionStore.InstallError.unsupportedSource(file.lastPathComponent)) {
        try store.install(from: file)
    }
}

@Test
func installingAZipKeepsTheArchiveForWebKit() throws {
    let zip = FileManager.default.temporaryDirectory
        .appendingPathComponent("Packed Extension-\(UUID().uuidString).zip")
    try Data([0x50, 0x4B, 0x03, 0x04]).write(to: zip)
    let store = try makeStore()

    let installed = try store.install(from: zip)

    #expect(installed.payload == .zip)
    #expect(installed.resourceURL.lastPathComponent == "extension.zip")
    #expect(try Data(contentsOf: installed.resourceURL) == Data([0x50, 0x4B, 0x03, 0x04]))
}

@Test
func reinstallingReplacesThePreviousCopy() throws {
    let source = try makeExtensionFolder(named: "Repeatable")
    let store = try makeStore()

    let first = try store.install(from: source)
    let second = try store.install(from: source)

    #expect(first.id == second.id)
    #expect(try store.installed().count == 1)
}

@Test
func removingAnExtensionDeletesItsFiles() throws {
    let source = try makeExtensionFolder(named: "Removable")
    let store = try makeStore()
    let installed = try store.install(from: source)

    try store.remove(id: installed.id)

    #expect(try store.installed().isEmpty)
    #expect(throws: ExtensionStore.InstallError.notFound(installed.id)) {
        try store.remove(id: installed.id)
    }
}

@Test(arguments: ["../outside", "/tmp/outside", "", ".hidden", "UPPERCASE"])
func destructiveStoreOperationsRejectUntrustedIdentifiers(_ id: String) throws {
    let store = try makeStore()
    #expect(throws: ExtensionStore.InstallError.invalidIdentifier(id)) {
        try store.remove(id: id)
    }
}

@Test
func failedReinstallLeavesTheWorkingExtensionUntouched() throws {
    let source = try makeExtensionFolder(named: "Stable")
    let store = try makeStore()
    let installed = try store.install(from: source)
    let originalManifest = try Data(contentsOf: installed.resourceURL.appendingPathComponent("manifest.json"))
    try FileManager.default.removeItem(at: source.appendingPathComponent("manifest.json"))

    #expect(throws: ExtensionStore.InstallError.missingManifest) {
        try store.install(from: source)
    }

    let surviving = try #require(store.installed().first)
    #expect(surviving.id == installed.id)
    #expect(try Data(contentsOf: surviving.resourceURL.appendingPathComponent("manifest.json")) == originalManifest)
}

@Test
func unpackedExtensionContainingASymlinkIsRejected() throws {
    let source = try makeExtensionFolder(named: "Linked")
    let link = source.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/tmp"))
    let store = try makeStore()

    #expect(throws: ExtensionStore.InstallError.symbolicLinkNotAllowed("escape")) {
        try store.install(from: source)
    }
    #expect(try store.installed().isEmpty)
}

@Test
func extensionIdentifiersAreFilesystemSafe() {
    let id = ExtensionStore.identifier(for: URL(fileURLWithPath: "/tmp/My Extension (Beta)!.zip"))
    #expect(id == "my-extension--beta")
    #expect(!id.contains(" "))
    #expect(!id.contains("!"))
}

// MARK: - Manifest

@Test
func manifestSplitsMV3HostPermissionsFromAPIPermissions() throws {
    let source = try makeExtensionFolder(named: "Split", manifest: """
        {
          "manifest_version": 3,
          "name": "Split",
          "version": "2.0",
          "permissions": ["storage", "alarms"],
          "host_permissions": ["https://*.example.com/*"]
        }
        """)

    let manifest = try #require(ExtensionManifest.read(fromDirectory: source))
    #expect(manifest.permissions == ["storage", "alarms"])
    #expect(manifest.hostPermissions == ["https://*.example.com/*"])
    #expect(manifest.manifestVersion == 3)
}

@Test
func manifestSplitsMV2PermissionsByShape() throws {
    let source = try makeExtensionFolder(named: "Legacy", manifest: """
        {
          "manifest_version": 2,
          "name": "Legacy",
          "version": "1.0",
          "permissions": ["storage", "https://*/*", "http://*/*"]
        }
        """)

    let manifest = try #require(ExtensionManifest.read(fromDirectory: source))
    #expect(manifest.permissions == ["storage"])
    #expect(manifest.hostPermissions == ["https://*/*", "http://*/*"])
}

@Test
func manifestResolvesLocalizedNames() throws {
    let source = try makeExtensionFolder(named: "Localized", manifest: """
        {"manifest_version":3,"name":"__MSG_extName__","version":"1.0"}
        """)
    let locales = source.appendingPathComponent("_locales/en", isDirectory: true)
    try FileManager.default.createDirectory(at: locales, withIntermediateDirectories: true)
    try #"{"extName":{"message":"Localized Name"}}"#
        .data(using: .utf8)!
        .write(to: locales.appendingPathComponent("messages.json"))

    let manifest = try #require(ExtensionManifest.read(fromDirectory: source))
    #expect(manifest.name == "Localized Name")
}

@Test
func manifestUnreadableYieldsNilInsteadOfThrowing() throws {
    let source = try makeExtensionFolder(named: "Garbage", manifest: "{not json")
    #expect(ExtensionManifest.read(fromDirectory: source) == nil)
}

// MARK: - CRX

@Test
func crxHeaderIsStrippedToTheEmbeddedZip() throws {
    var data = Data("Cr24".utf8)
    data.append(contentsOf: [3, 0, 0, 0])          // version 3
    data.append(contentsOf: [4, 0, 0, 0])          // header length 4
    data.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD])  // header bytes
    data.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])  // zip payload

    let payload = try CRXContainer.zipPayload(from: data)

    #expect(payload == Data([0x50, 0x4B, 0x03, 0x04]))
}

@Test
func crxV2HeaderIsStrippedToTheEmbeddedZip() throws {
    var data = Data("Cr24".utf8)
    data.append(contentsOf: [2, 0, 0, 0])          // version 2
    data.append(contentsOf: [2, 0, 0, 0])          // public key length
    data.append(contentsOf: [1, 0, 0, 0])          // signature length
    data.append(contentsOf: [0x01, 0x02, 0x03])    // key + signature
    data.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])

    #expect(try CRXContainer.zipPayload(from: data) == Data([0x50, 0x4B, 0x03, 0x04]))
}

@Test
func aFileWithoutTheCRXMagicIsRejected() {
    let data = Data("not a crx at all, but long enough".utf8)
    #expect(throws: CRXContainer.Error.notACRX) {
        try CRXContainer.zipPayload(from: data)
    }
}

@Test
func aTruncatedCRXIsRejected() {
    var data = Data("Cr24".utf8)
    data.append(contentsOf: [3, 0, 0, 0])
    data.append(contentsOf: [200, 0, 0, 0])   // header claims more bytes than exist
    #expect(throws: CRXContainer.Error.truncated) {
        try CRXContainer.zipPayload(from: data)
    }
}

@Test
func anUnknownCRXVersionIsRejected() {
    var data = Data("Cr24".utf8)
    data.append(contentsOf: [9, 0, 0, 0])
    data.append(contentsOf: [0, 0, 0, 0])
    data.append(contentsOf: [0, 0, 0, 0])
    #expect(throws: CRXContainer.Error.unsupportedVersion(9)) {
        try CRXContainer.zipPayload(from: data)
    }
}

// MARK: - Permission request model

@Test @MainActor
func permissionRequestListsItsItems() {
    let apiRequest = ExtensionPermissionRequest(
        extensionID: "demo",
        extensionName: "Demo",
        kind: .apiPermissions(["storage", "alarms"])
    )
    #expect(apiRequest.items == ["storage", "alarms"])

    let hostRequest = ExtensionPermissionRequest(
        extensionID: "demo",
        extensionName: "Demo",
        kind: .hostAccess(["https://*/*"])
    )
    #expect(hostRequest.items == ["https://*/*"])
}
