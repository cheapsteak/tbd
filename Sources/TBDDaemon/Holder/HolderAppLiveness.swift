import Foundation
import os

/// What the daemon has established about the app that was on the other end of a
/// sidecar connection.
///
/// Three values, and only one of them licenses the daemon to read a pty again.
/// Each carries the reason it reached, because the whole risk on this path is a
/// seizure — or a stall — nobody can explain afterwards.
enum AppLivenessVerdict: Sendable, Equatable {
    /// The recorded pid still names that same process. It is holding its
    /// `dup`s and may be reading them right now.
    case alive
    /// The recorded pid names nothing, or names a stranger. Its descriptors
    /// closed with it, so nothing it held can still be read by it.
    ///
    /// That implication is exact for the first case and holds for the second
    /// only under one qualification, which `execve` breaks: an exec preserves
    /// the pid *and* the start time while replacing the command line, and it
    /// does not close descriptors that lack `FD_CLOEXEC`. An app that exec'd
    /// itself in place, and whose sidecar connection had also dropped, would
    /// therefore be read as `pid-reused-executable` and have its sessions
    /// seized while its `dup`s were still live and readable. Left as it is
    /// because a macOS GUI app does not re-exec itself in place — but the whole
    /// design rests on "confirmed gone ⟹ descriptors closed", so the one shape
    /// that would falsify it is named here rather than left to be rediscovered.
    case confirmedGone(reason: String)
    /// Something could not be read. **Not** death: the failure direction on
    /// this path is always toward reading nothing until liveness says
    /// otherwise, so this is handled exactly as `alive` is.
    case undetermined(reason: String)

    /// Whether this verdict licenses taking sessions back from the app.
    var licensesSeizure: Bool {
        if case .confirmedGone = self { return true }
        return false
    }
}

/// Decides whether the app that owned a sidecar connection is gone.
///
/// **A sidecar disconnect is not death.** The sidecar reconnects — that is a
/// designed path, not a hope — so a socket drop can leave the app alive,
/// holding its `dup`s and still reading them. Seizing then puts the daemon's
/// drain on a pty another process is reading, which is the double-reader byte
/// theft this whole transport exists to prevent and the one failure it cannot
/// recover from.
///
/// So the drop is not the evidence. The evidence is the recorded identity of
/// the process that connected, re-verified through `ProcessIdentityCheck` —
/// **the same check `AgentReaper`'s holder leg uses before it signals
/// anything**, for the same reason: a pid the kernel has handed to somebody
/// else would otherwise report a dead app as running, and every session that
/// app was holding would stay unread, unwritable and un-reopenable for as long
/// as the stranger lives.
///
/// The tolerance is zero, and that differs from the reaper's five-minute window
/// deliberately. The reaper anchors on a session row's `createdAt`, which is a
/// *proxy* for when its job started; this anchors on the app's own start time,
/// read from the kernel at the moment the connection was adopted. When the
/// recorded fact is the fact itself, anything but equality is a different
/// process.
struct AppLivenessArbiter: Sendable {
    let signaller: any ProcessSignaller

    init(signaller: any ProcessSignaller) {
        self.signaller = signaller
    }

    /// The verdict for one recorded identity, or `undetermined` when there is
    /// none — an unidentified peer names no pid to ask about, and must never
    /// license a seizure.
    func verdict(for identity: ProcessIdentity?) -> AppLivenessVerdict {
        guard let identity else { return .undetermined(reason: "identity-unrecorded") }
        switch ProcessIdentityCheck.verify(
            pid: identity.pid,
            startedWithin: 0,
            of: identity.startedAt,
            executableIsAcceptable: { $0 == identity.commandLine },
            signaller: signaller
        ) {
        case .same:
            return .alive
        case .notRunning:
            return .confirmedGone(reason: "process-gone")
        case .startTimeMismatch:
            return .confirmedGone(reason: "pid-reused-start-time")
        case .foreignExecutable:
            return .confirmedGone(reason: "pid-reused-executable")
        case .startTimeUnreadable:
            return .undetermined(reason: "start-time-unreadable")
        case .commandUnreadable:
            return .undetermined(reason: "command-unreadable")
        }
    }
}

/// How one sidecar disconnect's arbitration ended, and what it ended on.
///
/// Returned rather than merely logged because it is the thing under test: "the
/// daemon stayed off the descriptors" and "the daemon never noticed the drop"
/// are the same absence of action from outside, and only one of them is
/// correct.
struct SidecarDisconnectRuling: Sendable, Equatable {
    enum Ending: Sendable, Equatable {
        /// Confirmed gone: the sessions that app held were taken back.
        case seized
        /// The same app is connected to the sidecar again. It is alive, and
        /// the next drop of that connection is arbitrated from the start.
        case reconnected
        /// The app holds no session, so its death would license nothing.
        case holdsNothing
        /// The connection's peer was never identified. There is no process to
        /// ask about, and no viewer claim names an unidentified app.
        case unidentified
        /// The re-check schedule ran out with the app still not confirmed
        /// gone. Its claims stand.
        case recheckBudgetSpent
        /// The task running the arbitration was cancelled. Its claims stand.
        case abandoned
    }

