import Darwin
import Foundation
import TBDShared
import os

private let handoverLogger = Logger(subsystem: "com.tbd.daemon", category: "handover")

/// The environment variable a successor daemon is started with to say which
/// daemon it is replacing.
///
/// **Contract, as `scripts/update.sh` uses it.** The update script builds a new
/// daemon out of place, then launches it with
/// `TBD_HANDOVER_FROM_PID=<pid of the running daemon>`. The successor's
/// single-instance gate reads the variable exactly once, at startup, and honors
/// it only when the pid file names a *live* `TBDDaemon` whose pid equals the
/// value.
///
/// **The script always sets the variable, and sets it to `0` when no daemon is
/// running.** So `0` is a first-class value meaning "there is nobody to hand
/// over from", not a malformed one — the script does not have to branch on
/// whether to export it at all, and this side does not have to tell an absent
/// variable from a deliberate "none". Unset, empty, `0`, a negative number and
/// anything unparsable are therefore all the same statement, and none of them
/// authorises a take-over.
///
/// Every other combination falls back to today's behavior — the ordinary
/// single-instance gate, which starts when no live daemon owns the pid file and
/// exits when one does. A stale file, a pid that is not a live `TBDDaemon`, a
/// different live daemon, a mistyped value: none of them can take over a daemon
/// the variable was not aimed at.
///
/// The variable must not outlive that read: `Daemon.scrubInheritedTBDEnv()`
/// unsets it before any tmux server is spawned, because a tmux server bakes its
/// spawn environment into every window it later creates, and a pane carrying a
/// stale handover pid would hand it to anything it launched.
public let handoverFromPIDEnvVar = "TBD_HANDOVER_FROM_PID"

/// What a starting daemon should do about the pid file it found.
///
/// A pure function of three inputs so every branch is reachable from a test
/// without a second process: the pid the file holds, the handover variable, and
/// whether that pid is a live `TBDDaemon`.
public enum HandoverDecision: Equatable, Sendable {
    /// No live daemon owns the pid file. Claim it and start normally.
    case normal
    /// The pid file names the live daemon we were sent to replace. Claim the
    /// file first, then retire that daemon, then start normally.
    case takeOver(predecessor: pid_t)
    /// The pid file names a live daemon that is not ours to replace. Exit.
    case refuse(existing: pid_t)

    public static func decide(
        pidFileContents: pid_t?,
        handoverEnv: String?,
        isLiveDaemon: (pid_t) -> Bool
    ) -> HandoverDecision {
        // Nobody live owns the pid file: start, whatever the variable says. A
        // stale file was already removed by `PIDFile.cleanupIfStale`, so a
        // handover aimed at a daemon that died before the successor launched
        // lands here and is simply an ordinary start.
        guard let existing = pidFileContents, isLiveDaemon(existing) else {
            return .normal
        }
        // A live daemon owns the file. Only an explicit, positive, matching pid
        // that is itself a live daemon may displace it; everything else — unset,
        // empty, `0` (the script's "no daemon was running"), negative,
        // unparsable, or a different pid — leaves the ordinary gate to refuse.
        guard let requested = requestedPredecessor(handoverEnv),
              requested == existing,
              isLiveDaemon(requested)
        else {
            return .refuse(existing: existing)
        }
        return .takeOver(predecessor: existing)
    }

    /// The pid the handover variable names, or `nil` when it names none.
    ///
    /// `nil` covers unset, empty, whitespace, unparsable, and every
    /// non-positive value including the script's `0`. A pid of `0` is not a
    /// process this daemon could ever be replacing — it addresses the caller's
    /// own process group — so refusing it here rather than relying on a
    /// liveness check keeps the "no predecessor" case from depending on what an
    /// injected `isLiveDaemon` happens to say about pid `0`.
    static func requestedPredecessor(_ handoverEnv: String?) -> pid_t? {
        guard let raw = handoverEnv?.trimmingCharacters(in: .whitespacesAndNewlines),
              let requested = pid_t(raw),
              requested > 0
        else {
            return nil
        }
        return requested
    }
}

