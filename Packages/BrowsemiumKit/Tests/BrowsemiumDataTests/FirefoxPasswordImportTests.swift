import BrowsemiumCore
@testable import BrowsemiumData
import Foundation
import GRDB
import Testing

// MARK: - Generated fixtures (never a real user profile)

private func randomBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

private struct FirefoxPasswordFixture {
    let profile: URL
    let logins: [(hostname: String, username: String, password: String)]

    /// A complete Firefox password profile: `places.sqlite` (validity gate),
    /// `logins.json`, and `key4.db` built to the documented layout with the
    /// given mechanism. `wrappingPassword` simulates a Primary Password when
    /// non-empty; the importer only ever tries the empty one.
    init(logins: [(String, String, String)],
         mechanism: Mechanism = .tripleDES,
         wrappingPassword: Data = Data(),
         bulkKeyLength: Int? = nil) throws {
        self.logins = logins.map { (hostname: $0.0, username: $0.1, password: $0.2) }
        profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-ff-pw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        let queue = try DatabaseQueue(path: profile.appendingPathComponent("places.sqlite").path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_date INTEGER)")
            try db.execute(sql: "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, title TEXT, dateAdded INTEGER)")
        }

        let globalSalt = randomBytes(16)
        let keyLength = bulkKeyLength ?? (mechanism == .tripleDES ? 32 : 48)
        let bulkKey = randomBytes(keyLength)
        let checkSalt = randomBytes(16)
        let keySalt = randomBytes(16)
        typealias F = FirefoxPasswordReader.FixtureSupport
        let item2: Data
        let wrapped: Data
        switch mechanism {
        case .tripleDES:
            item2 = try F.pbe3DESWrap(plaintext: FirefoxPasswordReader.passwordCheck,
                                      globalSalt: globalSalt, password: wrappingPassword, entrySalt: checkSalt)
            wrapped = try F.pbe3DESWrap(plaintext: bulkKey,
                                        globalSalt: globalSalt, password: wrappingPassword, entrySalt: keySalt)
        case .pbes2:
            item2 = try F.pbes2Wrap(plaintext: FirefoxPasswordReader.passwordCheck,
                                     globalSalt: globalSalt, password: wrappingPassword,
                                     entrySalt: randomBytes(32), iterations: 10, ivSuffix: randomBytes(14))
            wrapped = try F.pbes2Wrap(plaintext: bulkKey,
                                       globalSalt: globalSalt, password: wrappingPassword,
                                       entrySalt: randomBytes(32), iterations: 10, ivSuffix: randomBytes(14))
        }
        let keyQueue = try DatabaseQueue(path: profile.appendingPathComponent("key4.db").path)
        try keyQueue.write { db in
            try db.execute(sql: "CREATE TABLE metadata (id TEXT PRIMARY KEY, item1 BLOB, item2 BLOB)")
            try db.execute(sql: "INSERT INTO metadata (id, item1, item2) VALUES ('password', ?, ?)",
                           arguments: [globalSalt, item2])
            try db.execute(sql: "CREATE TABLE nssPrivate (a11 BLOB, a102 BLOB)")
            try db.execute(sql: "INSERT INTO nssPrivate (a11, a102) VALUES (?, ?)",
                           arguments: [wrapped, FirefoxPasswordReader.bulkKeyID])
        }

        let entries = try self.logins.map { login -> [String: String] in
            let ivLength = mechanism == .tripleDES ? 8 : 16
            return [
                "hostname": login.hostname,
                "encryptedUsername": try F.loginField(plaintext: login.username, bulkKey: bulkKey, iv: randomBytes(ivLength)),
                "encryptedPassword": try F.loginField(plaintext: login.password, bulkKey: bulkKey, iv: randomBytes(ivLength))
            ]
        }
        let json = try JSONSerialization.data(
            withJSONObject: ["logins": entries, "nextId": entries.count + 1])
        try json.write(to: profile.appendingPathComponent("logins.json"))
    }

    enum Mechanism { case tripleDES, pbes2 }

    func cleanUp() { try? FileManager.default.removeItem(at: profile) }
}

