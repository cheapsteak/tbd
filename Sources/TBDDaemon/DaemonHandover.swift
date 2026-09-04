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
    ///
    /// **30 s is sized to `stop()`, and the alternative is what went wrong.**
    /// `restart.sh` sends the daemon `SIGTERM`, sleeps **0.5 s**, and then
    /// deletes the pid, socket and port files and starts the new daemon
    /// regardless of whether the old one has finished — so a shutdown that
    /// takes longer than half a second overlaps its successor and loses its own
    /// files out from under it. Half a second is not a budget, it is a hope.
    ///
    /// The real shutdown is a sequence of awaits: the usage pollers and the
    /// limit-resume scheduler stop, every holder reader is released one at a
    /// time (`HolderReader.defaultStopTimeout` is 5 s each), the deferred
    /// remote-backends boot task is cancelled and awaited, and both servers
    /// stop. Every one of those is itself bounded, so the whole is bounded —
    /// 30 s covers the ordinary case with room to spare, without being so long
    /// that a wedged predecessor holds an operator's update open for minutes.
    public let termBudget: Duration
    /// How long to wait after `SIGKILL` before giving up.
    ///
    /// `SIGKILL` cannot be caught, blocked or ignored, so this is not a second
    /// grace period — there is no cleanup left to run. The only reason a pid
    /// outlives it is an uninterruptible wait in the kernel, and 5 s is long
    /// enough to tell that apart from the microseconds an ordinary teardown
    /// takes. A pid still there afterwards is `Outcome.stillAlive`, which
    /// `Daemon.start()` treats as a reason not to start at all.
    public let killBudget: Duration
    /// Gap between liveness checks.
    ///
    /// The successor cannot bind until the predecessor is gone, so every
    /// millisecond of this interval is a millisecond the socket is missing and
    /// CLI calls fail. 100 ms keeps that tail short — a second-long poll would
    /// add up to a second of dead socket for nothing — while 300 `kill(pid, 0)`
    /// probes across the whole `SIGTERM` budget is far too little work to be
    /// worth calling busy-polling.
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

/// The pid-file choreography of a handover: claim, retire, re-assert.
///
/// Extracted from `Daemon.start()` so the sequence is reachable from a test.
/// The branch it replaces sat between the single-instance gate and the socket
/// bind, hundreds of lines apart, and could only be exercised by hand.
public struct HandoverClaim: Sendable {
    private let handover: DaemonHandover
    private let ownPID: pid_t
    /// How a claim is written. Defaults to the pid file itself.
    ///
    /// A seam rather than a direct call, because the retry below is only
    /// interesting when a write fails and a later one succeeds, and contriving
    /// a filesystem that breaks on that schedule is far less honest than
    /// injecting the failure. Every write in this type goes through it, so the
    /// default path is the one the tests exercise everywhere else.
    private let writeClaim: @Sendable (pid_t) throws -> Void

    /// How many times to try handing the claim back before giving up.
    private let writeBackAttempts: Int
    /// Gap between those attempts.
    private let writeBackRetryDelay: Duration
    private let clock: any Clock<Duration>

    /// What the caller should do next.
    public enum Result: Equatable, Sendable {
        /// The predecessor is gone and the pid file names us. Carry on.
        case claimed(DaemonHandover.Outcome)
        /// The predecessor outlived `SIGKILL`. The caller must not start.
        ///
        /// `claimRestored` says whether the predecessor's pid made it back into
        /// the file. It is a value rather than only a log line because it is the
        /// difference between leaving the world as it was found and leaving a
        /// file naming a pid that is about to die — the caller decides how
        /// loudly to say so, and a test can assert it.
        case predecessorSurvived(claimRestored: Bool)
    }

    public init(
        pidFile: PIDFile,
        handover: DaemonHandover = DaemonHandover(),
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        writeBackAttempts: Int = 3,
        writeBackRetryDelay: Duration = .milliseconds(100),
        clock: any Clock<Duration> = ContinuousClock(),
        writeClaim: (@Sendable (pid_t) throws -> Void)? = nil
    ) {
        self.handover = handover
        self.ownPID = ownPID
        self.writeBackAttempts = max(1, writeBackAttempts)
        self.writeBackRetryDelay = writeBackRetryDelay
        self.clock = clock
        self.writeClaim = writeClaim ?? { try pidFile.write(pid: $0) }
    }

