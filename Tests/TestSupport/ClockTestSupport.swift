import Clocks
import Foundation
import Testing

// Shared clock seams for the test-hardening program
// (`docs/specs/2026-07-24-test-hardening-design.md` §5).
//
// §5's governing rule is **`Duration` is behavior, `Date` is data**: production
// types take `clock: any Clock<Duration> = ContinuousClock()` for delays,
// debounces, timers and deadlines, and a `now: @Sendable () -> Date` (or
// `date: Date = Date()`) parameter for timestamps that get persisted or
// compared. This file is the *only* place those two seams get test-side
// helpers. No slice should roll its own `TestClock` wrapper, advance helper, or
// mutable-clock date source — if something here is missing or wrong, change it
// here so all five consuming slices move together.

// MARK: - Hang guard

public extension Trait where Self == TimeLimitTrait {
    /// Suite/test trait for anything driven by a `TestClock`.
    ///
    /// The known failure mode of virtual time (§5, "Known failure mode") is
    /// that a tier-1 test awaiting a `TestClock` sleep nobody advances hangs
    /// **forever** — no assertion fails, no output appears, the whole `swift
    /// test` run just stops. That is far worse than a red test, because CI
    /// burns its job timeout and the failure names no suite.
    ///
    /// This bounds it. The value is not a performance budget — it is a
    /// hang-catcher, and Swift Testing expresses time limits in whole minutes,
    /// so the only dial available is an integer count of them. A clock-driven
    /// tier-1 test should still finish in milliseconds; if it takes minutes, it
    /// is wedged, and you want the failure attributed to the test rather than
    /// to the runner.
    ///
    /// **Why 4 and no longer 1.** The floor argument (whole minutes) says the
    /// limit cannot be *smaller* than a minute; it never argued that one minute
    /// was right. What pins the value from below are the two wall-clock waits a
    /// clock-driven test can sit on: this file's `waitForSuspension` (45 s,
    /// re-derived below) and `ciSafeDeadline` (90 s,
    /// `Tests/TBDDaemonTests/ControlModeTestSupport.swift`). Clock-driven
    /// suites really do consume the latter — `AttachRPCOrchestrationTests` and
    /// `PaneRepairCoordinatorTests` are both `.clockDriven, .serialized` and
    /// between them hold 44 `waitFor` call sites — so the two values race and
    /// must be derived together.
    ///
    /// The invariant is **not** "every chained wait in a test fits inside this
    /// limit". `waitFor` is non-throwing on timeout, so chains are real, and the
    /// deepest is 6 waits in one `PaneRepairCoordinator` test — unsatisfiable
    /// then (6 x 30 s vs `.minutes(1)`) and unsatisfiable now. The invariant is:
    /// **this limit must afford the first full deadline plus the rest of an
    /// ordinary test.** The first timeout's `Issue.record` fires immediately
    /// with its named diagnostic, so it survives even if this limit later
    /// truncates the test; chains beyond the first belong to a test that is
    /// already failing, and truncating those is deliberate.
    ///
    /// 4 minutes = 240 s satisfies that:
    /// - one `waitFor` (90 s) + one `waitForSuspension` (45 s) = 135 s ✓
    /// - two `waitFor` = 180 s ✓
    /// - two `waitForSuspension` = 90 s ✓ — this keeps the original "a test that
    ///   waits twice must afford both waits" property the one-minute pairing
    ///   was reasoned from
    ///
    /// 240 s stays far above any legitimate clock-driven run, which finishes in
    /// milliseconds.
    ///
    /// **The margin is thin, and it is worth naming how thin.** Do not read
    /// "240 s" as comfortable headroom — several existing chains sit near or
    /// past it, all consistent with the invariant (only an already-failing test
    /// ever pays a full chain of timeouts), but with nothing to spare:
    /// Count `advanceWhenSuspended` as a `waitForSuspension` when you tally a
    /// chain — it *calls* one before advancing, so it pays the full guard —
    /// and count each `EventDrivenTestClock.FireRecorder.next()` the same way.
    /// Grepping only for the literal `waitForSuspension(` undercounts every
    /// figure below, which is how a PR #547 reviewer read two of these chains
    /// as shallower than they are.
    /// - `PaneRepairCoordinatorTests.readerWaitEscalatesToTheSlowInterval` is
    ///   the deepest chain still riding this type's **non-throwing** pair: four
    ///   `advanceWhenSuspended` plus one `waitForSuspension`, five clock guards
    ///   for 225 s, and its two `waitFor` calls take the paper worst case to
    ///   405 s. Every guard there is payable in one run, because a miss records
    ///   and the chain keeps going.
    /// - The poller chains are nominally deeper still —
    ///   `GatedIntervalSleepTests.returnsAfterExpectedPollCount` pays six
    ///   guards (3 `requireAdvanceWhenArmed` + 2 `requireSleeperArmed` + 1
    ///   `FireRecorder.next()`) for 270 s, past this limit;
    ///   `GatedIntervalSleepTests.boundaryIsExact` and
    ///   `DaywatchRunnerLoopTests.testSubsequentTicksAtInterval` pay five for
    ///   225 s — but they are on `EventDrivenTestClock`'s strict waits, where a
    ///   missed arming throws before anything advances, so the chain stops at
    ///   the first bad step. Their one non-throwing guard, `next()`, sits last
    ///   with nothing behind it to inherit the run, so at most one 45 s guard
    ///   elapses in any single run and 270 s describes a run that cannot
    ///   happen (see "The event-driven alternative" below).
    /// - In `PaneRepairCoordinatorTests`, **6 of 13** tests have a worst case
    ///   above 240 s (counting `waitFor` at 90 s and each clock wait at 45 s),
    ///   not just the one 6-deep chain (540 s) usually cited. Four of the sites
    ///   that used to push that count to 9 of 13 are now single `advanceUntil`
    ///   guards instead of an advance plus a 90 s `waitFor`.
    ///
    /// **If these start tripping, shorten the chain — do not raise this limit
    /// again.** `Tests/CLAUDE.md` already requires advance chains to stay in
    /// single digits, and a 5-deep chain is at the edge of that rule; injecting
    /// pacing values to cross a threshold in 2–3 advances is the remedy. Raising
    /// 240 s buys room for chains that only an already-failing test walks, and
    /// costs every genuinely wedged test that much longer to be attributed.
    ///
    /// **Scope: this is sized for the fast parallel pass.** Every input above —
    /// the ~4536-test population, the arming latency it inflates, the two
    /// wall-clock waits it makes expensive — is a property of the in-process
    /// parallel run. Tier-3 suites in `Tests/TBDDaemonLiveTests` execute in the
    /// quiet pass (`--filter '^TBDDaemonLiveTests\.' --no-parallel`, idle
    /// machine), where arming latency is milliseconds and none of that applies.
    ///
    /// So a tier-3 suite whose time limit is its **regression detector** rather
    /// than a hang guard must pin its own `.timeLimit` instead of inheriting
    /// this one — a raise here would silently disarm the proof, with nothing
    /// going red to say so. Precedent, all pinned to `.timeLimit(.minutes(1))`
    /// with the reasoning in their suite docs:
    /// `SubprocessTimeoutStarvationTests` (a `sleep 90` child must outlive the
    /// limit), `GitManagerTimeoutTests` and `SubprocessTimeoutTests` (a
    /// regressed EOF-waiting drain must outlive it). Don't widen those to
    /// `.clockDriven` for consistency's sake.
    static var clockDriven: Self { .timeLimit(.minutes(4)) }
}

