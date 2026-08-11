import AppKit
import SwiftUI
import SwiftTerm
import os

private let ptyLogger = Logger(subsystem: "com.tbd.app", category: "localPTY")

/// A minimal SwiftTerm host for ONE locally-spawned process on a plain PTY.
/// Modeled on `TerminalPanelView`'s `Coordinator` (same `LocalProcess(delegate:)`
/// + `startProcess` path) but deliberately WITHOUT any of the tmux
/// window-recreate, hibernation, or control-mode machinery — this is the
/// "exec it and get out of the way" shape.
///
/// Two callers, both remote-provider-related and both wanting exactly this
/// behavior with a different argv:
///
/// - `RemoteAttachTerminalView` — the provider's `attach` verb
///   (`docs/remote-provider-contract.md` § `attach`).
/// - `RemoteRemediationTerminalSheet` — a provider-supplied remediation
///   command run through the user's login shell.
///
/// Everything that used to be attach-specific is now a parameter (`argv`,
/// `environment`), so the host's behavior — env handed to the child,
/// initial winsize, resize forwarding, explicit `terminate()` on dismantle —
/// is byte-for-byte what attach always did.
struct LocalPTYTerminalRepresentable: NSViewRepresentable {
    /// Full argv, `argv[0]` being the executable. Passed to `LocalProcess`
    /// verbatim — never joined into a shell string, never re-quoted.
    let argv: [String]
    /// The complete child environment. Callers build this themselves so no
    /// caller silently inherits another's contract-specific variables.
    let environment: [String: String]
    let appearance: AppearanceSettings
    /// Called once when the local process ends, for any reason. For a
    /// provider `attach` this never implies the remote session died — only
    /// that this local viewer process stopped.
    let onExit: (Int32?) -> Void

    func makeNSView(context: Context) -> TBDTerminalView {
        let tv = TBDTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: appearance.font,
            appearance: appearance
        )
        // Unlike `TerminalPanelView`, this view installs no scroll monitor of
        // its own, so SwiftTerm's native mouse reporting is the ONLY path
        // that can deliver wheel events to the child app at all. The far
        // side decides whether an event actually gets consumed there;
        // SwiftTerm still falls back to local scrollback scrolling whenever
        // the app hasn't requested mouse mode. Clicks are handled natively
        // too — `TBDTerminalView`'s shared click-passthrough monitor stands
        // down whenever `allowMouseReporting` is true (see
        // `handleClickPassthrough`), so this doesn't double-forward.
        tv.allowMouseReporting = true
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.onExit = onExit

        // TBDTerminalView fires `onReady` exactly once, the first time it's
        // laid out with non-zero bounds — the same hook TerminalPanelView
        // uses to defer starting the child process until SwiftTerm can
        // report real (not placeholder) column/row counts for the initial
        // PTY size.
        tv.onReady = { [weak tv, weak coordinator = context.coordinator] in
            guard let tv, let coordinator else { return }
            coordinator.start(terminalView: tv, argv: argv, environment: environment)
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
        var onExit: ((Int32?) -> Void)?
        /// Internal rather than private so `TerminalTeardownReapTests` can hand
        /// this coordinator a real `LocalProcess` and drive `cleanup()`
        /// headlessly — the reap wiring is otherwise unreachable from a test,
        /// since `start()` needs a live `TerminalView`.
        var localProcess: LocalProcess?
        private var started = false
        private var tornDown = false
        /// Recorded when `LocalProcess`'s own exit monitor fires — by then it
        /// has already called `waitpid`, so `cleanup()` must NOT reap this pid
        /// (it is free, and could have been recycled for another child of this
        /// process). Both sides are main-isolated — the callback by
        /// `LocalProcess`'s default `dispatchQueue`, `cleanup()` by its
        /// `@MainActor` below — so see `ChildExitObservation` for why the flag
        /// is lock-guarded regardless.
        private let childExitObservation = ChildExitObservation()

        @MainActor
        func start(terminalView: TerminalView, argv: [String], environment: [String: String]) {
            guard !started, !tornDown else { return }
            started = true

            guard let executable = argv.first else {
                ptyLogger.error("local PTY: empty argv, nothing to spawn")
                return
            }
            let args = Array(argv.dropFirst())
            let envPairs = environment.map { "\($0.key)=\($0.value)" }

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

        /// `@MainActor` like the panel coordinator's sibling: SwiftUI already
        /// calls `dismantleNSView` on the main thread, and annotating it turns
        /// that convention into a compiler-enforced guarantee. `ChildReaper`'s
        /// ordering fix depends on this teardown running on the main queue.
        @MainActor
        func cleanup() {
            // Idempotent: a second call must not re-run the teardown (it would
            // reap a pid whose `LocalProcess` this method already released).
            guard !tornDown else { return }
            tornDown = true
            // Capture the pid BEFORE releasing our reference — `LocalProcess`
            // is the only thing that knows it.
            let pid = localProcess?.shellPid ?? 0
            // Explicit terminate() — SwiftTerm's LocalProcess.deinit says
            // outright that it does NOT send SIGTERM (see its doc comment):
            // "we intentionally don't send SIGTERM here; terminate() remains
            // the explicit API for killing the shell." Dropping our
            // reference below only releases OUR side; without this call the
            // forked child (or, for a provider that execs a remote-shell
            // wrapper, that wrapper) is left to notice the closed master fd
            // (SIGHUP) on its own — which a well-behaved child handles, but
            // one that traps/ignores SIGHUP, or that `setsid`s a detached
            // wrapper, would leak a process per spawn. Safe by contract for
            // a provider `attach`: terminate() only kills the LOCAL viewer
            // process running the verb — the remote session itself is
            // unaffected (docs/remote-provider-contract.md § attach).
            localProcess?.terminate()
            localProcess = nil
            // terminate() cancels `LocalProcess`'s exit monitor (via
            // childStopped()) before the SIGTERM it just sent can land, so
            // nothing left will `waitpid` this child — that cancellation is
            // also what makes `ChildReaper` its sole waiter. Without the reap
            // it stays `<defunct>` under TBDApp forever.
            ChildReaper.reap(pid: pid, unless: childExitObservation)
        }

        // MARK: - LocalProcessDelegate

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            // `LocalProcess.processTerminated()` calls `waitpid` before it
            // calls us, so this child is already reaped and its pid is free to
            // be recycled — a later `cleanup()` must not wait on it, and the
            // `terminate()` below must not be read as re-killing it. Recorded
            // before the `async` so the flag is set as early as this callback
            // can set it.
            childExitObservation.record()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.tornDown else { return }
                // The child already exited, but `LocalProcess` doesn't close
                // its own master fd/DispatchIO channel on this path — only
                // the `childfd` EOF marker is cleared. Without an explicit
                // terminate() here, that fd stays open for as long as the
                // user sits on whatever overlay the caller shows next.
                self.localProcess?.terminate()
                self.onExit?(exitCode)
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
