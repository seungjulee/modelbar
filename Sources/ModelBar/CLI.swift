import Foundation

/// Character-cell bars, for terminal output only. The menu UI draws real
/// shapes instead — character art looked like debug output there.
enum Bars {
    static func text(_ fraction: Double, width: Int = 10) -> String {
        let f = fraction.isFinite ? max(0, min(1, fraction)) : 0
        let filled = Int((f * Double(width)).rounded())
        return "[" + String(repeating: "#", count: filled)
             + String(repeating: ".", count: max(0, width - filled)) + "]"
    }
}

/// Headless entry point.
///
/// This exists so the process lifecycle, manifest parsing, memory guard and
/// monitor can be exercised and tested from a terminal — the menubar UI cannot
/// be driven programmatically, and a separate test harness would only prove
/// that the *harness* works. Every subcommand goes through the same `AppState`
/// the UI uses.
@MainActor
enum CLI {

    static func run(_ args: [String]) async -> Int32 {
        var argv = args
        let force = argv.contains("--force")

        // Optional --manifest <path>, mainly so the failure paths can be
        // exercised against a scratch manifest without touching the real one.
        var manifestPath: String?
        if let i = argv.firstIndex(of: "--manifest"), i + 1 < argv.count {
            manifestPath = argv[i + 1].expandingTilde
            argv.removeSubrange(i...(i + 1))
        }
        argv.removeAll { $0 == "--cli" || $0 == "--force" }

        let command = argv.first ?? "help"
        let rest = Array(argv.dropFirst())

        let state = AppState(manifestPath: manifestPath)
        state.overBudgetPolicy = force ? .allow : .deny

        switch command {
        case "validate":  return validate(state)
        case "status":    return await status(state)
        case "monitor":   return await monitor(state)
        case "start":     return await start(state, id: rest.first)
        case "stop":      return await stop(state, id: rest.first)
        case "harness":   return await harness(state, rest)
        case "discover":  return await discover(state)
        case "context":   return context(state, rest)
        default:
            print("""
            ModelBar CLI — same code paths as the menubar app.

              --cli validate            parse the manifest, check every referenced path
              --cli status              backend health + served model + telemetry
              --cli monitor             one-shot htop-style resource snapshot
              --cli start <model-id>    stop the port's occupant, start the model, await health
              --cli stop  <model-id>    stop the server on that model's port
              --cli harness show        what Pi and Hermes point at
              --cli harness set <id>    point both at a model

            Add --manifest <path> to use a manifest other than ~/models/modelbar.json.

            Add --force to permit an over-budget load.
            """)
            return command == "help" ? 0 : 2
        }
    }

    // MARK: - Subcommands

    private static func validate(_ state: AppState) -> Int32 {
        if let error = state.manifestError {
            print("MANIFEST ERROR: \(error)")
            return 1
        }
        print("manifest: \(state.manifestPath)")
        print("backends: \(state.backends.count)   models: \(state.models.count)")

        if state.manifestWarnings.isEmpty {
            print("warnings: none")
        } else {
            print("warnings:")
            for w in state.manifestWarnings { print("  ! \(w)") }
        }

        var missingTotal = 0
        print("\nmodels:")
        for model in state.models {
            let missing = model.missingRequirements
            missingTotal += missing.count
            let mark = missing.isEmpty ? "OK  " : "MISS"
            print("  [\(mark)] " + Fmt.pad(model.displayName, 44)
                  + Fmt.pad(model.backendId, 10)
                  + Fmt.pad(":\(model.port)", 7)
                  + Fmt.pad(String(format: "~%.0fGB", model.estimatedGB), 8, right: true))
            for path in missing { print("         missing: \(path)") }
            for drafter in model.drafters {
                let dm = drafter.missingRequirements
                let flag = drafter.enabled ? (dm.isEmpty ? "enabled" : "enabled-but-missing")
                                           : "disabled"
                print("         drafter \(drafter.id): \(flag)")
            }
        }
        print("\n\(missingTotal) missing file(s) across all entries")
        return 0
    }

    private static func status(_ state: AppState) async -> Int32 {
        await state.refresh()
        print("backend      port    up  served model / telemetry")
        for backend in state.backends {
            let s = state.status(backend.id)
            let up = (s?.up ?? false) ? "yes" : "no "
            var line = Fmt.pad(backend.id, 13) + Fmt.pad(":\(backend.port)", 8) + up + "  "
            if let s, s.up {
                line += s.servedModel ?? "(no model reported)"
                if let uptime = s.uptime { line += "  up \(Fmt.uptime(uptime))" }
            }
            print(line)
            if let s, s.up { printTelemetry(s.telemetry) }
        }
        let loaded = state.models.filter { state.isLoaded($0) }
        print("\nloaded models: " + (loaded.isEmpty ? "none"
                                     : loaded.map(\.displayName).joined(separator: ", ")))
        print(String(format: "committed ~%.0f GB of %.0f GB budget",
                     state.committedGB(), state.budgetGB))
        return 0
    }