// MARK: - TestClock

/// A clock-driven wait that never saw its effect, rendered onto the **primary**
/// failure line.
///
/// Thrown-`Error` shape on purpose (`Tests/CLAUDE.md` assertion-hygiene rule 4):
/// only `Issue.record(_: some Error)` survives into a CI summary — both
/// `#expect(cond, "message")` and `Issue.record(String)` demote the text to a
/// trailing `↳` line the summary drops. `advances` is the observed half: zero
/// says the code under test never armed a sleep at all, while a large count says
/// it kept re-arming and never produced the effect. Those are different bugs.
public struct ClockAdvanceTimeout: Error, CustomStringConvertible {
    public let what: String
    public let advances: Int
    public let timeout: Swift.Duration

    public var description: String {
        """
        timed out waiting for \(what) — observed \(advances) clock advance(s) \
        over up to \(timeout) of real time
        """
    }
}

public extension TestClock {
    /// Waits until the code under test has actually registered a sleep on this
    /// clock, then advances virtual time by `duration`.
    ///
    /// Why this exists: `advance(by:)` on a clock with **no registered
    /// sleeper** merely moves `now` forward. The sleep that arrives afterwards
    /// is scheduled against the new `now` and blocks forever — the exact hang
    /// `.clockDriven` exists to catch. `TestClock.advance(to:)` calls
    /// `megaYield()` internally, so a bare `advance(by:)` *usually* happens to
    /// win the race against a task you just started. "Usually, on an unloaded
    /// machine" is precisely the flake class this program exists to kill, so
    /// don't rely on it — make the wait explicit.
    ///
    /// Convention that goes with it: **put the advance next to the assertion
    /// it unblocks.** Batching advances at the top of a test re-creates the
    /// same ordering ambiguity in a form that is harder to read.
    ///
    /// Non-throwing: a missing sleeper is reported via `Issue.record` at the
    /// caller's source location rather than thrown, so call sites stay free of
    /// `try` noise.
    func advanceWhenSuspended(by duration: Duration,
                              sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitForSuspension(sourceLocation: sourceLocation)
        await advance(by: duration)
    }

