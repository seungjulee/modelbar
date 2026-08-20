import Foundation
import Darwin

/// Result of running a short-lived helper process to completion.
struct RunResult: Sendable {
    var status: Int32
    /// stdout and stderr merged — these helpers are small and we only ever
    /// want the text for diagnostics, and one pipe cannot deadlock.
    var output: String
    var timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
    var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Handle to a server ModelBar launched.
struct SpawnHandle: Sendable {
    var pid: pid_t?
    var logPath: String?
    /// Size of the log at launch time, so failure diagnostics can show only
    /// the lines this run produced rather than a week of history.
    var logOffset: UInt64
}

enum StopOutcome: Sendable {
    case nothingListening
    case stopped(pids: [pid_t], usedSIGKILL: Bool)
    case refusedUnmanaged(pids: [pid_t])
    case failed(pids: [pid_t])
}

/// Serialises access to a checked continuation so a timeout and a normal exit
/// cannot both resume it.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum ProcessControl {

    // MARK: - Running helpers

    /// A PATH that works for a GUI app: launchd gives app bundles a minimal
    /// environment that omits Homebrew, so anything spawned needs this.
    static let defaultPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func run(_ argv: [String],
                    cwd: String? = nil,
                    env extraEnv: [String: String] = [:],
                    timeout: Double = 15) async -> RunResult {
        guard let exe = argv.first, !exe.isEmpty else {
            return RunResult(status: -1, output: "empty argv", timedOut: false)
        }

        let proc = Process()
        // Go through /usr/bin/env so bare program names still resolve via PATH.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = extraEnv["PATH"] ?? defaultPath
        for (k, v) in extraEnv { env[k] = v }
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return RunResult(status: -1, output: "spawn failed: \(error.localizedDescription)",
                             timedOut: false)
        }

        // Drain on a background queue so a chatty child cannot fill the pipe
        // buffer and wedge before we get to read it.
        let dataBox = DataBox()
        let readQueue = DispatchQueue(label: "modelbar.pipe-read")
        readQueue.async {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            dataBox.set(d)
        }

        let guardBox = ResumeGuard()
        return await withCheckedContinuation { (cont: CheckedContinuation<RunResult, Never>) in
            proc.terminationHandler = { p in
                guard guardBox.claim() else { return }
                readQueue.async {
                    let text = String(decoding: dataBox.get(), as: UTF8.self)
                    cont.resume(returning: RunResult(status: p.terminationStatus,
                                                     output: text, timedOut: false))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard proc.isRunning, guardBox.claim() else { return }
                proc.terminate()
                cont.resume(returning: RunResult(status: -1,
                                                 output: "timed out after \(Int(timeout))s",
                                                 timedOut: true))
            }
        }
    }

    // MARK: - Port ownership

    /// PIDs currently LISTENing on a TCP port. This is the only way ModelBar
    /// identifies what to stop — matching on process-name substrings would risk
    /// killing an unrelated process that merely looks similar.
    static func listeners(port: Int) async -> [pid_t] {
        let r = await run(["/usr/sbin/lsof", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
                         timeout: 8)
        // lsof exits non-zero when there are simply no matches, so status is
        // deliberately not treated as an error here.
        return r.output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 1 && $0 != getpid() }
    }

