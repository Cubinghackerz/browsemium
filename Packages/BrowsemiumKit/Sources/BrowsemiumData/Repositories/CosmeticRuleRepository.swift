import BrowsemiumCore
import Foundation
import GRDB

/// One element a user chose to hide on a site. Cosmetic only: the rule is a
/// CSS selector matched by an injected style element, never a network rule.
public struct CosmeticRule: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let host: String
    public let selector: String
    public let label: String
    public var isEnabled: Bool
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        host: String,
        selector: String,
        label: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.selector = selector
        self.label = label
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

/// Per-profile cosmetic rules, scoped to a lowercase hostname. Rules are
/// created by the element picker (⌘⇧H) and managed from the site shield.
public final class CosmeticRuleRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func rules(host: String) throws -> [CosmeticRule] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM cosmetic_rules WHERE host = ? ORDER BY created_at",
                    arguments: [host.lowercased()]
                ).map(Self.rule(from:))
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func add(host: String, selector: String, label: String, now: Date = Date()) throws -> CosmeticRule {
        let rule = CosmeticRule(host: host.lowercased(), selector: selector, label: label, createdAt: now)
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO cosmetic_rules (id, host, selector, label, is_enabled, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [rule.id, rule.host, rule.selector, rule.label, rule.isEnabled, rule.createdAt]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
        return rule
    }

    public func setEnabled(_ enabled: Bool, id: String) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "UPDATE cosmetic_rules SET is_enabled = ? WHERE id = ?",
                    arguments: [enabled, id]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func remove(id: String) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM cosmetic_rules WHERE id = ?", arguments: [id])
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Every host with at least one rule, for rebuilding the injected map.
    public func hosts() throws -> [String] {
        do {
            return try database.databaseQueue.read { db in
                try String.fetchAll(db, sql: "SELECT DISTINCT host FROM cosmetic_rules")
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// The CSS injected at document start for one host. Disabled rules are
    /// skipped rather than removed, so a rule can be toggled back on.
    public static func css(for rules: [CosmeticRule]) -> String {
        rules
            .filter(\.isEnabled)
            .map { "\($0.selector) { display: none !important; }" }
            .joined(separator: "\n")
    }

    private static func rule(from row: Row) -> CosmeticRule {
        CosmeticRule(
            id: row["id"],
            host: row["host"],
            selector: row["selector"],
            label: row["label"],
            isEnabled: row["is_enabled"],
            createdAt: row["created_at"]
        )
    }
}