    /// Advances virtual time in `interval` steps for as long as the code under
    /// test keeps **re-arming** a sleep, until `condition` holds. Returns
    /// whether it held.
    ///
    /// ## Why one advance is not enough for a poll-and-re-arm loop
    ///
    /// `advanceWhenSuspended` proves exactly one thing: a sleeper was armed at
    /// the instant it advanced. It cannot prove that the loop under test
    /// *observes* the state the test just created on the probe that follows
    /// that advance. Where the code under test is a **poll-and-re-arm loop** —
    /// probe some external state, and if it is not yet the state we are waiting
    /// for, arm another sleep — a test that grants exactly one advance stakes
    /// the whole run on a single probe. Any transient that makes that one probe
    /// read "keep waiting" re-arms a sleep that nothing will ever advance
    /// again, and the test does not fail: it **hangs** until its `.timeLimit`,
    /// with no assertion fired, a diagnostic that names the symptom rather than
    /// the cause, and minutes of CI burned.
    ///
    /// That failure is field-observed, not hypothetical.
    /// `PaneRepairCoordinatorTests`' broken-pipe test drove the repair's
    /// reader-wait — a `poll(2)`-and-re-arm loop — with a single advance after
    /// closing the pipe's read end, and wedged in CI for the full 240 s limit
    /// with only the pause written, the sink still `repairing` and the repair
    /// still in flight: the exact fingerprint of a probe that read "keep
    /// waiting" once and then never got another advance. It survived a
    /// `.timeLimit` raise from 60 s to 240 s, because the wait was not slow —
    /// it was over.
    ///
    /// ## What this does instead
    ///
    /// Each step is gated on the code under test actually being armed, so no
    /// advance is spent on an empty clock and virtual time never runs ahead of
    /// a sleeper that has not arrived yet: an armed clock is advanced, an
    /// unarmed one is stepped aside for. The loop ends the moment `condition`
    /// holds. **The assertion is not weakened** — code that never produces the
    /// effect still fails, and now inside this helper's own deadline with a
    /// named diagnostic on the primary failure line, rather than as an
    /// unattributed suite timeout.
    ///
    /// ## When NOT to use it
    ///
    /// Where the **number** of advances is itself the property under test.
    /// `PaneRepairCoordinatorTests.readerWaitEscalatesToTheSlowInterval` pins
    /// the pacing-escalation boundary by advancing an exact number of times and
    /// asserting nothing happened; this helper deliberately advances as often
    /// as the code re-arms, which would dissolve that proof. Use the explicit
    /// `advanceWhenSuspended` pair there.
    ///
    /// - Parameters:
    ///   - what: names the effect being waited for, for the timeout diagnostic.
    ///   - interval: virtual time per step — normally the pacing the code under
    ///     test sleeps on, so one step wakes it once.
    ///   - timeout: real-time hang guard, same family and same 45 s value as
    ///     `waitForSuspension` (see its note for the derivation). Count one call
    ///     to this helper as one guard when tallying a test's worst case; it
    ///     *replaces* an `advanceWhenSuspended` (45 s) plus the `waitFor` (90 s)
    ///     that used to follow it, so converting a site shortens the chain.
    ///   - pollInterval: how long to step aside when nothing is armed yet. Each
    ///     probe costs a `megaYield`, so lazier is better — same reasoning as
    ///     `waitForSuspension`.
    @discardableResult
    func advanceUntil(
        _ what: String,
        by interval: Duration,
        timeout: Swift.Duration = .seconds(45),
        pollInterval: Swift.Duration = .milliseconds(25),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var advances = 0
        repeat {
            if await condition() { return true }
            if await isArmed() {
                await advance(by: interval)
                advances += 1
            } else {
                try? await Task.sleep(for: pollInterval)
            }
        } while ContinuousClock.now < deadline
        if await condition() { return true }
        Issue.record(
            ClockAdvanceTimeout(what: what, advances: advances, timeout: timeout),
            sourceLocation: sourceLocation)
        return false
    }

    /// Whether a task is suspended on this clock right now — the quiet form of
    /// `waitForSuspension`'s probe, for callers that loop on it. Same inverted
    /// detection: `checkSuspension()` throws when a sleeper *is* registered.
    private func isArmed() async -> Bool {
        do {
            try await checkSuspension()
            return false
        } catch {
            return true
        }
    }

