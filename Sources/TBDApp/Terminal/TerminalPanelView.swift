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

/// Wraps SwiftTerm's `TerminalView` in a SwiftUI `NSViewRepresentable`.
///
/// Uses tmux grouped sessions for session persistence:
/// 1. TmuxBridge creates a grouped session pointing at the right window
/// 2. SwiftTerm spawns `tmux attach -t <grouped-session>` in a native PTY
/// 3. All input, output, and resize handled natively by the terminal driver
struct TerminalPanelView: NSViewRepresentable {
    let terminalID: UUID
    let tmuxServer: String
    let tmuxWindowID: String
    let tmuxBridge: TmuxBridge
    var worktreePath: String = ""
    var remoteURL: String?
    var onFilePathClicked: ((String) -> Void)?
    var onTerminalNotification: ((String, String) -> Void)?
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

    func makeNSView(context: Context) -> TBDTerminalView {
        let tv = TBDTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        // Dark terminal
        tv.nativeBackgroundColor = NSColor.black
        tv.nativeForegroundColor = NSColor(white: 0.85, alpha: 1.0)

        // Disable mouse reporting so click-drag selects text locally
        // instead of forwarding mouse events to tmux
        tv.allowMouseReporting = false

        // Wire up Cmd+Click file path detection
        tv.worktreePath = worktreePath
        tv.remoteURL = remoteURL
        tv.onFilePathClicked = onFilePathClicked
        tv.onNotification = onTerminalNotification

        // Set delegate for terminal events
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.tmuxBridge = tmuxBridge
        context.coordinator.tmuxServer = tmuxServer
        context.coordinator.panelID = terminalID

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
            context.coordinator.startTmuxClient(
                terminalView: tv,
                bridge: tmuxBridge,
                server: tmuxServer,
                windowID: tmuxWindowID,
                panelID: terminalID
            )
        }

        return tv
    }

    func updateNSView(_ nsView: TBDTerminalView, context: Context) {
        // Resize is handled by sizeChanged delegate
    }

    static func dismantleNSView(_ nsView: TBDTerminalView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, TerminalViewDelegate, LocalProcessDelegate, @unchecked Sendable {
        weak var terminalView: TerminalView?
        var tmuxBridge: TmuxBridge?
        var tmuxServer: String = ""
        var panelID: UUID = UUID()
        private var localProcess: LocalProcess?
        private var scrollMonitor: Any?
        private var clickMonitor: Any?

        func startTmuxClient(
            terminalView: TerminalView,
            bridge: TmuxBridge,
            server: String,
            windowID: String,
            panelID: UUID
        ) {
            guard let args = bridge.prepareSession(
                panelID: panelID,
                server: server,
                windowID: windowID
            ) else {
                debugLog("PANEL: Window \(windowID) is dead — showing message")
                DispatchQueue.main.async {
                    terminalView.feed(text: "\r\n  Terminal session expired.\r\n  Close this tab and create a new terminal.\r\n")
                }
                return
            }

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
            // (accounts for scroller width and actual cell metrics)
            MainActor.assumeIsolated {
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
            }

            // Intercept scroll wheel events before they reach TerminalView.
            // TerminalView.scrollWheel is not `open`, so we can't override it
            // in TBDTerminalView. Instead, a local event monitor intercepts
            // scroll events and forwards them to tmux as mouse button presses.
            let ref = WeakTerminalRef(terminalView)
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                let deltaY = event.deltaY
                let location = event.locationInWindow
                guard deltaY != 0 else { return event }

                let consumed = MainActor.assumeIsolated {
                    guard let tv = ref.view as? TBDTerminalView else { return false }
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
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                let location = event.locationInWindow

                // Claim first responder so key equivalents route to this terminal
                MainActor.assumeIsolated {
                    guard let tv = ref.view else { return }
                    let point = tv.convert(location, from: nil)
                    guard tv.bounds.contains(point) else { return }
                    tv.window?.makeFirstResponder(tv)
                }

                guard event.modifierFlags.contains(.command) else { return event }

                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let tv = ref.view as? TBDTerminalView else { return false }
                    let point = tv.convert(location, from: nil)
                    guard tv.bounds.contains(point) else { return false }

                    if let filePath = tv.extractFilePath(atWindowLocation: location) {
                        tv.onFilePathClicked?(filePath)
                        return true
                    }
                    // Fall back to hyperlink detection (OSC 8 or pattern matching)
                    if let urlString = tv.extractHyperlinkURL(atWindowLocation: location) {
                        // Try to resolve as a file path first (OSC 8 payload may be relative or file:// URL)
                        if let resolved = tv.resolveAsFilePath(urlString) {
                            tv.onFilePathClicked?(resolved)
                            return true
                        }
                        // Only open as external URL if it has a real scheme
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
