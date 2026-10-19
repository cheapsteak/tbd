import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "composer-draft")

/// What a park does with what the composer-draft feature knows about the
/// session. See `docs/specs/2026-10-19-tbd-session-mod-design.md`, "Parking".
enum ComposerDraftParkDecision: Equatable, Sendable {
    /// Spawned without the feature: today's rails decide, the pending-input
    /// scrape among them.
    case legacy
    /// The park goes on and the pending-input scrape never refuses it: the
    /// feature confirmed the draft is saved, or the park proceeds without that
    /// confirmation (a profile swap, or a manual park the person overrode).
    case proceed
    /// A manual park the feature cannot vouch for: the caller is asked, and a
    /// yes reissues the park with the override.
    case refuse(reason: String)
    /// An automatic park the feature cannot vouch for: the session is skipped.
    case skip(reason: String)
}

/// How a park, or an in-place profile swap, ends the Claude process it
/// replaces. See `docs/specs/2026-10-19-tbd-session-mod-design.md`, "Parking".
enum ParkEndingStyle: Equatable, Sendable {
    /// `/exit` typed into the composer, then the transport's existing
    /// fallbacks. Only a park of a session spawned without the feature ends
    /// this way, never a profile swap.
    case typedExit
    /// SIGTERM to the Claude process, and nothing typed into its terminal.
    case signal
}

/// The park gate for sessions spawned with the composer-draft feature.
enum ComposerDraftParkGate {
    /// Legacy keeps the old path; confirmed proceeds; unknown proceeds for a
    /// profile swap or an overridden manual park, refuses any other manual
    /// park, and skips the merge-park and the idle sweep. The reason is the
    /// `UnknownReason` raw value.
    static func decide(
        status: ComposerDraftStatus,
        policy: HibernateEligibilityPolicy,
        overrideUnconfirmed: Bool
    ) -> ComposerDraftParkDecision {
        switch status {
        case .legacy:
            return .legacy
        case .confirmed:
            return .proceed
        case .unknown(let unknown):
            let reason = unknown.rawValue
            switch policy {
            case .profileSwap:
                return .proceed
            case .manual:
                return overrideUnconfirmed ? .proceed : .refuse(reason: reason)
            case .merge, .automatic:
                return .skip(reason: reason)
            }
        }
    }

    /// How the park ends the process: a typed `/exit` only for a park of a
    /// legacy session.
    ///
    /// A profile swap ends by signal whatever the status. It honours no live
    /// rail, so the screen check that keeps a legacy park's typed `/exit` off
    /// a draft never runs, and a typed `/exit` would land after whatever the
    /// box holds and submit it to the model. A legacy session's draft is lost
    /// at a swap, since nothing saved it, but it is never typed into or sent.
    /// The tmux in-place swap, which never reaches a park, ends by signal for
    /// the same reason.
    ///
    /// A session spawned with the feature is never typed into: no `/exit`, and
    /// no Escape or Ctrl+C fallback either, because a daemon-sent Ctrl+C clears
    /// the box and the feature would record the draft as gone. SIGTERM runs
    /// the same graceful shutdown, so `session.end` still makes the final save.
    ///
    /// Reads the policy and `spawnedWithFeature`, which the
    /// replacement-snapshot check keeps stable across the wait for the server
    /// lock. Whether the box holds a draft, and how fresh the heartbeat is,
    /// never change how the process ends.
    static func endingStyle(
        for status: ComposerDraftStatus, policy: HibernateEligibilityPolicy
    ) -> ParkEndingStyle {
        switch policy {
        case .profileSwap:
            return .signal
        case .manual, .merge, .automatic:
            return status.spawnedWithFeature ? .signal : .typedExit
        }
    }

    /// The log line for a park where the feature and the pending-input scrape
    /// disagree about whether the composer holds a draft, or nil when they
    /// agree.
    static func shadowDisagreement(
        terminalID: UUID, featureHasDraft: Bool, scrapeHasDraft: Bool
    ) -> String? {
        guard featureHasDraft != scrapeHasDraft else { return nil }
        return "composer-draft shadow disagreement terminal=\(terminalID.uuidString)"
            + " feature=\(word(featureHasDraft)) scrape=\(word(scrapeHasDraft))"
    }

    /// The refusal a person reads when TBD cannot confirm the draft is saved:
    /// the `terminal.hibernate` error, and the reason every other surface
    /// records for an unconfirmed or skipped park.
    static func unconfirmedRefusal(reason: String) -> String {
        "TBD can't confirm this session's draft is saved (\(reason))."
    }

