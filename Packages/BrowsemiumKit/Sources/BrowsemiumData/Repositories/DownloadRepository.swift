import BrowsemiumCore
import Foundation
import GRDB

public enum DownloadState: String, Codable, Sendable {
    case inProgress
    case finished
    case failed
    case cancelled
}

public struct DownloadRecord: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let tabID: TabID?
    public let sourceURL: URL
    public let destinationURL: URL?
    public let suggestedFilename: String
    public let state: DownloadState
    public let bytesReceived: Int64
    public let totalBytes: Int64
    public let failureMessage: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        tabID: TabID?,
        sourceURL: URL,
        destinationURL: URL?,
        suggestedFilename: String,
        state: DownloadState,
        bytesReceived: Int64,
        totalBytes: Int64,
        failureMessage: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.tabID = tabID
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.suggestedFilename = suggestedFilename
        self.state = state
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.failureMessage = failureMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public final class DownloadRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func start(
        id: UUID = UUID(),
        tabID: TabID?,
        sourceURL: URL,
        suggestedFilename: String,
        now: Date = Date()
    ) throws -> DownloadRecord {
        let record = DownloadRecord(
            id: id,
            tabID: tabID,
            sourceURL: sourceURL,
            destinationURL: nil,
            suggestedFilename: suggestedFilename,
            state: .inProgress,
            bytesReceived: 0,
            totalBytes: 0,
            failureMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        try upsert(record)
        return record
    }

    public func upsert(_ record: DownloadRecord) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO downloads (
                            id, tab_id, source_url, destination_path, suggested_filename, state,
                            bytes_received, total_bytes, failure_message, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            destination_path = excluded.destination_path,
                            state = excluded.state,
                            bytes_received = excluded.bytes_received,
                            total_bytes = excluded.total_bytes,
                            failure_message = excluded.failure_message,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        record.id.uuidString,
                        record.tabID?.rawValue.uuidString,
                        record.sourceURL.absoluteString,
                        record.destinationURL?.path,
                        record.suggestedFilename,
                        record.state.rawValue,
                        record.bytesReceived,
                        record.totalBytes,
                        record.failureMessage,
                        record.createdAt,
                        record.updatedAt
                    ]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func recent(limit: Int = 100) throws -> [DownloadRecord] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM downloads ORDER BY created_at DESC LIMIT ?",
                    arguments: [limit]
                ).compactMap(Self.makeRecord)
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func clear() throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM downloads")
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    private static func makeRecord(_ row: Row) -> DownloadRecord? {
        guard let idString = row["id"] as String?,
              let id = UUID(uuidString: idString),
              let sourceString = row["source_url"] as String?,
              let sourceURL = URL(string: sourceString),
              let stateString = row["state"] as String?,
              let state = DownloadState(rawValue: stateString) else {
            return nil
        }
        let tabID = (row["tab_id"] as String?).flatMap { UUID(uuidString: $0) }.map { TabID(rawValue: $0) }
        let destination = (row["destination_path"] as String?).map { URL(fileURLWithPath: $0) }
        return DownloadRecord(
            id: id,
            tabID: tabID,
            sourceURL: sourceURL,
            destinationURL: destination,
            suggestedFilename: row["suggested_filename"] ?? "",
            state: state,
            bytesReceived: row["bytes_received"] ?? 0,
            totalBytes: row["total_bytes"] ?? 0,
            failureMessage: row["failure_message"],
            createdAt: row["created_at"] ?? Date(),
            updatedAt: row["updated_at"] ?? Date()
        )
    }
}
