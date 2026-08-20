import SwiftUI
import ServiceManagement

/// Real entry point. Dispatches to the headless CLI when invoked with `--cli`,
/// otherwise hands off to SwiftUI. This keeps one binary and one code path:
/// the CLI drives the same `AppState` the menu does.
@main
struct ModelBarMain {
    /// Deliberately NOT `async`.
    ///
    /// An `async main` runs the body as a Swift concurrency task rather than
    /// straight-line on the main thread, and starting the AppKit event loop
    /// from inside that task leaves the app running with no status item ever
    /// created — the process launches, idles, and shows nothing. The GUI path
    /// therefore calls `ModelBarApp.main()` synchronously, and the CLI path
    /// drives its own run loop instead.
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--selftest") {
            runSelfTest()
        }
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            runRenderPreview(args[i + 1])
        }
        guard args.contains("--cli") else {
            ModelBarApp.main()
            return
        }
        runCLI(args)
    }

    /// Launches the real UI, then reports the app's own windows and exits.
    ///
    /// This exists because the menubar cannot be inspected from outside without
    /// Screen Recording or Accessibility permission. Asking the app about its
    /// own `NSStatusBarWindow` needs neither, and proves the status item was
    /// actually created rather than merely that the process is alive.
    @MainActor
    private static func runSelfTest() -> Never {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let windows = NSApp.windows
            print("NSApp.windows: \(windows.count)")
            var statusItems = 0
            for w in windows {
                let cls = String(describing: type(of: w))
                if cls.contains("StatusBar") { statusItems += 1 }
                print("  - \(cls) visible=\(w.isVisible) level=\(w.level.rawValue) "
                      + "frame=\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)) "
                      + "\(Int(w.frame.width))x\(Int(w.frame.height))")
            }
            print("status-bar windows: \(statusItems)")
            print("activationPolicy: \(NSApp.activationPolicy().rawValue) (2 == .accessory)")
            print(statusItems > 0 ? "SELFTEST PASS: menubar item exists"
                                  : "SELFTEST FAIL: no status item")
            exit(statusItems > 0 ? 0 : 1)
        }
        ModelBarApp.main()
        exit(1)
    }

    /// Renders the real menu view offscreen to a PNG.
    ///
    /// The menubar popover cannot be opened programmatically without
    /// Accessibility permission, and screencapture needs Screen Recording, so
    /// this rasterises the same SwiftUI view the menu shows — with live state —
    /// to make the rendered result inspectable.
    @MainActor
    private static func runRenderPreview(_ path: String) -> Never {
        let state = AppState()
        Task { @MainActor in
            // Two refreshes: %CPU is a delta between samples.
            await state.refresh()
            await state.refreshHarness()
            try? await Task.sleep(for: .milliseconds(1200))
            await state.refresh()

            let renderer = ImageRenderer(
                content: MenuContentView(state: state, maxContentHeight: 4000, scrolls: false)
                    .padding(6)
                    .background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2

            if let image = renderer.nsImage,
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path) — \(Int(image.size.width))x\(Int(image.size.height)) pt")
                } catch {
                    print("write failed: \(error.localizedDescription)")
                }
            } else {
                print("render failed")
            }
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
        exit(0)
    }

    /// Runs the @MainActor CLI to completion. The main run loop has to be
    /// pumped for MainActor work to execute at all, so blocking on a semaphore
    /// here would deadlock; instead the run loop is stopped from inside the
    /// task once the command finishes.
    @MainActor
    private static func runCLI(_ args: [String]) -> Never {
        let box = ExitCodeBox()
        Task { @MainActor in
            box.code = await CLI.run(args)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
        exit(box.code)
    }
}

private final class ExitCodeBox: @unchecked Sendable {
    var code: Int32 = 0
}

