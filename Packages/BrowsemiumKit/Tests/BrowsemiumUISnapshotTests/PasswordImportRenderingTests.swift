import AppKit
import BrowsemiumCore
@testable import BrowsemiumData
@testable import BrowsemiumUI
import SwiftUI
import Testing

/// Generated data only. Rendering smoke checks, not pixel-diff baselines.
@Test @MainActor
func passwordImportRecoveryRendersInLightAndDark() throws {
    let directory = URL(fileURLWithPath: "/tmp/browsemium-import-qa-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let csv = try BrowserPasswordCSV(data: Data("name,url,username,password\nFixture,https://fixture.example,fixture-user,fixture-only\n".utf8))
    let preview = BrowserImportPreview(source: .chrome, bookmarks: [], visits: [], folders: [],
        credentials: [.init(url: URL(string: "https://fixture.example")!, username: "fixture-user")],
        cookieCount: 1, extensionIDs: [], searchEngine: nil, notImportable: [])
    let error = BrowserDataImporter.ImportError.credentialsLocked("Chrome").localizedDescription
    for dark in [false, true] {
        let csvView = PasswordCSVImportSheet(csv: csv, destinationName: "Imported profile",
            errorMessage: nil, onCancel: {}, onImport: { _ in })
        let browserView = ImportPreviewSheet(preview: preview,
            options: .constant(.init(includesPasswords: true)), destination: .constant(.currentProfile),
            newProfileName: .constant(""), currentProfileName: "Imported profile", isImporting: false,
            errorMessage: error, onCancel: {}, onImport: {}, onImportPasswordCSV: {})
        try render(csvView, name: "password-csv", dark: dark, directory: directory)
        try render(browserView, name: "browser-password-recovery", dark: dark, directory: directory)
    }
}

@MainActor
private func render<V: View>(_ view: V, name: String, dark: Bool, directory: URL) throws {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = host.fittingSize
    #expect(size.width > 0 && size.width <= 510)
    #expect(size.height > 0 && size.height < 650)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    try data.write(to: url)
    print("Import UI fixture: \(url.path)")
}
