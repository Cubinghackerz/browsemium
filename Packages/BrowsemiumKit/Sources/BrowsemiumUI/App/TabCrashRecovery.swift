import BrowsemiumCore
import Foundation

/// Tracks attempts, not successful loads: a reload must not reset the guard.
struct TabCrashRecovery {
    private var attempts: [TabID: Date] = [:]

    mutating func shouldReload(_ tabID: TabID, now: Date = Date()) -> Bool {
        if let previous = attempts[tabID], now.timeIntervalSince(previous) < 60 {
            return false
        }
        attempts[tabID] = now
        return true
    }

    mutating func remove(_ tabID: TabID) {
        attempts[tabID] = nil
    }
}
