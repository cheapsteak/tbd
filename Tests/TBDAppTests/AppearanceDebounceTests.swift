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
///
/// Every wait here takes ``mainActorHop`` as its hang guard, and the arming
/// waits are the strict form — a missed arming ends the test rather than
/// paying the recorder's guard as well, so the two-step chain in
/// `separatedChangesFireTwice` costs at most two guards (180 s) inside
/// `.clockDriven`'s 240 s limit.
@MainActor
@Suite("AppState appearance debounce", .clockDriven, .serialized)
struct AppearanceDebounceTests {
    private static let interval = Duration.milliseconds(200)

    /// Hang guard for every arming wait and every `fired.next()` in this
    /// suite: the fast pass's saturated budget, not the clock's 45 s default,
    /// because neither hop is one hop from the test body.
    /// `AppearanceBroadcastDebouncer` is `@MainActor` and fires through an
    /// unstructured `Task { @MainActor }`, so the timer arms only once that
    /// task has had a turn on the main actor — a process-wide queue every
    /// `@MainActor` test body in the pass waits on, deepest at pass start when
    /// this suite's first test runs — and the fire needs the main actor a
    /// second time after `advance`. On a green fast pass 2 the same shape
    /// measured 84 s to arm
    /// (`ComposerSendCoordinatorTests.theHoldTimesOutOnTheInjectedClock`, which
    /// takes this budget for the same reason), while 45 s sat below the pass's
    /// median reported per-test latency and turned the first test here red on
    /// ordinary CI — every later assertion a consequence, every sibling test
    /// passing in milliseconds. The rule is the `timeout` note on
    /// `EventDrivenTestClock.sleeperArmed`.
    private static let mainActorHop = TestDeadlines.saturatedPass

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

    @MainActor
    private static func withHarness(_ body: (Harness) async throws -> Void) async rethrows {
        let harness = Harness()
        harness.subscribe()
        // `defer`, not a trailing call: `schemeID`'s `didSet` writes to the
        // suite, so skipping teardown leaks a plist into the developer's real
        // ~/Library/Preferences — and a strict arming wait that throws out of
        // `body` still tears down.
        defer { harness.tearDown() }
        try await body(harness)
    }

    // Tier 1.
    @Test("rapid scheme changes within one window collapse to a single fire")
    func rapidChangesCollapse() async throws {
        try await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            h.appearance.schemeID = "scheme-b"
            h.appearance.schemeID = "scheme-c"

            try await h.clock.requireAdvanceWhenArmed(by: Self.interval, timeout: Self.mainActorHop)
            #expect(await h.fired.next(timeout: Self.mainActorHop) == "scheme-c")
            #expect(h.fired.values == ["scheme-c"])
        }
    }

    // Tier 1. The boundary the old wall-clock test structurally could not express.
    @Test("nothing fires until the full interval has elapsed")
    func firesExactlyOnTheBoundary() async throws {
        try await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"

            try await h.clock.requireAdvanceWhenArmed(
                by: Self.interval - .milliseconds(1), timeout: Self.mainActorHop)
            await settle()
            #expect(h.fired.values.isEmpty, "one millisecond short of the window must not fire")

            await h.clock.advance(by: .milliseconds(1))
            #expect(await h.fired.next(timeout: Self.mainActorHop) == "scheme-a")
            #expect(h.fired.values == ["scheme-a"], "the boundary must fire once, not twice")
        }
    }

    // Tier 1.
    @Test("a late change restarts the quiet window")
    func lateChangeRestartsWindow() async throws {
        try await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            try await h.clock.requireAdvanceWhenArmed(by: .milliseconds(150), timeout: Self.mainActorHop)
            await settle()
            #expect(h.fired.values.isEmpty)

            // Restarts the window: the first sleeper is cancelled, a fresh
            // 200 ms one is armed. The wait below is unambiguous about which of
            // the two it is satisfied by — cancelling the superseded task runs
            // the clock's cancellation handler synchronously, which removes its
            // ledger entry before `schedule` returns, so the only registration
            // left to signal is the new sleeper's.
            h.appearance.schemeID = "scheme-b"
            try await h.clock.requireAdvanceWhenArmed(by: .milliseconds(150), timeout: Self.mainActorHop)
            await settle()
            #expect(h.fired.values.isEmpty, "only 150ms since the restart — must not fire yet")

            await h.clock.advance(by: .milliseconds(50))
            #expect(await h.fired.next(timeout: Self.mainActorHop) == "scheme-b")
            #expect(h.fired.values == ["scheme-b"])
        }
    }

    // Tier 1.
    @Test("changes separated by a full window fire twice, in order")
    func separatedChangesFireTwice() async throws {
        try await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            try await h.clock.requireAdvanceWhenArmed(by: Self.interval, timeout: Self.mainActorHop)
            #expect(await h.fired.next(timeout: Self.mainActorHop) == "scheme-a")

            h.appearance.schemeID = "scheme-b"
            try await h.clock.requireAdvanceWhenArmed(by: Self.interval, timeout: Self.mainActorHop)
            #expect(await h.fired.next(timeout: Self.mainActorHop) == "scheme-b")
            #expect(h.fired.values == ["scheme-a", "scheme-b"])
        }
    }

    // Tier 1.
    @Test("dropFirst skips the subscriber-time value and removeDuplicates collapses repeats")
    func dropFirstAndRemoveDuplicates() async throws {
        try await Self.withHarness { h in
            // `dropFirst`: `@Published` replayed the current value at
            // subscription time in `subscribe()`. Assert on the SLEEPER, not on
            // `fired`: with no advance yet, `fired` is empty either way, so
            // checking it would pass just as happily with `dropFirst()` deleted
            // from production. And *watch* rather than settle: the timer a
            // missing `dropFirst()` arms needs a scheduling turn to appear, so
            // a fixed settle buys its whole proof at one instant and can miss
            // the arming entirely under saturation — the one condition where a
            // mutation most needs catching. The watch keeps looking for a
            // second and returns the moment a sleeper shows up. One-sided as
            // ever: absence holds only up to the window.
            #expect(await watchForSleeper(on: h.clock) == false,
                    "the subscriber-time replay must not arm a timer at all")
            #expect(h.fired.values.isEmpty)

            // `removeDuplicates`: the second assignment is not a distinct value,
            // so it never reaches the timer and cannot restart the window.
            h.appearance.schemeID = "scheme-a"
            try await h.clock.requireAdvanceWhenArmed(by: .milliseconds(100), timeout: Self.mainActorHop)
            h.appearance.schemeID = "scheme-a"
            await h.clock.advance(by: .milliseconds(100))

            #expect(await h.fired.next(timeout: Self.mainActorHop) == "scheme-a")
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
    func cancelAfterSleepResumesSuppressesFire() async throws {
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
        try await base.requireAdvanceWhenArmed(by: Self.interval, timeout: Self.mainActorHop)
        await settle()
        #expect(fired.values.isEmpty, "a fire cancelled after its sleep resumed must not land")
    }

    // Tier 1.
    @Test("cancel() suppresses a pending fire")
    func cancelSuppressesPendingFire() async throws {
        try await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            try await h.clock.requireAdvanceWhenArmed(by: .milliseconds(100), timeout: Self.mainActorHop)

            h.debouncer.cancel()
            await h.clock.advance(by: Self.interval)
            await settle()
            #expect(h.fired.values.isEmpty)
        }
    }
}