private func makeImporter() throws -> BrowserDataImporter {
    let database = try AppDatabase.inMemory()
    return BrowserDataImporter(
        bookmarks: BookmarkRepository(database: database),
        history: HistoryRepository(database: database)
    )
}

private func key4Database(at profile: URL) throws -> DatabaseQueue {
    try DatabaseQueue(path: profile.appendingPathComponent("key4.db").path)
}

// MARK: - Round trips

@Test func firefox3DESPasswordsDecrypt() throws {
    let fixture = try FirefoxPasswordFixture(logins: [
        ("https://one.example", "alice", "s3cret-one"),
        ("https://two.example/path", "bob", "s3cret-two")
    ])
    defer { fixture.cleanUp() }
    let importer = try makeImporter()

    // Preview counts without decrypting: usernames stay empty.
    let preview = try importer.preview(at: fixture.profile, source: .firefox)
    #expect(preview.credentialCount == 2)
    #expect(preview.credentials.allSatisfy { $0.username.isEmpty })

    var options = BrowserImportOptions()
    options.includesBookmarks = false
    options.includesHistory = false
    options.includesPasswords = true
    let result = try importer.apply(preview, options: options, profile: fixture.profile)
    #expect(result.credentials.count == 2)
    let first = try #require(result.credentials.first { $0.url.host == "one.example" })
    #expect(first.username == "alice")
    #expect(first.password == "s3cret-one")
    #expect(result.report.items.filter {
        $0.category == .password && $0.stage == .transfer && $0.outcome == .accepted
    }.count == 2)
}

@Test func firefoxPBES2PasswordsDecrypt() throws {
    let fixture = try FirefoxPasswordFixture(
        logins: [("https://aes.example", "carol", "aes-secret")],
        mechanism: .pbes2)
    defer { fixture.cleanUp() }
    let importer = try makeImporter()
    let preview = try importer.preview(at: fixture.profile, source: .firefox)
    #expect(preview.credentialCount == 1)

    var options = BrowserImportOptions()
    options.includesBookmarks = false
    options.includesHistory = false
    options.includesPasswords = true
    let result = try importer.apply(preview, options: options, profile: fixture.profile)
    let login = try #require(result.credentials.first)
    #expect(login.username == "carol")
    #expect(login.password == "aes-secret")
}

@Test func firefoxPreviewNeedsNoKeyDatabase() throws {
    // Presence is counted from logins.json alone: even a profile whose key
    // database is gone still previews its logins.
    let fixture = try FirefoxPasswordFixture(logins: [("https://one.example", "alice", "s3cret")])
    defer { fixture.cleanUp() }
    try FileManager.default.removeItem(at: fixture.profile.appendingPathComponent("key4.db"))

    let preview = try makeImporter().preview(at: fixture.profile, source: .firefox)
    #expect(preview.credentialCount == 1)
}

// MARK: - Honest classification

@Test func firefoxPrimaryPasswordIsDetectedFromTheCheckSignal() throws {
    // Wrapped with a non-empty password: the empty-password unwrap yields
    // garbage, and only the check mismatch may claim "protected".
    let fixture = try FirefoxPasswordFixture(
        logins: [("https://one.example", "alice", "s3cret")],
        wrappingPassword: Data("primary-password".utf8))
    defer { fixture.cleanUp() }

    let queue = try key4Database(at: fixture.profile)
    let status: FirefoxPasswordReader.Failure? = try queue.read { db in
        do {
            _ = try FirefoxPasswordReader.bulkKey(database: db)
            return nil
        } catch let failure as FirefoxPasswordReader.Failure {
            return failure
        }
    }
    #expect(status == .primaryPasswordProtected)

    let importer = try makeImporter()
    let preview = try importer.preview(at: fixture.profile, source: .firefox)
    var options = BrowserImportOptions()
    options.includesBookmarks = false
    options.includesHistory = false
    options.includesPasswords = true
    let result = try importer.apply(preview, options: options, profile: fixture.profile)
    #expect(result.credentials.isEmpty)
    #expect(result.report.items.contains {
        $0.category == .password && $0.ordinal == 0
            && $0.outcome == .unsupported && $0.reason == .primaryPasswordRequired
    })
}

