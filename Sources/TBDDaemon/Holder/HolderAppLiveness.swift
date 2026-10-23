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

    /// `verdict(for:)`, reached on a GCD thread rather than on the caller's
    /// executor.
    ///
    /// A verdict spawns `ps` twice and waits for both. Run inline on an actor,
    /// that holds the actor for both spawns — every other call into it queues
    /// behind the check, including ones that need no check at all — and pins
    /// one of the cooperative pool's few threads while it waits. So the check
    /// runs on a GCD thread, the discipline `TmuxControlSupervisor.stopAll`
    /// follows for its blocking `stop()`s, and the caller suspends until it
    /// answers. An actor awaiting this is free for the whole check, so
    /// anything it read before the `await` may have changed by the time the
    /// verdict arrives.
    func verdictOffThePool(for identity: ProcessIdentity?) async -> AppLivenessVerdict {
        await withCheckedContinuation { (continuation: CheckedContinuation<AppLivenessVerdict, Never>) in
            // `.userInitiated`, not `.utility`: utility work is throttled onto the efficiency cores under load.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.verdict(for: identity))
            }
        }
    }
}

/// How one sidecar departure's arbitration ended, and what it ended on.
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
        /// The app holds no session and has none on its way to it, so its
        /// death would license nothing.
        case holdsNothing
        /// The connection's peer was never identified. There is no process to
        /// ask about, and no viewer claim names an unidentified app.
        case unidentified
        /// The same app is already being watched, and that watch takes this
        /// departure over: it answers it at its next re-check — starting its
        /// schedule over from the front, unless it already did so less than
        /// one ceiling ago — and ends on nothing it read before this
        /// departure was reported.
        case absorbed
        /// The task running the arbitration was cancelled while its watch
        /// slept. Its claims stand.
        ///
        /// Production never ends this way: the daemon starts each arbitration
        /// in an unstructured `Task` and never cancels it, so a watch runs
        /// until one of the endings above ends it or the process exits.
        /// Cancellation exists for tests, which end a watch once they have
        /// observed what they came for.
        case abandoned
    }

    let ending: Ending
    /// The last liveness verdict reached — the one the ending rests on. Nil
    /// only for `.absorbed`, which leaves every verdict to the watch already
    /// running.
    let verdict: AppLivenessVerdict?
    /// How many liveness verdicts were reached, the first one included. Zero
    /// for `.absorbed`.
    let checks: Int
    /// The sessions taken back; empty unless `ending` is `.seized`.
    let reclaimed: [UUID]
}

