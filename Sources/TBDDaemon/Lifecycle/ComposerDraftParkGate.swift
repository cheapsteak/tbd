import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "composer-draft")

/// `TmuxSignalEnding`'s lines go where the coordinator logs every other park
/// and swap ending. They fire for every tmux park, whatever the session's
/// composer-draft status, so they are not composer-draft soak signals.
private let endingLogger = Logger(subsystem: "com.tbd.daemon", category: "Hibernation")

/// What a park does with what the composer-draft feature knows about the
/// session. The session mod is the park's only guard for an unsent draft.
/// See `docs/specs/2026-10-24-mod-only-park-guard-design.md`, "Which parks go
/// ahead".
enum ComposerDraftParkDecision: Equatable, Sendable {
    /// The park goes on and ends Claude by signal.
    case proceed
    /// An automatic park the feature cannot vouch for: the session is skipped.
    /// `reason` is the `SessionModLiveness.UnknownReason` raw value.
    case skip(reason: String)
}

/// The park gate the session mod answers.
enum ComposerDraftParkGate {
    /// Every park of a session spawned without the feature, or one whose mod
    /// confirmed the draft, proceeds: the first has saved nothing and nothing
    /// can see its draft, the second has saved it. A session spawned with the
    /// feature whose mod is not confirmed proceeds for a manual park and a
    /// profile swap, which are gestures, and is skipped by the merge-park and
    /// the idle sweep, which nobody asked for: on a machine where the mod never
    /// loads, that condition never clears at a respawn.
    static func decide(
        status: ComposerDraftStatus,
        policy: HibernateEligibilityPolicy
    ) -> ComposerDraftParkDecision {
        switch status {
        case .legacy, .confirmed:
            return .proceed
        case .unknown(let unknown):
            switch policy {
            case .manual, .profileSwap:
                return .proceed
            case .merge, .automatic:
                return .skip(reason: unknown.rawValue)
            }
        }
    }

    /// The reason a skipped park records: the `.notEligible` reason the merge
    /// fan-out and the idle sweep's actuation row carry.
    static func skipReason(_ reason: String) -> String {
        "TBD can't confirm this session's draft is saved (\(reason))."
    }

    /// Logs a park the gate skipped. Automatic parks have no caller to tell,
    /// so the log is where the reason goes.
    static func logSkip(terminalID: UUID, reason: String) {
        logger.notice("composer-draft: skipped park of \(terminalID.uuidString, privacy: .public): \(reason, privacy: .public)")
    }
}

/// Ends the Claude process in a tmux pane by signal, typing nothing into the
/// pane: the ending of every tmux park and of the tmux in-place profile swap.
/// Nothing is ever typed into a composer to end Claude, because a typed
/// `/exit` lands after whatever the box holds and Enter submits it, and a
/// daemon-sent Ctrl+C clears a draft the session mod would then record as
/// gone. SIGTERM runs Claude Code's graceful shutdown, so the mod makes its
/// final save in `session.end`.
///
/// The pane's own pid is its login-shell wrapper, so the Claude process is
/// looked up beneath it on the process table, never read off the screen.
/// SIGTERM goes to exactly that pid, never to the wrapper and never to a
/// process group. Then the pane's current command is polled on the injected
/// clock for Claude to leave.
///
/// Best-effort: each caller's `respawn-window -k` is what guarantees the
/// process ends, and it follows every outcome.
enum TmuxSignalEnding {
    enum Outcome: Equatable, Sendable {
        /// SIGTERM went to `pid`, and the pane stopped running Claude inside
        /// the poll window.
        case exited(pid: Int32)
        /// SIGTERM went to `pid`, and Claude was still running when the poll
        /// window closed.
        case stillRunning(pid: Int32)
        /// No Claude process answered under the pane, so nothing was signalled
        /// and nothing was waited for.
        case noClaudeProcess
    }

    /// `attempts` × `interval` is the poll window. `try?` on the sleep is not
    /// a cancellation check: a cancelled task
    /// burns the attempts at zero delay and reports `.stillRunning`, and the
    /// caller's respawn still ends the process. An outcome short of `.exited`
    /// is logged under the `Hibernation` category, naming `terminalID`:
    /// `.noClaudeProcess` at `.notice`, because no SIGTERM went out and the
    /// ending falls to the respawn alone, and `.stillRunning` at `.debug`.
    @discardableResult
    static func end(
        tmux: TmuxManager,
        server: String,
        paneID: String,
        terminalID: UUID,
        inspector: any PaneProcessInspecting,
        signaller: any ProcessSignaller,
        clock: any Clock<Duration>,
        attempts: Int,
        interval: Duration
    ) async -> Outcome {
        // `panePID > 0` is not decoration: a tmux that cannot answer reports
        // "0", and the process table has no meaningful answer about pid 0.
        guard let panePIDString = try? await tmux.panePID(server: server, paneID: paneID),
              let panePID = Int32(panePIDString), panePID > 0,
              let claudePID = inspector.foregroundClaudePID(panePID: panePID),
              claudePID > 0 else {
            endingLogger.notice("signal ending: found no claude process under \(terminalID.uuidString, privacy: .public)'s pane, so no SIGTERM was sent — respawn-window -k alone ends the pane")
            return .noClaudeProcess
        }
        signaller.terminateProcessOnly(claudePID)
        for _ in 0..<max(0, attempts) {
            try? await clock.sleep(for: interval)
            if let command = try? await tmux.paneCurrentCommand(server: server, paneID: paneID),
               !ClaudeStateDetector.isClaudeProcess(command) {
                return .exited(pid: claudePID)
            }
        }
        endingLogger.debug("signal ending: SIGTERM did not end claude pid \(claudePID, privacy: .public) for \(terminalID.uuidString, privacy: .public) within the poll window — respawn-window -k ends it")
        return .stillRunning(pid: claudePID)
    }
}