    /// Waits until at least one task is suspended on this clock.
    ///
    /// Detection is inverted from how it reads: `checkSuspension()` **throws**
    /// when a sleeper *is* registered (its job is to prove "no further
    /// time-based asynchrony"), so catching its error is the success signal
    /// here, and a normal return means nobody has reached their `sleep` yet.
    ///
    /// ## Why this polls with a real sleep instead of yielding
    ///
    /// This waiter used to spin `await Task.yield()` up to a fixed budget of 20.
    /// That budget was not merely too small — **the loop does not converge**, and
    /// raising it makes things worse: measured on the 1331-test `TBDAppTests`
    /// target, a budget of 5000 turned a 17 s run into a **577 s** run that still
    /// failed. The contrast that identifies the variable: the same six tests are
    /// 6/6 green under `--filter AppearanceDebounceTests`, 10/10 green under a
    /// 24-test filter, and 0/3 in the full target *at the same machine load*. So
    /// the failure scales with the number of runnable tasks in the process, not
    /// with CPU load.
    ///
    /// The reason is what `Task.yield()` actually does: it keeps the calling task
    /// **runnable** and re-enqueues it behind every other runnable task in the
    /// process. In a large parallel target that queue is thousands deep, so the
    /// waiter spends its whole budget cycling through the back of the queue while
    /// the one task it is waiting for — the code under test, on its way to its
    /// `sleep` — never gets a turn. Spinning harder enqueues more work and starves
    /// it further, which is exactly the 577 s result.
    ///
    /// A real `Task.sleep` inverts that: it makes this task **non-runnable** and
    /// hands the executor back, so the runtime schedules the code under test
    /// normally instead of making it win a race against our own spin loop.
    ///
    /// This is bounded polling with a deadline — sanctioned by `Tests/CLAUDE.md`
    /// assertion-hygiene rule 3 — and it is *not* a wall-clock assertion. What is
    /// being waited on here is real task scheduling, which is genuinely real-time;
    /// the behaviour under test stays on virtual time and its assertions stay
    /// exact. The timeout is a hang-catcher, in the same family as `.clockDriven`,
    /// not a timing budget.
    ///
    /// ## What this does NOT fix
    ///
    /// `checkSuspension()` opens with `Task.megaYield()` — 20 serially-awaited
    /// **background-QoS** detached tasks — and `TestClock.advance(to:)` calls it
    /// twice more per advance. That is inside swift-clocks, on the hot path of
    /// every clock-driven test, and no change here can remove it. macOS starves
    /// background QoS under saturation, so a residual load sensitivity remains:
    /// this is load-*tolerant*, not load-*independent*. Measured healthy-path
    /// cost is tens of microseconds to a few milliseconds, but a 6-test suite was
    /// observed taking 8.4 s instead of 0.05 s — green, visibly stuck behind a
    /// slow megaYield — at load average >= 200 on 12 cores. CI (3–4 cores, `-j 2`,
    /// otherwise idle) is far from that regime. Making this load-independent
    /// means a megaYield-free virtual clock replacing `TestClock`, which is a
    /// shared-contract change and deliberately not bundled here.
    ///
    /// Lowering the megaYield count is **refuted** as a remedy at CI's regime,
    /// and this closes the open question in issue #496. `TASK_MEGA_YIELD_COUNT=1`
    /// was measured against an unset baseline across interleaved runs under
    /// induced load, population held constant: p90 26.5 s / 31.2 s -> 26.0 s /
    /// 29.4 s, p99 26.6 s -> 27.0 s. That is noise. The megaYield is a real but
    /// **secondary** contributor; the dominant term is the number of runnable
    /// tasks in the process (see the population note on `timeout` below), which
    /// is why CI shards the fast pass in two rather than tuning this knob.
    ///
    /// - Parameters:
    ///   - timeout: hang guard, and the value is a two-sided constraint. It must
    ///     stay well under `.clockDriven`'s limit — a test that waits twice has
    ///     to afford both waits and still get this helper's diagnostic, rather
    ///     than tripping the suite limit first and reporting an uninformative
    ///     "wedged". But it must also clear the worst-case real arming latency:
    ///     at 5 s, the appearance suite failed 4 of 6 full-target runs on this
    ///     handshake.
    ///
    ///     The pair is therefore derived together, and 15 s / `.minutes(1)` was
    ///     derived against a 1332-test target inside a ~3000-test process. What
    ///     invalidated it is population growth: 3013 -> 4536 tests in three
    ///     weeks. Swift Testing runs every non-serialized test in one process
    ///     with no concurrency cap, so real arming latency scales with the
    ///     process-wide runnable-task count, not with the suite under test —
    ///     mined CI runs show p50 per-test reported duration at ~1/3 of total
    ///     wall time even on green runs, i.e. tests spend most of their
    ///     "duration" suspended waiting for a turn.
    ///
    ///     Re-derived for the current population: 45 s here, so a twice-waiting
    ///     test needs 90 s, inside `.clockDriven`'s 4-minute (240 s) limit with
    ///     room for the rest of the test — and 45 s plus one 90 s
    ///     `ciSafeDeadline` wait is 135 s, also inside it. See `.clockDriven`
    ///     above for the full triple and the invariant that licenses it. Only a
    ///     genuinely un-armed timer ever pays this timeout — a healthy handshake
    ///     returns in milliseconds, so the raise costs passing runs nothing.
    ///
    ///     What 45 s does **not** buy is a deep chain: at five of these waits
    ///     a test is at 225 s of a 240 s limit, and this helper's non-throwing
    ///     shape means a chain that size pays every guard rather than stopping
    ///     at the first miss (contrast `EventDrivenTestClock`'s strict pair,
    ///     `requireSleeperArmed` / `requireAdvanceWhenArmed`, under "The
    ///     event-driven alternative" below, where a miss throws immediately).
    ///     ("Fast pass", not "live": tier-3 `TBDDaemonLiveTests` pins its own
    ///     limit and is unaffected.) That is
    ///     consistent with the invariant — only a failing test walks the whole
    ///     chain — but it is not headroom. The remedy if it bites is to shorten
    ///     the chain (`Tests/CLAUDE.md`: keep advances in single digits; inject
    ///     pacing), not to raise 240 s. Re-derive all three numbers again if the
    ///     population moves materially.
    ///   - pollInterval: how long to step aside between probes. Each probe costs
    ///     a megaYield, so probing tightly floods the pool with background tasks
    ///     and starves the very task being waited for — lazier is better.
    /// Note both are `Swift.Duration`, not this clock's generic `Duration`: they
    /// are real wall-clock quantities for the scheduling handshake, deliberately
    /// unrelated to the virtual time the clock hands out.
    func waitForSuspension(timeout: Swift.Duration = .seconds(45),
                           pollInterval: Swift.Duration = .milliseconds(25),
                           sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            do {
                try await checkSuspension()
            } catch {
                return  // A sleeper is registered — that is what we were waiting for.
            }
            try? await Task.sleep(for: pollInterval)
        } while ContinuousClock.now < deadline
        // One last probe, so the verdict is a fresh read rather than the loop's
        // exit. The deadline is tested *after* the poll sleep, so the last probe
        // is already `pollInterval` old before that test runs — and under the
        // fast parallel pass a 25 ms step aside can return its turn tens of
        // seconds later, by which time an arming that happened during the sleep
        // would be reported as never having happened. Same shape as
        // `advanceUntil` above, which re-reads its condition here for the same
        // reason. Costs one extra probe, and only on the path about to fail.
        do {
            try await checkSuspension()
        } catch {
            return
        }
        Issue.record(
            """
            TestClock: no task was suspended on the clock within \(timeout) — the \
            code under test never reached its sleep. Did you start the task, or \
            advance before it was armed?
            """,
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - Date

/// A mutable, thread-safe source of "now" for the `Date`-as-data seam.
///
/// Backs the `now: @Sendable () -> Date` parameter that §5 (shared contract 2)
/// standardizes for timestamps that get persisted or compared (`lastUsedAt`,
/// hibernation stamps). It replaces wall-clock freshness windows in
/// assertions — the flake shape where `resolve_success_bumpsLastUsedAt` blew a
/// 5-second tolerance by 0.11 s under CI load.
///
/// Deliberately a lock-guarded `final class`, not an `actor`: the seam it feeds
/// is a **synchronous** `() -> Date`, which an actor cannot satisfy without
/// making every timestamping call site `async`. The lock is uncontended in
/// practice (a test sets it, production code reads it).
public final class TestDateSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    /// - Parameter start: default is a fixed, recognizable instant
    ///   (2023-11-14T22:13:20Z) so failure output is stable and obviously
    ///   synthetic rather than "whenever CI ran".
    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.value = start
    }

    public var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    public func advance(by seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }

    /// The closure to hand to the production seam. It reads through to the
    /// current value on every call, so mutations made *after* injection are
    /// observed — that is the whole point.
    public var provider: @Sendable () -> Date {
        { [self] in now }
    }
}
