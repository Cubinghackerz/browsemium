import Darwin
import Foundation

/// Real, measurable memory for this process and the helpers it owns.
///
/// WebKit renders pages in separate helper processes and does not expose a
/// per-tab figure, so Browsemium reports only numbers it can actually verify:
/// the browser's own physical footprint, the footprint of the process group it
/// is responsible for, and whether a tab currently holds a live web view. It
/// never invents a per-tab memory estimate.
public enum ProcessMemory {
    /// What a group measurement actually covered.
    public struct GroupFootprint: Sendable {
        /// Sum of the physical footprints that could be read, in bytes.
        public let bytes: UInt64
        /// Number of processes that contributed a figure.
        public let measuredProcesses: Int
        /// True when every process in the tree answered. False means a helper
        /// refused to be measured (a sandbox can deny this) and the total is a
        /// lower bound rather than the whole truth.
        public let isComplete: Bool

        public init(bytes: UInt64, measuredProcesses: Int, isComplete: Bool) {
            self.bytes = bytes
            self.measuredProcesses = measuredProcesses
            self.isComplete = isComplete
        }
    }

    /// Physical footprint of the current process in bytes.
    public static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// Physical footprint of this process and every descendant it owns —
    /// WebKit's web-content, networking, and GPU processes. This is the figure
    /// `Benchmarks/benchmark-memory.sh` measures for the whole app, and the
    /// only one that describes what browsing actually costs.
    public static func groupFootprint() -> GroupFootprint {
        var bytes: UInt64 = 0
        var measured = 0
        var failed = 0
        for pid in processTreePIDs(root: getpid()) {
            let footprint = footprintBytes(of: pid)
            if footprint > 0 {
                bytes &+= footprint
                measured += 1
            } else {
                failed += 1
            }
        }
        return GroupFootprint(bytes: bytes, measuredProcesses: measured, isComplete: failed == 0)
    }

    /// What the app can honestly say about its own memory.
    public struct Summary: Sendable {
        /// Bytes measured across the processes that could be attributed.
        public let bytes: UInt64
        /// True when page processes were included, which only happens when the
        /// engine parents them. WebKit's page processes are XPC services owned
        /// by launchd, so with WebKit this is false and the figure covers the
        /// app process alone.
        public let includesPageProcesses: Bool

        public var formatted: String {
            guard bytes > 0 else { return "Unavailable" }
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        }
    }

    /// The figure the UI should show, with the scope it actually covers.
    public static func summary() -> Summary {
        let group = groupFootprint()
        let own = footprintBytes()
        if group.measuredProcesses > 1, group.bytes > own {
            return Summary(bytes: group.bytes, includesPageProcesses: true)
        }
        return Summary(bytes: own, includesPageProcesses: false)
    }

    /// Human-readable footprint of this process, e.g. "412 MB".
    public static func formattedFootprint() -> String {
        formatted(footprintBytes())
    }

    private static func formatted(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private static func processTreePIDs(root: pid_t) -> [pid_t] {
        var collected: [pid_t] = [root]
        var index = 0
        while index < collected.count {
            for child in childPIDs(of: collected[index]) where !collected.contains(child) {
                collected.append(child)
            }
            index += 1
        }
        return collected
    }

    /// Direct children of `pid`. `proc_listchildpids` reports either a pid
    /// count or a byte count depending on the SDK generation, so both readings
    /// are accepted: the buffer is zero-filled and empty slots are dropped, so
    /// a misread can only under-report, never invent a process.
    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let capacity = 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let reported = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
        }
        guard reported > 0 else { return [] }
        let count = reported <= Int32(capacity)
            ? Int(reported)
            : Int(reported) / MemoryLayout<pid_t>.size
        return Array(buffer[0..<min(count, capacity)]).filter { $0 > 0 }
    }

    private static func footprintBytes(of pid: pid_t) -> UInt64 {
        if pid == getpid() {
            return footprintBytes()
        }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            // rusage_info_t is void*, so the parameter is a pointer to the
            // struct itself, not to a pointer-sized slot — the kernel writes
            // sizeof(rusage_info_v4) bytes at the address it is given.
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return 0 }
        return info.ri_phys_footprint
    }
}