    public func takeOver(from predecessor: pid_t) async throws -> Result {
        // Claim first. With our pid in the file from this instant, every
        // spurious spawn during the retirement — the app's two-second poller,
        // a stray `restart.sh` — meets a file naming a live daemon and exits at
        // the same gate we just came through.
        try writeClaim(ownPID)
        handoverLogger.info("handover: claimed the pid file from predecessor daemon \(predecessor, privacy: .public); retiring it now")

        let outcome = await handover.retire(predecessor: predecessor)
        if outcome == .stillAlive {
            // Hand the claim back so the world is exactly as it was found: the
            // file names the live predecessor, and nothing treats the daemon
            // that is still serving as absent. Retried, because the write is a
            // whole-file replace that a transient filesystem error can lose.
            return .predecessorSurvived(claimRestored: await restoreClaim(to: predecessor))
        }

        // Re-assert the claim, because the predecessor may have deleted it on
        // the way out.
        //
        // **This is for predecessors older than this change.** Their `stop()`
        // ends with an unconditional `pidFile.remove()`, so a daemon built
        // before `removeIfOwned` existed deletes OUR pid file as it exits — and
        // the very first update on any machine is, by definition, handing over
        // from exactly such a daemon. What follows is the failure the claim was
        // supposed to prevent: no socket and no live pid, so the app's
        // two-second poller spawns a daemon, which passes the gate because
        // nothing owns the file, and now there are two successors. For a
        // predecessor that carries `removeIfOwned` this write changes nothing —
        // the file already names us — which is what makes it safe to do
        // unconditionally rather than probe the predecessor's vintage.
        //
        // A third daemon could in principle claim the file between the
        // predecessor's unlink and this write and have its claim overwritten
        // here. That window is the retirement poll interval at most, against
        // the app's two-second poll, and it is strictly narrower than the one
        // this write closes.
        //
        // Retried like the hand-back, for the same reason: a whole-file
        // replace that a transient error can lose, and here the predecessor is
        // already dead, so one hiccup would otherwise turn a finished handover
        // into an aborted start. If every attempt fails the start still
        // aborts, because proceeding with a file that may name nobody is the
        // two-successor race this write exists to close; the exit leaves a
        // stale or missing pid file, which the app's poller answers by
        // starting a fresh daemon from the installed bundle.
        guard await writeClaimRetrying(ownPID, purpose: "re-assert this daemon's") else {
            throw ReassertFailed(pid: ownPID, attempts: writeBackAttempts)
        }
        return .claimed(outcome)
    }

    /// The re-assert after a successful retirement could not be written.
    public struct ReassertFailed: LocalizedError, CustomStringConvertible, Sendable {
        public let pid: pid_t
        public let attempts: Int
        public var description: String {
            "handover: could not re-assert the pid file claim for \(pid) after \(attempts) attempts"
        }
        public var errorDescription: String? { description }
    }

    /// Write `pid` into the file, retrying `writeBackAttempts` times with
    /// `writeBackRetryDelay` between attempts. Returns whether a write landed.
    private func writeClaimRetrying(_ pid: pid_t, purpose: String) async -> Bool {
        for attempt in 1...writeBackAttempts {
            do {
                try writeClaim(pid)
                return true
            } catch {
                handoverLogger.error("handover: attempt \(attempt, privacy: .public) of \(self.writeBackAttempts, privacy: .public) to \(purpose, privacy: .public) pid file claim (\(pid, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
                if attempt < writeBackAttempts {
                    try? await clock.sleep(for: writeBackRetryDelay)
                }
            }
        }
        return false
    }

    /// Put the predecessor's pid back in the file, retrying a few times.
    ///
    /// **Failing to restore it is not a two-writer hazard, and it is worth
    /// saying why rather than leaving it to be re-derived.** This path is only
    /// reached when the predecessor outlived `SIGKILL`, and `SIGKILL` cannot be
    /// caught, blocked or ignored — a pid still present five seconds after it is
    /// in an uninterruptible kernel wait, not serving RPCs. Meanwhile this
    /// process is about to exit. So the worst case is a pid file naming a pid
    /// that is dead or dying, which is exactly the stale-pid case the rest of
    /// the system already reconciles: `PIDFile.cleanupIfStale` removes a file
    /// whose pid is not a live `TBDDaemon` (called at the top of
    /// `Daemon.start()`), and the app's poller spawns a fresh daemon from the
    /// installed bundle whenever the pid file names no live daemon
    /// (`startDaemonAndConnect` in `Sources/TBDApp/AppState.swift`). The cost of
    /// the failure is a delayed recovery, not a corrupted one.
    ///
    /// Returns whether the claim was restored.
    private func restoreClaim(to predecessor: pid_t) async -> Bool {
        if await writeClaimRetrying(predecessor, purpose: "restore the predecessor's") {
            return true
        }
        handoverLogger.error("handover: could not restore predecessor daemon \(predecessor, privacy: .public)'s pid file claim after \(self.writeBackAttempts, privacy: .public) attempts — the file now names this exiting process, which reads as a stale pid and is cleaned up by the next daemon start")
        return false
    }
}
