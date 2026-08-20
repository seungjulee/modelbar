import Foundation
import IOKit
import Darwin

/// GPU wired memory against the `iogpu.wired_limit_mb` ceiling.
///
/// That ceiling is what actually decides whether a large model loads at all, so
/// it is shown as a used/limit bar.
///
/// Caveat worth knowing when reading these numbers: the driver's
/// "In use system memory" counter tracks GPU-resident allocations. A
/// llama.cpp/ds4 server that mmaps its GGUF has most of its weights in the
/// shared file cache rather than in driver allocations, so this figure can be
/// far below the model's nominal size while the model is idle. The companion
/// "Alloc system memory" key is a cumulative/oversubscribed counter (it reads
/// ~149 GB on a 128 GB machine) and is deliberately not used.
struct GPUSnapshot: Sendable {
    var inUseBytes: UInt64
    var limitBytes: UInt64
    var available: Bool

    var fraction: Double {
        limitBytes == 0 ? 0 : min(1.0, Double(inUseBytes) / Double(limitBytes))
    }
}

enum GPUMemory {
    /// The `iogpu.wired_limit_mb` sysctl, in bytes. A value of 0 means the
    /// kernel is using its default heuristic rather than an explicit cap.
    static func wiredLimitBytes() -> UInt64 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("iogpu.wired_limit_mb", &value, &size, nil, 0) == 0, value > 0 else {
            return 0
        }
        return UInt64(value) * 1_048_576
    }

    static func snapshot() -> GPUSnapshot {
        let limit = wiredLimitBytes()
        guard let inUse = inUseSystemMemory() else {
            return GPUSnapshot(inUseBytes: 0, limitBytes: limit, available: false)
        }
        return GPUSnapshot(inUseBytes: inUse, limitBytes: limit, available: true)
    }

    /// Reads PerformanceStatistics."In use system memory" from the AGX driver.
    /// Uses IOKit directly rather than shelling out to ioreg, since this is on
    /// the ~1 s refresh path while the menu is open.
    private static func inUseSystemMemory() -> UInt64? {
        guard let matching = IOServiceMatching("AGXAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let raw = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
            guard let props = raw?.takeRetainedValue() as? [String: Any] else { continue }
            if let n = props["In use system memory"] as? NSNumber {
                return n.uint64Value
            }
        }
        return nil
    }
}
