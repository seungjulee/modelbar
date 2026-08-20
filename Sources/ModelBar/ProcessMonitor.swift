import Foundation
import Darwin

/// One sampled process row, htop-style.
struct ProcSample: Sendable, Identifiable, Equatable {
    var id: pid_t { pid }
    var pid: pid_t
    var label: String
    var command: String
    var rssBytes: UInt64
    var footprintBytes: UInt64
    var cpuPercent: Double
    var uptime: TimeInterval
}

/// A process's command line, split into the part that identifies the *program*
/// and the full line including arguments.
struct ProcIdentity: Sendable {
    /// Executable path plus argv[0]. argv[0] matters for shebang scripts:
    /// `mlx_lm.server` execs as the venv's python, and only argv[0] names the
    /// script.
    var identity: String
    /// Executable path plus every argument.
    var full: String
}

/// Declarative rule for deciding which processes belong to a backend.
///
/// `any` is matched against the program identity only — NOT the whole command
/// line. Matching arbitrary argv text produced real false positives: an
/// unrelated shell whose script merely contained the word "ollama" was being
/// reported as an AI process. `all` is matched against the full line, to
/// disambiguate programs that share an interpreter (ComfyUI runs as a bare
/// `python`, so it is identified by `main.py` in its arguments).
struct ProcessMatcher: Sendable {
    var label: String
    /// At least one of these must appear in the program identity.
    var any: [String]
    /// All of these must also appear somewhere in the full command line.
    var all: [String]

    func matches(_ p: ProcIdentity) -> Bool {
        let id = p.identity.lowercased()
        guard any.contains(where: { id.contains($0.lowercased()) }) else { return false }
        let full = p.full.lowercased()
        return all.allSatisfy { full.contains($0.lowercased()) }
    }
}

/// Samples the AI-related processes. Holds two caches across polls:
/// a pid→command-line cache (argv is immutable for a live process, so it is
/// fetched once) and a pid→CPU-time cache used to derive %CPU from the delta
/// between polls, the same way htop does.
actor ProcessMonitor {
    private var cmdlineCache: [pid_t: ProcIdentity] = [:]
    private var cpuCache: [pid_t: (cpuNanos: UInt64, at: Date)] = [:]

    func sample(matchers: [ProcessMatcher]) -> [ProcSample] {
        let pids = Self.allPIDs()
        let live = Set(pids)

        // Drop dead pids so the caches cannot grow without bound.
        cmdlineCache = cmdlineCache.filter { live.contains($0.key) }
        cpuCache = cpuCache.filter { live.contains($0.key) }

        var out: [ProcSample] = []
        let now = Date()

        for pid in pids {
            let ident: ProcIdentity
            if let cached = cmdlineCache[pid] {
                ident = cached
            } else {
                guard let fetched = Self.commandLine(pid: pid) else { continue }
                cmdlineCache[pid] = fetched
                ident = fetched
            }

            guard let matcher = matchers.first(where: { $0.matches(ident) }) else { continue }
            guard let usage = Self.rusage(pid: pid) else { continue }

            let cpuNanos = usage.ri_user_time &+ usage.ri_system_time
            var cpuPercent = 0.0
            if let prev = cpuCache[pid] {
                let wall = now.timeIntervalSince(prev.at)
                if wall > 0.05, cpuNanos >= prev.cpuNanos {
                    cpuPercent = Double(cpuNanos - prev.cpuNanos) / 1_000_000_000 / wall * 100
                }
            }
            cpuCache[pid] = (cpuNanos, now)

            out.append(ProcSample(
                pid: pid,
                label: matcher.label,
                command: Self.shortCommand(ident.full),
                rssBytes: usage.ri_resident_size,
                footprintBytes: usage.ri_phys_footprint,
                cpuPercent: cpuPercent,
                uptime: Self.startTime(pid: pid) ?? 0))
        }

        // htop order, biggest consumer first — but keyed on footprint rather
        // than RSS. Every model server here mmaps its weights, so RSS collapses
        // to a few MB for all of them and would give an arbitrary ordering.
        return out.sorted { $0.footprintBytes > $1.footprintBytes }
    }

    // MARK: - Darwin plumbing

    private static func allPIDs() -> [pid_t] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        // Over-allocate: the process table can grow between the sizing call
        // and the fetch.
        let capacity = Int(count) / MemoryLayout<pid_t>.size + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bytes = buffer.withUnsafeMutableBufferPointer { ptr in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, ptr.baseAddress,
                          Int32(capacity * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return [] }
        return Array(buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    private static func rusage(pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { raw in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, raw)
            }
        }
        return rc == 0 ? info : nil
    }

    /// Wall-clock uptime, from the process's BSD start timestamp.
    ///
    /// Deliberately NOT derived from `ri_proc_start_abstime`: that is on the
    /// mach_absolute_time clock, which does not advance while the machine is
    /// asleep. On this laptop that under-reported a 6.9-day-old server as
    /// 1.1 days. `pbi_start_tvsec` is a real Unix timestamp and matches
    /// `ps -o etime`.
    private static func startTime(pid: pid_t) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_start_tvsec > 0 else { return nil }
        let elapsed = Date().timeIntervalSince1970 - Double(info.pbi_start_tvsec)
        return elapsed > 0 ? elapsed : 0
    }

    /// Full command line via KERN_PROCARGS2.
    ///
    /// Layout is: argc (Int32), the executable path, NUL padding, then argc
    /// NUL-separated argv strings, then the environment. Returns nil for
    /// processes we may not inspect (other users, some system daemons).
    private static func commandLine(pid: pid_t) -> ProcIdentity? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }

        let bytes = buffer.prefix(size).map { UInt8(bitPattern: $0) }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            for i in 0..<MemoryLayout<Int32>.size where i < bytes.count {
                dst[i] = bytes[i]
            }
        }

        var cursor = MemoryLayout<Int32>.size
        // Executable path, then any NUL padding before argv[0].
        var execPath = [UInt8]()
        while cursor < bytes.count, bytes[cursor] != 0 {
            execPath.append(bytes[cursor]); cursor += 1
        }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }

        var parts: [String] = []
        var collected: Int32 = 0
        while collected < argc, cursor < bytes.count {
            var token = [UInt8]()
            while cursor < bytes.count, bytes[cursor] != 0 {
                token.append(bytes[cursor]); cursor += 1
            }
            cursor += 1
            parts.append(String(decoding: token, as: UTF8.self))
            collected += 1
        }

        let exec = String(decoding: execPath, as: UTF8.self)
        // argv[0] is kept, not dropped: for a shebang script the kernel reports
        // the *interpreter* as the exec path, and only argv[0] carries the
        // script name that actually identifies the program.
        let identity = ([exec] + parts.prefix(1)).joined(separator: " ")
        let full = ([exec] + parts).joined(separator: " ")
        return ProcIdentity(identity: identity, full: full)
    }

    /// Condenses a long command line for display: program basename plus a few
    /// meaningful arguments.
    private static func shortCommand(_ cmdline: String) -> String {
        let tokens = cmdline.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return cmdline }
        let base = (first as NSString).lastPathComponent
        let rest = tokens.dropFirst().prefix(3).map { token -> String in
            token.contains("/") ? (token as NSString).lastPathComponent : token
        }
        return ([base] + rest).joined(separator: " ")
    }
}
