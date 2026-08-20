import Foundation
import Observation
import AppKit

/// Who asked for a model to load. Manual is a menu click (pre-warming);
/// incomingRequest is the proxy's own reaction to a cold client connection —
/// distinguished in the UI ("starting ds4 for an incoming request…" reads very
/// differently from "loading ds4…" after a click) and in policy (a manual load
/// can pop a blocking over-budget confirmation; an auto load cannot, since
/// nobody is watching the screen to answer it).
enum StartTrigger: Sendable, Equatable {
    case manual
    case incomingRequest
}

/// What the app is currently doing to a backend. The 84 GB ds4 model takes
/// ~30 s to load, so this drives an explicit transitional state rather than a
/// spinner with no detail.
enum Activity: Equatable, Sendable {
    case idle
    case stopping(modelId: String)
    case starting(modelId: String, since: Date, trigger: StartTrigger)

    var modelId: String? {
        switch self {
        case .idle: return nil
        case .stopping(let id): return id
        case .starting(let id, _, _): return id
        }
    }
    var isBusy: Bool { self != .idle }
}

struct LoadFailure: Sendable, Equatable {
    var modelId: String
    var summary: String
    var logLines: [String]
    var logPath: String?
    var at: Date
}

@MainActor
@Observable
final class AppState {

    // MARK: - Observable state

    private(set) var manifest: Manifest?
    private(set) var manifestWarnings: [String] = []
    private(set) var manifestError: String?
    private(set) var manifestPath: String = ManifestLoader.defaultPath

    private(set) var statuses: [String: BackendStatus] = [:]
    private(set) var loadedModelIds: Set<String> = []
    private(set) var procs: [ProcSample] = []
    private(set) var memory: MemorySnapshot = SystemMemory.snapshot()
    private(set) var swap: SwapSnapshot = SystemMemory.swap()
    private(set) var swapTrend: SwapTrend = .steady
    private(set) var freeBytes: UInt64 = SystemMemory.freeBytes()
    private(set) var gpu: GPUSnapshot = GPUMemory.snapshot()
    /// False until the first backend probe completes. Without this the menu
    /// would render every backend as "down" on open, which reads as broken
    /// rather than as "not measured yet".
    private(set) var hasProbed = false

    /// Direction of swap use over the last minute.
    ///
    /// macOS never pages swap back in just because pressure dropped, so a
    /// non-zero figure is routinely stale — it can be hours old. Flagging it
    /// red merely for being non-zero is alarming and wrong; only *growing*
    /// swap indicates current distress.
    enum SwapTrend: Sendable, Equatable {
        case growing, steady, shrinking

        var label: String {
            switch self {
            case .growing: return "growing"
            case .steady: return "steady"
            case .shrinking: return "receding"
            }
        }
    }
    private(set) var harness = HarnessState()
    /// Files/entries found on disk or in a backend's own inventory that no
    /// manifest model currently references. Refreshed on a slow cadence, not
    /// the live poll loop — a directory walk plus GGUF header reads is real
    /// I/O that has no business running every 1-4 seconds.
    private(set) var discovered: [DiscoveredItem] = []
    private var lastDiscoveryScan: Date?

    /// Live phase per proxied backend (ds4, MLX), mirrored from each
    /// `ProxyServer` actor. `nil` for a backend with no `publicPort` — those
    /// are not proxied and have no on-demand lifecycle to show.
    private(set) var proxyPhases: [String: ProxyServer.Phase] = [:]

    var activity: Activity = .idle
    private(set) var lastFailure: LoadFailure?
    private(set) var lastRefresh: Date?
    private(set) var actionNote: String?

    /// Set by the UI when the dropdown opens/closes. Drives the refresh rate:
    /// ~1 s while visible so it feels live, slow when hidden so it is not
    /// burning CPU all day.
    var menuOpen: Bool = false {
        didSet { if menuOpen && menuOpen != oldValue { Task { await refresh() } } }
    }

    // MARK: - Private

    private let monitor = ProcessMonitor()
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false
    /// Remembers which manifest model was last started on each port, used to
    /// attribute a running server when the backend does not report a usable
    /// model name.
    private var lastStartedByPort: [Int: String] = [:]
    /// Rolling swap samples, used to derive `swapTrend`.
    private var swapHistory: [(at: Date, used: UInt64)] = []
    /// One `ProxyServer` per on-demand backend (ds4, MLX), keyed by backend id.
    private var proxies: [String: ProxyServer] = [:]
    /// User's chosen context-window size per model id, for models whose
    /// backend takes context as a restart-time launch flag. Persisted so a
    /// choice survives an idle-stop/auto-restart cycle.
    private var contextSelection: [String: Int] = [:]

    private static let lastStartedKey = "ModelBar.lastStartedByPort"
    private static let contextSelectionKey = "ModelBar.contextSelection"

