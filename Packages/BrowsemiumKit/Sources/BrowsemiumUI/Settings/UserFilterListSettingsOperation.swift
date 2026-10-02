import Observation
import Foundation

@Observable @MainActor final class UserFilterListSettingsOperation {
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token: UUID?

    @discardableResult
    func run(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        guard !isRunning else { return false }
        let token = UUID()
        self.token = token
        isRunning = true
        task = Task {
            await operation()
            guard self.token == token else { return }
            self.token = nil
            task = nil
            isRunning = false
        }
        return true
    }

    func cancel() { token = nil; task?.cancel(); task = nil; isRunning = false }
}