/// The arbitration itself: what the daemon does when an app's sidecar
/// connection goes away.
///
/// It is an actor with seams rather than a method on the daemon so that the
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
/// a successor app's included. So a verdict short of death starts a **watch**
/// that re-checks on `recheckSchedule` until one of these ends it:
///
///   - **death is confirmed** — the sessions *that* app held, and only those,
///     are taken back (`HolderRegistry.reclaimSessions(heldBy:)` says why the
///     scoping is the whole safety of a late verdict);
///   - **the same app is connected again** — it is alive, and the next drop of
///     that connection is reported and arbitrated in its turn;
///   - **the app holds nothing** — no claim names it and no vended attach can
///     still turn out to be its (`HolderRegistry.sessionsHeld(by:)`), so its
///     death would license nothing, and it cannot come to hold more without a
///     connection whose own drop is reported.
///
/// **Nothing else ends a watch — time least of all.** An app can stay alive
/// and disconnected for as long as it runs: two app instances take the
/// sidecar from each other, or an app reconnects under an identity the daemon
/// could not read. Its claims rightly stand while it lives, and the watch is
/// what takes them back when it finally quits; a watch that gave up after a
/// budget would leave them claimed for the daemon's whole life, with nothing
/// left to arbitrate them. The schedule's ceiling bounds what a long watch
/// costs instead.
///
/// **At most one watch per app.** A departure of an app that is already being
/// watched is absorbed by that watch rather than starting a second beside it,
/// which would double the `ps` load and race it to the same take-back. The
/// absorbed departure is not lost: the watch answers it at its next re-check —
/// at most one ceiling away — and starts its schedule over from the front if
/// it has not already done so within the last ceiling
/// (`RecheckSchedule.mayRestart(afterSleeping:)` says why that is limited),
/// and it ends on a reconnect or on "holds nothing" only if no departure of
/// that app was reported after it read the state that ending rests on (see
/// `watch(_:)`).
///
/// **The check runs off the actor.** Each verdict waits on two `ps` spawns,
/// and it is awaited through `AppLivenessArbiter.verdictOffThePool(for:)`, so
/// the actor holds only bookkeeping: a departure absorbed while a check is
/// running is counted at once rather than queued behind it, and no
/// cooperative-pool thread waits on `ps`.
///
/// `.undetermined` is re-checked exactly as `.alive` is and never seizes: the
/// failure direction on this path is always toward reading nothing until
/// liveness says otherwise.
///
/// Every ruling is logged at `.notice`, so it is persisted in the unified log.
/// The verdict is the one fact a stalled session needs explained after the
/// fact, and an info-level line is gone by the time anybody asks.
actor SidecarDisconnectArbiter {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    /// How a watch spaces its re-checks: doubling from `first` up to
    /// `ceiling`, then once per `ceiling` for as long as the watch lasts.
    /// There is no last delay; the arbiter's doc says why time ends nothing.
    struct RecheckSchedule: Sendable, Equatable {
        let first: Duration
        let ceiling: Duration

        init(first: Duration, ceiling: Duration) {
            precondition(first > .zero, "a re-check schedule must wait between its checks")
            self.first = first
            self.ceiling = max(first, ceiling)
        }

        /// The delay that follows `previous`.
        func delay(after previous: Duration) -> Duration {
            min(previous * 2, ceiling)
        }

        /// Whether a departure the watch absorbed may start the schedule over
        /// from `first`, given how long the watch has slept since the schedule
        /// last started there: only once that is a full `ceiling`.
        ///
        /// **The front is for a departure that may be an exit**, so an
        /// absorbed departure earns it — but an app that keeps dropping and
        /// reconnecting, or two app instances taking the sidecar from each
        /// other, report departures as fast as they churn, and a front
        /// restarted by every one of them would keep a watch on a live app at
        /// four checks a second for as long as the churn lasts. Limited to one
        /// restart per `ceiling` of the watch's own sleep, a watch runs at most
        /// one front per that interval however often its app departs: eight
        /// checks in about a minute with the default numbers, where a restart
        /// on every departure could cost 240. A departure inside the window is
        /// not dropped: the progression already under way answers it at its
        /// next re-check, so an exit there is still caught, at most one ceiling
        /// later.
        ///
        /// Measured in the watch's own sleep rather than read off the clock:
        /// the injected clock is an existential, which offers no instant
        /// arithmetic, and a watch's time is nearly all sleep — a check takes
        /// milliseconds.
        func mayRestart(afterSleeping slept: Duration) -> Bool {
            slept >= ceiling
        }
    }

    /// Doubling from 250 ms to a one-minute ceiling, then once a minute.
    ///
    /// **The front of the schedule is for an app that is exiting.** It has
    /// already closed its descriptors — that is what the disconnect was — so
    /// what is left of its exit is a moment of teardown and its parent's reap.
    /// A first re-check at 250 ms, and four of them inside four seconds,
    /// resolve that case before a user reopening a tab is likely to notice.
    ///
    /// **The back of it is for an app that is alive.** Each check runs `ps`
    /// twice (start time, then command line), so the interval backs off to one
    /// check a minute, which stays cheap however long the watch lasts — and a
    /// watch on an app that stays alive and disconnected lasts until it quits.
    /// The ceiling is also how long, at most, that app's death goes unnoticed.
    ///
    /// **And the front comes round again at most once a minute.** A departure
    /// absorbed into a running watch restarts it only once a full ceiling has
    /// passed since it last did (`RecheckSchedule.mayRestart(afterSleeping:)`),
    /// so an app that departs over and over costs one front a minute rather
    /// than four checks a second.
    static let defaultRecheckSchedule = RecheckSchedule(
        first: .milliseconds(250), ceiling: .seconds(60))

    let liveness: AppLivenessArbiter
    /// Reverts the sessions `app` was holding — and only those — to
    /// daemon-read, and answers with the ones it took back. Called **only** on
    /// a confirmed death.
    let reclaim: @Sendable (ProcessIdentity) async -> [UUID]
    /// How many sessions `app` holds a descriptor for, or may yet turn out to
    /// — `HolderRegistry.sessionsHeld(by:)` says which count. Zero ends the
    /// watch.
    let sessionsHeld: @Sendable (ProcessIdentity) async -> Int
    /// The app connected to the sidecar right now, if any. The same identity
    /// here ends the watch: that app is alive, and connected again.
    let connectedApp: @Sendable () async -> ProcessIdentity?
    /// See `defaultRecheckSchedule`.
    let recheckSchedule: RecheckSchedule
    /// Delay seam: existential, not generic, so the arbiter's type carries no
    /// clock parameter.
    private let clock: any Clock<Duration>

    /// The apps being watched, and how many departures each has reported
    /// since its watch began — the one that started it included.
    ///
    /// An entry is a watch's hold on its app: a departure that finds one is
    /// absorbed, and the watch removes it on every way out, so the first
    /// departure after a watch ends starts a new one. The count is how a watch
    /// learns that a departure arrived while it was reading something else.
    private var departuresReported: [ProcessIdentity: Int] = [:]

    init(
        liveness: AppLivenessArbiter,
        reclaim: @escaping @Sendable (ProcessIdentity) async -> [UUID],
        sessionsHeld: @escaping @Sendable (ProcessIdentity) async -> Int,
        connectedApp: @escaping @Sendable () async -> ProcessIdentity?,
        recheckSchedule: RecheckSchedule = SidecarDisconnectArbiter.defaultRecheckSchedule,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.liveness = liveness
        self.reclaim = reclaim
        self.sessionsHeld = sessionsHeld
        self.connectedApp = connectedApp
        self.recheckSchedule = recheckSchedule
        self.clock = clock
    }

    /// Arbitrates one departure — a sidecar connection that dropped, or one a
    /// different app took over — and answers how it ended.
    ///
    /// A departure of an app already being watched returns at once, as
    /// `.absorbed`: the watch running for that app carries it. Any other
    /// returns when its own watch ends.
    ///
    /// An unidentified peer is ruled on the spot, with the synchronous
    /// verdict: there is no pid to ask about, so that verdict spawns nothing.
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
        if let reported = departuresReported[identity] {
            departuresReported[identity] = reported + 1
            Self.logger.notice(
                """
                app pid \(identity.pid, privacy: .public) left the sidecar again while its earlier \
                departure is still being watched; that watch takes this one over at its next \
                re-check, rather than a second watch running beside it
                """)
            return SidecarDisconnectRuling(
                ending: .absorbed, verdict: nil, checks: 0, reclaimed: [])
        }
        departuresReported[identity] = 1
        return await watch(identity)
    }

    /// One app's watch: a verdict now, then re-checks on `recheckSchedule`
    /// until a death, a reconnect, or holding nothing ends it.
    ///
    /// The order inside each round is the argument. The verdict comes first,
    /// so a death is acted on whatever else is true — and a dead app is
    /// remembered by the reclaim even when it held nothing at that instant,
    /// which is what catches a delivery to it recorded a moment later. Only a
    /// verdict short of death goes on to ask whether the watch is still needed.
    ///
    /// **Every suspension in a round lets a departure in**, the verdict's
    /// included: it is awaited off the actor, so the actor takes other calls
    /// for the whole check. That is why the round reads the departure count
    /// once, at its top and before its first suspension, and judges whether
    /// anything arrived since by comparing a fresh read against that one.
    ///
    /// **Ending on a reconnect or on "holds nothing" is conditional.** Both
    /// rest on state other actors own, read across suspensions, and a
    /// departure of this app reported meanwhile — the connection it came back
    /// on dropping, say, after it attached tabs over it — was absorbed on the
    /// strength of this watch going on. So the round ends the watch only if
    /// the departure count is still the one it read before asking anything,
    /// compared with no suspension between the comparison and the entry's
    /// removal; otherwise the watch goes on, and the next round reads the
    /// state that departure left. Ending on a death is unconditional: the
    /// take-back selects by identity, so it covers every connection that app
    /// ever had.
    ///
    /// **Every round that does not end sleeps before the next**, whatever
    /// kept it from ending, for the schedule's current delay. So a watch runs
    /// at most one check per scheduled delay however fast its app churns. A
    /// round that answers a departure restarts the schedule from the front
    /// only when `RecheckSchedule.mayRestart(afterSleeping:)` allows it, and
    /// otherwise keeps the progression it was on — so the front, too, comes
    /// round at most once per ceiling of sleep. The watch's own start is a
    /// front, so the window begins with the watch.
    private func watch(_ app: ProcessIdentity) async -> SidecarDisconnectRuling {
        // Every way out ends the watch, so the next departure starts a new
        // one. A `defer` runs at the return itself, with no suspension before
        // it, so nothing can be absorbed into a watch that has decided to end.
        defer { departuresReported[app] = nil }
        var checks = 0
        var departuresAnswered = 0
        var delay = recheckSchedule.first
        // How long the watch has slept since the schedule last started from
        // the front, capped at the ceiling — the only value the restart rule
        // compares it with.
        var sleptSinceFront: Duration = .zero
        var announced = false
        while true {
            // Read before anything this round decides on: a departure counted
            // after this line is one the round cannot have seen.
            let reported = departuresReported[app] ?? 0
            if reported != departuresAnswered {
                if departuresAnswered > 0 {
                    let pacing: String
                    if recheckSchedule.mayRestart(afterSleeping: sleptSinceFront) {
                        delay = recheckSchedule.first
                        sleptSinceFront = .zero
                        pacing = "re-checking from the front of the schedule"
                    } else {
                        pacing = """
                            keeping its current pacing, since the schedule last started from the \
                            front less than one ceiling ago
                            """
                    }
                    Self.logger.debug(
                        """
                        app pid \(app.pid, privacy: .public) left the sidecar again during its \
                        watch (\(reported, privacy: .public) departure(s) so far); \
                        \(pacing, privacy: .public)
                        """)
                }
                departuresAnswered = reported
            }
            let verdict = await liveness.verdictOffThePool(for: app)
            checks += 1
            if checks > 1 {
                Self.logger.debug(
                    """
                    re-check \(checks, privacy: .public) of app pid \(app.pid, privacy: .public): \
                    \(String(describing: verdict), privacy: .public)
                    """)
            }
            if verdict.licensesSeizure {
                let reclaimed = await reclaim(app)
                Self.logger.notice(
                    """
                    app pid \(app.pid, privacy: .public) is confirmed gone \
                    (\(String(describing: verdict), privacy: .public)) after \
                    \(checks, privacy: .public) check(s) since its sidecar connection dropped; \
                    took back \(reclaimed.count, privacy: .public) session(s) it held
                    """)
                return SidecarDisconnectRuling(
                    ending: .seized, verdict: verdict, checks: checks, reclaimed: reclaimed)
            }
            let held = await sessionsHeld(app)
            let reconnected = await connectedApp() == app
            let readAnEnding = reconnected || held == 0
            let departedSinceTheRoundBegan = (departuresReported[app] ?? 0) != departuresAnswered
            if readAnEnding, !departedSinceTheRoundBegan {
                if reconnected {
                    Self.logger.notice(
                        """
                        app pid \(app.pid, privacy: .public) is connected to the sidecar again \
                        (\(String(describing: verdict), privacy: .public) after \
                        \(checks, privacy: .public) check(s)); its \(held, privacy: .public) \
                        session(s) stay with it, and its next disconnect is arbitrated afresh
                        """)
                    return SidecarDisconnectRuling(
                        ending: .reconnected, verdict: verdict, checks: checks, reclaimed: [])
                }
                Self.logger.notice(
                    """
                    app pid \(app.pid, privacy: .public) holds no session \
                    (\(String(describing: verdict), privacy: .public) after \
                    \(checks, privacy: .public) check(s)); nothing to take back, and nothing to \
                    watch it for
                    """)
                return SidecarDisconnectRuling(
                    ending: .holdsNothing, verdict: verdict, checks: checks, reclaimed: [])
            }
            if readAnEnding {
                // A departure of this app arrived while the round read what it
                // would have ended on, so the watch goes on — and like every
                // round that does not end, this one sleeps first. Churn is
                // exactly what reaches this line: an app dropping and
                // reconnecting, or two instances taking the sidecar from each
                // other, report a departure inside nearly every round, and a
                // round that skipped its sleep for each would run its `ps` pair
                // back to back for as long as the churn lasts, past both the
                // backoff and `mayRestart`'s limit.
                let readAs = reconnected ? "connected again" : "holding nothing"
                Self.logger.debug(
                    """
                    app pid \(app.pid, privacy: .public) left the sidecar again while its watch \
                    read it as \(readAs, privacy: .public); the watch goes on, at its next \
                    scheduled re-check
                    """)
            }
            if !announced {
                announced = true
                Self.logger.notice(
                    """
                    the app's sidecar connection dropped and app pid \
                    \(app.pid, privacy: .public) is \
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
                    the watch on app pid \(app.pid, privacy: .public) was cancelled after \
                    \(checks, privacy: .public) check(s) (\(String(describing: verdict), privacy: .public)); \
                    its \(held, privacy: .public) session(s) stay claimed
                    """)
                return SidecarDisconnectRuling(
                    ending: .abandoned, verdict: verdict, checks: checks, reclaimed: [])
            }
            sleptSinceFront = min(sleptSinceFront + delay, recheckSchedule.ceiling)
            delay = recheckSchedule.delay(after: delay)
        }
    }
}
