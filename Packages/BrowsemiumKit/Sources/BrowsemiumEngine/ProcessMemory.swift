import Darwin
import Foundation

/// Real, measurable memory for this process.
///
/// WebKit renders pages in separate helper processes and does not expose a
/// per-tab figure, so Browsemium reports only numbers it can actually verify:
/// the browser's own physical footprint, and whether a tab currently holds a
/// live web view. It never invents a per-tab memory estimate.
public enum ProcessMemory {
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

    /// Human-readable footprint, e.g. "412 MB".
    public static func formattedFootprint() -> String {
        let bytes = footprintBytes()
        guard bytes > 0 else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