/// A backend an on-demand proxy is holding open must never be orphaned when
/// ModelBar quits — nothing else would ever idle-reap it. `applicationShouldTerminate`
/// defers the real quit (`.terminateLater`) until every proxy has stopped its
/// backend, then lets AppKit finish tearing the process down.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        Task { @MainActor in
            await state.shutdownProxies()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ModelBarApp: App {
    @State private var state = AppState(manifestPath: Self.manifestOverride())
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// `--manifest <path>` works in GUI mode too, not just `--cli` — needed to
    /// point a real, launched `.app` at a scratch manifest for verification
    /// (an idle timeout of a few minutes is impractical to wait out against the
    /// real one) without ever touching `~/models/modelbar.json`.
    private static func manifestOverride() -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--manifest"), i + 1 < args.count else { return nil }
        return (args[i + 1] as NSString).expandingTildeInPath
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: state)
                .onAppear {
                    state.menuOpen = true
                    Task { await state.refreshHarness() }
                }
                .onDisappear { state.menuOpen = false }
        } label: {
            // The icon carries the coarse state; the title carries the one
            // number worth glancing at, and is empty when there is none.
            HStack(spacing: 3) {
                Image(systemName: state.iconName)
                if !state.menubarTitle.isEmpty {
                    Text(state.menubarTitle)
                }
            }
            .onAppear {
                state.startPolling()
                state.startProxies()
                appDelegate.state = state
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Reports the laid-out height of the menu's content.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MenuContentView: View {
    @Bindable var state: AppState
    /// Cap on the scrolling region. Raised for offscreen preview rendering so
    /// the whole menu is captured rather than just the visible slice.
    var maxContentHeight: CGFloat = 580
    /// ImageRenderer does not rasterise ScrollView content, so preview renders
    /// lay the same sections out in a plain stack instead.
    var scrolls: Bool = true

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let error = state.manifestError {
                manifestErrorView(error)
            } else {
                contentStack
            }

            Divider()
            footer
        }
        .frame(width: 400)
    }

    @ViewBuilder
    private var contentStack: some View {
        let sections = VStack(alignment: .leading, spacing: 12) {
            if !state.manifestWarnings.isEmpty { warningsView }

            NowRunningView(state: state)

            MemoryView(memory: state.memory, swap: state.swap,
                       swapTrend: state.swapTrend, freeBytes: state.freeBytes,
                       gpu: state.gpu,
                       aiFootprint: state.procs.reduce(0) { $0 &+ $1.footprintBytes })

            modelsSection

            BackendStripView(backends: state.backends, statuses: state.statuses,
                             hasProbed: state.hasProbed)

            ProcessListView(procs: state.procs)

            if let failure = state.lastFailure { failureView(failure) }

            harnessSection
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)

        if scrolls {
            // A ScrollView has no intrinsic height. Inside a MenuBarExtra
            // window — which sizes itself to fit its content — `maxHeight`
            // alone let it collapse to zero, so the menu opened showing only
            // its header and footer with an empty gap between them. Measuring
            // the content and giving the ScrollView a definite height fixes
            // that while still capping how tall the menu can get.
            ScrollView {
                sections.background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: geo.size.height)
                    })
            }
            .frame(height: min(max(contentHeight, 80), maxContentHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        } else {
            sections
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: state.iconName).font(.system(size: 11))
            Text("ModelBar").font(.system(size: 12, weight: .bold))
            Spacer()
            if let note = state.actionNote {
                Text(note)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            } else if let last = state.lastRefresh {
                Text(freshness(last))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func freshness(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return s < 2 ? "live" : "\(s)s ago"
    }

    /// Everything that is not model control lives behind one gear menu.
    ///
    /// The old footer had a button labelled "Models" that opened Finder while a
    /// section three inches above was also headed "MODELS" — clicking the
    /// obvious thing gave you a Finder window instead of model status. Nothing
    /// in this menu reuses a word for two different actions now.
    private var footer: some View {
        HStack(spacing: 10) {
            Text(String(format: "%.0f of %.0f GB committed",
                        state.committedGB(), state.budgetGB))
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
            // Quit stays a plain always-visible button rather than living only
            // inside the gear menu: if the menu ever fails to open there must
            // still be a way out of the app.
            Button { NSApplication.shared.terminate(nil) } label: {
                Text("Quit").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Menu {
                Button("Reveal Models Folder in Finder") { state.revealInFinder("~/models") }
                Button("Open Manifest (modelbar.json)") { state.openPath(state.manifestPath) }
                Button("Open ds4 Server Log") { state.openPath("/tmp/ds4-server.log") }
                Divider()
                Button("Reload Manifest") {
                    state.reloadManifest()
                    Task { await state.refresh() }
                }
                LaunchAtLoginToggle()
            } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Sections

    private func manifestErrorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Manifest problem", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
            Text(error)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Fix \(state.manifestPath), then Reload from the gear menu.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var warningsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "MANIFEST WARNINGS")
            ForEach(state.manifestWarnings, id: \.self) { w in
                Text("• \(w)")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "MODELS",
                          trailing: "\(state.loadedModelIds.count) of \(state.models.count) loaded")
            ForEach(state.models) { model in
                ModelRowView(
                    model: model,
                    backendName: state.backend(for: model)?.displayName ?? model.backendId,
                    loaded: state.isLoaded(model),
                    activity: state.activity,
                    contextSize: model.context != nil ? state.selectedContextSize(for: model) : nil,
                    onLoad: { Task { await state.load(model) } },
                    onStop: { Task { await state.stop(model) } },
                    onSetContext: { size in state.setContextSize(size, for: model) })
            }
        }
    }

    private func failureView(_ failure: LoadFailure) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: "LAST FAILURE")
            Text("\(shortName(failure.modelId)): \(failure.summary)")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(failure.logLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // The "NEW — NOT YET CONFIGURED" section that used to sit here has been
    // removed. It scanned disk and backend inventories for anything without a
    // manifest entry, which in practice meant a permanent list of things the
    // user had deliberately not configured (LTX-2.5, MiniMax Music-3, DFlash2
    // artifacts) in a menu that is already dense. `ModelDiscovery` itself is
    // kept and still reachable as `--cli discover`, since reconciling the
    // manifest against disk is a reasonable thing to ask for on demand — it is
    // only the always-on display and its per-poll I/O that are gone.
    //
    // Note this is not the same as the manifest *validation* warnings, which
    // stay: those fire when a configured model's files have gone missing, and
    // that catches real breakage rather than listing roads not taken.

    /// Each harness gets a picker listing exactly the models eligible for it
    /// (populated by the manifest, verified against what each backend's wire
    /// format actually supports) — not a fixed one-model toggle. The manifest
    /// entry is the only thing that determines what shows up here, and
    /// clicking an entry is the only thing that writes to that harness's
    /// config; nothing else touches these files.
    private var harnessSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "HARNESSES")
            harnessRow(.hermes, current: "\(state.harness.hermesProvider ?? "?") / \(state.harness.hermesModel ?? "?")")
            harnessRow(.pi, current: "\(state.harness.piProvider ?? "?") / \(state.harness.piModel ?? "?")")
            harnessRow(.codex, current: state.harness.codexActiveProfile.map { "Local (\(profileModelName($0)))" } ?? "API")
            harnessRow(.claudeCode, current: state.harness.claudeLocalActiveModel.map { "Local (\($0))" } ?? "API")
            ForEach(state.harness.errors, id: \.self) { e in
                Text("• \(e)").font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
    }

    private func profileModelName(_ profile: String) -> String {
        state.models.first { $0.harness?.codexProfile == profile }?.displayName ?? profile
    }

    /// The picker lists *every* manifest model, not just the ones already
    /// written into that harness's config — selecting one registers it there.
    /// Models the harness cannot drive stay visible but disabled, with the
    /// reason attached: an option that silently vanishes reads as a bug, while
    /// "MLX does not serve /v1/responses" is a fact the user can act on.
    private func harnessRow(_ kind: AppState.HarnessKind, current: String) -> some View {
        let options = state.harnessOptions(for: kind)
        let anyEligible = options.contains { $0.eligible }
        return HStack(spacing: 7) {
            Text(kind.displayName)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 76, alignment: .leading)
            Text(current)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Menu {
                if options.isEmpty {
                    Text("no models in manifest")
                } else {
                    ForEach(options) { option in
                        Button(option.eligible
                               ? option.model.displayName
                               : "\(option.model.displayName) — \(option.reason ?? "unavailable")") {
                            Task { await state.pointHarness(kind, at: option.model) }
                        }
                        .disabled(!option.eligible)
                    }
                    if kind.hasAPIOption {
                        Divider()
                        Button("API (disarm)") {
                            Task { await state.pointHarness(kind, at: nil) }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!anyEligible && !kind.hasAPIOption)
        }
    }

    private func shortName(_ id: String) -> String {
        state.models.first { $0.id == id }?.displayName ?? id
    }
}

/// One model row: state dot, name, backend, size, and hover actions.
struct ModelRowView: View {
    var model: ModelSpec
    var backendName: String
    var loaded: Bool
    var activity: Activity
    /// Currently-selected context size, or nil if this model has none
    /// adjustable (hidden entirely, not shown disabled — see `ContextOption`).
    var contextSize: Int?
    var onLoad: () -> Void
    var onStop: () -> Void
    var onSetContext: (Int) -> Void

    @State private var hovering = false

    private var missing: [String] { model.missingRequirements }
    private var available: Bool { missing.isEmpty }
    private var isTarget: Bool { activity.modelId == model.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Group {
                    if isTarget {
                        Image(systemName: "circle.dotted").foregroundStyle(.orange)
                    } else if loaded {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if available {
                        Image(systemName: "circle").foregroundStyle(.secondary.opacity(0.4))
                    } else {
                        // Not a download-in-progress glyph, for the same reason
                        // the label no longer says "downloading".
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange.opacity(0.8))
                    }
                }
                .font(.system(size: 11))
                .frame(width: 14)

                Text(model.displayName)
                    .font(.system(size: 11, weight: loaded ? .semibold : .regular))
                    .foregroundStyle(available ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.tail)

                Spacer(minLength: 4)

                Text(backendName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(model.estimatedGB > 0
                     ? String(format: "%.0f GB", model.estimatedGB) : "—")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }

            if !available {
                // "downloading" was a guess about *why* a file was absent, and
                // usually the wrong one: the real causes seen here have been a
                // moved script and a backend re-pointed at a new models
                // directory, neither of which involves a download. State the
                // fact — a required file is missing — and name it, so the row
                // is diagnosable without opening the manifest.
                Text("     missing \(missingSummary)")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.middle)
            } else if hovering {
                HStack(spacing: 12) {
                    Button(loaded ? "Restart" : "Load", action: onLoad)
                        .disabled(activity.isBusy)
                    if loaded { Button("Stop", action: onStop).disabled(activity.isBusy) }
                    if let ctx = model.context, let current = contextSize {
                        contextPicker(ctx, current: current)
                    }
                    Spacer()
                }
                .buttonStyle(.link)
                .font(.system(size: 9))
                .padding(.leading, 21)
            } else if let notes = model.notes, !notes.isEmpty {
                Text("     \(notes)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if available && !activity.isBusy { onLoad() } }
        .help(available ? (model.notes ?? model.displayName)
              : "Required file(s) not found:\n" + missing.joined(separator: "\n"))
    }

    /// Names the missing file when there is one, counts them when there are
    /// several. Paths are shown expanded — a tilde in the manifest is not what
    /// the check actually tested, and printing it back would send someone
    /// looking in the wrong place.
    private var missingSummary: String {
        guard let first = missing.first else { return "file" }
        let name = (first as NSString).lastPathComponent
        return missing.count == 1 ? name : "\(name) +\(missing.count - 1) more"
    }

    /// Context picker: restart-to-apply, so it never touches a running
    /// server — it only decides what argv the *next* load uses.
    private func contextPicker(_ ctx: ContextOption, current: Int) -> some View {
        Menu {
            ForEach(ctx.options, id: \.self) { size in
                Button(size == current ? "✓ \(size.formatted())" : size.formatted()) {
                    onSetContext(size)
                }
            }
        } label: {
            Text("ctx \(current.formatted())")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Context window — restart to apply")
    }
}

/// Launch-at-login via SMAppService. Hides itself if the API is unavailable.
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var failed = false

    var body: some View {
        if failed {
            EmptyView()
        } else {
            Toggle("Launch at Login", isOn: Binding(
                get: { enabled },
                set: { newValue in
                    do {
                        if newValue { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        enabled = SMAppService.mainApp.status == .enabled
                    } catch {
                        failed = true
                    }
                }))
        }
    }
}
