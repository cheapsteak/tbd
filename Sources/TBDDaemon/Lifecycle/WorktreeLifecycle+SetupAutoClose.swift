import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "setupHook")

/// Auto-close for the setup-hook tab, gated on `config.auto_close_setup_enabled`
/// (default OFF, soaking). When the flag is on AND a setup hook resolves, the
/// hook command writes its exit code to a marker file; a detached watcher
/// tears the tab down on a clean exit and leaves it open (with an interactive
/// shell) on failure/timeout/killed pane. Flag off keeps today's behavior
/// byte-for-byte (plain `shellWrapped`, no marker, no watcher).
extension WorktreeLifecycle {

    /// Directory holding setup-hook completion markers. Sibling of
    /// `preSessionRuntimeDir`; TBD_HOME-relative so tests redirect automatically.
    static var setupRuntimeDir: String {
        TBDConstants.configDir
            .appendingPathComponent("runtime")
            .appendingPathComponent("setup")
            .path
    }

    /// Marker file the wrapped setup-hook command writes its exit code to.
    static func setupMarkerPath(worktreeID: UUID) -> String {
        (setupRuntimeDir as NSString)
            .appendingPathComponent(worktreeID.uuidString)
    }

    /// Wraps the setup hook so its exit code lands in the marker file.
    /// Unlike `preSessionCommand` (which always execs the shell so the pane
    /// stays usable), this execs the interactive shell ONLY on failure — a
    /// clean run lets the pane exit so the watcher's teardown races nothing,
    /// and a failed run keeps the pane alive for debugging. Single-quote
    /// escaping matches `preSessionCommand` / `shellWrapped`.
    static func setupAutoCloseCommand(
        hookPath: String, runtimeDir: String, markerPath: String, shell: String
    ) -> String {
        func quoted(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return "\(quoted(hookPath)); __tbd_rc=$?; "
            + "/bin/mkdir -p \(quoted(runtimeDir)); "
            + "/bin/echo $__tbd_rc > \(quoted(markerPath)); "
            + "if [ $__tbd_rc -ne 0 ]; then exec \(shell); fi"
    }

    /// Detached tail of a flag-on setup spawn: await the marker (reusing the
    /// pre-session polling, including its dead-window and deadline races),
    /// then close the tab on exit 0. Any other outcome leaves the tab alone —
    /// the wrapped command already exec'd a shell there on failure, and a
    /// timeout/killed pane needs no daemon action.
    func finishAutoCloseSetup(worktree: Worktree, setup: PreSessionSpawn) async {
        let outcome = await waitForPreSessionCompletion(
            preSession: setup, tmuxServer: setup.tmuxServer
        )
        // The marker must never outlive the wait, whatever the outcome.
        try? FileManager.default.removeItem(atPath: setup.markerPath)

        switch outcome {
        case .completed(exitCode: 0):
            logger.info("setup hook completed cleanly for worktree \(worktree.id, privacy: .public) — closing its tab")
            await closeHookTerminal(
                worktree: worktree,
                tmuxServer: setup.tmuxServer,
                terminalID: setup.terminalID,
                windowID: setup.windowID
            )
        case .completed(let exitCode):
            logger.info("setup hook failed (exit \(exitCode, privacy: .public)) for worktree \(worktree.id, privacy: .public) — leaving its tab open")
        case .timedOut:
            logger.info("setup hook timed out for worktree \(worktree.id, privacy: .public) — leaving its tab open")
        case .paneKilled:
            logger.debug("setup hook pane closed before the marker was written for worktree \(worktree.id, privacy: .public)")
        }
    }
}
