import Combine
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Tier 1. Debounce contract for scheme changes before they turn into daemon RPCs.
///
/// The suite drives `AppearanceBroadcastDebouncer` — the production wiring —
/// directly, in virtual time. That matters twice over: Combine's `.debounce`
/// takes a `Scheduler`, which can never be an `any Clock<Duration>`, so the
/// timed stage lives outside Combine precisely so a test clock can own it; and
/// because every timing here is virtual, the assertions are boundary-precise
/// rather than tolerance-windowed. There is no wall clock in the behaviour under
/// test.
///
/// The clock is `EventDrivenTestClock`, not `TestClock`. Its arming handshake is
/// a signal emitted from inside the same critical section that registers the
/// sleeper, so `advanceWhenArmed` cannot be starved by a saturated process the
/// way a megaYield-driven probe can — the failure this suite reproduced under
/// full-suite load. Its `advance` does no yielding at all, which is why every
/// *positive* assertion below awaits `fired.next()` instead of reading the
/// recorder synchronously: `advance` returning means the continuation was
/// resumed, not that the resumed task has run. Design:
/// `docs/specs/2026-08-11-event-driven-test-clock-design.md`.
///
/// `.serialized` is retained as cheap isolation between seven tests that each
/// mint a `UserDefaults` suite and a debouncer; it is no longer load-bearing for
/// the handshake.
@MainActor
@Suite("AppState appearance debounce", .clockDriven, .serialized)
struct AppearanceDebounceTests {
    private static let interval = Duration.milliseconds(200)

    /// Isolated `AppearanceSettings` + debouncer + fired-value recorder.
    /// `UserDefaults.standard` on this unbundled executable is the developer's
    /// real `TBDApp.plist`, so the suite name must be unique and torn down.
    @MainActor
    private final class Harness {
        let suiteName: String
        let defaults: UserDefaults
        let appearance: AppearanceSettings
        let clock = EventDrivenTestClock()
        let debouncer: AppearanceBroadcastDebouncer
        let fired = FireRecorder<String>()
        var subscription: AnyCancellable?

        init() {
            suiteName = "TBDAppTests.AppearanceDebounce.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            // `userThemesDirectory` is the injection seam named in the root
            // CLAUDE.md; without it `init` stats the developer's real `~/tbd`.
            // A non-existent temp path is the point — the lookup must miss
            // deterministically rather than depend on what is on this machine.
            appearance = AppearanceSettings(
                defaults: defaults,
                userThemesDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("TBDAppTests.AppearanceDebounce.\(UUID().uuidString)")
            )
            debouncer = AppearanceBroadcastDebouncer(
                interval: AppearanceDebounceTests.interval,
                clock: clock
            )
        }

        func subscribe() {
            subscription = debouncer.start(observing: appearance) { [fired] value in
                fired.record(value)
            }
        }

        func tearDown() {
            subscription?.cancel()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// A `Clock<Duration>` that delegates to an `EventDrivenTestClock` and then
    /// cancels the sleeping task the instant its sleep resumes.
    ///
    /// This reproduces the one window a `try? await clock.sleep(...)` cannot
    /// see: cancellation that arrives *after* the sleep completed, which cannot
    /// retroactively make that `await` throw. `withUnsafeCurrentTask` is what
    /// makes it exact — the hook runs inside the production debounce task
    /// itself, so it cancels precisely that task, synchronously, between its
    /// sleep returning and its next statement.
    ///
    /// (An earlier attempt called `debouncer.cancel()` through
    /// `MainActor.assumeIsolated` here and crashed with SIGTRAP: `sleep` is a
    /// `nonisolated` protocol requirement, so it runs on the generic executor
    /// even when the calling task is `@MainActor`.)
    ///
    /// Delegating rather than reimplementing keeps virtual time exact — the base
    /// clock still owns every suspension, so `advanceWhenArmed` on it behaves
    /// normally.
    fileprivate struct CancelOnResumeClock: Clock {
        let base: EventDrivenTestClock

        var now: EventDrivenTestClock.Instant { base.now }
        var minimumResolution: Swift.Duration { base.minimumResolution }

        func sleep(until deadline: EventDrivenTestClock.Instant,
                   tolerance: Swift.Duration?) async throws {
            try await base.sleep(until: deadline, tolerance: tolerance)
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    /// Hands the main actor back for a few real turns, so a fire that *would*
    /// land gets the chance to before a negative assertion reads the recorder.
    ///
    /// Negative assertions are one-sided by nature — a pathologically late fire
    /// can make one false-*pass*, never false-fail — and that was equally true
    /// when `TestClock.advance`'s trailing megaYield supplied the same settling
    /// incidentally. This makes the settle explicit and bounded instead.
    private static func settle() async {
        for _ in 0..<3 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor
    private static func withHarness(_ body: (Harness) async -> Void) async {
        let harness = Harness()
        harness.subscribe()
        // `defer`, not a trailing call: `schemeID`'s `didSet` writes to the
        // suite, so skipping teardown leaks a plist into the developer's real
        // ~/Library/Preferences. Same length, one less coupling to `body`
        // never throwing.
        defer { harness.tearDown() }
        await body(harness)
    }

    // Tier 1.
    @Test("rapid scheme changes within one window collapse to a single fire")
    func rapidChangesCollapse() async {
        await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            h.appearance.schemeID = "scheme-b"
            h.appearance.schemeID = "scheme-c"

            await h.clock.advanceWhenArmed(by: Self.interval)
            #expect(await h.fired.next() == "scheme-c")
            #expect(h.fired.values == ["scheme-c"])
        }
    }

    // Tier 1. The boundary the old wall-clock test structurally could not express.
    @Test("nothing fires until the full interval has elapsed")
    func firesExactlyOnTheBoundary() async {
        await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"

            await h.clock.advanceWhenArmed(by: Self.interval - .milliseconds(1))
            await Self.settle()
            #expect(h.fired.values.isEmpty, "one millisecond short of the window must not fire")

            await h.clock.advance(by: .milliseconds(1))
            #expect(await h.fired.next() == "scheme-a")
        }
    }

    // Tier 1.
    @Test("a late change restarts the quiet window")
    func lateChangeRestartsWindow() async {
        await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            await h.clock.advanceWhenArmed(by: .milliseconds(150))
            await Self.settle()
            #expect(h.fired.values.isEmpty)

            // Restarts the window: the first sleeper is cancelled, a fresh
            // 200 ms one is armed. The wait below is unambiguous about which of
            // the two it is satisfied by — cancelling the superseded task runs
            // the clock's cancellation handler synchronously, which removes its
            // ledger entry before `schedule` returns, so the only registration
            // left to signal is the new sleeper's.
            h.appearance.schemeID = "scheme-b"
            await h.clock.advanceWhenArmed(by: .milliseconds(150))
            await Self.settle()
            #expect(h.fired.values.isEmpty, "only 150ms since the restart — must not fire yet")

            await h.clock.advance(by: .milliseconds(50))
            #expect(await h.fired.next() == "scheme-b")
            #expect(h.fired.values == ["scheme-b"])
        }
    }

    // Tier 1.
    @Test("changes separated by a full window fire twice, in order")
    func separatedChangesFireTwice() async {
        await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            await h.clock.advanceWhenArmed(by: Self.interval)
            #expect(await h.fired.next() == "scheme-a")

            h.appearance.schemeID = "scheme-b"
            await h.clock.advanceWhenArmed(by: Self.interval)
            #expect(await h.fired.next() == "scheme-b")
            #expect(h.fired.values == ["scheme-a", "scheme-b"])
        }
    }

