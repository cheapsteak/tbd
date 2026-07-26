import AppKit
import SwiftUI
import SwiftTerm
import TBDShared
import os

private let attachLogger = Logger(subsystem: "com.tbd.app", category: "remoteAttach")

/// A minimal SwiftTerm host for a remote-session `attach`. Modeled on
/// `TerminalPanelView`'s `Coordinator` (same `LocalProcess(delegate:)` +
/// `startProcess` path), but spawning `<exec> [args...] attach <id>` on a
/// plain PTY instead of a tmux attach client — deliberately WITHOUT any of
/// the tmux window-recreate, hibernation, or control-mode machinery, since a
/// provider's `attach` is just "exec me and get out of the way"
/// (`docs/remote-provider-contract.md` § `attach`).
///
/// Per the contract, pane exit means the viewer detached — it never means
/// the remote session died (only `list`/`events` are authoritative about
/// that). This view itself no longer renders the "Detached" overlay: since
/// attach is now mounted across MULTIPLE sessions at once by
/// `RemoteAttachPager` (bounded keep-alive, see `RemoteAttachLifecycle`),
/// the decision of "should this still be mounted at all" has to survive
/// this view's own instance being torn down and recreated (a detached
/// session that ages out of the keep-alive cap gets a BRAND NEW instance
/// when the user comes back to it) — so detach state lives on `AppState`
/// instead (`AppState.explicitlyDetachedRemoteSessions`, written via
/// `onDetached` below) and the overlay/Reattach UI is rendered by
/// `RemoteSessionDetailView`, which persists across that churn. This view
/// is now just the bare terminal host plus one pure classification helper.
struct RemoteAttachTerminalView: View {
    let provider: RemoteProviderConfig
    let sessionID: String
    /// Called once when the local attach process ends, for any reason
    /// (clean exit, crash, unreachable host). Never implies the remote
    /// session died — only that this local viewer process stopped.
    let onDetached: (Int32?) -> Void
    @EnvironmentObject var appearance: AppearanceSettings

    /// A non-zero (or unreadable) exit code means the local `attach` process
    /// ended on its own rather than the user cleanly detaching — e.g. a bad
    /// credential or an unreachable host that made the provider's `attach`
    /// fail to even connect. `nil` (no exit code available) is treated as
    /// the non-alarming case: there's nothing here to confidently call a
    /// failure. Either way the session itself is unaffected — only the
    /// caller's framing (title/icon) should change, never the "keeps
    /// running remotely" contract line.
    static func isUnexpectedExit(exitCode: Int32?) -> Bool {
        guard let exitCode else { return false }
        return exitCode != 0
    }

    var body: some View {
        RemoteAttachTerminalRepresentable(
            provider: provider,
            sessionID: sessionID,
            appearance: appearance,
            onDetached: onDetached
        )
    }
}

/// Wraps a bare SwiftTerm `TBDTerminalView` (for consistent font/appearance
/// theming) hosting exactly one `LocalProcess` running the provider's
/// `attach` verb. `makeNSView`/`dismantleNSView` own the process lifecycle —
/// unlike `TerminalPanelRepresentable`, there is no tmux bridge, no snapshot
/// feed, no control-mode branch, and no app-wide NSEvent scroll/click
/// monitors (those exist in `TerminalPanelView` to route events around
/// SwiftUI overlays layered on top of a LIVE worktree tab; this view has no
/// such siblings competing for events).
private struct RemoteAttachTerminalRepresentable: NSViewRepresentable {
    let provider: RemoteProviderConfig
    let sessionID: String
    let appearance: AppearanceSettings
    let onDetached: (Int32?) -> Void

    func makeNSView(context: Context) -> TBDTerminalView {
        let tv = TBDTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: appearance.font,
            appearance: appearance
        )
        tv.allowMouseReporting = false
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.onDetached = onDetached