    private static func printTelemetry(_ t: Telemetry) {
        if let d = t.decodeTPS {
            var line = String(format: "               decode %.2f t/s", d)
            if let p = t.prefillTPS { line += String(format: " · prefill %.2f t/s", p) }
            if let b = t.busy { line += " · busy \(b)" }
            if let q = t.queueDepth { line += " · queue \(q)" }
            print(line)
        }
        if let used = t.contextUsed, let size = t.contextSize, size > 0 {
            let frac = Double(used) / Double(size)
            print("               ctx " + Bars.text(frac)
                  + String(format: " %.1f%%  ", frac * 100) + "\(used) / \(size)")
        }
        for m in t.ollamaResident {
            print("               resident \(m.name) · \(Fmt.bytes(m.sizeBytes))")
        }
        if let r = t.jobsRunning {
            print("               queue running \(r) · pending \(t.jobsPending ?? 0)")
        }
        if !t.extra.isEmpty {
            print("               " + t.extra.map { "\($0.key) \($0.value)" }
                    .joined(separator: " · "))
        }
    }

    private static func monitor(_ state: AppState) async -> Int32 {
        // Two passes: %CPU is a delta between samples, so a single pass would
        // report 0.0% for everything.
        await state.refresh()
        try? await Task.sleep(for: .milliseconds(1200))
        await state.refresh()

        let m = state.memory
        let s = state.swap
        let g = state.gpu

        print("SYSTEM                                     pressure: \(m.pressure.label)")
        print("RAM  " + Bars.text(m.usedFraction)
              + String(format: " %3.0f%%   ", m.usedFraction * 100)
              + "\(Fmt.gb(m.usedBytes)) / \(Fmt.gb(m.totalBytes))")
        print("     free \(Fmt.gb(state.freeBytes)) · wired \(Fmt.gb(m.wiredBytes))"
              + " · cached \(Fmt.gb(m.cachedFileBytes)) · compressed \(Fmt.gb(m.compressedBytes))")

        let swapFrac = s.totalBytes == 0 ? 0 : Double(s.usedBytes) / Double(s.totalBytes)
        // Only growing swap indicates current distress; a steady non-zero
        // figure is just history macOS has not reclaimed.
        print("SWAP " + Bars.text(swapFrac)
              + " \(Fmt.gb(s.usedBytes)) used of \(Fmt.gb(s.totalBytes))"
              + "  (\(state.swapTrend.label))"
              + (state.swapTrend == .growing ? "  *** GROWING — under real pressure ***" : ""))

        if g.limitBytes > 0 {
            let detail = g.available
                ? "\(Fmt.gb(g.inUseBytes)) / \(Fmt.gb(g.limitBytes)) wired cap"
                : "cap \(Fmt.gb(g.limitBytes)) (driver usage unavailable)"
            print("GPU  " + Bars.text(g.fraction)
                  + String(format: " %3.0f%%   ", g.fraction * 100) + detail)
        }

        print("\nAI PROCESSES (\(state.procs.count))")
        if state.procs.isEmpty {
            print("  none running")
        } else {
            print("  " + Fmt.pad("PROCESS", 18) + Fmt.pad("PID", 8, right: true)
                  + Fmt.pad("RSS", 11, right: true) + Fmt.pad("FOOTPRINT", 11, right: true)
                  + Fmt.pad("CPU", 9, right: true) + Fmt.pad("UPTIME", 9, right: true))
            var totalFootprint: UInt64 = 0
            for p in state.procs {
                totalFootprint &+= p.footprintBytes
                print("  " + Fmt.pad(p.label, 18) + Fmt.pad("\(p.pid)", 8, right: true)
                      + Fmt.pad(Fmt.bytes(p.rssBytes), 11, right: true)
                      + Fmt.pad(Fmt.bytes(p.footprintBytes), 11, right: true)
                      + Fmt.pad(String(format: "%.1f%%", p.cpuPercent), 9, right: true)
                      + Fmt.pad(Fmt.uptime(p.uptime), 9, right: true))
            }
            print("  " + String(repeating: "-", count: 62))
            print("  " + Fmt.pad("TOTAL", 18) + Fmt.pad("", 8) + Fmt.pad("", 11)
                  + Fmt.pad(Fmt.bytes(totalFootprint), 11, right: true))
            print("  note: sorted by footprint. rss excludes mmapped GGUF weights,")
            print("        which live in the shared file cache ('cached' above) —")
            print("        ds4-server holds an 84GB model at ~5MB rss.")
        }

        print("\nBACKENDS")
        for backend in state.backends {
            guard let st = state.status(backend.id) else { continue }
            let dot = st.up ? (st.telemetry.busy == true ? "~" : "*") : "."
            print("  \(dot) \(backend.id):\(backend.port) "
                  + (st.up ? (st.servedModel ?? "up") : "down"))
            if st.up { printTelemetry(st.telemetry) }
        }
        return 0
    }

