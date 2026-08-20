import Foundation
import Darwin

/// A point-in-time view of system memory, modelled on the numbers Activity
/// Monitor shows so they can be compared directly.
///
/// IMPORTANT for this app's purpose: a llama.cpp/ds4 server mmaps its GGUF, so
/// the weights land in the *file-backed* page cache, not in the process's
/// private footprint. That is why `ds4-server` reports a ~7 GB footprint while
/// holding an 84 GB model. Budgeting therefore uses the manifest's declared
/// `estimatedGB`, and these figures are shown as context, not as the budget.
struct MemorySnapshot: Sendable {
    var totalBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var cachedFileBytes: UInt64
    var pressure: Pressure

    enum Pressure: Sendable {
        case normal, warning, critical, unknown

        var label: String {
            switch self {
            case .normal: return "normal"
            case .warning: return "warning"
            case .critical: return "critical"
            case .unknown: return "unknown"
            }
        }
    }

    /// "Memory Used" in Activity Monitor terms.
    var usedBytes: UInt64 { appBytes &+ wiredBytes &+ compressedBytes }
    var usedFraction: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes)
    }
}

enum SystemMemory {

    /// Kernel page size, queried once. `vm_kernel_page_size` is a mutable C
    /// global and so is off-limits under strict concurrency; it is also 16384
    /// on Apple Silicon rather than the 4096 that is often assumed, and every
    /// figure below is wrong by 4x if that is hardcoded.
    static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else {
            return UInt64(sysconf(_SC_PAGESIZE))
        }
        return UInt64(size)
    }()
    /// Reads `host_statistics64` and the kernel pressure level.
    static func snapshot() -> MemorySnapshot {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return MemorySnapshot(totalBytes: total, appBytes: 0, wiredBytes: 0,
                                  compressedBytes: 0, cachedFileBytes: 0, pressure: .unknown)
        }

        let page = Self.pageSize
        // App memory = internal pages minus the purgeable share, matching how
        // Activity Monitor splits "App Memory" from "Cached Files".
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? (internalPages - purgeable) * page : 0
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page

        return MemorySnapshot(totalBytes: total, appBytes: app, wiredBytes: wired,
                              compressedBytes: compressed, cachedFileBytes: cached,
                              pressure: pressureLevel())
    }

    private static func pressureLevel() -> MemorySnapshot.Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        // Values are from <sys/kern_memorystatus.h>: 1 normal, 2 warn, 4 critical.
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    /// Physical footprint of one process, the same figure Activity Monitor's
    /// "Memory" column and `footprint(1)` report. Returns nil if the pid is
    /// gone or not owned by us.
    static func footprintBytes(pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { raw in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, raw)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : nil
    }
}

// MARK: - Formatting

enum Fmt {
    /// Auto-scaling byte formatter. Needed because these processes span six
    /// orders of magnitude: an mmap-backed server can report 4.8 MB resident
    /// while its footprint is 38 GB, and a fixed "GB" column renders the small
    /// figures as a useless "0.0 GB".
    static func bytes(_ b: UInt64) -> String {
        let v = Double(b)
        if v >= 1_073_741_824 { return String(format: "%.1f GB", v / 1_073_741_824) }
        if v >= 1_048_576 { return String(format: "%.0f MB", v / 1_048_576) }
        if v >= 1024 { return String(format: "%.0f KB", v / 1024) }
        return "\(b) B"
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    static func gb(_ value: Double) -> String {
        String(format: "%.0f GB", value)
    }

    static func uptime(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return String(format: "%.1fh", Double(s) / 3600) }
        return String(format: "%.1fd", Double(s) / 86400)
    }
}

// MARK: - Swap

/// Swap is the number that matters most on this machine: once a model exceeds
/// the wired limit the system pages silently and tok/s collapses, with no other
/// visible symptom. Non-zero swap is therefore surfaced prominently.
struct SwapSnapshot: Sendable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var freeBytes: UInt64
    var isNonZero: Bool { usedBytes > 0 }
}

extension SystemMemory {
    static func swap() -> SwapSnapshot {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return SwapSnapshot(totalBytes: 0, usedBytes: 0, freeBytes: 0)
        }
        return SwapSnapshot(totalBytes: usage.xsu_total,
                            usedBytes: usage.xsu_used,
                            freeBytes: usage.xsu_avail)
    }

    /// Free (immediately available) memory: free + speculative pages.
    static func freeBytes() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = Self.pageSize
        return (UInt64(stats.free_count) + UInt64(stats.speculative_count)) * page
    }
}

extension Fmt {
    /// Pads to a fixed column width. `String(format:)` ignores width flags on
    /// `%@`, so table alignment has to be done explicitly.
    static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        let fill = String(repeating: " ", count: width - s.count)
        return right ? fill + s : s + fill
    }
}
