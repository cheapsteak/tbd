import SwiftUI
import SwiftTerm
import AppKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "TerminalPanel")

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

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        // Dark terminal
        tv.nativeBackgroundColor = NSColor.black
        tv.nativeForegroundColor = NSColor(white: 0.85, alpha: 1.0)

        // Disable mouse reporting so click-drag selects text locally
        // instead of forwarding mouse events to tmux
        tv.allowMouseReporting = false

        // Set delegate for terminal events
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.tmuxBridge = tmuxBridge
        context.coordinator.tmuxServer = tmuxServer
        context.coordinator.panelID = terminalID

        // Delay process start to let SwiftUI lay out the view first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak tv] in
            guard let tv else { return }
            // Capture frame on main thread before calling startTmuxClient
            context.coordinator.initialFrame = tv.frame
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

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Resize is handled by sizeChanged delegate
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
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
        var initialFrame: NSRect = .zero
        private var localProcess: LocalProcess?

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
                debugLog("PANEL: Failed to prepare session for \(panelID.uuidString.prefix(8))")
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

            // Send correct initial size based on view frame
            if initialFrame.width > 0 && initialFrame.height > 0 && process.childfd >= 0 {
                let (cols, rows) = Self.colsRows(from: initialFrame)
                var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                _ = ioctl(process.childfd, TIOCSWINSZ, &size)
                debugLog("PANEL: initial resize \(cols)x\(rows) from frame \(initialFrame.width)x\(initialFrame.height)")
            }

            // Focus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }

        func cleanup() {
            debugLog("PANEL: cleanup for \(panelID.uuidString.prefix(8))")
            tmuxBridge?.cleanupSession(panelID: panelID, server: tmuxServer)
        }

        deinit {
            debugLog("PANEL: deinit for \(panelID.uuidString.prefix(8))")
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
            if initialFrame.width > 0 {
                let (cols, rows) = Self.colsRows(from: initialFrame)
                debugLog("PANEL: getWindowSize \(cols)x\(rows)")
                return winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            }
            debugLog("PANEL: getWindowSize fallback 80x24")
            return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }

        static func colsRows(from frame: NSRect) -> (Int, Int) {
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let cols = max(Int(frame.width / charWidth), 20)
            let rows = max(Int(frame.height / lineHeight), 5)
            return (cols, rows)
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
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
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