    static func isAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM  // exists, just not ours to signal
    }

    /// Frees a port: SIGTERM everything listening, escalate to SIGKILL only if
    /// the grace period expires. `allowKill == false` protects service-managed
    /// backends (Ollama) that must never be taken down by this app.
    static func stop(port: Int, grace: Double, allowKill: Bool = true) async -> StopOutcome {
        let pids = await listeners(port: port)
        guard !pids.isEmpty else { return .nothingListening }
        guard allowKill else { return .refusedUnmanaged(pids: pids) }

        for pid in pids { _ = kill(pid, SIGTERM) }
        if await waitForExit(pids: pids, timeout: grace) {
            return .stopped(pids: pids, usedSIGKILL: false)
        }

        let stubborn = pids.filter { isAlive(pid: $0) }
        for pid in stubborn { _ = kill(pid, SIGKILL) }
        if await waitForExit(pids: stubborn, timeout: 5) {
            return .stopped(pids: pids, usedSIGKILL: true)
        }
        return .failed(pids: pids.filter { isAlive(pid: $0) })
    }

    private static func waitForExit(pids: [pid_t], timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !pids.contains(where: { isAlive(pid: $0) }) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !pids.contains(where: { isAlive(pid: $0) })
    }

    // MARK: - Launching servers

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Starts a server fully detached, the way `( cd dir && nohup cmd & )` does
    /// from a shell.
    ///
    /// Why a shell at all: the server must outlive ModelBar. Backgrounding
    /// inside `sh` makes the grandchild an orphan that launchd reparents, so
    /// quitting the menubar app never takes the model down with it. `sh` exits
    /// immediately; we wait only for that, never for the server.
    ///
    /// argv is shell-quoted element by element, so arguments are not re-split
    /// and manifest content cannot inject extra commands.
    static func spawnDetached(_ cmd: CommandSpec) async -> (handle: SpawnHandle, error: String?) {
        let argv = cmd.resolvedArgv
        guard !argv.isEmpty else {
            return (SpawnHandle(pid: nil, logPath: nil, logOffset: 0), "start command has no argv")
        }

        let logPath = cmd.resolvedLogPath ?? "/tmp/modelbar-\(abs(argv[0].hashValue)).log"
        // Record where this run's output begins so failure diagnostics do not
        // dredge up unrelated history from a long-lived log.
        let offset = fileSize(logPath)

        let pidFile = NSTemporaryDirectory() + "modelbar-\(UUID().uuidString).pid"

        var envAssignments = ["PATH=\(cmd.env["PATH"] ?? defaultPath)"]
        for (k, v) in cmd.env.sorted(by: { $0.key < $1.key }) where k != "PATH" {
            envAssignments.append("\(k)=\(v)")
        }

        var inner = ""
        if let cwd = cmd.resolvedCwd {
            inner += "cd \(shellQuote(cwd)) && "
        }
        inner += "exec /usr/bin/env "
        inner += envAssignments.map(shellQuote).joined(separator: " ")
        inner += " "
        inner += argv.map(shellQuote).joined(separator: " ")

        let script = "{ \(inner) ; } >> \(shellQuote(logPath)) 2>&1 & echo $! > \(shellQuote(pidFile))"

        let r = await run(["/bin/sh", "-c", script], timeout: 20)
        guard r.succeeded else {
            return (SpawnHandle(pid: nil, logPath: logPath, logOffset: offset),
                    "launcher failed: \(r.trimmed.isEmpty ? "status \(r.status)" : r.trimmed)")
        }

        let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        try? FileManager.default.removeItem(atPath: pidFile)

        return (SpawnHandle(pid: pid, logPath: logPath, logOffset: offset), nil)
    }

    // MARK: - Logs

    static func fileSize(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Reads what a log gained since `offset`, capped to the last `maxBytes`.
    static func tail(path: String, from offset: UInt64, maxBytes: Int = 16384) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: offset)
            let data = try fh.readToEnd() ?? Data()
            let slice = data.count > maxBytes ? data.suffix(maxBytes) : data
            return String(decoding: slice, as: UTF8.self)
        } catch {
            return ""
        }
    }

    /// Picks the lines from a log excerpt most likely to explain a failure.
    static func likelyErrors(in text: String, limit: Int = 6) -> [String] {
        let needles = ["error", "fatal", "failed", "cannot", "unable",
                       "no such file", "traceback", "assert", "abort",
                       "out of memory", "insufficient", "address already in use"]
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let hits = lines.filter { line in
            let low = line.lowercased()
            return needles.contains { low.contains($0) }
        }
        // Fall back to the last few lines when nothing matched — a server that
        // died silently still leaves a clue at the end of its log.
        let chosen = hits.isEmpty ? Array(lines.suffix(limit)) : Array(hits.suffix(limit))
        return chosen.map { String($0.prefix(220)) }
    }
}

/// Tiny lock-protected box for handing pipe output between queues.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
