import Foundation

@MainActor
func waitFor(timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}
