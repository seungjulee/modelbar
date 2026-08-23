import SwiftUI

// MARK: - Design tokens

/// One threshold convention applied everywhere, so a colour always means the
/// same thing: green fine, amber getting tight, red about to hurt.
enum Level {
    static func color(_ fraction: Double) -> Color {
        if !fraction.isFinite { return .secondary }
        if fraction >= 0.90 { return .red }
        if fraction >= 0.70 { return .orange }
        return .green
    }
}

/// A real progress bar. Character-art bars looked like debug output and were
/// nearly invisible at menu size, so these are drawn shapes.
struct Meter: View {
    var fraction: Double
    var tint: Color
    var width: CGFloat = 84
    var height: CGFloat = 6

    private var clamped: Double {
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.13))
            Capsule().fill(tint).frame(width: max(clamped > 0 ? 3 : 0, width * clamped))
        }
        .frame(width: width, height: height)
    }
}

struct StatusDot: View {
    enum Kind { case up, down, busy, warn, unknown, unmanaged }
    var kind: Kind
    var size: CGFloat = 7

    private var color: Color {
        switch kind {
        case .up: return .green
        case .busy: return .yellow
        case .warn: return .red
        case .unmanaged: return .blue
        case .down: return .secondary.opacity(0.35)
        case .unknown: return .secondary.opacity(0.2)
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct SectionHeader: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if let trailing {
                Text(trailing).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

/// `label ▓▓▓░░ 42%  detail` — the one row shape used for every metric.
struct MeterRow: View {
    var label: String
    var fraction: Double
    var value: String
    var detail: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 38, alignment: .leading)
            Meter(fraction: fraction, tint: tint ?? Level.color(fraction))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Hero: what is actually running

/// The hero section. Two jobs, in priority order:
///
/// 1. If anything is actively generating right now, that is the single most
///    useful fact in the whole menu — a big, loud tok/s readout, not a line
///    buried under status rows. This is the thing LlamaBar does well that the
///    user explicitly asked to keep.
/// 2. Otherwise, show each on-demand backend's state (ds4, MLX): idle and
///    which model would auto-start, mid-transition (with *why* — a click or
///    an incoming request), or running and idle-timer-armed. This is derived
///    entirely from `state.activity` / `isLoaded` / `statuses` rather than a
///    separate mirrored phase, so it can never drift out of sync with the
///    state that actually drives the spawn/stop logic.
struct NowRunningView: View {
    var state: AppState

    private struct Highlight { var label: String; var tps: Double; var prefill: Double? }

    private var busyHighlight: Highlight? {
        for backend in state.backends {
            guard let status = state.status(backend.id), status.up else { continue }
            guard status.telemetry.busy == true, let tps = status.telemetry.decodeTPS, tps > 0
            else { continue }
            let label = state.models.first { $0.backendId == backend.id && state.isLoaded($0) }?
                .displayName ?? status.servedModel ?? backend.displayName
            return Highlight(label: label, tps: tps, prefill: status.telemetry.prefillTPS)
        }
        return nil
    }

    private var onDemandBackends: [BackendSpec] { state.backends.filter(\.isProxied) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hl = busyHighlight {
                liveHeadline(hl)
            }

            if onDemandBackends.isEmpty {
                if busyHighlight == nil { staticFallback }
            } else {
                ForEach(onDemandBackends) { backend in
                    onDemandRow(backend)
                }
            }
        }
    }

    // MARK: - The live tok/s headline

    private func liveHeadline(_ hl: Highlight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
                .shadow(color: .green.opacity(0.7), radius: 3)
            Text(String(format: "%.1f", hl.tps))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.green)
            Text("tok/s")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green.opacity(0.85))
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text(hl.label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                if let p = hl.prefill, p > 0 {
                    Text(String(format: "%.0f prefill", p))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Per-backend on-demand row

    @ViewBuilder
    private func onDemandRow(_ backend: BackendSpec) -> some View {
        let modelId = state.autoModelId(forBackend: backend.id)
        let model = modelId.flatMap { state.manifest?.model(id: $0) }

        if state.activity.isBusy, let am = state.activity.modelId,
           model?.id == am || state.manifest?.model(id: am)?.backendId == backend.id {
            transitionRow(backend: backend)
        } else if let model, state.isLoaded(model) {
            runningRow(backend: backend, model: model)
        } else {
            idleRow(backend: backend, model: model)
        }
    }

    private func transitionRow(backend: BackendSpec) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(transitionLabel(backend: backend))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                if case .starting(_, let since, _) = state.activity {
                    Text("\(Int(Date().timeIntervalSince(since)))s elapsed — large models take ~30s")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func transitionLabel(backend: BackendSpec) -> String {
        let name = state.activity.modelId.flatMap { state.manifest?.model(id: $0)?.displayName }
            ?? backend.displayName
        switch state.activity {
        case .starting(_, _, .incomingRequest):
            return "Starting \(name) for an incoming request…"
        case .starting(_, _, .manual):
            return "Loading \(name)…"
        case .stopping:
            return "Stopping \(name)…"
        case .idle:
            return name
        }
    }

    private func runningRow(backend: BackendSpec, model: ModelSpec) -> some View {
        let status = state.status(backend.id)
        return HStack(spacing: 7) {
            StatusDot(kind: .up, size: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 5) {
                    Text(backend.displayName)
                    if let up = status?.uptime { Text("· up \(Fmt.uptime(up))") }
                    Text("· auto-stops after \(idleLabel(model))")
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let t = status?.telemetry, let frac = t.contextFraction {
                Text(String(format: "ctx %.0f%%", frac * 100))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func idleRow(backend: BackendSpec, model: ModelSpec?) -> some View {
        HStack(spacing: 7) {
            StatusDot(kind: .down, size: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(backend.displayName) idle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if let model {
                    Text("starts \(model.displayName) automatically on request")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text("no model configured for this backend")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func idleLabel(_ model: ModelSpec) -> String {
        Fmt.uptime(state.idleTimeoutSeconds(forModelId: model.id))
    }

    private var staticFallback: some View {
        HStack(spacing: 7) {
            StatusDot(kind: .down, size: 9)
            Text("No model loaded")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Memory

struct MemoryView: View {
    var memory: MemorySnapshot
    var swap: SwapSnapshot
    var swapTrend: AppState.SwapTrend
    var freeBytes: UInt64
    var gpu: GPUSnapshot
    var aiFootprint: UInt64
    /// Who the used memory belongs to. A bare percentage cannot distinguish a
    /// deliberately-loaded 84 GB model from a runaway process, and that is the
    /// question a high number actually prompts.
    var attribution: AppState.MemoryAttribution

    /// Swap is only alarming when it is actively growing. macOS does not page
    /// swap back in when pressure drops, so a non-zero resting figure is
    /// usually just history.
    private var swapTint: Color {
        swapTrend == .growing && swap.isNonZero ? .red : .secondary
    }

    /// "of 127 GB in use: ≈84 GB DeepSeek-V4-Flash · ≈43 GB other", naming the
    /// model when one dominates and counting them when several are up.
    ///
    /// The denominator is stated inline because it is deliberately *not* the
    /// figure in the bar above (see `MemoryAttribution`): the bar reports
    /// Activity Monitor's "used", which excludes the file cache where mmapped
    /// weights sit, so an unlabelled split against a different total would look
    /// like an arithmetic error. The `≈` is not decoration either — these are
    /// declared sizes, and implying measured precision would be a claim the
    /// numbers cannot support.
    private var attributionText: String {
        let mine: String
        if attribution.modelCount == 1, let name = attribution.primaryLabel {
            mine = String(format: "≈%.0f GB %@", attribution.modelGB, name)
        } else if let name = attribution.primaryLabel {
            mine = String(format: "≈%.0f GB %@ +%d more",
                          attribution.modelGB, name, attribution.modelCount - 1)
        } else {
            mine = String(format: "≈%.0f GB loaded models", attribution.modelGB)
        }
        return String(format: "of %.0f GB in use: ", attribution.spokenForGB)
            + mine + String(format: " · ≈%.0f GB other", attribution.otherGB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: "MEMORY", trailing: "pressure \(memory.pressure.label)")

            MeterRow(label: "RAM", fraction: memory.usedFraction,
                     value: String(format: "%.0f%%", memory.usedFraction * 100),
                     detail: "\(Fmt.gb(memory.usedBytes)) of \(Fmt.gb(memory.totalBytes))")

            // The attribution line. Placed directly under the bar rather than
            // in a tooltip: it is the explanation for the number immediately
            // above it, and a number that needs explaining should not require
            // a hover to get one.
            if attribution.hasModels {
                HStack(spacing: 8) {
                    Text("").frame(width: 38)
                    HStack(spacing: 4) {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        Text(attributionText)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .help("Counted against used + cached, not the \"used\" figure above. A "
                      + "model's weights sit in wired memory once the GPU holds them, and "
                      + "in the file cache while they are only mmapped — \"used\" counts "
                      + "the first and excludes the second, so it alone cannot account for "
                      + "a loaded model. Either way the memory is spoken for and invisible "
                      + "to per-process tools: ds4-server reports a ~20 MB RSS while "
                      + "holding its whole model. Sizes are the manifest's declared "
                      + "figures, not measurements.")
            }

            HStack(spacing: 8) {
                Text("").frame(width: 38)
                Text("\(Fmt.gb(freeBytes)) free · \(Fmt.gb(memory.cachedFileBytes)) cached · AI \(Fmt.bytes(aiFootprint))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if gpu.limitBytes > 0 {
                MeterRow(label: "GPU", fraction: gpu.fraction,
                         value: String(format: "%.0f%%", gpu.fraction * 100),
                         detail: gpu.available
                            ? "\(Fmt.gb(gpu.inUseBytes)) of \(Fmt.gb(gpu.limitBytes)) wired cap"
                            : "cap \(Fmt.gb(gpu.limitBytes))")
            }

            HStack(spacing: 8) {
                Text("Swap").font(.system(size: 11, weight: .medium))
                    .frame(width: 38, alignment: .leading)
                Text(Fmt.gb(swap.usedBytes))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(swapTint)
                Text(swapTrend == .growing ? "and growing — under real pressure"
                                           : "\(swapTrend.label) · macOS never frees swap on its own")
                    .font(.system(size: 9))
                    .foregroundStyle(swapTrend == .growing ? .red : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help("Swap only indicates a problem when it is increasing. macOS leaves "
                  + "previously swapped pages on disk even after memory frees up, so a "
                  + "steady non-zero number is normally just history.")
        }
    }
}

// MARK: - Backends

struct BackendStripView: View {
    var backends: [BackendSpec]
    var statuses: [String: BackendStatus]
    var hasProbed: Bool

    private func kind(_ b: BackendSpec) -> StatusDot.Kind {
        guard hasProbed else { return .unknown }
        guard let s = statuses[b.id], s.up else { return .down }
        if s.telemetry.busy == true { return .busy }
        return b.managed ? .up : .unmanaged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "BACKENDS")
            ForEach(backends) { b in
                HStack(spacing: 7) {
                    StatusDot(kind: kind(b))
                    Text(b.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 118, alignment: .leading)
                        .lineLimit(1)
                    Text(":" + String(b.port))
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                    Text(detail(b))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func detail(_ b: BackendSpec) -> String {
        guard hasProbed else { return "checking…" }
        guard let s = statuses[b.id], s.up else { return "offline" }
        if let m = s.servedModel, !m.isEmpty { return m }
        if !s.telemetry.ollamaResident.isEmpty {
            return s.telemetry.ollamaResident.map(\.name).joined(separator: ", ")
        }
        if let r = s.telemetry.jobsRunning { return r > 0 ? "job running" : "idle" }
        return "up"
    }
}

// MARK: - Processes

struct ProcessListView: View {
    var procs: [ProcSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "PROCESSES",
                          trailing: procs.isEmpty ? nil
                            : Fmt.bytes(procs.reduce(0) { $0 &+ $1.footprintBytes }))
            if procs.isEmpty {
                Text("no model servers running")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                ForEach(procs) { p in
                    HStack(spacing: 7) {
                        Text(p.label)
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 118, alignment: .leading)
                            .lineLimit(1)
                        Text(Fmt.bytes(p.footprintBytes))
                            .font(.system(size: 10, design: .rounded)).monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                        Text(String(format: "%.0f%%", p.cpuPercent))
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(p.cpuPercent > 80 ? .orange : .secondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(Fmt.uptime(p.uptime))
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Spacer(minLength: 0)
                    }
                    .help("pid \(p.pid) — \(p.command)\nRSS \(Fmt.bytes(p.rssBytes)) "
                          + "(excludes mmapped weights, which live in the shared file cache)")
                }
            }
        }
    }
}
