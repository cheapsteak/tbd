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

    /// Yields until at least one task is suspended on this clock.
    ///
    /// Detection is inverted from how it reads: `checkSuspension()` **throws**
    /// when a sleeper *is* registered (its job is to prove "no further
    /// time-based asynchrony"), so catching its error is the success signal
    /// here, and a normal return means nobody has reached their `sleep` yet.
    ///
    /// Budget-exhausted is a test bug, not a flake, so it records an Issue
    /// naming the likely cause instead of hanging or throwing.
    func waitForSuspension(maxYields: Int = 20,
                           sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<maxYields {
            do {
                try await checkSuspension()
            } catch {
                return  // A sleeper is registered — that is what we were waiting for.
            }
            await Task.yield()
        }
        Issue.record(
            """
            TestClock: no task was suspended on the clock after \(maxYields) yields — \
            the code under test never reached its sleep. Did you start the task, or \
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