    private static func start(_ state: AppState, id: String?) async -> Int32 {
        guard let id, let model = state.models.first(where: { $0.id == id }) else {
            print("unknown model id \(id ?? "(none)")")
            print("known: " + state.models.map(\.id).joined(separator: ", "))
            return 2
        }
        print("starting \(model.displayName) on :\(model.port) …")
        let began = Date()
        await state.load(model)
        let elapsed = Date().timeIntervalSince(began)

        if let failure = state.lastFailure, failure.modelId == model.id {
            print(String(format: "FAILED after %.1fs: %@", elapsed, failure.summary as NSString))
            for line in failure.logLines { print("  | \(line)") }
            return 1
        }
        print(String(format: "started in %.1fs", elapsed))
        _ = await status(state)
        return 0
    }

    private static func stop(_ state: AppState, id: String?) async -> Int32 {
        guard let id, let model = state.models.first(where: { $0.id == id }) else {
            print("unknown model id \(id ?? "(none)")")
            return 2
        }
        print("stopping \(model.displayName) on :\(model.port) …")
        await state.stop(model)
        print(state.actionNote ?? "done")
        return 0
    }

    private static func context(_ state: AppState, _ rest: [String]) -> Int32 {
        guard rest.count >= 2, let model = state.models.first(where: { $0.id == rest[0] }),
              let size = Int(rest[1]) else {
            print("usage: --cli context <model-id> <size>")
            return 2
        }
        guard let ctx = model.context else {
            print("\(model.displayName) has no adjustable context")
            return 2
        }
        guard ctx.options.contains(size) else {
            print("size \(size) not in \(ctx.options)")
            return 2
        }
        state.setContextSize(size, for: model)
        print("context set to \(state.selectedContextSize(for: model)) for \(model.displayName)")
        return 0
    }

    private static func discover(_ state: AppState) async -> Int32 {
        await state.refreshDiscovery(force: true)
        if state.discovered.isEmpty {
            print("nothing found outside the manifest")
            return 0
        }
        print("found \(state.discovered.count) item(s) not referenced by any manifest model:\n")
        for item in state.discovered {
            print("  [\(item.source.rawValue)] \(item.name)")
            print("        \(item.detail)" + (item.sizeBytes > 0 ? " · \(Fmt.bytes(item.sizeBytes))" : ""))
        }
        return 0
    }

    private static func harness(_ state: AppState, _ rest: [String]) async -> Int32 {
        let sub = rest.first ?? "show"
        await state.refreshHarness()

        if sub == "show" {
            printHarnessState(state)
            return 0
        }

        // set <kind> <model-id|api>   — kind is hermes|pi|codex|claude
        guard sub == "set", rest.count >= 3 else {
            print("usage: --cli harness set <hermes|pi|codex|claude> <model-id|api>")
            return 2
        }
        let kindArg = rest[1]
        let target = rest[2]
        let kindMap: [String: AppState.HarnessKind] = [
            "hermes": .hermes, "pi": .pi, "codex": .codex,
            "claude": .claudeCode, "claudecode": .claudeCode,
        ]
        guard let kind = kindMap[kindArg.lowercased()] else {
            print("unknown harness \(kindArg) — one of: hermes, pi, codex, claude")
            return 2
        }

        var model: ModelSpec?
        if target.lowercased() != "api" {
            guard let m = state.models.first(where: { $0.id == target }) else {
                print("unknown model id \(target)")
                return 2
            }
            model = m
        } else if !kind.hasAPIOption {
            print("\(kind.displayName) has no API/off state — pass a model id")
            return 2
        }

        await state.pointHarness(kind, at: model)
        print(state.actionNote ?? "done")
        await state.refreshHarness()
        printHarnessState(state)
        return 0
    }

    private static func printHarnessState(_ state: AppState) {
        let h = state.harness
        print("hermes:      \(h.hermesProvider ?? "?") / \(h.hermesModel ?? "?")")
        print("pi:          \(h.piProvider ?? "?") / \(h.piModel ?? "?")")
        print("codex-local: \(h.codexActiveProfile.map { "profile \($0)" } ?? "API (disarmed)")")
        print("claude-local:\(h.claudeLocalActiveModel.map { " \($0)" } ?? " API (disarmed)")")
        for e in h.errors { print("  ! \(e)") }
    }
}