@Test func firefoxUnknownWrappingAlgorithmIsUnsupported() throws {
    let fixture = try FirefoxPasswordFixture(logins: [("https://one.example", "alice", "s3cret")])
    defer { fixture.cleanUp() }
    // Rewrite item2 with an unknown OID: valid DER, newer-format statement.
    typealias F = FirefoxPasswordReader.FixtureSupport
    let unknown = F.derSequence([
        F.derSequence([F.derOID([0x2A, 0x03]), F.derSequence([])]),
        F.derOctetString(Data([0x01, 0x02]))
    ])
    let queue = try key4Database(at: fixture.profile)
    try queue.write { db in
        try db.execute(sql: "UPDATE metadata SET item2 = ? WHERE id = 'password'", arguments: [unknown])
    }
    let status: FirefoxPasswordReader.Failure? = try queue.read { db in
        do {
            _ = try FirefoxPasswordReader.bulkKey(database: db)
            return nil
        } catch let failure as FirefoxPasswordReader.Failure {
            return failure
        }
    }
    #expect(status == .unsupported("unknown password-wrapping algorithm"))

    var report = BrowserImportReport()
    let logins = try queue.read { db in
        FirefoxPasswordReader.decryptLogins(
            database: db,
            loginsJSON: try Data(contentsOf: fixture.profile.appendingPathComponent("logins.json")),
            report: &report)
    }
    #expect(logins.isEmpty)
    #expect(report.items.contains {
        $0.category == .password && $0.outcome == .unsupported && $0.reason == .unsupportedFormat
    })
}

@Test func firefoxCorruptKeyDatabaseFailsWithoutClaimingProtection() throws {
    let fixture = try FirefoxPasswordFixture(logins: [("https://one.example", "alice", "s3cret")])
    defer { fixture.cleanUp() }
    let queue = try key4Database(at: fixture.profile)
    try queue.write { db in
        try db.execute(sql: "UPDATE metadata SET item2 = ? WHERE id = 'password'",
                       arguments: [Data([0x00, 0x01, 0x02])])
    }
    let status: FirefoxPasswordReader.Failure? = try queue.read { db in
        do {
            _ = try FirefoxPasswordReader.bulkKey(database: db)
            return nil
        } catch let failure as FirefoxPasswordReader.Failure {
            return failure
        }
    }
    // Damage is damage: corrupt is reported, never "protected".
    if case .corrupt = status {
    } else {
        Issue.record("expected a corrupt failure, got \(String(describing: status))")
    }
}

@Test func firefoxLegacyKey3ProfileIsUnsupported() throws {
    let fixture = try FirefoxPasswordFixture(logins: [("https://one.example", "alice", "s3cret")])
    defer { fixture.cleanUp() }
    try FileManager.default.removeItem(at: fixture.profile.appendingPathComponent("key4.db"))
    try Data().write(to: fixture.profile.appendingPathComponent("key3.db"))

    let importer = try makeImporter()
    let preview = try importer.preview(at: fixture.profile, source: .firefox)
    #expect(preview.credentialCount == 1)
    var options = BrowserImportOptions()
    options.includesBookmarks = false
    options.includesHistory = false
    options.includesPasswords = true
    let result = try importer.apply(preview, options: options, profile: fixture.profile)
    #expect(result.credentials.isEmpty)
    #expect(result.report.items.contains {
        $0.category == .password && $0.outcome == .unsupported && $0.reason == .unsupportedFormat
    })
    // Other categories still import around the unsupported passwords.
    #expect(result.bookmarks == 0)
}

