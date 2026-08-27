import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "TmuxServerProcessProbe")

/// One short-lived memo of the machine-global "is any tmux server running for
/// this uid?" reading, with concurrent askers collapsed onto a single in-flight
/// reading.
///
/// **The answer is a fact about the machine, not about a server.**
/// `TmuxManager.serverPresence` consults the process table only after a
/// `list-sessions` that did not answer, and what it asks there is deliberately
/// name-agnostic — see `TmuxManager.tmuxServerProcessesExist` for why keying on
/// `-L <name>` would assume the very name-to-socket resolution the probe exists
/// to doubt. So N unanswered servers in one sweep is one question asked N
/// times, and each asking is a `/bin/ps -axww` over every process on the box,
/// bounded at 60 seconds and subject to no concurrency limit of its own. The
/// post-reboot sweep — where every server is unanswered at once, and which is
/// the whole reason the probe exists — is precisely when that multiplies.
///
/// Two collapses, covering different shapes of the same waste:
///
/// - **In flight.** An asker that arrives while a reading is being taken awaits
///   that reading rather than spawning a second `ps` beside it. This is the arm
///   that matters under a sweep, where the askers arrive together.
/// - **Just taken.** An asker that arrives within `freshness` of a completed
///   reading reuses it.
///
/// **Why the window is short, and why the residual risk is closed.** The only
/// verdict this probe licenses is `.absent`, which is what lets reconcile park
/// sessions and delete rows, so a memo that outlived the truth of "no tmux
/// anywhere" would reclaim rows on a machine where tmux had since come back.
/// For a stale "no tmux processes" to cause harm, ALL of these would have to
/// hold at once: a tmux server is running, a terminal row points at a window on
/// it, `list-sessions` for that row's server name still fails, and that server
/// started within the last `freshness` seconds. A row pointing at a server that
/// young was created by TBD's own `ensureServer` moments earlier, resolving the
/// same name the same way in the same process — so its `list-sessions` answers
/// and the probe is never reached for it. `freshness` is nonetheless kept an
/// order of magnitude below the interval between reclaiming sweeps
/// (`AgentReaper` at 60 s, `OrphanGC` hourly), so nothing is ever carried from
/// one sweep into the next.
///
/// **The stamp is taken when the reading LANDS, not when it was asked for.** A
/// `ps` that took 40 seconds to come back describes a machine 40 seconds ago;
/// measuring the window from the request would hand that reading a full
/// `freshness` of additional life on top of however long it was in the air.
///
/// `now` is the date seam (`CLAUDE.md`: `Duration` is behavior, `Date` is
/// data). This type never sleeps, debounces or times out — it stamps a reading
/// and compares stamps — so it takes a date source rather than a clock.
actor TmuxServerProcessProbeCache {
    /// How long a completed reading may stand in for a fresh one.
    ///
    /// Sized to cover one sweep of a machine whose servers are all gone (where
    /// `list-sessions` fails immediately rather than burning its 15 s timeout),
    /// and to expire many times over between the sweeps that could act on it.
    static let freshness: TimeInterval = 10

    /// A completed reading and when it landed.
    ///
    /// `answer` carries the probe's own optional: `nil` means *the reading could
    /// not be taken*, which `TmuxManager` maps to `.unreachable` and which is
    /// never evidence of absence. A failed reading is memoized like any other —
    /// re-running a `ps` that just failed is no more likely to answer, and the
    /// verdict it produces protects rows either way.
    private struct Reading {
        let answer: Bool?
        let takenAt: Date
    }

    private let now: @Sendable () -> Date
    private var last: Reading?
    private var inFlight: Task<Bool?, Never>?

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// The current reading, taking a fresh one with `take` only when neither
    /// collapse above applies.
    func reading(taking take: @escaping @Sendable () async -> Bool?) async -> Bool? {
        if let last {
            let age = now().timeIntervalSince(last.takenAt)
            if age < Self.freshness {
                logger.debug(
                    "tmux server process probe: reusing a reading \(age, privacy: .public)s old")
                return last.answer
            }
        }
        if let inFlight {
            logger.debug("tmux server process probe: joining the reading already in flight")
            return await inFlight.value
        }

        // Detached so that one asker's cancellation cannot cancel a reading
        // every other asker is waiting on, and so the reading does not inherit
        // whatever priority the first asker happened to have.
        let pending = Task.detached { await take() }
        inFlight = pending
        let answer = await pending.value
        // Only the task still holding the slot may clear it: a newer reading
        // may already have replaced this one while this one was in the air.
        if inFlight == pending { inFlight = nil }
        last = Reading(answer: answer, takenAt: now())
        return answer
    }
}
