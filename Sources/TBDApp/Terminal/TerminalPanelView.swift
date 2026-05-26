import SwiftUI
import SwiftTerm
import AppKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "TerminalPanel")

/// Sendable wrapper for a weak TerminalView reference, used to pass the
/// reference into an `NSEvent` local monitor closure under strict concurrency.
private final class WeakTerminalRef: @unchecked Sendable {
    weak var view: TerminalView?
    init(_ view: TerminalView) { self.view = view }
}

// MARK: - TerminalPanelView

/// SwiftUI view that hosts a SwiftTerm-backed terminal panel and, for terminals
/// pinned to a proxy profile (`baseURL != nil`), shows a one-shot
/// proxy-unreachable banner driven by a TCP-connect health probe.
struct TerminalPanelView: View {
    let terminalID: UUID
    let tmuxServer: String
    let tmuxWindowID: String
    let tmuxBridge: TmuxBridge
    var tabCloseContext: TabCloseContext? = nil
    var worktreePath: String = ""
    var remoteURL: String?
    var onFilePathClicked: ((String) -> Void)?
    var onTerminalNotification: ((String, String) -> Void)?
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appearance: AppearanceSettings
    /// Called when the tmux window is dead and needs recreation. The callback
    /// should ask the daemon to recreate the window and trigger a state refresh.
    var onDeadWindow: (() -> Void)?
    /// When set, this ANSI text is fed into the terminal buffer before the tmux
    /// client connects. The live tmux output overwrites it seamlessly.
    /// See docs/superpowers/specs/2026-03-31-snapshot-display-approaches.md for
    /// alternative approaches that were tried and why they failed.
    var initialSnapshot: String?
    /// When true, the terminal was suspended at view creation time. The view
    /// feeds the snapshot but does NOT start a tmux client — the old window's
    /// shell would overwrite the snapshot. Once resume completes and
    /// `tmuxWindowID` changes, the view is recreated (`.id` changes) with
    /// this flag false, and tmux connects normally.
    var isSuspendedSnapshot: Bool = false
    /// Called on every scroll/click event. When it returns `true`, both
    /// NSEvent monitors short-circuit — the terminal does NOT consume the
    /// event, leaving it for whatever SwiftUI overlay (currently a
    /// transcript-card overlay; see #129) is rendered on top. Must be
    /// `@MainActor` since it is invoked from inside `assumeIsolated` blocks.
    var shouldSuppressEvents: @MainActor () -> Bool = { false }

    @State private var proxyWarning: String?
    @State private var didProbe = false

    /// Profile id pinned to this terminal (if any). Used as the `.task` id so
    /// the probe re-fires once AppState populates. `nil` while AppState hasn't
    /// loaded the terminal yet — the probe just returns without consuming its
    /// one-shot gate.
    private var pinnedProfileID: UUID? {
        appState.terminals.values.flatMap({ $0 })
            .first(where: { $0.id == terminalID })?.profileID
    }

    var body: some View {
        VStack(spacing: 0) {
            if let warning = proxyWarning,
               !appState.dismissedProxyWarnings.contains(terminalID) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(warning).font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        appState.dismissedProxyWarnings.insert(terminalID)
                    }
                        .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.yellow.opacity(0.2))
            }
            TerminalPanelRepresentable(
                terminalID: terminalID,
                tmuxServer: tmuxServer,
                tmuxWindowID: tmuxWindowID,
                tmuxBridge: tmuxBridge,
                tabCloseContext: tabCloseContext,
                worktreePath: worktreePath,
                remoteURL: remoteURL,
                onFilePathClicked: onFilePathClicked,
                onTerminalNotification: onTerminalNotification,
                onDeadWindow: onDeadWindow,
                initialSnapshot: initialSnapshot,
                isSuspendedSnapshot: isSuspendedSnapshot,
                shouldSuppressEvents: shouldSuppressEvents
            )
        }
        .task(id: pinnedProfileID) {
            await maybeProbeProxy()
        }
    }

    @MainActor
    private func maybeProbeProxy() async {
        if didProbe { return }

        // Look up the pinned profile for this terminal. Only proxy profiles
        // (baseURL != nil) get probed — Claude-direct has nothing to be
        // unreachable. If the lookup fails (AppState hasn't populated yet),
        // return WITHOUT setting `didProbe` so a later `.task` fire — once
        // `pinnedProfileID` settles — gets another chance.
        guard let terminal = appState.terminals.values.flatMap({ $0 })
            .first(where: { $0.id == terminalID }),
              let profileID = terminal.profileID,
              let profile = appState.modelProfiles
                  .first(where: { $0.profile.id == profileID })?.profile,
              let baseURL = profile.baseURL, !baseURL.isEmpty
        else {
            return
        }

        didProbe = true   // gate further attempts only once we actually probe

        try? await Task.sleep(nanoseconds: 500_000_000)
        let result = await appState.healthCheckProfile(baseURL: baseURL)
        if !result.reachable {
            proxyWarning = "Proxy unreachable at \(baseURL). Is your local proxy running?"
            logger.debug("proxy unreachable for terminal \(terminalID, privacy: .public) base=\(baseURL, privacy: .public) detail=\(result.detail ?? "nil", privacy: .public)")
        }
    }
}

