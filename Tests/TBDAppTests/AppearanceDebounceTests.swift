import Clocks
import Combine
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Tier 1. Debounce contract for scheme changes before they turn into daemon RPCs.
///
/// What changed and why: this suite used to *reconstruct*
/// `AppState.setupAppearanceSubscriptions`' Combine chain inside its own body
/// and assert against the copy, then wait on the real 200 ms
/// `DispatchQueue.main` debounce by polling a 5 s wall-clock deadline. So the
/// production wiring had no coverage at all, and the test failed under load
/// (reproduced locally, 2 of 5 runs). Combine's `.debounce` takes a `Scheduler`,
/// which can never be an `any Clock<Duration>`, so the fix was to move the
/// timed stage out of Combine entirely — see `AppearanceBroadcastDebouncer`,
/// which these tests now drive directly against a `TestClock`.
///
/// Consequence: there is no wall clock anywhere below. Every timing is virtual
/// and exact, so the assertions are boundary-precise rather than
/// tolerance-windowed. The old doc comment's `DispatchQueue.main` vs
/// `RunLoop.main` reasoning no longer applies — no Combine scheduler is
/// involved.
/// `.serialized` is load-bearing, not tidiness. Every test here drives a
/// `TestClock`, and each probe/advance costs a `Task.megaYield()` — 20
/// serially-awaited background-QoS detached tasks. Run in parallel, seven such
/// tests flood the pool with exactly the low-priority work they are each
/// waiting on, and they starve *each other*: measured in the full 1332-test
/// target, the unserialized suite failed 4 of 6 runs on the arming handshake
/// while taking ~12.6 s even when it passed. Serialized, the suite stops being
/// its own contention source. This narrows one suite, not the target — other
/// suites still run in parallel around it.
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
        let clock = TestClock()
        let debouncer: AppearanceBroadcastDebouncer
        let fired = Box()
        var subscription: AnyCancellable?

        final class Box { var values: [String] = [] }

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
                fired.values.append(value)
            }
        }

        func tearDown() {
            subscription?.cancel()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// A `Clock<Duration>` that delegates to a `TestClock` and then cancels the
    /// sleeping task the instant its sleep resumes.
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
    /// Delegating rather than reimplementing keeps virtual time exact —
    /// `TestClock` still owns every suspension, so `advanceWhenSuspended` on the
    /// base clock behaves normally.
    fileprivate struct CancelOnResumeClock: Clock {
        let base: TestClock<Swift.Duration>

        var now: TestClock<Swift.Duration>.Instant { base.now }
        var minimumResolution: Swift.Duration { base.minimumResolution }

        func sleep(until deadline: TestClock<Swift.Duration>.Instant,
                   tolerance: Swift.Duration?) async throws {
            try await base.sleep(until: deadline, tolerance: tolerance)
            withUnsafeCurrentTask { $0?.cancel() }
        }
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

            await h.clock.advanceWhenSuspended(by: Self.interval)
            #expect(h.fired.values == ["scheme-c"])
        }
    }

    // Tier 1. The boundary the old wall-clock test structurally could not express.
    @Test("nothing fires until the full interval has elapsed")
    func firesExactlyOnTheBoundary() async {
        await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"

            await h.clock.advanceWhenSuspended(by: Self.interval - .milliseconds(1))
            #expect(h.fired.values.isEmpty, "one millisecond short of the window must not fire")

            await h.clock.advance(by: .milliseconds(1))
            #expect(h.fired.values == ["scheme-a"])
        }
    }

    // Tier 1.
    @Test("a late change restarts the quiet window")
    func lateChangeRestartsWindow() async {
        await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            await h.clock.advanceWhenSuspended(by: .milliseconds(150))
            #expect(h.fired.values.isEmpty)

            // Restarts the window: the first sleeper is cancelled, a fresh
            // 200 ms one is armed. Note what the wait below can and cannot
            // promise — `checkSuspension()` only asks "is anything suspended",
            // so it can in principle be satisfied by the superseded sleeper
            // whose entry is still being cleaned up, rather than by the new one.
            // `advance(to:)` megaYields before touching `suspensions`, which is
            // why the cleanup and the re-arm land first in practice. A
            // "wait for a sleeper at/after deadline X" helper would make it a
            // guarantee; that is a shared-helper change, not a C1 change.
            h.appearance.schemeID = "scheme-b"
            await h.clock.advanceWhenSuspended(by: .milliseconds(150))
            #expect(h.fired.values.isEmpty, "only 150ms since the restart — must not fire yet")

            await h.clock.advance(by: .milliseconds(50))
            #expect(h.fired.values == ["scheme-b"])
        }
    }

    // Tier 1.
    @Test("changes separated by a full window fire twice, in order")
    func separatedChangesFireTwice() async {
        await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            await h.clock.advanceWhenSuspended(by: Self.interval)
            #expect(h.fired.values == ["scheme-a"])

            h.appearance.schemeID = "scheme-b"
            await h.clock.advanceWhenSuspended(by: Self.interval)
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
            // from production. `checkSuspension()` throws when a sleeper is
            // registered, so "does not throw" is the real assertion — the
            // subscriber-time replay never armed a timer at all.
            await #expect(throws: Never.self) { try await h.clock.checkSuspension() }
            #expect(h.fired.values.isEmpty)

            // `removeDuplicates`: the second assignment is not a distinct value,
            // so it never reaches the timer and cannot restart the window.
            h.appearance.schemeID = "scheme-a"
            await h.clock.advanceWhenSuspended(by: .milliseconds(100))
            h.appearance.schemeID = "scheme-a"
            await h.clock.advance(by: .milliseconds(100))

            #expect(h.fired.values == ["scheme-a"], "a repeated value must neither fire twice nor restart the window")
        }
    }

    /// Tier 1. Covers the branch that a plain `try? await clock.sleep(...)`
    /// does **not**: cancellation arriving *after* the sleep has already
    /// resumed, which cannot retroactively make that `await` throw.
    ///
    /// The other cancellation test below cancels while the timer is still
    /// asleep, which the thrown-error path already handles — delete the
    /// `Task.isCancelled` guard in production and that test stays green. This
    /// one goes red, because `PostResumeCancelClock` lands the cancel in
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

        let base = TestClock()
        let debouncer = AppearanceBroadcastDebouncer(
            interval: Self.interval,
            clock: CancelOnResumeClock(base: base)
        )
        let fired = Harness.Box()
        let subscription = debouncer.start(observing: appearance) { [fired] value in
            fired.values.append(value)
        }
        defer { subscription.cancel() }

        appearance.schemeID = "scheme-a"
        await base.advanceWhenSuspended(by: Self.interval)
        #expect(fired.values.isEmpty, "a fire cancelled after its sleep resumed must not land")
    }

    // Tier 1.
    @Test("cancel() suppresses a pending fire")
    func cancelSuppressesPendingFire() async {
        await Self.withHarness { h in
            h.appearance.schemeID = "scheme-a"
            await h.clock.advanceWhenSuspended(by: .milliseconds(100))

            h.debouncer.cancel()
            await h.clock.advance(by: Self.interval)
            #expect(h.fired.values.isEmpty)
        }
    }
}
