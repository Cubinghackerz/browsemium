import BrowsemiumCore
import CryptoKit
import Foundation
import GRDB

public struct UserFilterList: Sendable, Identifiable, Equatable {
    public enum Source: String, Codable, Sendable { case localFile, https }
    public let id: UUID
    public let name: String
    public let source: Source
    public let revision: Int64
    public let contentHash: String
    public let rulesJSON: String
    public let acceptedCount: Int
    public let skippedCount: Int
    public let ignoredCount: Int
    public let isEnabled: Bool
    public let updatedAt: Date
}

/// A non-persisted candidate. Compile its exact payload using its identifier,
/// then commit only after WebKit returns that identifier. Constructed only by
/// this repository; callers cannot change its payload or expected revision.
public struct PreparedUserFilterList: Sendable {
    public let profileID: UUID
    public let id: UUID
    public let name: String
    public let source: UserFilterList.Source
    public let conversion: FilterListConversion
    public let contentHash: String
    public let compiledIdentifier: String
    let expectedRevision: Int64?
}

public final class UserFilterListRepository: @unchecked Sendable {
    public enum RepositoryError: Error, LocalizedError, Equatable {
        case readOnly, invalidName, wrongProfile, staleCandidate, notFound
        case notCompiled, limitExceeded, storageFailure

        public var errorDescription: String? {
            switch self {
            case .readOnly: "Filter list changes cannot be saved from a private window."
            case .invalidName: "Give the filter list a name of 1–80 characters."
            case .wrongProfile: "This filter list belongs to another profile."
            case .staleCandidate: "The list changed while compiling. Import it again."
            case .notFound: "The filter list no longer exists."
            case .notCompiled: "The candidate has not compiled with its expected identifier."
            case .limitExceeded: "This profile supports up to 10 lists, 50,000 rules, and 16 MiB of rules."
            case .storageFailure: "The filter list could not be stored or read. The previous version has not been replaced."
            }
        }
    }

    public let profileID: UUID
    private let database: AppDatabase
    private let allowsWrites: Bool

    public init(database: AppDatabase, profileID: UUID, allowsWrites: Bool = true) {
        self.database = database
        self.profileID = profileID
        self.allowsWrites = allowsWrites
    }