    init(manifestPath: String? = nil) {
        if let manifestPath { self.manifestPath = manifestPath }
        if let stored = UserDefaults.standard.dictionary(forKey: Self.lastStartedKey)
            as? [String: String] {
            for (k, v) in stored {
                if let port = Int(k) { lastStartedByPort[port] = v }
            }
        }
        if let stored = UserDefaults.standard.dictionary(forKey: Self.contextSelectionKey)
            as? [String: Int] {
            contextSelection = stored
        }
        reloadManifest()
    }

    // MARK: - Context selection

    /// The context size that will actually be used the next time this model
    /// starts: the user's last pick if it is still a valid option, else the
    /// manifest default. Returns 0 for a model with no adjustable context.
    func selectedContextSize(for model: ModelSpec) -> Int {
        guard let ctx = model.context else { return 0 }
        if let picked = contextSelection[model.id], ctx.options.contains(picked) { return picked }
        return ctx.defaultSize
    }

    func setContextSize(_ size: Int, for model: ModelSpec) {
        guard let ctx = model.context, ctx.options.contains(size) else { return }
        contextSelection[model.id] = size
        UserDefaults.standard.set(contextSelection, forKey: Self.contextSelectionKey)

        // A launch-flag size is applied by `effectiveStart` at spawn time, so
        // remembering it is enough. A file-backed size has to be written now:
        // ModelBar never launches that backend, so there is no later moment at
        // which the choice would otherwise take effect.
        if ctx.isFileBacked {
            if let error = ContextFile.write(size: size, option: ctx) {
                note(error)
                return
            }
            note("\(model.displayName) context set to \(size.formatted()) — "
                 + "applies next time the backend loads this model")
            return
        }
        note("\(model.displayName) context set to \(size.formatted()) — applies on next load")
    }

    // MARK: - Manifest

    func reloadManifest() {
        do {
            let load = try ManifestLoader.load(path: manifestPath)
            manifest = load.manifest
            manifestWarnings = load.warnings
            manifestError = nil
        } catch {
            manifest = nil
            manifestWarnings = []
            manifestError = error.localizedDescription
        }
    }

    var backends: [BackendSpec] { manifest?.backends ?? [] }
    var models: [ModelSpec] { manifest?.models ?? [] }
    var settings: ManifestSettings { manifest?.settings ?? ManifestSettings() }

    func backend(for model: ModelSpec) -> BackendSpec? { manifest?.backend(id: model.backendId) }
    func status(_ backendId: String) -> BackendStatus? { statuses[backendId] }

    // MARK: - Polling