        // TBDTerminalView fires `onReady` exactly once, the first time it's
        // laid out with non-zero bounds — the same hook TerminalPanelView
        // uses to defer starting the child process until SwiftTerm can
        // report real (not placeholder) column/row counts for the initial
        // PTY size.
        tv.onReady = { [weak tv, weak coordinator = context.coordinator] in
            guard let tv, let coordinator else { return }
            coordinator.start(terminalView: tv, provider: provider, sessionID: sessionID)
        }
        return tv
    }

    func updateNSView(_ nsView: TBDTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TBDTerminalView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, TerminalViewDelegate, LocalProcessDelegate, @unchecked Sendable {
        weak var terminalView: TerminalView?
        var onDetached: ((Int32?) -> Void)?
        private var localProcess: LocalProcess?
        private var started = false
        private var tornDown = false

        @MainActor
        func start(terminalView: TerminalView, provider: RemoteProviderConfig, sessionID: String) {
            guard !started, !tornDown else { return }
            started = true

            let argv = provider.argv + ["attach", sessionID]
            guard let executable = argv.first else {
                attachLogger.error("remote attach: empty provider argv for \(provider.name, privacy: .public)")
                return
            }
            let args = Array(argv.dropFirst())

            // Strip TMUX/TMUX_PANE like `TerminalPanelView.makeViewerEnvironment`
            // does — the provider may itself exec tmux on the far side (e.g.
            // over SSM), and a nested-attach guard failure there is the same
            // failure mode a nested LOCAL tmux attach hits.
            let env = TerminalPanelView.makeViewerEnvironment(base: ProcessInfo.processInfo.environment)
            let envPairs = env.map { "\($0.key)=\($0.value)" }

            let process = LocalProcess(delegate: self)
            self.localProcess = process
            process.startProcess(executable: executable, args: args, environment: envPairs, execName: nil)

            let cols = terminalView.terminal.cols
            let rows = terminalView.terminal.rows
            if cols > 0, rows > 0, process.childfd >= 0 {
                var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                _ = ioctl(process.childfd, TIOCSWINSZ, &size)
            }

            DispatchQueue.main.async { [weak terminalView] in
                terminalView?.window?.makeFirstResponder(terminalView)
            }
        }

        func cleanup() {
            tornDown = true
            // Explicit terminate() — SwiftTerm's LocalProcess.deinit says
            // outright that it does NOT send SIGTERM (see its doc comment):
            // "we intentionally don't send SIGTERM here; terminate() remains
            // the explicit API for killing the shell." Dropping our
            // reference below only releases OUR side; without this call the
            // forked child (or, over SSH/SSM-style providers, a wrapper
            // process it execs into) is left to notice the closed master fd
            // (SIGHUP) on its own — which a well-behaved attach handles, but
            // a provider whose attach traps/ignores SIGHUP, or that
            // `setsid`s a detached wrapper, would leak a process per attach.
            // Safe by contract regardless: terminate() only kills the LOCAL
            // viewer process running the provider's `attach` verb — the
            // remote session itself is unaffected
            // (docs/remote-provider-contract.md § attach).
            localProcess?.terminate()
            localProcess = nil
        }

        // MARK: - LocalProcessDelegate

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.tornDown else { return }
                // The child already exited, but `LocalProcess` doesn't close
                // its own master fd/DispatchIO channel on this path — only
                // the `childfd` EOF marker is cleared. Without an explicit
                // terminate() here, that fd stays open for as long as the
                // user sits on the "Detached" overlay, i.e. until they
                // navigate away (`cleanup()`) or hit Reattach: that clears
                // `explicitlyDetachedRemoteSessions`, which re-admits this
                // selection into `attachedRemoteSelections`, and
                // `RemoteAttachPager.updateNSViewController` responds by
                // removing this tab item (tearing this instance down) and
                // adding a brand new one backed by a fresh `LocalProcess`.
                self.localProcess?.terminate()
                self.onDetached?(exitCode)
            }
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.feed(byteArray: slice)
            }
        }

        func getWindowSize() -> winsize {
            MainActor.assumeIsolated {
                if let tv = terminalView, tv.terminal.cols > 0, tv.terminal.rows > 0 {
                    return winsize(
                        ws_row: UInt16(tv.terminal.rows), ws_col: UInt16(tv.terminal.cols),
                        ws_xpixel: 0, ws_ypixel: 0)
                }
                return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            }
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            localProcess?.send(data: data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                guard newCols > 0, newRows > 0, let fd = localProcess?.childfd, fd >= 0 else { return }
                var size = winsize(ws_row: UInt16(newRows), ws_col: UInt16(newCols), ws_xpixel: 0, ws_ypixel: 0)
                _ = ioctl(fd, TIOCSWINSZ, &size)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard link.contains("://"), let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) { NSSound.beep() }

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
