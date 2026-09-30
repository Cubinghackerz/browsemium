import Foundation

@MainActor
func waitFor(timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(100))
    }
    return true
}
