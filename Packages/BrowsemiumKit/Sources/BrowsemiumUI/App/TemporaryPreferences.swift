import Foundation

/// Each in-memory environment owns a disposable, suite-scoped domain.
final class TemporaryPreferences {
    private enum InitializationError: Error { case unavailable }
    private let suiteName = "com.browsemium.fixture.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw InitializationError.unavailable
        }
        self.defaults = defaults
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
