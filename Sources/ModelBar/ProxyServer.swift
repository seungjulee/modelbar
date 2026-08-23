import Foundation
import Network

/// Why ds4 and MLX need this and Ollama/Llama.app do not:
///
/// Ollama is a launchd service with its own model-swap-on-request behaviour,
/// and Llama.app already owns lifecycle for generic llama.cpp/GGUF backends
/// (its own `sleep-idle-seconds` unloads idle models). `ds4-server` and
/// `mlx_lm.server` have no such behaviour of their own — once started they sit
/// resident until something kills them. For the user's actual want ("only run
/// ds4 when I make a request") ModelBar has to be the thing that is always
/// listening on the port clients expect, so it can notice the first request
/// and take responsibility for the process behind it.
///
/// Design: a plain TCP-level splice, not an HTTP proxy. `ProxyServer` binds
/// the *public* port (the one Pi/Hermes/curl already point at) and, for each
/// accepted connection, either connects straight through to the already-running
/// backend on its *internal* port, or — if that connect fails — starts the
/// backend, waits for `/health`, and then connects. Once connected it copies
/// bytes in both directions until either side closes. Working at the byte
/// level rather than parsing HTTP means streaming (SSE) responses, chunked
/// encoding, and keep-alive all just work, because none of it is interpreted.
///
/// A cold client's request bytes are not lost while ModelBar waits on the
/// backend: they sit in the kernel's receive buffer for the client's already-
/// accepted connection, un-read, until the upstream link exists and the first
/// forwarding read drains them. From the client's point of view this looks
/// exactly like a slow first response — which is the intended illusion, and
/// exactly what was asked for ("hold the connection through the ~30s load").
actor ProxyServer {
    struct Config: Sendable {
        var publicPort: Int
        var internalHost: String
        var internalPort: Int
        var connectProbeTimeout: Double = 0.6   // fast path: is it already up?
        var connectStartTimeout: Double = 240   // cold path: allow a full cold load
        var idleReapInterval: Double = 5
    }

    /// What the proxy is doing right now. Internal lifecycle state, not a UI
    /// feed: the menu derives everything it shows from `AppState.activity` /
    /// `isLoaded` / `statuses`, which is what drives the spawn and stop logic
    /// too, so it cannot drift from reality the way a separately-mirrored copy
    /// of this could.
    enum Phase: Sendable, Equatable {
        case idle                              // listening, backend not running
        case startingForRequest(modelId: String, since: Date)
        case running(modelId: String)
        case stoppingIdle(modelId: String)
    }

    private let backendId: String
    private var config: Config
    private var listener: NWListener?
    private let queue: DispatchQueue

    /// Live proxied connections. A backend is never reaped while this is
    /// non-empty, regardless of how idle `lastActivity` looks — this is the
    /// same "still has clients" grace case ds4-watchdog.sh handles via lsof,
    /// done exactly rather than approximately since ModelBar already owns
    /// every connection that reaches the backend.
    private var activeConnections = 0
    private var lastActivity = Date()
    private var ensureTask: Task<Bool, Never>?
    private var reaperTask: Task<Void, Never>?
    private(set) var phase: Phase = .idle

    /// Supplied by AppState: spawn/await-health for a given model (reusing the
    /// exact same code path a manual menu click uses), and stop-by-port for the
    /// idle reaper. Injected as closures rather than holding an AppState
    /// reference directly, so this actor stays independently testable and the
    /// MainActor hop is explicit at the call site.
    private let resolveModelId: @Sendable () async -> String?
    private let ensureRunning: @Sendable (_ modelId: String, _ auto: Bool) async -> Bool
    private let idleTimeoutFor: @Sendable (_ modelId: String) async -> Double
    private let stopIdle: @Sendable (_ modelId: String) async -> Void

    init(backendId: String,
         config: Config,
         resolveModelId: @escaping @Sendable () async -> String?,
         ensureRunning: @escaping @Sendable (String, Bool) async -> Bool,
         idleTimeoutFor: @escaping @Sendable (String) async -> Double,
         stopIdle: @escaping @Sendable (String) async -> Void) {
        self.backendId = backendId
        self.config = config
        self.queue = DispatchQueue(label: "modelbar.proxy.\(backendId)")
        self.resolveModelId = resolveModelId
        self.ensureRunning = ensureRunning
        self.idleTimeoutFor = idleTimeoutFor
        self.stopIdle = stopIdle
    }

    // MARK: - Lifecycle

    func start() throws {
        guard listener == nil else { return }

        let params = NWParameters.tcp
        // Loopback only — these backends have no auth, matching the posture
        // they already had before the proxy existed (bound to 127.0.0.1).
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(config.publicPort))!)
        params.allowLocalEndpointReuse = true

        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { await self.accept(conn) }
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { await self?.logListenerFailure(error) }
            }
        }
        l.start(queue: queue)
        listener = l

        reaperTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(await self.config.idleReapInterval))
                await self.reapIfIdle()
            }
        }
    }

    /// Stops accepting new connections and, if a backend is currently running
    /// under this proxy, stops it too — called when ModelBar itself is
    /// quitting, so a proxied backend is never orphaned with nothing left to
    /// idle-reap it.
    func shutdown() async {
        reaperTask?.cancel()
        reaperTask = nil
        listener?.cancel()
        listener = nil

        // A backend caught mid-start is the case that actually orphans one.
        // The spawn is detached and already in flight, so dropping the listener
        // does not stop it, and the reaper that would eventually have collected
        // it has just been cancelled — quitting here left ~84 GB resident with
        // nothing owning its lifecycle. Let the start settle first, then stop
        // whatever it produced.
        if let ensureTask { _ = await ensureTask.value }

        switch phase {
        case .running(let modelId), .startingForRequest(let modelId, _):
            await stopIdle(modelId)
        case .stoppingIdle, .idle:
            break
        }
        setPhase(.idle)
    }

    private func logListenerFailure(_ error: NWError) {
        FileHandle.standardError.write(Data(
            "ModelBar proxy[\(backendId)]: listener failed: \(error)\n".utf8))
    }

    private func setPhase(_ p: Phase) {
        phase = p
    }

    // MARK: - Per-connection handling

    private func accept(_ client: NWConnection) async {
        activeConnections += 1
        lastActivity = Date()
        client.start(queue: queue)

        defer {
            activeConnections -= 1
            lastActivity = Date()
        }

        // Fast path: backend already up. A short probe connect avoids paying
        // any "ensure running" overhead on the common case of steady-state
        // traffic to an already-warm backend.
        if let upstream = try? await connect(timeout: config.connectProbeTimeout) {
            if case .idle = phase, let id = await resolveModelId() { setPhase(.running(modelId: id)) }
            await splice(client: client, upstream: upstream)
            return
        }

        // Cold path: coalesce concurrent first-requests into one spawn.
        guard let modelId = await resolveModelId() else {
            await respondUnavailable(client, reason: "no default model configured for this backend")
            return
        }

        let started = await coalescedEnsureRunning(modelId: modelId)
        guard started else {
            await respondUnavailable(client, reason: "backend failed to start — see ModelBar menu")
            return
        }

        guard let upstream = try? await connect(timeout: config.connectStartTimeout) else {
            await respondUnavailable(client, reason: "backend started but is not accepting connections")
            return
        }
        await splice(client: client, upstream: upstream)
    }

    private func coalescedEnsureRunning(modelId: String) async -> Bool {
        if let existing = ensureTask {
            return await existing.value
        }
        setPhase(.startingForRequest(modelId: modelId, since: Date()))
        let task = Task { [ensureRunning] in
            await ensureRunning(modelId, true)
        }
        ensureTask = task
        let result = await task.value
        ensureTask = nil
        setPhase(result ? .running(modelId: modelId) : .idle)
        return result
    }

    /// Connects to the real backend on its internal, never-client-facing port.
    private func connect(timeout: Double) async throws -> NWConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.internalHost),
            port: NWEndpoint.Port(rawValue: UInt16(config.internalPort))!)
        let conn = NWConnection(to: endpoint, using: .tcp)

        return try await withCheckedThrowingContinuation { cont in
            let box = ResumeOnce()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if box.claim() { cont.resume(returning: conn) }
                case .failed(let error):
                    if box.claim() { cont.resume(throwing: error) }
                case .cancelled:
                    if box.claim() {
                        cont.resume(throwing: NWError.posix(.ECANCELED))
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if box.claim() {
                    conn.cancel()
                    cont.resume(throwing: NWError.posix(.ETIMEDOUT))
                }
            }
        }
    }

    /// Bidirectional byte copy. Each direction is an independent pump; when
    /// either side finishes (EOF or error), both connections are torn down —
    /// there is no meaningful half-open state to preserve for this use case.
    private func splice(client: NWConnection, upstream: NWConnection) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pump(from: client, to: upstream) }
            group.addTask { await self.pump(from: upstream, to: client) }
            await group.next()
            group.cancelAll()
        }
        client.cancel()
        upstream.cancel()
    }

    private func pump(from: NWConnection, to: NWConnection) async {
        while true {
            let chunk: (Data?, Bool, NWError?) = await withCheckedContinuation { cont in
                from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    cont.resume(returning: (data, complete, error))
                }
            }
            let (data, isComplete, error) = chunk

            if let data, !data.isEmpty {
                lastActivity = Date()
                let ok: Bool = await withCheckedContinuation { cont in
                    to.send(content: data, completion: .contentProcessed { sendError in
                        cont.resume(returning: sendError == nil)
                    })
                }
                if !ok { return }
            }
            if isComplete || error != nil { return }
        }
    }

    private func respondUnavailable(_ client: NWConnection, reason: String) async {
        // A synthesized minimal HTTP response rather than a bare connection
        // reset: every client here (Pi, Hermes, curl, an OpenAI SDK) already
        // expects to parse an HTTP response and most surface the body of a
        // non-2xx reply in their own error message, so this turns "connection
        // reset, no idea why" into an actual readable reason.
        // Escaped, because `reason` is interpolated into a JSON string body and
        // a backend display name is free text from the manifest — an embedded
        // quote would produce a malformed body that the client reports as a
        // parse error instead of the diagnosis this exists to deliver.
        let body = "{\"error\":{\"message\":\"ModelBar: \(jsonEscape(reason))\","
            + "\"type\":\"modelbar_proxy_error\"}}"
        let response = "HTTP/1.1 503 Service Unavailable\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n\(body)"
        // No `client.start` here: `accept` already started this connection, and
        // starting an NWConnection twice is an API misuse.
        await withCheckedContinuation { cont in
            client.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                cont.resume()
            })
        }
        client.cancel()
    }

    private func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Idle reaping

    private func reapIfIdle() async {
        guard case .running(let modelId) = phase else { return }
        guard activeConnections == 0 else { return }
        let idleFor = Date().timeIntervalSince(lastActivity)
        let threshold = await idleTimeoutFor(modelId)
        guard idleFor >= threshold else { return }

        setPhase(.stoppingIdle(modelId: modelId))
        await stopIdle(modelId)
        setPhase(.idle)
    }
}

/// Guards a checked continuation against being resumed twice (once by the
/// state-update handler, once by the timeout), the same hazard `ProcessControl`
/// already guards against for its own timeouts.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