// MARK: - TerminalPanelRepresentable

/// Wraps SwiftTerm's `TerminalView` in a SwiftUI `NSViewRepresentable`.
///
/// Uses tmux grouped sessions for session persistence:
/// 1. TmuxBridge creates a grouped session pointing at the right window
/// 2. SwiftTerm spawns `tmux attach -t <grouped-session>` in a native PTY
/// 3. All input, output, and resize handled natively by the terminal driver
private struct TerminalPanelRepresentable: NSViewRepresentable {
    let terminalID: UUID
    let tmuxServer: String
    let tmuxWindowID: String
    let tmuxBridge: TmuxBridge
    var tabCloseContext: TabCloseContext? = nil
    var worktreePath: String = ""
    var remoteURL: String?
    var onFilePathClicked: ((String) -> Void)?
    var onTerminalNotification: ((String, String) -> Void)?
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appearance: AppearanceSettings
    var onDeadWindow: (() -> Void)?
    var initialSnapshot: String?
    var isSuspendedSnapshot: Bool = false
    var shouldSuppressEvents: @MainActor () -> Bool = { false }

    func makeNSView(context: Context) -> TBDTerminalView {
        let tv = TBDTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: appearance.font,
            appearance: appearance
        )

        // Disable mouse reporting so click-drag selects text locally
        // instead of forwarding mouse events to tmux
        tv.allowMouseReporting = false

        // Wire up Cmd+Click file path detection
        tv.worktreePath = worktreePath
        tv.remoteURL = remoteURL
        tv.onFilePathClicked = onFilePathClicked
        tv.onNotification = onTerminalNotification
        tv.onCloseTab = {
            guard let tabCloseContext else { return }
            appState.focusedTabCloseContext = tabCloseContext
            appState.closeFocusedTab()
        }

        // Set delegate for terminal events
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.tmuxBridge = tmuxBridge
        context.coordinator.tmuxServer = tmuxServer
        context.coordinator.panelID = terminalID
        context.coordinator.appState = appState
        context.coordinator.tabCloseContext = tabCloseContext
        context.coordinator.onDeadWindow = onDeadWindow
        context.coordinator.shouldSuppressEvents = shouldSuppressEvents

        // Feed snapshot before tmux connects so the user sees the last state
        let snapshot = initialSnapshot
        let suspendedOnCreate = isSuspendedSnapshot
        // Start tmux client as soon as the view has real dimensions from layout
        tv.onReady = { [weak tv] in
            guard let tv else { return }
            if let snapshot {
                // SwiftTerm expects \r\n line endings. Normalize first to avoid
                // doubling any \r\n that might already exist in the snapshot.
                let normalized = snapshot
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\n", with: "\r\n")
                tv.feed(text: normalized)
            }
            // Skip tmux connect for suspended terminals — the old window's shell
            // would overwrite the snapshot. The view will be recreated with a new
            // .id when tmuxWindowID changes after resume completes.
            guard !suspendedOnCreate else { return }
            // Detach to a Task so `prepareSession` (which spawns tmux subprocesses)
            // doesn't block the main thread. `startTmuxClient` hops back to
            // `@MainActor` once the tmux args come back.
            Task { [weak coordinator = context.coordinator, weak tv] in
                guard let coordinator, let tv else { return }
                await coordinator.startTmuxClient(
                    terminalView: tv,
                    bridge: tmuxBridge,
                    server: tmuxServer,
                    windowID: tmuxWindowID,
                    panelID: terminalID
                )
            }
        }

