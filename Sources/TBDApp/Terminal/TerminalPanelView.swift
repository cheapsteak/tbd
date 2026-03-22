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

        // Dark terminal appearance
        tv.nativeBackgroundColor = NSColor.black
        tv.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)

        // Set delegate for terminal events
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.tmuxBridge = tmuxBridge
        context.coordinator.tmuxServer = tmuxServer
        context.coordinator.panelID = terminalID

        // Prepare the grouped session and start the tmux client
        DispatchQueue.main.async {
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
        // Nothing to do — resize is handled by the PTY automatically
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        // Clean up the grouped session when the view is removed
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

            debugLog("PANEL: Starting tmux client: \(args.joined(separator: " "))")

            // Use SwiftTerm's LocalProcess to spawn tmux in a PTY
            let process = LocalProcess(delegate: self)
            self.localProcess = process

            // args[0] = "tmux", rest are arguments
            let executable = args[0]
            let processArgs = Array(args.dropFirst())

            // Find tmux path
            let tmuxPath = findExecutable(executable)

            process.startProcess(
                executable: tmuxPath,
                args: processArgs,
                environment: nil, // inherit
                execName: nil
            )

            // Make sure the terminal view accepts keyboard focus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }

        func cleanup() {
            debugLog("PANEL: cleanup for \(panelID.uuidString.prefix(8))")
            tmuxBridge?.cleanupSession(panelID: panelID, server: tmuxServer)
        }

        deinit {
            debugLog("PANEL: deinit for \(panelID.uuidString.prefix(8))")
            // Note: cleanup is called by dismantleNSView, not deinit
        }

        // MARK: - LocalProcessDelegate

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            debugLog("PANEL: process terminated, exitCode=\(exitCode ?? -1)")
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.feed(text: "\r\n[Process exited with code \(exitCode ?? -1)]\r\n")
            }
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            // Data from the PTY → feed into SwiftTerm for rendering
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.feed(byteArray: slice)
            }
        }

        func getWindowSize() -> winsize {
            // Return default size — the actual size will be set by SwiftTerm
            // when the view lays out, triggering a SIGWINCH to the PTY
            return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // User keystrokes → write to PTY
            localProcess?.send(data: data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // SwiftTerm notifies us of size change → LocalProcess handles SIGWINCH
            debugLog("PANEL: sizeChanged cols=\(newCols) rows=\(newRows)")
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Could update tab title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

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
            // Check common paths
            for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] {
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
            // Fall back to using env to find it
            return "/usr/bin/env"
        }
    }
}
