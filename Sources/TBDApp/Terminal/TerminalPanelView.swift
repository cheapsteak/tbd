import SwiftUI
import SwiftTerm
import AppKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "TerminalPanel")

// MARK: - TerminalPanelView

/// Wraps SwiftTerm's `TerminalView` (AppKit NSView) in a SwiftUI `NSViewRepresentable`.
///
/// Connects to the TmuxBridge for a specific pane: receives decoded output bytes
/// and feeds them into the terminal emulator, and captures user keystrokes to send
/// back through the bridge.
struct TerminalPanelView: NSViewRepresentable {
    let terminalID: UUID
    let tmuxServer: String
    let tmuxPaneID: String
    let tmuxBridge: TmuxBridge

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        // Dark terminal appearance
        tv.nativeBackgroundColor = NSColor.black
        tv.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)

        // Set the delegate so we capture keystrokes
        tv.terminalDelegate = context.coordinator

        // Register with TmuxBridge to receive pane output
        context.coordinator.registerWithBridge(
            terminalView: tv,
            tmuxBridge: tmuxBridge,
            server: tmuxServer,
            paneID: tmuxPaneID
        )

        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // On resize, use the terminal's current cols/rows (which SwiftTerm updates
        // internally on frame change) and compare with our last-sent dimensions.
        let currentCols = nsView.getTerminal().cols
        let currentRows = nsView.getTerminal().rows

        guard currentCols > 0, currentRows > 0 else { return }

        if currentCols != context.coordinator.lastCols ||
           currentRows != context.coordinator.lastRows {
            context.coordinator.handleResize(cols: currentCols, rows: currentRows)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    /// Bridges TmuxBridge output to the SwiftTerm TerminalView, and captures
    /// user keystrokes to send back via the bridge.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private weak var terminalView: TerminalView?
        private var tmuxBridge: TmuxBridge?
        private var server: String = ""
        private var paneID: String = ""
        fileprivate var lastCols: Int = 0
        fileprivate var lastRows: Int = 0

        /// Register with the TmuxBridge to receive output for this pane.
        func registerWithBridge(
            terminalView: TerminalView,
            tmuxBridge: TmuxBridge,
            server: String,
            paneID: String
        ) {
            self.terminalView = terminalView
            self.tmuxBridge = tmuxBridge
            self.server = server
            self.paneID = paneID

            // Register a handler that feeds decoded bytes into the terminal view
            let weakTV = Weak(terminalView)
            Task {
                await tmuxBridge.registerPane(server: server, paneID: paneID) { data in
                    let bytes = ArraySlice<UInt8>(data)
                    DispatchQueue.main.async {
                        guard let tv = weakTV.value else { return }
                        tv.feed(byteArray: bytes)
                    }
                }
            }
        }

        /// Handle view resize by notifying tmux of new dimensions.
        func handleResize(cols: Int, rows: Int) {
            guard cols != lastCols || rows != lastRows else { return }
            lastCols = cols
            lastRows = rows

            let bridge = tmuxBridge
            let srv = server
            // tmux resize uses window ID; for control mode, pane ID works with resize-pane
            let pane = paneID

            Task {
                // Use resize-pane for per-pane resizing in control mode
                await bridge?.writeCommand(
                    server: srv,
                    command: "resize-pane -t \(pane) -x \(cols) -y \(rows)\n"
                )
            }
        }

        /// Unregister from the bridge on deinit.
        deinit {
            let bridge = tmuxBridge
            let srv = server
            let pid = paneID
            Task {
                await bridge?.unregisterPane(server: srv, paneID: pid)
            }
        }

        // MARK: - TerminalViewDelegate

        /// Called when the terminal emulator wants to send data back (user keystrokes).
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let bridge = tmuxBridge else { return }
            let text = String(bytes: data, encoding: .utf8) ?? ""
            guard !text.isEmpty else { return }

            let srv = server
            let pid = paneID
            Task {
                await bridge.sendKeys(server: srv, paneID: pid, text: text)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            handleResize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Could update tab title in the future
            logger.debug("Terminal title changed: \(title)")
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Could track CWD in the future
        }

        func scrolled(source: TerminalView, position: Double) {
            // Scroll position tracking — no-op for now
        }

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
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
            // Not handled
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            // Visual change notification — no-op
        }
    }
}

// MARK: - Weak Reference Helper

/// A simple weak reference wrapper to allow capturing in @Sendable closures.
private final class Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}