        // Register snapshot provider so SidebarContextMenu can capture this view
        let captureID = terminalID
        appState.snapshotProviders[captureID] = { [weak tv] in
            tv?.captureScreenshot()
        }
        appState.registerTerminalCloseContext(tabCloseContext, for: terminalID)
        appState.registerTerminalView(tv, for: terminalID)

        return tv
    }

    func updateNSView(_ nsView: TBDTerminalView, context: Context) {
        // Resize is handled by sizeChanged delegate
    }

    static func dismantleNSView(_ nsView: TBDTerminalView, coordinator: Coordinator) {
        coordinator.appState?.unregisterTerminalView(nsView, for: coordinator.panelID)
        coordinator.cleanup()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, TerminalViewDelegate, LocalProcessDelegate, @unchecked Sendable {
        weak var terminalView: TerminalView?
        weak var appState: AppState?
        var tmuxBridge: TmuxBridge?
        var tmuxServer: String = ""
        var panelID: UUID = UUID()
        var tabCloseContext: TabCloseContext?
        var onDeadWindow: (() -> Void)?
        /// Returns `true` when a SwiftUI overlay (e.g. transcript card) is open
        /// over this terminal and should receive scroll/click events instead of
        /// the terminal. Set by `TerminalPanelRepresentable.makeNSView`.
        var shouldSuppressEvents: @MainActor () -> Bool = { false }
        private var localProcess: LocalProcess?
        private var scrollMonitor: Any?
        private var clickMonitor: Any?
        private var recreationAttempts = 0
        private static let maxRecreationAttempts = 2

        @MainActor
        func startTmuxClient(
            terminalView: TerminalView,
            bridge: TmuxBridge,
            server: String,
            windowID: String,
            panelID: UUID
        ) async {
            // `prepareSession` is non-isolated and awaits tmux subprocesses
            // off the main actor — Swift releases main while we suspend here,
            // so SwiftUI's render loop is no longer blocked while tmux runs.
            guard let args = await bridge.prepareSession(
                panelID: panelID,
                server: server,
                windowID: windowID
            ) else {
                recreationAttempts += 1
                if recreationAttempts <= Self.maxRecreationAttempts {
                    debugLog("PANEL: Window \(windowID) is dead — requesting recreation (attempt \(recreationAttempts))")
                    DispatchQueue.main.async { [weak self] in
                        self?.onDeadWindow?()
                    }
                } else {
                    debugLog("PANEL: Window \(windowID) is dead — max recreation attempts reached")
                    DispatchQueue.main.async {
                        terminalView.feed(text: "\r\n  Terminal session expired.\r\n  Close this tab and create a new terminal.\r\n")
                    }
                }
                return
            }
            recreationAttempts = 0 // Reset on successful connect

            let tmuxPath = findExecutable(args[0])
            let processArgs = Array(args.dropFirst())

            debugLog("PANEL: Starting: \(tmuxPath) \(processArgs.joined(separator: " "))")

            // Inherit environment with proper TERM
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            let envPairs = env.map { "\($0.key)=\($0.value)" }

            let process = LocalProcess(delegate: self)
            self.localProcess = process

            process.startProcess(
                executable: tmuxPath,
                args: processArgs,
                environment: envPairs,
                execName: nil
            )

            // Send correct initial size from SwiftTerm's own computed dimensions
            // (accounts for scroller width and actual cell metrics).
            // The enclosing function is `@MainActor async`, so we're already
            // main-isolated here — no `assumeIsolated` wrapper needed.
            do {
                let cols = terminalView.terminal.cols
                let rows = terminalView.terminal.rows
                if cols > 0 && rows > 0 && process.childfd >= 0 {
                    var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                    _ = ioctl(process.childfd, TIOCSWINSZ, &size)
                    debugLog("PANEL: initial resize \(cols)x\(rows)")
                }
            }

            // Focus on next run loop iteration (needs main actor for window access)
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
                self.appState?.focusedTabCloseContext = self.tabCloseContext
            }

            // Intercept scroll wheel events before they reach TerminalView.
            // TerminalView.scrollWheel is not `open`, so we can't override it
            // in TBDTerminalView. Instead, a local event monitor intercepts
            // scroll events and forwards them to tmux as mouse button presses.
            //
            // Visibility filter: the `tv.window != nil` guard inside the
            // closure rejects events when the terminal isn't currently part of
            // the visible UI. This is load-bearing for the worktree keep-alive
            // system (see WorktreePager + TerminalContainerView): inactive
            // worktrees keep their terminal NSViews alive but detached from the
            // window. Without the guard, every kept-alive terminal's monitor
            // would still fire for every app-wide scroll-wheel event, and the
            // `bounds.contains(point)` check below wouldn't filter them out
            // (bounds-space math works fine on detached views) — events would
            // be silently consumed and forwarded to hidden terminals' tmux
            // sessions, scrolling them invisibly. tv.window == nil ⇒ this
            // terminal isn't visible right now ⇒ no-op the monitor.
            let ref = WeakTerminalRef(terminalView)
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                let deltaY = event.deltaY
                let location = event.locationInWindow
                guard deltaY != 0 else { return event }

                let consumed = MainActor.assumeIsolated { [weak self] in
                    guard let self else { return false }
                    guard let tv = ref.view as? TBDTerminalView else { return false }
                    guard tv.window != nil else { return false }
                    // Short-circuit when a SwiftUI overlay is open on top of this
                    // terminal — pass the event through so the overlay can handle it.
                    if self.shouldSuppressEvents() { return false }
                    let point = tv.convert(location, from: nil)
                    guard tv.bounds.contains(point) else { return false }
                    guard tv.terminal.mouseMode != .off else { return false }

                    // Use actual scroll position so tmux routes to the correct pane
                    guard let (col, row) = tv.gridPosition(atWindowLocation: location) else { return false }

                    let isUp = deltaY > 0
                    let buttonFlags = tv.terminal.encodeButton(
                        button: isUp ? 4 : 5,
                        release: false, shift: false, meta: false, control: false
                    )
                    let lines = max(1, Int(abs(deltaY)))
                    for _ in 0..<lines {
                        tv.terminal.sendEvent(buttonFlags: buttonFlags, x: col, y: row)
                    }
                    return true
                }
                return consumed ? nil : event
            }

            // Intercept clicks: claim first responder on any click (so Cmd+Arrow
            // routes to the focused terminal), and handle Cmd+Click for file paths.
            //
            // Visibility filter: each `assumeIsolated` block guards on
            // `tv.window != nil` for the same reason as scrollMonitor above —
            // the worktree keep-alive system retains terminal NSViews for
            // inactive worktrees in a detached state, and we must skip event
            // processing for those (otherwise clicks would claim first responder
            // for a hidden terminal, or fire Cmd+Click handlers against
            // invisible bounds).
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                let location = event.locationInWindow

                // Claim first responder so key equivalents route to this terminal
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    guard let tv = ref.view else { return }
                    guard tv.window != nil else { return }
                    // Short-circuit when a SwiftUI overlay is open on top of this
                    // terminal — leave first-responder where it is so the overlay
                    // receives key and click events.
                    if self.shouldSuppressEvents() { return }
                    let point = tv.convert(location, from: nil)
                    if !tv.bounds.contains(point) {
                        if self.appState?.focusedTabCloseContext == self.tabCloseContext,
                           tv.window?.firstResponder === tv {
                            self.appState?.focusedTabCloseContext = nil
                        }
                        return
                    }
                    self.appState?.focusedTabCloseContext = self.tabCloseContext
                    tv.window?.makeFirstResponder(tv)
                }

                guard event.modifierFlags.contains(.command) else { return event }

                let consumed = MainActor.assumeIsolated { [weak self] () -> Bool in
                    guard let self else { return false }
                    guard let tv = ref.view as? TBDTerminalView else { return false }
                    guard tv.window != nil else { return false }
                    if self.shouldSuppressEvents() { return false }
                    let point = tv.convert(location, from: nil)
                    guard tv.bounds.contains(point) else { return false }

                    // OSC 8 hyperlinks are handled by SwiftTerm's mouseUp path
                    // (requestOpenLink). If we also fired here on mouseDown,
                    // a single cmd+click would route through both paths and
                    // open two viewer panes.
                    if tv.hasOSC8Payload(atWindowLocation: location) {
                        logger.debug("file-click: skipping mouseDown handling — OSC 8 payload present, deferring to requestOpenLink")
                        return false
                    }

                    if let filePath = tv.extractFilePath(atWindowLocation: location) {
                        logger.debug("file-click[mouseDown/path]: \(filePath, privacy: .public)")
                        tv.onFilePathClicked?(filePath)
                        return true
                    }
                    // Fall back to hyperlink detection (PR pattern; OSC 8 was
                    // already short-circuited above).
                    if let urlString = tv.extractHyperlinkURL(atWindowLocation: location) {
                        if let resolved = tv.resolveAsFilePath(urlString) {
                            logger.debug("file-click[mouseDown/hyperlink-as-file]: \(resolved, privacy: .public)")
                            tv.onFilePathClicked?(resolved)
                            return true
                        }
                        if urlString.contains("://"), let url = URL(string: urlString) {
                            NSWorkspace.shared.open(url)
                            return true
                        }
                    }
                    return false
                }
                return consumed ? nil : event
            }
        }

        func cleanup() {
            debugLog("PANEL: cleanup for \(panelID.uuidString.prefix(8))")
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
            tmuxBridge?.cleanupSession(panelID: panelID, server: tmuxServer)
        }

        deinit {
            debugLog("PANEL: deinit for \(panelID.uuidString.prefix(8))")
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        // MARK: - LocalProcessDelegate

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            debugLog("PANEL: process terminated, exitCode=\(exitCode ?? -1)")
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.feed(text: "\r\n[Process exited with code \(exitCode ?? -1)]\r\n")
            }
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.feed(byteArray: slice)
            }
        }

        func getWindowSize() -> winsize {
            // Use SwiftTerm's own dimensions — they account for scroller width
            // and actual cell metrics computed from the font
            return MainActor.assumeIsolated {
                if let tv = terminalView, tv.terminal.cols > 0 && tv.terminal.rows > 0 {
                    let cols = tv.terminal.cols
                    let rows = tv.terminal.rows
                    debugLog("PANEL: getWindowSize \(cols)x\(rows)")
                    return winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                }
                debugLog("PANEL: getWindowSize fallback 80x24")
                return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            }
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            localProcess?.send(data: data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Propagate resize to the PTY so tmux/shell gets SIGWINCH
            guard newCols > 0, newRows > 0, let fd = localProcess?.childfd, fd >= 0 else { return }
            var size = winsize(ws_row: UInt16(newRows), ws_col: UInt16(newCols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(fd, TIOCSWINSZ, &size)
            debugLog("PANEL: resize -> \(newCols)x\(newRows)")
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            MainActor.assumeIsolated {
                // Try to resolve as a file path (absolute, file://, or relative to worktree)
                if let tv = source as? TBDTerminalView,
                   let resolved = tv.resolveAsFilePath(link) {
                    logger.debug("file-click[requestOpenLink/file]: \(resolved, privacy: .public) raw=\(link, privacy: .public)")
                    tv.onFilePathClicked?(resolved)
                    return
                }

                // Only open as external URL if it has a real scheme
                if link.contains("://"), let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        func bell(source: TerminalView) { NSSound.beep() }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        // MARK: - Helpers

        private func findExecutable(_ name: String) -> String {
            for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] {
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
            return "/usr/bin/env"
        }
    }
}