    public func all() throws -> [UserFilterList] {
        try accessing {
            try database.databaseQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM user_filter_lists ORDER BY name COLLATE NOCASE, id")
                    .map(Self.list(from:))
            }
        }
    }

    public func prepare(_ conversion: FilterListConversion, name: String,
                        source: UserFilterList.Source, replacing id: UUID? = nil) throws -> PreparedUserFilterList {
        guard allowsWrites else { throw RepositoryError.readOnly }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80, trimmed.utf8.count <= 320,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RepositoryError.invalidName
        }
        let existing: UserFilterList? = try accessing {
            try database.databaseQueue.read { db in
                guard let id else { return nil }
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM user_filter_lists WHERE id = ?", arguments: [id.uuidString]) else {
                    throw RepositoryError.notFound
                }
                return try Self.list(from: row)
            }
        }
        let listID = existing?.id ?? UUID()
        let hash = Self.hash(conversion.rulesJSON)
        return PreparedUserFilterList(profileID: profileID, id: listID, name: trimmed, source: source,
                                      conversion: conversion, contentHash: hash,
                                      compiledIdentifier: Self.compiledIdentifier(profileID: profileID, listID: listID, contentHash: hash),
                                      expectedRevision: existing?.revision)
    }

    @discardableResult
    public func commit(_ candidate: PreparedUserFilterList, compiledIdentifier: String,
                       now: Date = Date()) throws -> UserFilterList {
        guard allowsWrites else { throw RepositoryError.readOnly }
        guard candidate.profileID == profileID else { throw RepositoryError.wrongProfile }
        guard compiledIdentifier == candidate.compiledIdentifier else { throw RepositoryError.notCompiled }
        return try accessing {
            try database.databaseQueue.write { db in
                let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM user_filter_list_revisions WHERE id = ?",
                                                 arguments: [candidate.id.uuidString])
                guard revision == candidate.expectedRevision else { throw RepositoryError.staleCandidate }
                guard (revision ?? 0) < Int64.max else { throw RepositoryError.storageFailure }
                let existing = try Row.fetchOne(db, sql: "SELECT * FROM user_filter_lists WHERE id = ?", arguments: [candidate.id.uuidString])
                guard (existing == nil) == (revision == nil) else { throw RepositoryError.staleCandidate }
                let totals = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS list_count, COALESCE(SUM(accepted_count), 0) AS rule_count,
                           COALESCE(SUM(length(CAST(rules_json AS BLOB))), 0) AS byte_count
                    FROM user_filter_lists WHERE id != ?
                    """, arguments: [candidate.id.uuidString])
                guard let totals, (totals["list_count"] as Int) < 10,
                      (totals["rule_count"] as Int) + candidate.conversion.acceptedCount <= 50_000,
                      (totals["byte_count"] as Int) + candidate.conversion.rulesJSON.utf8.count <= 16 * 1024 * 1024 else {
                    throw RepositoryError.limitExceeded
                }
                let next = (revision ?? 0) + 1
                let enabled: Bool = existing?["is_enabled"] ?? true
                // Both the revision ledger and last-good payload commit in
                // this transaction. A statement failure rolls back both.
                try db.execute(sql: """
                    INSERT INTO user_filter_list_revisions (id, revision) VALUES (?, ?)
                    ON CONFLICT(id) DO UPDATE SET revision = excluded.revision
                    """, arguments: [candidate.id.uuidString, next])
                try db.execute(sql: """
                    INSERT INTO user_filter_lists
                        (id, name, source, revision, content_hash, rules_json, accepted_count,
                         skipped_count, ignored_count, is_enabled, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name, source = excluded.source, revision = excluded.revision,
                        content_hash = excluded.content_hash, rules_json = excluded.rules_json,
                        accepted_count = excluded.accepted_count, skipped_count = excluded.skipped_count,
                        ignored_count = excluded.ignored_count, is_enabled = excluded.is_enabled,
                        updated_at = excluded.updated_at
                    """, arguments: [candidate.id.uuidString, candidate.name, candidate.source.rawValue, next,
                                      candidate.contentHash, candidate.conversion.rulesJSON, candidate.conversion.acceptedCount,
                                      candidate.conversion.skipped.count, candidate.conversion.ignoredCount, enabled, now])
                // Return the database representation, including its stored
                // date precision, so an immediate reload has the same value.
                guard let stored = try Row.fetchOne(db, sql: "SELECT * FROM user_filter_lists WHERE id = ?",
                                                    arguments: [candidate.id.uuidString]) else {
                    throw RepositoryError.storageFailure
                }
                return try Self.list(from: stored)
            }
        }
    }

    public func setEnabled(_ enabled: Bool, id: UUID) throws {
        try changing(id: id) { db, next in
            try db.execute(sql: "UPDATE user_filter_lists SET is_enabled = ?, revision = ?, updated_at = ? WHERE id = ?",
                           arguments: [enabled, next, Date(), id.uuidString])
        }
    }

    public func remove(id: UUID) throws {
        try changing(id: id) { db, _ in
            try db.execute(sql: "DELETE FROM user_filter_lists WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private func changing(id: UUID, body: (Database, Int64) throws -> Void) throws {
        guard allowsWrites else { throw RepositoryError.readOnly }
        try accessing {
            try database.databaseQueue.write { db in
                guard let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM user_filter_lists WHERE id = ?",
                                                       arguments: [id.uuidString]), revision < Int64.max else {
                    throw RepositoryError.notFound
                }
                try db.execute(sql: "UPDATE user_filter_list_revisions SET revision = ? WHERE id = ?",
                               arguments: [revision + 1, id.uuidString])
                try body(db, revision + 1)
            }
        }
    }

    private func accessing<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as RepositoryError { throw error }
        catch { throw RepositoryError.storageFailure } // Never expose raw SQL or list values.
    }

    private static func hash(_ json: String) -> String {
        SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func list(from row: Row) throws -> UserFilterList {
        guard let id = UUID(uuidString: row["id"]), let source = UserFilterList.Source(rawValue: row["source"]) else {
            throw RepositoryError.storageFailure
        }
        let json: String = row["rules_json"]
        let contentHash: String = row["content_hash"]
        guard hash(json) == contentHash else { throw RepositoryError.storageFailure }
        return UserFilterList(id: id, name: row["name"], source: source, revision: row["revision"],
                              contentHash: contentHash, rulesJSON: json, acceptedCount: row["accepted_count"],
                              skippedCount: row["skipped_count"], ignoredCount: row["ignored_count"],
                              isEnabled: row["is_enabled"], updatedAt: row["updated_at"])
    }

    public static func compiledIdentifier(profileID: UUID, listID: UUID, contentHash: String) -> String {
        "BrowsemiumUserRules-\(profileID.uuidString)-\(listID.uuidString)-\(contentHash)"
    }
}