@Test func firefoxTamperedLoginFailsAlone() throws {
    let fixture = try FirefoxPasswordFixture(logins: [
        ("https://one.example", "alice", "s3cret-one"),
        ("https://two.example", "bob", "s3cret-two")
    ])
    defer { fixture.cleanUp() }
    // Flip a byte deep in the second password's ciphertext.
    let loginsURL = fixture.profile.appendingPathComponent("logins.json")
    var root = try JSONSerialization.jsonObject(with: Data(contentsOf: loginsURL)) as! [String: Any]
    var entries = root["logins"] as! [[String: String]]
    var ciphertext = try #require(Data(base64Encoded: entries[1]["encryptedPassword"]!))
    ciphertext[ciphertext.count - 1] ^= 0xFF
    entries[1]["encryptedPassword"] = ciphertext.base64EncodedString()
    root["logins"] = entries
    try JSONSerialization.data(withJSONObject: root).write(to: loginsURL)

    let importer = try makeImporter()
    let preview = try importer.preview(at: fixture.profile, source: .firefox)
    var options = BrowserImportOptions()
    options.includesBookmarks = false
    options.includesHistory = false
    options.includesPasswords = true
    let result = try importer.apply(preview, options: options, profile: fixture.profile)
    #expect(result.credentials.count == 1)
    #expect(result.credentials.first?.username == "alice")
    #expect(result.report.items.contains {
        $0.category == .password && $0.stage == .transfer && $0.outcome == .failed
    })
}

@Test func firefoxEmptyPasswordLoginIsNotImported() throws {
    let fixture = try FirefoxPasswordFixture(logins: [("https://one.example", "alice", "")])
    defer { fixture.cleanUp() }
    let importer = try makeImporter()
    let preview = try importer.preview(at: fixture.profile, source: .firefox)
    var options = BrowserImportOptions()
    options.includesBookmarks = false
    options.includesHistory = false
    options.includesPasswords = true
    let result = try importer.apply(preview, options: options, profile: fixture.profile)
    #expect(result.credentials.isEmpty)
    #expect(result.report.items.contains {
        $0.category == .password && $0.outcome == .unsupported && $0.reason == .invalidItem
    })
}

@Test func firefoxPasswordReportContainsNoSecrets() throws {
    let fixture = try FirefoxPasswordFixture(logins: [("https://secret-vault.example", "hunter2-user", "hunter2-pass")])
    defer { fixture.cleanUp() }
    let importer = try makeImporter()
    let preview = try importer.preview(at: fixture.profile, source: .firefox)
    var options = BrowserImportOptions()
    options.includesBookmarks = false
    options.includesHistory = false
    options.includesPasswords = true
    let result = try importer.apply(preview, options: options, profile: fixture.profile)
    #expect(result.credentials.count == 1)
    let payload = try JSONEncoder().encode(result.report)
    let text = String(data: payload, encoding: .utf8) ?? ""
    #expect(!text.contains("secret-vault"))
    #expect(!text.contains("hunter2"))
}

@Test func firefoxOverLimitLoginListIsUnsupported() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-ff-limit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var entries: [[String: String]] = []
    entries.reserveCapacity(50_001)
    for index in 0..<50_001 {
        entries.append([
            "hostname": "https://site\(index).example",
            "encryptedUsername": "dXNlcg==",
            "encryptedPassword": "cGFzcw=="
        ])
    }
    let json = try JSONSerialization.data(withJSONObject: ["logins": entries])
    try json.write(to: folder.appendingPathComponent("logins.json"))

    var report = BrowserImportReport()
    #expect(FirefoxPasswordReader.summarizeProfile(in: folder, report: &report)?.isEmpty == true)
    #expect(report.items.contains {
        $0.category == .password && $0.outcome == .unsupported && $0.reason == .limitExceeded
    })
}

@Test func firefoxDuplicateLoginsDedupe() throws {
    let fixture = try FirefoxPasswordFixture(logins: [
        ("https://one.example", "alice", "s3cret"),
        ("https://one.example", "alice", "s3cret")
    ])
    defer { fixture.cleanUp() }
    let importer = try makeImporter()
    let preview = try importer.preview(at: fixture.profile, source: .firefox)
    var options = BrowserImportOptions()
    options.includesBookmarks = false
    options.includesHistory = false
    options.includesPasswords = true
    let result = try importer.apply(preview, options: options, profile: fixture.profile)
    #expect(result.credentials.count == 1)
    #expect(result.report.items.contains {
        $0.category == .password && $0.outcome == .duplicate && $0.reason == .duplicateInSource
    })
}