    func startPolling() {
        refreshTask?.cancel()
        // Task inherits the MainActor context from this type, so `self` is
        // reachable without hopping actors.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.currentInterval
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
        }
    }

    func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private var currentInterval: Double {
        if activity.isBusy { return 1.0 }
        return menuOpen ? 1.0 : max(1, settings.pollSeconds)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Cheap local counters first so the headline numbers are never stale
        // just because a backend is slow to answer.
        memory = SystemMemory.snapshot()
        swap = SystemMemory.swap()
        freeBytes = SystemMemory.freeBytes()
        gpu = GPUMemory.snapshot()
        updateSwapTrend()

        let matchers = backends.compactMap(\.matcher)
        if !matchers.isEmpty {
            procs = await monitor.sample(matchers: matchers)
        }

        await refreshBackends()
        lastRefresh = Date()
    }

    /// Compares the newest swap reading against the oldest within a 60 s
    /// window. The 256 MB dead-band keeps ordinary churn from reading as
    /// growth.
    private func updateSwapTrend() {
        let now = Date()
        swapHistory.append((now, swap.usedBytes))
        swapHistory.removeAll { now.timeIntervalSince($0.at) > 60 }

        guard let oldest = swapHistory.first, swapHistory.count >= 2 else {
            swapTrend = .steady
            return
        }
        let deadBand: Int64 = 256 * 1_048_576
        let delta = Int64(swap.usedBytes) - Int64(oldest.used)
        if delta > deadBand { swapTrend = .growing }
        else if delta < -deadBand { swapTrend = .shrinking }
        else { swapTrend = .steady }
    }

    private func refreshBackends() async {
        let specs = backends
        guard !specs.isEmpty else { return }

        // Probe every backend concurrently — a wedged one must not delay the rest.
        let results: [BackendStatus] = await withTaskGroup(of: BackendStatus.self) { group in
            for spec in specs {
                let kind = spec.telemetryKind
                let path = spec.telemetryPath
                group.addTask {
                    await Probe.status(for: spec, kind: kind, telemetryPath: path)
                }
            }
            var out: [BackendStatus] = []
            for await status in group { out.append(status) }
            return out
        }

        var map: [String: BackendStatus] = [:]
        for r in results { map[r.backendId] = r }
        statuses = map
        hasProbed = true

        loadedModelIds = await computeLoadedModels()
    }

    /// Decides which manifest models are currently loaded, in priority order:
    /// an explicit `loadedCheck`, then the backend's own authoritative
    /// residency list, then a served-name match, then the port bookkeeping
    /// from the last start we performed.
    ///
    /// The residency step exists because for a multi-model server that stays up
    /// across loads (LocalAI, Ollama) every weaker signal below it is wrong:
    /// the port answering proves only that the server is running, and its model
    /// *listing* enumerates what is configured, not what is in memory.
    private func computeLoadedModels() async -> Set<String> {
        var loaded = Set<String>()

        for model in models {
            guard let backend = manifest?.backend(id: model.backendId) else { continue }
            guard let status = statuses[backend.id], status.up else { continue }

            if let check = model.loadedCheck {
                if let url = backend.url(check.path), let text = await Probe.getText(url),
                   text.localizedCaseInsensitiveContains(check.contains) {
                    loaded.insert(model.id)
                }
                continue
            }

            // Authoritative residency. Matched strictly and case-insensitively
            // against the *whole* name the backend reports — never a substring
            // test. Substring matching is what let one loaded model light up
            // sibling entries: "qwen38-obliterated" contains "qwen38", and the
            // manifest ids ("localai-muse-glimmer") are deliberately not the
            // names LocalAI knows ("muse-glimmer"), so `servedName` is the only
            // correct field to compare.
            if let resident = status.residentModelIDs {
                if let want = model.servedName, !want.isEmpty,
                   resident.contains(where: { $0.caseInsensitiveCompare(want) == .orderedSame }) {
                    loaded.insert(model.id)
                }
                // Authoritative means authoritative: absent from the list is a
                // positive statement that this model is NOT loaded, so no
                // fallback to weaker signals below.
                continue
            }

            if let served = status.servedModel, let want = model.servedName,
               !want.isEmpty {
                if served.localizedCaseInsensitiveContains(want)
                    || want.localizedCaseInsensitiveContains(served) {
                    loaded.insert(model.id)
                }
                continue
            }

            if lastStartedByPort[model.port] == model.id {
                loaded.insert(model.id)
            }
        }
        return loaded
    }

    func isLoaded(_ model: ModelSpec) -> Bool { loadedModelIds.contains(model.id) }

    // MARK: - Memory accounting

    /// Estimated GB currently committed to models/pipelines, from the manifest's
    /// declared sizes.
    ///
    /// Declared sizes are used rather than measured RSS on purpose: these
    /// servers mmap their weights, so the pages live in the shared file cache
    /// and a process can hold an 84 GB model while reporting a single-digit
    /// RSS. Measured figures are shown in the monitor, but the *guard* has to
    /// use the nominal sizes or it would happily approve a load that cannot fit.
    func committedGB(excludingPort: Int? = nil) -> Double {
        var total = 0.0
        for model in models where loadedModelIds.contains(model.id) {
            if let skip = excludingPort, model.port == skip { continue }
            total += model.estimatedGB(atContextSize: selectedContextSize(for: model))
        }
        // Backends with their own footprint not attributable to a manifest
        // model — ComfyUI's diffusers pipeline being the case that matters.
        for backend in backends where backend.estimatedGB > 0 {
            if let skip = excludingPort, backend.port == skip { continue }
            guard statuses[backend.id]?.up == true else { continue }
            let attributed = models.contains {
                $0.backendId == backend.id && loadedModelIds.contains($0.id)
            }
            if !attributed { total += unattributedChargeGB(for: backend) }
        }
        return total
    }

    /// What to charge a backend that is up with nothing attributable loaded.
    ///
    /// For `.nominal` this is the declared size, which is correct for a server
    /// whose weights are mmapped and therefore invisible to RSS. For
    /// `.measured` it is the process's real footprint, because that backend
    /// allocates anonymously and stays up while idle — ComfyUI sits at ~1 GB
    /// with no pipeline resident, and charging its ~62 GB nominal size for
    /// merely being reachable was consuming half the budget for memory nothing
    /// had actually taken. Capped at the nominal figure so a mid-generation
    /// spike cannot read as more than the pipeline's known size.
    private func unattributedChargeGB(for backend: BackendSpec) -> Double {
        guard backend.memoryAccounting == .measured else { return backend.estimatedGB }
        guard let label = backend.matcher?.label else { return backend.estimatedGB }
        let bytes = procs.filter { $0.label == label }
                         .reduce(UInt64(0)) { $0 &+ $1.footprintBytes }
        // No sample yet (first refresh, or the process matcher found nothing)
        // is not evidence of zero — fall back to nominal rather than silently
        // freeing up budget that may well be in use.
        guard bytes > 0 else { return backend.estimatedGB }
        return min(backend.estimatedGB, Double(bytes) / 1_073_741_824)
    }

    var budgetGB: Double { settings.memoryBudgetGB }

    struct BudgetVerdict: Sendable {
        var wouldUseGB: Double
        var budgetGB: Double
        var fits: Bool
        var others: [String]
    }

    func budgetCheck(for model: ModelSpec) -> BudgetVerdict {
        let committed = committedGB(excludingPort: model.port)
        let modelGB = model.estimatedGB(atContextSize: selectedContextSize(for: model))
        let total = committed + modelGB
        var others: [String] = []
        for m in models where loadedModelIds.contains(m.id) && m.port != model.port {
            others.append("\(m.displayName) (~\(Fmt.gb(m.estimatedGB(atContextSize: selectedContextSize(for: m)))))")
        }
        for b in backends where b.estimatedGB > 0 && b.port != model.port {
            guard statuses[b.id]?.up == true else { continue }
            let attributed = models.contains {
                $0.backendId == b.id && loadedModelIds.contains($0.id)
            }
            if !attributed {
                let charge = unattributedChargeGB(for: b)
                // Only worth naming as a competitor for memory if it is
                // actually holding a meaningful amount.
                if charge >= 1 {
                    others.append(String(format: "%@ (~%.0f GB)", b.displayName, charge))
                }
            }
        }
        return BudgetVerdict(wouldUseGB: total, budgetGB: budgetGB,
                             fits: total <= budgetGB, others: others)
    }

    // MARK: - Actions

    func note(_ text: String?) {
        actionNote = text
        guard text != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            if actionNote == text { actionNote = nil }
        }
    }

    /// Stops whatever holds the model's port, then starts the model and waits
    /// for its backend to report healthy. Returns whether it ended up healthy
    /// — the proxy's cold path needs this to decide whether to connect
    /// through or answer the client with an error.
    @discardableResult
    func load(_ model: ModelSpec, trigger: StartTrigger = .manual) async -> Bool {
        guard !activity.isBusy else {
            note("Busy — already \(activity.modelId.map { "working on \($0)" } ?? "working")")
            return false
        }
        guard let backend = manifest?.backend(id: model.backendId) else {
            note("Unknown backend \(model.backendId)")
            return false
        }

        // The memory guard reads `loadedModelIds`, which only exists after a
        // refresh. Without this the guard silently passes on stale/empty state
        // — which is exactly what happens on the first action after launch, and
        // on every CLI invocation, since neither has polled yet.
        if lastRefresh == nil || Date().timeIntervalSince(lastRefresh ?? .distantPast) > 2 {
            await refresh()
        }

        let missing = model.missingRequirements
        guard missing.isEmpty else {
            lastFailure = LoadFailure(
                modelId: model.id,
                summary: "Not available yet — \(missing.count) required file(s) missing",
                logLines: missing.map { "missing: \($0)" },
                logPath: nil, at: Date())
            return false
        }

        // Memory guard, before anything is stopped.
        let verdict = budgetCheck(for: model)
        if !verdict.fits {
            guard confirmOverBudget(model: model, verdict: verdict, trigger: trigger) else {
                return false
            }
        }

        lastFailure = nil

        // Take over the port. Unmanaged backends (Ollama) stay up by design;
        // their "load" is a model-swap request, not a server restart.
        if backend.managed {
            activity = .stopping(modelId: model.id)
            let outcome = await ProcessControl.stop(port: model.port,
                                                    grace: settings.stopGraceSeconds,
                                                    allowKill: true)
            if case .failed(let pids) = outcome {
                activity = .idle
                lastFailure = LoadFailure(
                    modelId: model.id,
                    summary: "Could not free port \(model.port); pid(s) \(pids.map(String.init).joined(separator: ", ")) survived SIGKILL",
                    logLines: [], logPath: nil, at: Date())
                return false
            }
            if case .stopped = outcome {
                // Give the OS a moment to release the listening socket.
                try? await Task.sleep(for: .milliseconds(600))
            }
        }

        let contextSize = model.context != nil ? selectedContextSize(for: model) : nil
        guard let command = model.effectiveStart(contextSize: contextSize) else {
            // No start command: nothing to launch (a backend that is always up).
            activity = .idle
            lastStartedByPort[model.port] = model.id
            persistLastStarted()
            await refresh()
            note("\(model.displayName) selected")
            return true
        }

        activity = .starting(modelId: model.id, since: Date(), trigger: trigger)
        let (handle, spawnError) = await ProcessControl.spawnDetached(command)
        if let spawnError {
            activity = .idle
            lastFailure = LoadFailure(modelId: model.id, summary: spawnError,
                                      logLines: [], logPath: handle.logPath, at: Date())
            return false
        }

        lastStartedByPort[model.port] = model.id
        persistLastStarted()

        return await awaitHealthy(model: model, backend: backend, handle: handle)
    }

    /// Polls the backend until it answers, the launched process dies, or the
    /// timeout expires — then reports the log lines that explain a failure.
    @discardableResult
    private func awaitHealthy(model: ModelSpec, backend: BackendSpec, handle: SpawnHandle) async -> Bool {
        let deadline = Date().addingTimeInterval(settings.startTimeoutSeconds)

        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(1000))

            if let url = backend.url(backend.health.path), await Probe.get(url) != nil {
                activity = .idle
                await refresh()
                note("\(model.displayName) is up on :\(model.port)")
                return true
            }

            // A dead pid means it failed to load — no point waiting out the
            // full timeout when the process is already gone.
            if let pid = handle.pid, !ProcessControl.isAlive(pid: pid) {
                activity = .idle
                failFromLog(model: model, handle: handle,
                            summary: "Server exited during startup")
                await refresh()
                return false
            }
        }

        activity = .idle
        failFromLog(model: model, handle: handle,
                    summary: "Timed out after \(Int(settings.startTimeoutSeconds))s waiting for :\(model.port)")
        await refresh()
        return false
    }

    private func failFromLog(model: ModelSpec, handle: SpawnHandle, summary: String) {
        var lines: [String] = []
        if let path = handle.logPath {
            let text = ProcessControl.tail(path: path, from: handle.logOffset)
            lines = ProcessControl.likelyErrors(in: text)
        }
        lastFailure = LoadFailure(modelId: model.id, summary: summary,
                                  logLines: lines, logPath: handle.logPath, at: Date())
    }

    /// Stops the server on a model's port.
    func stop(_ model: ModelSpec) async {
        guard !activity.isBusy else { return }
        guard let backend = manifest?.backend(id: model.backendId) else { return }
        guard backend.managed else {
            note("\(backend.displayName) is service-managed — ModelBar will not stop it")
            return
        }

        activity = .stopping(modelId: model.id)
        // An explicit stop command wins when the manifest supplies one (an
        // Ollama keep_alive:0 unload, for instance, which is not a kill).
        if let stopCmd = model.stop {
            _ = await ProcessControl.run(stopCmd.resolvedArgv,
                                         cwd: stopCmd.resolvedCwd,
                                         env: stopCmd.env,
                                         timeout: 30)
        } else {
            _ = await ProcessControl.stop(port: model.port,
                                          grace: settings.stopGraceSeconds,
                                          allowKill: true)
        }
        if lastStartedByPort[model.port] == model.id {
            lastStartedByPort.removeValue(forKey: model.port)
            persistLastStarted()
        }
        activity = .idle
        await refresh()
        note("Stopped \(model.displayName)")
    }

    private func persistLastStarted() {
        var out: [String: String] = [:]
        for (port, id) in lastStartedByPort { out[String(port)] = id }
        UserDefaults.standard.set(out, forKey: Self.lastStartedKey)
    }

    // MARK: - On-demand proxies (ds4, MLX)

    /// Which manifest model should start when a cold request lands on a
    /// proxied backend's public port. For ds4 there is exactly one candidate;
    /// for MLX, whichever model was last manually loaded wins (so a deliberate
    /// choice sticks across idle-stop/restart cycles), falling back to the
    /// manifest's declared `defaultModelId`, falling back to the first entry.
    func autoModelId(forBackend backendId: String) -> String? {
        guard let manifest, let backend = manifest.backend(id: backendId) else { return nil }
        let candidates = manifest.models(backendId: backendId)
        guard !candidates.isEmpty else { return nil }
        if let lastId = lastStartedByPort[backend.port],
           candidates.contains(where: { $0.id == lastId }) {
            return lastId
        }
        if let def = backend.defaultModelId, candidates.contains(where: { $0.id == def }) {
            return def
        }
        return candidates.first?.id
    }

    func idleTimeoutSeconds(forModelId modelId: String) -> Double {
        guard let manifest, let model = manifest.model(id: modelId) else {
            return ManifestSettings().defaultSleepIdleSeconds
        }
        return manifest.effectiveSleepIdleSeconds(model)
    }

    /// Binds a `ProxyServer` for every backend that declares a `publicPort`.
    /// Idempotent — safe to call again after a manifest reload; existing
    /// proxies for unchanged backends are left running rather than bounced,
    /// since bouncing the listener would drop any in-flight connection.
    func startProxies() {
        guard let manifest else { return }
        for backend in manifest.backends {
            guard let publicPort = backend.publicPort else { continue }
            guard proxies[backend.id] == nil else { continue }

            let config = ProxyServer.Config(publicPort: publicPort,
                                            internalHost: backend.host,
                                            internalPort: backend.port)
            let id = backend.id
            let proxy = ProxyServer(
                backendId: id,
                config: config,
                resolveModelId: { [weak self] in
                    await self?.autoModelId(forBackend: id)
                },
                ensureRunning: { [weak self] modelId, _ in
                    guard let self else { return false }
                    guard let model = await self.manifest?.model(id: modelId) else { return false }
                    return await self.load(model, trigger: .incomingRequest)
                },
                idleTimeoutFor: { [weak self] modelId in
                    await self?.idleTimeoutSeconds(forModelId: modelId) ?? 300
                },
                stopIdle: { [weak self] modelId in
                    guard let self, let model = await self.manifest?.model(id: modelId) else { return }
                    await self.stop(model)
                },
                onPhaseChange: { [weak self] backendId, phase in
                    Task { @MainActor in self?.proxyPhases[backendId] = phase }
                })

            proxies[backend.id] = proxy
            Task {
                do {
                    try await proxy.start()
                } catch {
                    self.note("Proxy for \(backend.displayName) failed to bind :\(publicPort): "
                             + error.localizedDescription)
                }
            }
        }
    }

    /// Stops every proxy and, transitively, whatever backend it was holding
    /// resident — called on app quit so a backend the proxy started is never
    /// left running with nothing left to idle-reap it.
    func shutdownProxies() async {
        for proxy in proxies.values {
            await proxy.shutdown()
        }
    }

    // MARK: - Harness

    func refreshHarness() async {
        guard let config = manifest?.harness else { return }
        harness = await HarnessControl.read(config: config)
    }

    // MARK: - Discovery

    /// Rescans for unconfigured models. Rate-limited to once a minute even if
    /// called more often (e.g. every menu open) — directory walks and GGUF
    /// header reads are cheap individually but add up, and nothing about
    /// "what's on disk" changes fast enough to need it live.
    func refreshDiscovery(force: Bool = false) async {
        if !force, let last = lastDiscoveryScan, Date().timeIntervalSince(last) < 60 { return }
        lastDiscoveryScan = Date()
        let comfyBackend = manifest?.backends.first { $0.id == "comfyui" && $0.telemetryKind == .comfyui }
        discovered = await ModelDiscovery.scan(manifest: manifest, comfyBackend: comfyBackend)
    }

    /// The four harnesses ModelBar can point. Hermes and Pi always have some
    /// active provider/model — there is no "off" for them here, only "which
    /// one." Codex and Claude Code are explicit two-state toggles: `nil`
    /// model means "API" (native ChatGPT auth / real Anthropic, respectively).
    enum HarnessKind: String, Sendable, CaseIterable {
        case hermes, pi, codex, claudeCode

        var displayName: String {
            switch self {
            case .hermes: return "Hermes"
            case .pi: return "Pi"
            case .codex: return "Codex"
            case .claudeCode: return "Claude Code"
            }
        }
        var hasAPIOption: Bool { self == .codex || self == .claudeCode }

        /// The wire format this harness speaks. A backend that does not serve
        /// it cannot host a model for this harness at all — no amount of
        /// config writing fixes a protocol mismatch, it just relocates the
        /// failure to the first request.
        var requiredAPI: BackendAPI {
            switch self {
            case .hermes, .pi: return .chat
            case .codex: return .responses
            case .claudeCode: return .messages
            }
        }
    }

    /// One entry in a harness picker: a manifest model, plus whether this
    /// harness can actually use it and — when it cannot — why.
    ///
    /// Ineligible models are carried through rather than filtered out so the
    /// menu can show them greyed with a reason. Silently omitting them made
    /// the picker look broken: with only ds4 carrying hand-written harness
    /// fields, every harness offered exactly one model and there was nothing
    /// on screen to explain the absence of the other seven.
    struct HarnessOption: Identifiable, Sendable {
        var model: ModelSpec
        var eligible: Bool
        /// Present only when `eligible` is false.
        var reason: String?
        var id: String { model.id }
    }

    /// Every manifest model, judged against one harness.
    ///
    /// Eligibility is a property of the *backend's wire format*, not of whether
    /// someone remembered to write harness fields into the manifest entry —
    /// that inversion is the whole feature. A model on a backend that serves
    /// the right API can be registered into the harness on the spot; one on a
    /// backend that does not is shown disabled with the protocol named.
    func harnessOptions(for kind: HarnessKind) -> [HarnessOption] {
        models.map { model in
            guard let backend = manifest?.backend(id: model.backendId) else {
                return HarnessOption(model: model, eligible: false,
                                     reason: "unknown backend \(model.backendId)")
            }
            guard backend.apis.contains(kind.requiredAPI) else {
                return HarnessOption(
                    model: model, eligible: false,
                    reason: "\(backend.displayName) does not serve \(kind.requiredAPI.path)")
            }
            guard model.apiModelName(for: kind) != nil else {
                return HarnessOption(model: model, eligible: false,
                                     reason: "no served model name in the manifest")
            }
            let missing = model.missingRequirements
            guard missing.isEmpty else {
                return HarnessOption(model: model, eligible: false,
                                     reason: "\(missing.count) required file(s) not on disk")
            }
            return HarnessOption(model: model, eligible: true, reason: nil)
        }
    }

    /// Backwards-compatible convenience: just the usable ones.
    func eligibleModels(for kind: HarnessKind) -> [ModelSpec] {
        harnessOptions(for: kind).filter(\.eligible).map(\.model)
    }

    /// Assembles the provider definition to write into a harness config.
    /// Everything is derived from the backend + model pair, with the manifest's
    /// existing per-harness fields taken as overrides where present so the
    /// hand-tuned ds4 entry keeps working exactly as it did.
    func registration(for model: ModelSpec, kind: HarnessKind) -> HarnessRegistration? {
        guard let backend = manifest?.backend(id: model.backendId),
              let modelName = model.apiModelName(for: kind) else { return nil }
        let providerId = model.providerId(for: kind) ?? backend.id
        return HarnessRegistration(
            providerId: providerId,
            providerLabel: "\(backend.displayName) (local)",
            openAIBaseURL: backend.clientBaseURL,
            anthropicBaseURL: backend.anthropicBaseURL,
            modelName: modelName,
            contextLength: model.effectiveContextLength(
                selected: selectedContextSize(for: model)))
    }

    /// Registers a model into one harness if it is not already defined there,
    /// then points that harness at it — or, for Codex/Claude Code, clears back
    /// to "API" when `model` is nil.
    ///
    /// Registration first, pointer second, and the pointer is only moved if
    /// registration succeeded: pointing a harness at a provider it has no
    /// definition for is exactly the broken state this is meant to prevent.
    ///
    /// This remains the single write path into every harness config, and the
    /// manifest is still the only source for what gets written — what changed
    /// is that a manifest model no longer has to be pre-declared inside each
    /// harness's own config file to be selectable. Removing a model used to
    /// mean hand-editing six files; adding one meant the same.
    func pointHarness(_ kind: HarnessKind, at model: ModelSpec?) async {
        guard let config = manifest?.harness else { return }

        // Clearing back to "API" needs no registration.
        if model == nil {
            let error: String?
            switch kind {
            case .codex: error = HarnessControl.clearCodexProfile(config: config)
            case .claudeCode: error = HarnessControl.clearClaudeLocal(config: config)
            case .hermes, .pi: return  // no "off" state; picker never offers it
            }
            await refreshHarness()
            note(error ?? "\(kind.displayName) → API")
            return
        }

        guard let m = model else { return }

        // Refuse rather than write a config that cannot work. The picker
        // already greys these out; this is the guard for the CLI path and for
        // anything that gets past the UI.
        guard let option = harnessOptions(for: kind).first(where: { $0.id == m.id }),
              option.eligible else {
            let why = harnessOptions(for: kind).first { $0.id == m.id }?.reason
                ?? "not eligible"
            note("\(m.displayName) can't drive \(kind.displayName): \(why)")
            return
        }
        guard let reg = registration(for: m, kind: kind) else {
            note("No \(kind.displayName) mapping for \(m.displayName)")
            return
        }

        var error: String?
        switch kind {
        case .hermes:
            error = HarnessRegistrar.registerHermes(config: config, registration: reg)
            if error == nil {
                error = await HarnessControl.setHermes(config: config,
                                                       provider: reg.providerId,
                                                       model: reg.modelName)
            }
        case .pi:
            error = HarnessRegistrar.registerPi(config: config, registration: reg)
            if error == nil {
                error = HarnessControl.setPi(config: config,
                                             provider: reg.providerId,
                                             model: reg.modelName)
            }
        case .codex:
            let profile = m.codexProfileName
            error = HarnessRegistrar.registerCodex(config: config, profile: profile,
                                                   registration: reg)
            if error == nil {
                error = HarnessControl.setCodexProfile(config: config, profile: profile)
            }
        case .claudeCode:
            // No provider definition exists to write: `claude-local` takes the
            // endpoint as call-scoped environment, which is the entire reason
            // this harness is safe to point at a local model at all. Bare
            // `claude` is never touched — see HarnessControl.setClaudeLocal.
            error = HarnessControl.setClaudeLocal(config: config,
                                                  model: reg.modelName,
                                                  baseURL: reg.anthropicBaseURL)
        }

        await refreshHarness()
        note(error ?? "\(kind.displayName) → \(m.displayName)")
    }

    // MARK: - Alerts

    /// How to handle an over-budget load. The UI asks; the CLI cannot show a
    /// modal, so it either refuses or is explicitly forced with --force.
    enum OverBudgetPolicy: Sendable { case ask, allow, deny }
    var overBudgetPolicy: OverBudgetPolicy = .ask

    /// Blocking confirmation before overcommitting memory. A menubar dropdown
    /// closes on click, so an alert is the only reliable way to make the user
    /// acknowledge this before ~90 GB starts moving.
    ///
    /// That reasoning does not hold for `.incomingRequest`: nobody is watching
    /// the screen when a proxy connection triggers a cold start, so a blocking
    /// `NSAlert` would just hang the client's request forever waiting on a
    /// dialog no one can answer. The auto path therefore always proceeds,
    /// never asks, and leaves a note in the menu so the overcommit is at least
    /// visible after the fact — refusing outright would be worse: it would
    /// silently fail a request the user actually made, for a policy reason
    /// they never saw.
    private func confirmOverBudget(model: ModelSpec, verdict: BudgetVerdict,
                                   trigger: StartTrigger) -> Bool {
        if trigger == .incomingRequest {
            note(String(format: "%@ loaded over budget (~%.0f/%.0f GB) to serve a request",
                        model.displayName, verdict.wouldUseGB, verdict.budgetGB))
            return true
        }
        switch overBudgetPolicy {
        case .allow:
            FileHandle.standardError.write(Data(
                String(format: "warning: over budget (~%.0f GB of %.0f GB) — forced\n",
                       verdict.wouldUseGB, verdict.budgetGB).utf8))
            return true
        case .deny:
            lastFailure = LoadFailure(
                modelId: model.id,
                summary: String(format: "refused: would use ~%.0f GB against a %.0f GB budget",
                                verdict.wouldUseGB, verdict.budgetGB),
                logLines: verdict.others.map { "resident: \($0)" },
                logPath: nil, at: Date())
            return false
        case .ask:
            break
        }
        NSApp.activate(ignoringOtherApps: true)
        let modelGB = model.estimatedGB(atContextSize: selectedContextSize(for: model))
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Loading \(model.displayName) would exceed the memory budget"
        var body = String(format: "This model needs about %.0f GB. Already committed: %.0f GB. "
                          + "Total would be about %.0f GB against a %.0f GB budget.",
                          modelGB,
                          verdict.wouldUseGB - modelGB,
                          verdict.wouldUseGB, verdict.budgetGB)
        if !verdict.others.isEmpty {
            body += "\n\nAlready resident:\n• " + verdict.others.joined(separator: "\n• ")
        }
        body += "\n\nContinuing will most likely thrash into swap and collapse throughput."
        alert.informativeText = body
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Load anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Convenience

    func openPath(_ path: String) {
        let expanded = path.expandingTilde
        guard FileManager.default.fileExists(atPath: expanded) else {
            note("Not found: \(expanded)")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
    }

    func revealInFinder(_ path: String) {
        let expanded = path.expandingTilde
        guard FileManager.default.fileExists(atPath: expanded) else {
            note("Not found: \(expanded)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
    }

    // MARK: - Menubar summary

    /// The persistent menubar strip is shared real estate with every other
    /// running app's status item, so this stays as close to empty as
    /// possible: icon carries state, text appears only for the one number
    /// worth seeing without opening the menu (live tok/s while generating),
    /// and even that is abbreviated rather than spelled out. Everything else
    /// — model names, RAM%, uptime — lives in the dropdown, not up here.
    var menubarTitle: String {
        if activity.isBusy { return "" }
        for status in statuses.values where status.up {
            if status.telemetry.busy == true, let tps = status.telemetry.decodeTPS, tps > 0 {
                return String(format: "%.0ft/s", tps)
            }
        }
        return ""
    }

    /// The loaded model to feature — the largest one, which is the one that
    /// matters for memory.
    var primaryLoadedModel: ModelSpec? {
        models.filter { loadedModelIds.contains($0.id) }
              .max { $0.estimatedGB < $1.estimatedGB }
    }

    var iconName: String {
        if activity.isBusy { return "hourglass" }
        if manifestError != nil { return "exclamationmark.triangle" }
        for status in statuses.values where status.up && status.telemetry.busy == true {
            return "bolt.fill"   // actively generating — the one state worth a distinct icon
        }
        return loadedModelIds.isEmpty ? "cpu" : "cpu.fill"
    }
}

// MARK: - Harness mapping
//
// How a manifest model presents itself to each harness. Kept as derivations
// with manifest overrides rather than as four hand-written fields per model:
// the point of registration is that adding a model to the manifest is enough,
// and requiring a full set of per-harness names before it could be selected
// would put the six-files-to-edit problem straight back.

extension ModelSpec {

    /// The string a client sends as `model`. Per-harness override first, then
    /// the shared `apiName`, then the name the backend reports.
    ///
    /// `servedName` is the last resort rather than the first because the two
    /// are not the same concept: it exists to *recognise* a loaded model in a
    /// health response, and for at least one backend it is a display string
    /// with spaces that no client could send.
    func apiModelName(for kind: AppState.HarnessKind) -> String? {
        let perHarness: String?
        switch kind {
        case .hermes: perHarness = harness?.hermesModel
        case .pi: perHarness = harness?.piModel
        case .codex: perHarness = harness?.codexModel
        case .claudeCode: perHarness = harness?.claudeLocalModel
        }
        let name = perHarness ?? harness?.apiName ?? servedName
        return (name?.isEmpty == false) ? name : nil
    }

    /// Provider key override for a harness, if the manifest names one. `nil`
    /// means "use the backend id", which is what every current entry resolves
    /// to anyway.
    func providerId(for kind: AppState.HarnessKind) -> String? {
        switch kind {
        case .hermes: return harness?.hermesProvider
        case .pi: return harness?.piProvider
        case .codex: return harness?.codexProvider
        case .claudeCode: return nil   // no provider concept; env-scoped
        }
    }

    /// Codex profile file name (`~/.codex/<name>.config.toml`). Derived from
    /// the model id when the manifest does not name one, so a new model is
    /// selectable in Codex without a manifest edit.
    var codexProfileName: String {
        if let p = harness?.codexProfile, !p.isEmpty { return p }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let slug = id.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { acc, ch in
                // Collapse runs of separators; a profile name is a filename.
                if ch == "-" && acc.hasSuffix("-") { return }
                acc.append(ch)
            }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }

    /// Context window to advertise to a harness: the live selection when this
    /// model has an adjustable one, else the manifest's fixed figure, else a
    /// conservative default that no local model here is smaller than.
    func effectiveContextLength(selected: Int) -> Int {
        if context != nil, selected > 0 { return selected }
        if let fixed = contextLength, fixed > 0 { return fixed }
        return 32768
    }
}
