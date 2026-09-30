import Foundation
import OSLog

enum PersistenceFailureLog {
    private static let logger = Logger(subsystem: "com.browsemium.browser", category: "persistence")

    static func record(_ what: String, error: Error) {
        let failure = error as NSError
        // No error description: SQLite errors can contain URLs or bindings.
        logger.error("Couldn't save \(what, privacy: .public): \(failure.domain, privacy: .private) (\(failure.code))")
    }
}
