import BrowsemiumCore
import Foundation
import GRDB

public struct SavedCredential: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let host: String
    public let username: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        host: String,
        username: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.host = host.lowercased()
        self.username = username
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var keychainAccount: String {
        "credential.\(id.uuidString)"
    }
}

public final class SavedCredentialRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func save(host: String, username: String) throws -> SavedCredential {
        let normalizedHost = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, !normalizedUsername.isEmpty else {
            throw BrowsemiumError.databaseFailure("A website and username are required.")
        }
        if let existing = try credentials(for: normalizedHost).first(where: { $0.username == normalizedUsername }) {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "UPDATE saved_credentials SET updated_at = ? WHERE id = ?",
                    arguments: [Date(), existing.id.uuidString]
                )
            }
            return SavedCredential(
                id: existing.id,
                host: existing.host,
                username: existing.username,
                createdAt: existing.createdAt,
                updatedAt: Date()
            )
        }
        let credential = SavedCredential(host: normalizedHost, username: normalizedUsername)
        try database.databaseQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO saved_credentials (id, host, username, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    credential.id.uuidString,
                    credential.host,
                    credential.username,
                    credential.createdAt,
                    credential.updatedAt
                ]
            )
        }
        return credential
    }

    public func all() throws -> [SavedCredential] {
        try read(
            sql: "SELECT * FROM saved_credentials ORDER BY host, username",
            arguments: []
        )
    }

    public func credentials(for host: String) throws -> [SavedCredential] {
        try read(
            sql: "SELECT * FROM saved_credentials WHERE host = ? ORDER BY updated_at DESC",
            arguments: [host.lowercased()]
        )
    }

    @discardableResult
    public func remove(id: UUID) throws -> Bool {
        try database.databaseQueue.write { db in
            try db.execute(sql: "DELETE FROM saved_credentials WHERE id = ?", arguments: [id.uuidString])
            return db.changesCount > 0
        }
    }

    private func read(sql: String, arguments: StatementArguments) throws -> [SavedCredential] {
        try database.databaseQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
                guard let idString = row["id"] as String?,
                      let id = UUID(uuidString: idString) else {
                    return nil
                }
                return SavedCredential(
                    id: id,
                    host: row["host"] ?? "",
                    username: row["username"] ?? "",
                    createdAt: row["created_at"] ?? Date(),
                    updatedAt: row["updated_at"] ?? Date()
                )
            }
        }
    }
}
