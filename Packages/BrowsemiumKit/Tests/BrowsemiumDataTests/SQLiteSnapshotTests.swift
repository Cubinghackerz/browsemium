@testable import BrowsemiumData
import Foundation
import Testing

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-snapshot-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

@Suite
struct SQLiteSnapshotTests {
    @Test
    func aStableSourceIsCopiedWithItsWriteAheadLog() throws {
        let source = try makeDirectory(), work = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: work) }
        let db = source.appendingPathComponent("Cookies")
        try Data("db".utf8).write(to: db)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: db.path + "-wal"))

        let copy = try SQLiteSnapshot.copy(db, into: work)

        #expect(try Data(contentsOf: copy) == Data("db".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy.path + "-wal")) == Data("wal".utf8))
    }

    @Test
    func aSourceThatChangesOnceIsCopiedAgainUntilItIsStable() throws {
        let source = try makeDirectory(), work = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: work) }
        let db = source.appendingPathComponent("Cookies")
        try Data("db".utf8).write(to: db)
        var attempts = 0

        let copy = try SQLiteSnapshot.copy(db, into: work) { attempt in
            attempts = attempt
            if attempt == 1 { try? append("-changed", to: db) }
        }

        #expect(attempts == 2)
        #expect(try Data(contentsOf: copy) == Data("db-changed".utf8))
    }

    @Test
    func aSourceThatKeepsChangingIsReportedAndNothingIsReturned() throws {
        let source = try makeDirectory(), work = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: work) }
        let db = source.appendingPathComponent("Cookies")
        try Data("db".utf8).write(to: db)

        do {
            _ = try SQLiteSnapshot.copy(db, into: work) { _ in try? append("+", to: db) }
            Issue.record("A source that never settles must not be read")
        } catch let error as BrowserDataImporter.ImportError {
            #expect(error.localizedDescription.contains("while it was being copied"))
            #expect(error.localizedDescription.contains("Quit"))
        }
    }

    @Test
    func aGrowingWriteAheadLogCountsAsAChange() throws {
        let source = try makeDirectory(), work = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: work) }
        let db = source.appendingPathComponent("Cookies")
        let wal = URL(fileURLWithPath: db.path + "-wal")
        try Data("db".utf8).write(to: db)
        try Data("wal".utf8).write(to: wal)
        var attempts = 0

        _ = try SQLiteSnapshot.copy(db, into: work) { attempt in
            attempts = attempt
            if attempt == 1 { try? append("more", to: wal) }
        }

        #expect(attempts == 2)
    }

    @Test
    func aMissingSourceIsAnErrorNotAnEmptyCopy() throws {
        let work = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        #expect(throws: BrowserDataImporter.ImportError.self) {
            _ = try SQLiteSnapshot.copy(URL(fileURLWithPath: "/nonexistent/browsemium/Cookies"), into: work)
        }
    }
}
