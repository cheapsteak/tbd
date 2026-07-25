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
    /// This bounds it. `.minutes(1)` is not a performance budget — it is
    /// Swift Testing's floor granularity (time limits are expressed in whole
    /// minutes), and it is a hang-catcher. A clock-driven tier-1 test should
    /// finish in milliseconds; if it takes a minute, it is wedged, and you
    /// want the failure attributed to the test rather than to the runner.
    static var clockDriven: Self { .timeLimit(.minutes(1)) }
}

// MARK: - TestClock

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
    /// - Parameters:
    ///   - timeout: hang guard, and the value is a two-sided constraint. It must
    ///     stay well under `.clockDriven`'s one-minute limit (Swift Testing's
    ///     floor granularity) — a test that waits twice has to afford both waits
    ///     and still get this helper's diagnostic, rather than tripping the
    ///     suite limit first and reporting an uninformative "wedged". But it
    ///     must also clear the worst-case real arming latency: at 5 s, the
    ///     appearance suite failed 4 of 6 full-target runs on this handshake.
    ///     15 s is ~10x the observed healthy-path arming cost inside a
    ///     1332-test target while still leaving half the per-test budget for a
    ///     twice-waiting test. Only a genuinely un-armed timer ever pays it.
    ///   - pollInterval: how long to step aside between probes. Each probe costs
    ///     a megaYield, so probing tightly floods the pool with background tasks
    ///     and starves the very task being waited for — lazier is better.
    /// Note both are `Swift.Duration`, not this clock's generic `Duration`: they
    /// are real wall-clock quantities for the scheduling handshake, deliberately
    /// unrelated to the virtual time the clock hands out.
    func waitForSuspension(timeout: Swift.Duration = .seconds(15),
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