    /// Logs a park the gate skipped. Automatic parks have no caller to tell,
    /// so the log is where the reason goes.
    static func logSkip(terminalID: UUID, reason: String) {
        logger.notice("composer-draft: skipped park of \(terminalID.uuidString, privacy: .public): \(reason, privacy: .public)")
    }

    private static func word(_ hasDraft: Bool) -> String {
        hasDraft ? "draft" : "empty"
    }
}

/// The gate's answer for one park, computed once in `performHibernate` and
/// carried down to the transport leg that carries the park out, where the
/// pending-input rails consult it and the ending reads its status.
struct ComposerDraftParkContext: Sendable {
    let status: ComposerDraftStatus
    let decision: ComposerDraftParkDecision
    /// The park's policy, which the ending reads beside `status`.
    let policy: HibernateEligibilityPolicy
    /// Where a shadow disagreement goes. Nil logs it at `.notice`, which is
    /// what production does; a test records the lines through the
    /// coordinator's `composerDraftShadowLog` seam.
    var shadowLog: (@Sendable (String) -> Void)?

    /// How the transport leg ends the process. See
    /// `ComposerDraftParkGate.endingStyle(for:policy:)`.
    var endingStyle: ParkEndingStyle {
        ComposerDraftParkGate.endingStyle(for: status, policy: policy)
    }

    /// Whether one pending-input scrape result refuses the park.
    ///
    /// Only a legacy session is refused on the scrape. For any other session
    /// the scrape never decides. Compares nothing and logs nothing: the tmux
    /// park's fast pre-lock rail asks this, and the authoritative read under
    /// the lock is the one compared, so a park logs a disagreement at most
    /// once.
    func scrapeRefuses(hasPendingInput: Bool) -> Bool {
        decision == .legacy && hasPendingInput
    }

    /// The park's authoritative pending-input read: whether it refuses the
    /// park, exactly as `scrapeRefuses(hasPendingInput:)` answers.
    ///
    /// While the flag exists, a confirmed session's result is also compared
    /// with the feature's answer and any disagreement logged at `.notice`.
    /// Each park calls this once: the tmux park under its server lock, the
    /// holder park on its one screen read.
    func judgeAuthoritativeScrape(hasPendingInput: Bool, terminalID: UUID) -> Bool {
        if case .confirmed(let featureHasDraft) = status,
           let line = ComposerDraftParkGate.shadowDisagreement(
               terminalID: terminalID,
               featureHasDraft: featureHasDraft,
               scrapeHasDraft: hasPendingInput) {
            if let shadowLog {
                shadowLog(line)
            } else {
                logger.notice("\(line, privacy: .public)")
            }
        }
        return scrapeRefuses(hasPendingInput: hasPendingInput)
    }
}

/// Ends the Claude process in a tmux pane by signal, typing nothing into the
/// pane: the tmux park's ending for a session spawned with the composer-draft
/// feature, and the tmux in-place profile swap's ending for every session.
///
/// The pane's own pid is its login-shell wrapper, so the Claude process is
/// looked up beneath it on the process table, never read off the screen.
/// SIGTERM goes to exactly that pid, never to the wrapper and never to a
/// process group. Then the pane's current command is polled on the injected
/// clock for Claude to leave.
///
/// Best-effort, like the typed ending it stands in for: each caller's
/// `respawn-window -k` is what guarantees the process ends, and it follows
/// every outcome.
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

    /// `attempts` × `interval` is the poll window. Like the typed ending's
    /// poll, `try?` on the sleep is not a cancellation check: a cancelled task
    /// burns the attempts at zero delay and reports `.stillRunning`, and the
    /// caller's respawn still ends the process. An outcome short of `.exited`
    /// is logged, naming `terminalID`: `.noClaudeProcess` at `.notice`,
    /// because no SIGTERM went out and the ending falls to the respawn alone,
    /// and `.stillRunning` at `.debug`.
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
            logger.notice("composer-draft: found no claude process under \(terminalID.uuidString, privacy: .public)'s pane to signal, so no SIGTERM was sent — the respawn ends whatever is there")
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
        logger.debug("composer-draft: SIGTERM did not end claude pid \(claudePID, privacy: .public) for \(terminalID.uuidString, privacy: .public) within the poll window — the respawn ends it")
        return .stillRunning(pid: claudePID)
    }
}