    let ending: Ending
    /// The last liveness verdict reached — the one the ending rests on.
    let verdict: AppLivenessVerdict
    /// How many liveness verdicts were reached, the first one included.
    let checks: Int
    /// The sessions taken back; empty unless `ending` is `.seized`.
    let reclaimed: [UUID]
}

/// The arbitration itself: what the daemon does when the app's sidecar
/// connection goes away.
///
/// It is a value with seams rather than a method on the daemon so that the
/// decision — which is the whole of this task — can be stated and tested
/// without a pty, a holder, a process to kill, or a wall clock. `reclaim` is
/// the action a confirmed death licenses, and nothing else in this type may
/// take it.
///
/// **One look is not enough, so it keeps looking.** The socket closes when the
/// app's descriptors do, and a process closes its descriptors on its way out,
/// before it has finished exiting and been reaped. So at the instant of the
/// disconnect an app that is dying can still answer `kill(pid, 0)`, and the
/// first verdict is `.alive` — or `.undetermined`, when `ps` catches it
/// mid-teardown. A verdict nobody asks again holds that app's sessions for the
/// daemon's whole life: undrained, unwritable, and refused to every attach,
/// a successor app's included. So a verdict short of death is re-checked on
/// `recheckDelays` until one of these settles it:
///
///   - **death is confirmed** — the sessions *that* app held, and only those,
///     are taken back (`HolderRegistry.reclaimSessions(heldBy:)` says why the
///     scoping is the whole safety of a late verdict);
///   - **the same app is connected again** — it is alive, and the next drop of
///     that connection starts its own arbitration;
///   - **the app holds nothing** — its claims were handed back, so its death
///     would license nothing, and it cannot come to hold more without a
///     connection whose own drop is arbitrated;
///   - **the schedule runs out** — the claims stand, which is the fail-closed
///     direction, and the ruling says so at error level.
///
/// `.undetermined` is re-checked exactly as `.alive` is and never seizes: the
/// failure direction on this path is always toward reading nothing until
/// liveness says otherwise.
///
/// Every ruling is logged at `.notice` or above, so it is persisted in the
/// unified log. The verdict is the one fact a stalled session needs explained
/// after the fact, and an info-level line is gone by the time anybody asks.
struct SidecarDisconnectArbiter: Sendable {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    /// The delays between re-checks of an app that was not confirmed gone at
    /// its disconnect: doubling from 250 ms to a one-minute ceiling, then once
    /// a minute, for an hour in all — 66 re-checks after the first verdict.
    ///
    /// **The front of the schedule is for an app that is exiting.** It has
    /// already closed its descriptors — that is what the disconnect was — so
    /// what is left of its exit is a moment of teardown and its parent's reap.
    /// A first re-check at 250 ms, and four of them inside four seconds,
    /// resolve that case before a user reopening a tab is likely to notice.
    ///
    /// **The back of it is for an app that is alive.** Each check runs `ps`
    /// twice (start time, then command line), so the interval backs off to one
    /// check a minute, which stays cheap however long the watch lasts.
    ///
    /// **The hour bounds the watch, not its cost.** An alive app's sidecar
    /// reconnects within seconds by design, and an app that hands its tabs back
    /// holds nothing; either ends the watch long before the hour. An app that
    /// has done neither for an hour is wedged rather than reconnecting, and its
    /// claims then stand — fail-closed — with an error naming how many. The
    /// bound exists so that every arbitration ends: each disconnect starts one,
    /// and nothing else would stop it.
    static let defaultRecheckDelays: [Duration] = doublingSchedule(
        startingAt: .milliseconds(250), ceiling: .seconds(60), budget: .seconds(3600))

    /// A schedule that doubles from `first` up to `ceiling` and stops before
    /// the delays would add up to more than `budget`. Empty unless both are
    /// positive: a delay that never grows the total would never reach the
    /// budget either.
    static func doublingSchedule(
        startingAt first: Duration, ceiling: Duration, budget: Duration
    ) -> [Duration] {
        guard first > .zero, ceiling > .zero else { return [] }
        var delays: [Duration] = []
        var next = first
        var total: Duration = .zero
        while total + next <= budget {
            delays.append(next)
            total += next
            next = min(next * 2, ceiling)
        }
        return delays
    }

    let liveness: AppLivenessArbiter
    /// Reverts the sessions `app` was holding — and only those — to
    /// daemon-read, and answers with the ones it took back. Called **only** on
    /// a confirmed death.
    let reclaim: @Sendable (ProcessIdentity) async -> [UUID]
    /// How many sessions `app` holds a descriptor for. Zero ends the watch.
    let sessionsHeld: @Sendable (ProcessIdentity) async -> Int
    /// The app connected to the sidecar right now, if any. The same identity
    /// here ends the watch: that app is alive, and connected again.
    let connectedApp: @Sendable () async -> ProcessIdentity?
    /// See `defaultRecheckDelays`. Empty means a single verdict and no watch.
    let recheckDelays: [Duration]
    /// Delay seam: existential, not generic, so the arbiter stays a plain
    /// `Sendable` value.
    private let clock: any Clock<Duration>

