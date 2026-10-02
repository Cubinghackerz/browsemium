@testable import BrowsemiumUI
import Testing

@Suite @MainActor struct UserFilterListSettingsOperationTests {
    @Test func rapidDuplicateActionsCannotReplaceTheCancellableTask() async throws {
        let operation = UserFilterListSettingsOperation()
        var continuation: CheckedContinuation<Void, Never>?
        var sawCancellation = false
        var duplicateRan = false
        #expect(operation.run {
            await withCheckedContinuation { continuation = $0 }
            sawCancellation = Task.isCancelled
        })
        #expect(try await waitFor { continuation != nil })
        #expect(!operation.run { duplicateRan = true })
        operation.cancel()
        continuation?.resume()
        #expect(try await waitFor { sawCancellation || duplicateRan })
        #expect(sawCancellation && !duplicateRan)
    }

    @Test func anOldCancelledCompletionCannotUnlockANewOperation() async throws {
        let operation = UserFilterListSettingsOperation()
        var first: CheckedContinuation<Void, Never>?
        var second: CheckedContinuation<Void, Never>?
        var firstReturned = false
        operation.run { await withCheckedContinuation { first = $0 }; firstReturned = true }
        #expect(try await waitFor { first != nil })
        operation.cancel()
        operation.run { await withCheckedContinuation { second = $0 } }
        #expect(try await waitFor { second != nil })
        first?.resume()
        #expect(try await waitFor { firstReturned })
        #expect(operation.isRunning)
        operation.cancel()
        second?.resume()
    }
}