    // Tier 1.
    @Test("dropFirst skips the subscriber-time value and removeDuplicates collapses repeats")
    func dropFirstAndRemoveDuplicates() async {
        await Self.withHarness { h in
            // `dropFirst`: `@Published` replayed the current value at
            // subscription time in `subscribe()`. Assert on the SLEEPER, not on
            // `fired`: with no advance yet, `fired` is empty either way, so
            // checking it would pass just as happily with `dropFirst()` deleted
            // from production. The settle is what makes the negative worth
            // anything — the timer a missing `dropFirst()` would arm needs a
            // scheduling turn to appear, so give it several before looking. It
            // is a weaker proof than the old "a registered sleeper makes
            // `checkSuspension()` throw", and one-sided like every negative
            // here: it can only ever false-pass.
            await Self.settle()
            #expect(h.clock.hasSleeper == false,
                    "the subscriber-time replay must not arm a timer at all")
            #expect(h.fired.values.isEmpty)

            // `removeDuplicates`: the second assignment is not a distinct value,
            // so it never reaches the timer and cannot restart the window.
            h.appearance.schemeID = "scheme-a"
            await h.clock.advanceWhenArmed(by: .milliseconds(100))
            h.appearance.schemeID = "scheme-a"
            await h.clock.advance(by: .milliseconds(100))

            #expect(await h.fired.next() == "scheme-a")
            #expect(h.fired.values == ["scheme-a"],
                    "a repeated value must neither fire twice nor restart the window")
        }
    }

    /// Tier 1. Covers the branch that a plain `try? await clock.sleep(...)`
    /// does **not**: cancellation arriving *after* the sleep has already
    /// resumed, which cannot retroactively make that `await` throw.
    ///
    /// The other cancellation test below cancels while the timer is still
    /// asleep, which the thrown-error path already handles — delete the
    /// `Task.isCancelled` guard in production and that test stays green. This
    /// one goes red, because `CancelOnResumeClock` lands the cancel in
    /// exactly the window the guard exists for.
    @Test("a cancel landing after the sleep resumes still suppresses the fire")
    func cancelAfterSleepResumesSuppressesFire() async {
        let suiteName = "TBDAppTests.AppearanceDebounce.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceSettings(
            defaults: defaults,
            userThemesDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("TBDAppTests.AppearanceDebounce.\(UUID().uuidString)")
        )

        let base = EventDrivenTestClock()
        let debouncer = AppearanceBroadcastDebouncer(
            interval: Self.interval,
            clock: CancelOnResumeClock(base: base)
        )
        let fired = FireRecorder<String>()
        let subscription = debouncer.start(observing: appearance) { [fired] value in
            fired.record(value)
        }
        defer { subscription.cancel() }

        appearance.schemeID = "scheme-a"
        await base.advanceWhenArmed(by: Self.interval)
        await Self.settle()
        #expect(fired.values.isEmpty, "a fire cancelled after its sleep resumed must not land")
    }

    // Tier 1.
    @Test("cancel() suppresses a pending fire")
    func cancelSuppressesPendingFire() async {
        await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            await h.clock.advanceWhenArmed(by: .milliseconds(100))

            h.debouncer.cancel()
            await h.clock.advance(by: Self.interval)
            await Self.settle()
            #expect(h.fired.values.isEmpty)
        }
    }
}