/// Retires the predecessor daemon during a handover: `SIGTERM`, wait, then
/// `SIGKILL` and a shorter wait.
///
/// The waiting is polled rather than deadline-computed because the clock is an
/// existential (`any Clock<Duration>`) whose `Instant` type is erased, so there
/// is no arithmetic to do on it — see `Tests/CLAUDE.md`, "Clock and date
/// seams". Budgets are instance properties rather than constants so a test can
/// exercise the escalation in three polls instead of three hundred.
public struct DaemonHandover: Sendable {
    /// How long to wait for a polite exit before escalating.
    public let termBudget: Duration
    /// How long to wait after `SIGKILL` before giving up.
    public let killBudget: Duration
    /// Gap between liveness checks.
    public let pollInterval: Duration

    private let sendSignal: @Sendable (pid_t, Int32) -> Void
    private let isLive: @Sendable (pid_t) -> Bool
    private let clock: any Clock<Duration>

    /// What retiring the predecessor came to.
    public enum Outcome: String, Sendable, Equatable {
        /// The predecessor was already gone when we looked.
        case alreadyGone
        /// It exited within the `SIGTERM` budget.
        case exitedAfterTerm
        /// It needed `SIGKILL` and then exited.
        case exitedAfterKill
        /// It was still alive after `SIGKILL` and the second budget. The
        /// successor must NOT start: see `Daemon.start()`, which hands the pid
        /// file back to the predecessor and exits rather than put a second
        /// writer on `state.db`.
        case stillAlive
    }

    public init(
        termBudget: Duration = .seconds(30),
        killBudget: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(100),
        sendSignal: @escaping @Sendable (pid_t, Int32) -> Void = { pid, signal in
            _ = kill(pid, signal)
        },
        isLive: @Sendable @escaping (pid_t) -> Bool = { pid in
            ProcessLiveness.isLiveNamedProcess(pid: pid, name: ProcessLiveness.daemonExecutableName)
        },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.termBudget = termBudget
        self.killBudget = killBudget
        self.pollInterval = pollInterval
        self.sendSignal = sendSignal
        self.isLive = isLive
        self.clock = clock
    }

    /// Signal the predecessor and wait for it to go.
    public func retire(predecessor: pid_t) async -> Outcome {
        guard isLive(predecessor) else { return .alreadyGone }

        handoverLogger.info("handover: sending SIGTERM to predecessor daemon \(predecessor, privacy: .public)")
        sendSignal(predecessor, SIGTERM)
        if await waitForExit(of: predecessor, budget: termBudget) {
            handoverLogger.info("handover: predecessor daemon \(predecessor, privacy: .public) exited after SIGTERM")
            return .exitedAfterTerm
        }

        handoverLogger.info("handover: predecessor daemon \(predecessor, privacy: .public) outlived the \(String(describing: self.termBudget), privacy: .public) SIGTERM budget — escalating to SIGKILL")
        sendSignal(predecessor, SIGKILL)
        if await waitForExit(of: predecessor, budget: killBudget) {
            handoverLogger.info("handover: predecessor daemon \(predecessor, privacy: .public) exited after SIGKILL")
            return .exitedAfterKill
        }

        handoverLogger.error("handover: predecessor daemon \(predecessor, privacy: .public) still alive after SIGKILL and \(String(describing: self.killBudget), privacy: .public) — the successor must not start alongside it")
        return .stillAlive
    }

    /// True once `pid` is no longer a live daemon, false if the budget runs out
    /// first.
    private func waitForExit(of pid: pid_t, budget: Duration) async -> Bool {
        for _ in 0..<Self.pollCount(budget: budget, interval: pollInterval) {
            try? await clock.sleep(for: pollInterval)
            if !isLive(pid) { return true }
        }
        return false
    }

    /// How many polls fit in a budget, floored, never fewer than one.
    static func pollCount(budget: Duration, interval: Duration) -> Int {
        let attos = { (duration: Duration) -> Double in
            Double(duration.components.seconds) * 1e18 + Double(duration.components.attoseconds)
        }
        let intervalAttos = attos(interval)
        guard intervalAttos > 0 else { return 1 }
        return max(1, Int((attos(budget) / intervalAttos).rounded(.down)))
    }
}
