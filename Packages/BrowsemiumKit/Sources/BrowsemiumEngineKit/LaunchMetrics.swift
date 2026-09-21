import Foundation
import OSLog

/// Launch-timing instrumentation. Each milestone is emitted once, as a
/// signpost event (visible in Instruments' Points of Interest track) and a
/// plain log line carrying the elapsed time since the process-start mark.
///
/// Read a launch timeline with:
///   log show --predicate 'subsystem == "com.browsemium.launch"' --last 5m
///
/// Milestone names only — no URLs, titles, or profile data ever attach to a
/// mark, so this is safe to keep enabled in release builds.
public enum LaunchMetrics {
    public enum Milestone: String, Sendable {
        case processStart = "process-start"
        case environmentReady = "environment-ready"
        case modelReady = "model-ready"
        case firstFrame = "first-frame"
        case firstNavigation = "first-navigation"
        case idle = "idle"
    }

    private static let log = OSLog(subsystem: "com.browsemium.launch", category: .pointsOfInterest)
    private static let signposter = OSSignposter(logHandle: log)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var start = ContinuousClock.now
    nonisolated(unsafe) private static var emitted = Set<Milestone>()

    /// Records a milestone. The first mark of any kind sets the clock's zero
    /// point — property initializers can run before `init`, so no single
    /// milestone may assume it comes first. Repeating a milestone is a no-op:
    /// second windows must not rewrite the launch timeline.
    public static func mark(_ milestone: Milestone) {
        let now = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        guard emitted.insert(milestone).inserted else { return }
        let elapsed = now - start
        let milliseconds = elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        signposter.emitEvent("launch milestone")
        // .default so the timeline persists in the log store — .info is
        // memory-only and `log show` would never see it.
        os_log(
            .default,
            log: log,
            "launch %{public}@ t+%lldms",
            milestone.rawValue,
            milliseconds
        )
    }
}