    init(
        liveness: AppLivenessArbiter,
        reclaim: @escaping @Sendable (ProcessIdentity) async -> [UUID],
        sessionsHeld: @escaping @Sendable (ProcessIdentity) async -> Int,
        connectedApp: @escaping @Sendable () async -> ProcessIdentity?,
        recheckDelays: [Duration] = SidecarDisconnectArbiter.defaultRecheckDelays,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.liveness = liveness
        self.reclaim = reclaim
        self.sessionsHeld = sessionsHeld
        self.connectedApp = connectedApp
        self.recheckDelays = recheckDelays
        self.clock = clock
    }

    /// Arbitrates one disconnect, re-checking a verdict short of death until
    /// something settles it, and answers how it ended.
    ///
    /// The order inside each round is the argument. The verdict comes first,
    /// so a death is acted on whatever else is true — and a dead app is
    /// remembered by the reclaim even when it held nothing at that instant,
    /// which is what catches a delivery to it recorded a moment later. Only a
    /// verdict short of death goes on to ask whether the watch is still needed.
    @discardableResult
    func handleDisconnect(identity: ProcessIdentity?) async -> SidecarDisconnectRuling {
        guard let identity else {
            let verdict = liveness.verdict(for: nil)
            Self.logger.notice(
                """
                the app's sidecar connection dropped and its peer was never identified \
                (\(String(describing: verdict), privacy: .public)); no viewer claim names an \
                unidentified app, so nothing is taken back
                """)
            return SidecarDisconnectRuling(
                ending: .unidentified, verdict: verdict, checks: 1, reclaimed: [])
        }
        var verdict = liveness.verdict(for: identity)
        var checks = 1
        var delays = recheckDelays.makeIterator()
        while true {
            if verdict.licensesSeizure {
                let reclaimed = await reclaim(identity)
                Self.logger.notice(
                    """
                    app pid \(identity.pid, privacy: .public) is confirmed gone \
                    (\(String(describing: verdict), privacy: .public)) after \
                    \(checks, privacy: .public) check(s) since its sidecar connection dropped; \
                    took back \(reclaimed.count, privacy: .public) session(s) it held
                    """)
                return SidecarDisconnectRuling(
                    ending: .seized, verdict: verdict, checks: checks, reclaimed: reclaimed)
            }
            let held = await sessionsHeld(identity)
            if await connectedApp() == identity {
                Self.logger.notice(
                    """
                    app pid \(identity.pid, privacy: .public) is connected to the sidecar again \
                    (\(String(describing: verdict), privacy: .public) after \
                    \(checks, privacy: .public) check(s)); its \(held, privacy: .public) \
                    session(s) stay with it, and its next disconnect is arbitrated afresh
                    """)
                return SidecarDisconnectRuling(
                    ending: .reconnected, verdict: verdict, checks: checks, reclaimed: [])
            }
            if held == 0 {
                Self.logger.notice(
                    """
                    app pid \(identity.pid, privacy: .public) holds no session \
                    (\(String(describing: verdict), privacy: .public) after \
                    \(checks, privacy: .public) check(s)); nothing to take back, and nothing to \
                    watch it for
                    """)
                return SidecarDisconnectRuling(
                    ending: .holdsNothing, verdict: verdict, checks: checks, reclaimed: [])
            }
            guard let delay = delays.next() else {
                Self.logger.error(
                    """
                    app pid \(identity.pid, privacy: .public) is still not confirmed gone \
                    (\(String(describing: verdict), privacy: .public)) after \
                    \(checks, privacy: .public) check(s), and has not reconnected; its \
                    \(held, privacy: .public) session(s) stay claimed and undrained until it \
                    detaches them or its next disconnect is arbitrated
                    """)
                return SidecarDisconnectRuling(
                    ending: .recheckBudgetSpent, verdict: verdict, checks: checks, reclaimed: [])
            }
            if checks == 1 {
                Self.logger.notice(
                    """
                    the app's sidecar connection dropped and app pid \
                    \(identity.pid, privacy: .public) is \
                    \(String(describing: verdict), privacy: .public), holding \
                    \(held, privacy: .public) session(s); the daemon stays off those ptys and \
                    re-checks until it is confirmed gone, reconnects, or holds nothing
                    """)
            }
            do {
                try await clock.sleep(for: delay)
            } catch {
                Self.logger.notice(
                    """
                    the watch on app pid \(identity.pid, privacy: .public) was cancelled after \
                    \(checks, privacy: .public) check(s) (\(String(describing: verdict), privacy: .public)); \
                    its \(held, privacy: .public) session(s) stay claimed
                    """)
                return SidecarDisconnectRuling(
                    ending: .abandoned, verdict: verdict, checks: checks, reclaimed: [])
            }
            verdict = liveness.verdict(for: identity)
            checks += 1
            Self.logger.debug(
                """
                re-check \(checks, privacy: .public) of app pid \(identity.pid, privacy: .public): \
                \(String(describing: verdict), privacy: .public)
                """)
        }
    }
}
