import Clocks
import Darwin
import Foundation
import os
import Testing

@testable import TBDApp
import TestSupport

/// Tier 2 throughout: a real temp file and a real `DispatchSource` deliver the
/// *event*, so this suite exercises the production kqueue path. What is virtual
/// is the *timer* — `FileWatcher` takes `clock: any Clock<Duration>`, so the
/// 150 ms debounce and the 50 ms re-open delay are asserted at exact virtual
/// boundaries instead of being waited out on a loaded runner.
///
/// Two deliberate splits:
///
/// - The debounce/re-open tests inject a `TestClock` (wrapped, see
///   `RecordingClock`) and never look at wall time for the behaviour under test.
/// - The lifecycle tests construct `FileWatcher()` with **no clock argument**.
///   That is deliberate, but it is *not* proof that the production default is
///   wired: none of them ever writes to the watched file, so none of them
///   reaches `clock.sleep`, and swapping the production default for a
///   `TestClock` would leave all four green.
///   `defaultClockDeliversOneRealDebouncedNotification` is the single test that
///   closes that hole — default clock, a real write, a real ~150 ms wait.
///
/// `.serialized` is load-bearing and now doubly so: `TestClock.advance(to:)`
/// calls `Task.megaYield()` — 20 serially-awaited background-QoS tasks — twice
/// per advance, so clock-driven tests are their own contention source and
/// starve each other when run in parallel. `.clockDriven` is the hang guard for
/// the known virtual-time failure mode (a sleep nobody advances hangs forever).
///
/// ## Deadline budget
///
/// Every wait here is a **hang guard**, never a tolerance window: the healthy
/// path exits on its first probe (whole suite: ~0.6 s locally), and only a
/// genuinely broken watcher pays a deadline. A hang guard being *slow to fire*
/// is the property that distinguishes it from a wall-clock tolerance window,
/// which assertion-hygiene rule 2 forbids. Two tiers:
///
/// | Guard | Value | What it waits on |
/// |---|---|---|
/// | `poll` / `writeUntilArmed` default | 8 s | task scheduling, `AsyncStream` delivery, `clock.sleep` entry |
/// | `fdCloseTimeout` | 25 s | `close(fd)` in a GCD **cancel handler on a utility-QoS global queue** |
/// | `withWatchedFile` FD quiescence | 12 s | same cancel handler, but not an assertion |
/// | `advanceWhenSuspended` | 45 s | fixed by `ClockTestSupport`, not ours to set |
///
/// **The criterion these are sized against** is: the FIRST guard to fire must
/// get its named diagnostic out inside `.clockDriven`'s 240 s per-test limit,
/// otherwise the limit kills the test and reports an unnamed "wedged" instead
/// of observed state (rule 4). Healthy prefix ~0.6 s + the largest single
/// deadline (45 s, the fixed handshake guard) = well under a quarter of the
/// limit, for every test here.
///
/// It is deliberately *not* "the sum of every deadline in a test stays under
/// the limit". That framing was unachievable when the limit was 60 s and
/// `ClockTestSupport`'s handshake guard was 15 s used 2–3× per test; it is a
/// weak criterion rather than a wrong one, and it is not what these values are
/// sized against. Worst-case cascades, at the current 45 s handshake guard:
///
/// | Test | Worst-case cascade (all guards fire) |
/// |---|---|
/// | `liveStreamCountReturnsToBaselineAfterIteratorDrops` | 8 + 25 = 33 s |
/// | `cancellingConsumingTaskTerminatesStream` | 2×8 + 25 = 41 s |
/// | `nonExistentPathFinishesStreamImmediately` | 8 s |
/// | `writesWithinOneWindowCollapseToOneNotification` | 3×8 + 45 + 8 + 12 = 89 s |
/// | `nothingFiresUntilTheFullIntervalElapsed` | 8 + 45 + 8 + 12 = 73 s |
/// | `lateWriteRestartsTheWindow` | 2×8 + **2×45** + 8 + 12 = 126 s |
/// | `separatedWritesNotifyTwice` | 2×8 + **2×45** + 2×8 + 12 = 134 s |
/// | `atomicSaveReopensAndKeepsStreamLive` | 2×8 + **3×45** + 3×8 + 25 + 12 = 212 s |
/// | `terminationWithAPendingDebounceStillClosesTheFD` | 8 + 8 + 25 + 12 = 53 s |
/// | `defaultClockDeliversOneRealDebouncedNotification` | ~1.8 + 8 = 10 s |
///
/// Both inputs moved together (handshake guard 15 s → 45 s, suite limit 60 s →
/// 240 s; see `ClockTestSupport`), and the limit outgrew the cascades: every
/// row now fits, where three used to blow it. The docstring's own prediction —
/// "the remaining lever, if a full cascade ever needs to fit, is the suite's
/// time limit, not the guards" — is what happened, incidentally rather than by
/// design. Do not start relying on it: the worst row (212 s) clears 240 s by
/// only 28 s, so it would go back over on any further handshake-guard raise,
/// and the first-diagnostic criterion above remains the property these values
/// are actually sized against.
@MainActor
@Suite("FileWatcher", .clockDriven, .serialized)
struct FileWatcherTests {

    /// Deadline for any poll that waits on `close(fd)`.
    ///
    /// The invariant asserted at these sites ("exactly one FD closed") is
    /// exact. *When* it becomes observable is not: `close(fd)` runs in the
    /// dispatch source's **cancel handler**, which GCD submits to
    /// `DispatchQueue.global(qos: .utility)` (`startWatching()`). Utility QoS
    /// is the first thing macOS starves on a saturated runner, so these
    /// assertions are load-**tolerant**, not load-**independent**.
    ///
    /// 25 s is that tolerance, and it is derived, not tuned to green: the
    /// tightest test carrying one of these polls
    /// (`terminationWithAPendingDebounceStillClosesTheFD`) spends 8 + 8 + 12 s
    /// on its other guards, leaving 32 s under the 60 s limit — 25 s takes it
    /// to 53 s. It also clears the observed contention magnitude: in the CI run
    /// that reddened this suite at a 4 s deadline, sibling tests that are
    /// normally sub-second took 22.9 s each.
    private static let fdCloseTimeout: Duration = .seconds(25)

    // MARK: - Lifecycle (tier 2, DEFAULT clock — but they never reach the sleep; see the suite header)

    /// Construct many watchers without ever calling `changes(for:)`.
    /// `FileWatcher` itself is a stateless factory, so this should be trivially
    /// balanced — no streams alive, and no FDs opened, hence none closed.
    @Test func factoryConstructionIsStateless() async {
        let baseline = FileWatcher.liveStreamCount
        let fdBaseline = FileWatcher.closedFDCount
        do {
            var watchers: [FileWatcher] = []
            for _ in 0..<50 {
                watchers.append(FileWatcher())
            }
            // Constructing a FileWatcher must not start any stream.
            #expect(FileWatcher.liveStreamCount == baseline)
            watchers.removeAll()
        }
        // No wait between `removeAll()` and the re-assertion, deliberately:
        // `changes(for:)` was never called, so no stream and no FD ever existed,
        // and releasing watchers that started nothing has no asynchronous effect
        // to settle. The re-assertion still earns its place — it says releasing
        // them must not move either counter.
        //
        // This used to be `await Task.yield()`, which was not merely redundant
        // but actively harmful: `yield()` keeps the calling task RUNNABLE and
        // re-enqueues it behind every other runnable task in a large parallel
        // target — the same non-converging spin
        // `cancellingConsumingTaskTerminatesStream` documents. Measured under a
        // full-target run it cost this one test 22.4s.
        #expect(FileWatcher.liveStreamCount == baseline)
        #expect(FileWatcher.closedFDCount == fdBaseline, "no FD was opened, so none may be closed")
    }

    /// Start a stream against a real temp file, drop the iterator, and confirm
    /// the stream's `onTermination` ran (live count returns to baseline) **and**
    /// that the dispatch source's cancel handler closed the FD.
    ///
    /// The second half is what the docstring used to claim without testing:
    /// `liveStreamCount` only observes that `onTermination` fired — it is
    /// decremented on a line independent of `box.terminate()`. `closedFDCount`
    /// is incremented next to `close(fd)` inside the cancel handler, so it is
    /// the only assertion here that a deleted `src?.cancel()` would break.
    @Test func liveStreamCountReturnsToBaselineAfterIteratorDrops() async {
        let baseline = FileWatcher.liveStreamCount
        let fdBaseline = FileWatcher.closedFDCount

        let tmpURL = Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            let w = FileWatcher()
            let iterator = w.changes(for: tmpURL.path).makeAsyncIterator()
            #expect(FileWatcher.liveStreamCount == baseline + 1)
            // Dropping `iterator` here triggers continuation.onTermination
            // (no consumer left to receive yields).
            _ = iterator
        }

        await Self.poll("liveStreamCount back to baseline \(baseline)",
                        observing: { FileWatcher.liveStreamCount }) { $0 == baseline }
        // The live count reaching baseline proves only that `onTermination` ran
        // and `terminate()` issued `src.cancel()`; the FD is closed later still,
        // in the source's cancel handler on a utility-QoS queue. Hence the
        // longer, load-tolerant deadline — a hang guard, not a latency budget.
        await Self.poll("exactly one FD closed (baseline \(fdBaseline))",
                        timeout: Self.fdCloseTimeout,
                        observing: { FileWatcher.closedFDCount }) { $0 == fdBaseline + 1 }
    }

    /// Cancelling the consuming `Task` (the SwiftUI `.task` analogue) must also
    /// drive the stream's onTermination and close the FD — that's the most
    /// common real-world cleanup path.
    @Test func cancellingConsumingTaskTerminatesStream() async {
        let baseline = FileWatcher.liveStreamCount
        let fdBaseline = FileWatcher.closedFDCount

        let tmpURL = Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let w = FileWatcher()
        let path = tmpURL.path
        let task = Task {
            for await _ in w.changes(for: path) {
                // Nothing to do — we just need a live consumer.
            }
        }

        // This used to be a single `await Task.yield()`, which was the live
        // flake: `yield()` keeps this task RUNNABLE and re-enqueues it behind
        // every other runnable task in a 1300-test target, so it competes with
        // the very task it is waiting for and one turn guarantees nothing. The
        // poll below sleeps instead, which makes this task non-runnable and
        // hands the executor back — the same reasoning
        // `ClockTestSupport.waitForSuspension` documents.
        await Self.poll("consuming task reached changes(for:) (baseline \(baseline))",
                        observing: { FileWatcher.liveStreamCount }) { $0 >= baseline + 1 }

        task.cancel()
        _ = await task.value

        await Self.poll("liveStreamCount back to baseline \(baseline)",
                        observing: { FileWatcher.liveStreamCount }) { $0 == baseline }
        // Utility-QoS cancel handler again — see the sibling test above. This
        // deadline also protects the PRECEDING test's assertion transitively:
        // the baseline read at the top of this test is only clean if the
        // previous test's close had already landed, so a deadline too thin to
        // outlast the starvation reddens twice — once as a missing close here,
        // once as a doubled count in the next test to capture a baseline.
        await Self.poll("exactly one FD closed (baseline \(fdBaseline))",
                        timeout: Self.fdCloseTimeout,
                        observing: { FileWatcher.closedFDCount }) { $0 == fdBaseline + 1 }
    }

    /// Opening a non-existent path must finish the stream cleanly — no hang, no
    /// leak. The for-await loop should exit immediately, and since `open()`
    /// never succeeded there is no FD to close.
    @Test func nonExistentPathFinishesStreamImmediately() async {
        let baseline = FileWatcher.liveStreamCount
        let fdBaseline = FileWatcher.closedFDCount
        let w = FileWatcher()
        let bogus = "/definitely/does/not/exist/\(UUID().uuidString)"

        var receivedAny = false
        for await _ in w.changes(for: bogus) {
            receivedAny = true
        }
        #expect(receivedAny == false)

        await Self.poll("liveStreamCount back to baseline \(baseline)",
                        observing: { FileWatcher.liveStreamCount }) { $0 == baseline }
        #expect(FileWatcher.closedFDCount == fdBaseline,
                "open() failed, so no dispatch source and no FD to close")
    }

    // MARK: - Debounce (tier 2: real FS event, virtual timer)

    /// Tier 2. Several writes inside one window collapse to a single
    /// notification, and it lands only at the full `debounceInterval`.
    ///
    /// No virtual time elapses between the writes, so every one of them arms
    /// its timer at the same virtual deadline — which is exactly what makes the
    /// boundary assertion below unambiguous. (`writeUntilArmed` may itself
    /// write more than once; extra writes inside the same window are more of
    /// the input this test collapses, not a confound.)
    @Test func writesWithinOneWindowCollapseToOneNotification() async {
        await Self.withWatchedFile { f in
            await Self.writeUntilArmed(f, firstWriteAfterResume: true)
            await Self.writeUntilArmed(f)
            await Self.writeUntilArmed(f)

            // Discriminating by TIMING, not by yield count: `continuation.yield()`
            // has two producers — the debounce task and `performReopen()` on a
            // successful re-open — so a bare "one yield" assertion has two ways
            // to pass. 150 ms is the debounce, 50 ms the re-open; landing on the
            // 150 ms boundary is what pins the producer.
            //
            // The early and the confirming assertion cover two DIFFERENT
            // production defects — they are not one belt and one brace:
            //
            // - Delete `scheduleDebouncedNotify`'s `Task.isCancelled` guard and
            //   the EARLY assertion below goes red. Cancelling a task suspended
            //   on a clock resumes it with `CancellationError` at `cancel()`
            //   time and removes its suspension, so the two superseded sleeps
            //   resume during the second and third `writeUntilArmed` above — no
            //   advance involved. `try?` swallows the error, `yieldIfActive()`
            //   finds the stream still live, and the stale yields land before
            //   virtual time has moved at all.
            // - Delete `i.debounceTask?.cancel()` instead — never cancel a
            //   superseded debounce — and the early assertion stays green: all
            //   three sleeps simply run to the same virtual deadline. The
            //   CONFIRMING re-assertion at the bottom is what reddens then, and
            //   that is the mutation it was measured against.
            await f.clock.advanceWhenSuspended(by: FileWatcher.debounceInterval - .milliseconds(1))
            #expect(f.yields.count == 0, "one millisecond short of the window must not notify")

            await f.clock.advance(by: .milliseconds(1))
            await Self.poll("a notification landed on the debounce boundary",
                            observing: { f.yields.count }) { $0 == 1 }

            // `poll` returns on the FIRST read that satisfies its condition, so
            // the poll above proves only "the count reached 1" — a second
            // notification arriving afterwards is never looked at. The confirming
            // advance below is what upgrades that into "one fired and nothing
            // else was pending": a further full window with no yield.
            //
            // Plain `advance(by:)`, NOT `advanceWhenSuspended(by:)`: the debounce
            // has already fired, so there is no sleeper registered and waiting
            // for a suspension would (correctly) time out and record a spurious
            // Issue. Do not "fix" this to `advanceWhenSuspended`.
            await f.clock.advance(by: FileWatcher.debounceInterval)
            let settled = f.yields.count
            #expect(settled == 1,
                    "three writes in one window must collapse to one notification: observed \(settled)")
        }
    }

    /// Tier 2. The boundary assertion no wall-clock test can express: nothing
    /// fires at `debounceInterval - 1ms`, and the notification lands on the
    /// very next millisecond.
    @Test func nothingFiresUntilTheFullIntervalElapsed() async {
        await Self.withWatchedFile { f in
            await Self.writeUntilArmed(f, firstWriteAfterResume: true)

            await f.clock.advanceWhenSuspended(by: FileWatcher.debounceInterval - .milliseconds(1))
            #expect(f.yields.count == 0, "the debounce must not fire early")

            await f.clock.advance(by: .milliseconds(1))
            await Self.poll("notification on the debounce boundary",
                            observing: { f.yields.count }) { $0 == 1 }

            // Confirming advance — `poll` exits on the first satisfying read, so
            // without this the test would also pass if the single write somehow
            // produced a second notification a window later. Plain `advance(by:)`
            // deliberately: the debounce has fired, no sleeper is registered, and
            // `advanceWhenSuspended` would time out and record a spurious Issue.
            await f.clock.advance(by: FileWatcher.debounceInterval)
            let settled = f.yields.count
            #expect(settled == 1,
                    "one write must notify exactly once, at the boundary: observed \(settled)")
        }
    }

    /// Tier 2. Trailing edge: a write partway through the window cancels the
    /// pending deadline and arms a fresh one, so the *original* deadline must
    /// pass without a notification.
    ///
    /// The second `writeUntilArmed` is what makes this sound rather than
    /// hopeful, but only up to what it actually establishes: the FS event was
    /// delivered and a *new* sleep is armed at the restarted deadline, so the
    /// advance below cannot cross the original deadline before the late write
    /// has taken effect. It does **not** establish that the superseded timer is
    /// already cancelled — `RecordingClock` records the arm on *entry* to
    /// `sleep`, while the old task's `cancel()` happens in
    /// `scheduleDebouncedNotify`'s `inner.withLock` on the dispatch queue,
    /// concurrently with the new task's body. Residual, named because it is
    /// real: a pathologically delayed cancel could still let the old deadline
    /// fire. It would fail RED here, not pass silently.
    @Test func lateWriteRestartsTheWindow() async {
        await Self.withWatchedFile { f in
            await Self.writeUntilArmed(f, firstWriteAfterResume: true)
            await f.clock.advanceWhenSuspended(by: .milliseconds(100))
            #expect(f.yields.count == 0)

            await Self.writeUntilArmed(f)

            // Now at virtual 100 with a deadline at 250. Advancing 149 crosses
            // the ORIGINAL deadline (150) — if the window had not restarted,
            // this is where the stale notification would land.
            await f.clock.advanceWhenSuspended(by: FileWatcher.debounceInterval - .milliseconds(1))
            #expect(f.yields.count == 0, "the superseded deadline must not fire")

            await f.clock.advance(by: .milliseconds(1))
            await Self.poll("a notification landed at the restarted deadline",
                            observing: { f.yields.count }) { $0 == 1 }

            // Confirming advance — the poll above exits on its first satisfying
            // read, so on its own it cannot distinguish "the restarted window
            // notified once" from "the superseded deadline also fired, just
            // later". Plain `advance(by:)` deliberately: the debounce has fired,
            // no sleeper is registered, and `advanceWhenSuspended` would time out
            // and record a spurious Issue.
            await f.clock.advance(by: FileWatcher.debounceInterval)
            let settled = f.yields.count
            #expect(settled == 1,
                    "the restarted window must notify exactly once: observed \(settled)")
        }
    }

    /// Tier 2. Writes separated by a full window notify twice. With `Void`
    /// elements the only observable ordering is *when* each arrives, so the
    /// per-window assertions below are the ordering assertion: the count is 1
    /// after the first window closes and 2 after the second.
    @Test func separatedWritesNotifyTwice() async {
        await Self.withWatchedFile { f in
            await Self.writeUntilArmed(f, firstWriteAfterResume: true)
            await f.clock.advanceWhenSuspended(by: FileWatcher.debounceInterval)
            await Self.poll("first window notified",
                            observing: { f.yields.count }) { $0 == 1 }

            await Self.writeUntilArmed(f)
            await f.clock.advanceWhenSuspended(by: FileWatcher.debounceInterval)
            await Self.poll("second window notified",
                            observing: { f.yields.count }) { $0 == 2 }

            // Confirming advance, same reason as the sibling debounce tests:
            // `poll` exits on the first read that satisfies it, so on its own it
            // proves only "at least two" — a notify-per-write regression would
            // pass through 2 on its way to 3+. Plain `advance(by:)` deliberately:
            // both windows have fired, no sleeper is registered, and
            // `advanceWhenSuspended` would time out and record a spurious Issue.
            await f.clock.advance(by: FileWatcher.debounceInterval)
            let settled = f.yields.count
            #expect(settled == 2,
                    "two separated writes must notify exactly twice: observed \(settled)")
        }
    }

    /// Tier 2. Atomic save: `rename(2)` a different file over the watched path.
    /// The watched inode is unlinked, so the source reports `.delete`, and the
    /// watcher re-opens the path after `reopenDelay` — 50 ms, not 150 ms, which
    /// is what distinguishes the re-open producer of `yield()` from the
    /// debounce producer.
    @Test func atomicSaveReopensAndKeepsStreamLive() async {
        await Self.withWatchedFile { f in
            // Warm-up: prove the dispatch source is registered and delivering
            // before the rename. `DispatchSource.resume()` registers its kqueue
            // filter asynchronously, and unlike a write a rename cannot be
            // retried against the same temp file, so liveness is established
            // first rather than assumed.
            await Self.writeUntilArmed(f, firstWriteAfterResume: true)
            await f.clock.advanceWhenSuspended(by: FileWatcher.debounceInterval)
            await Self.poll("watcher is live before the rename",
                            observing: { f.yields.count }) { $0 == 1 }

            let fdBaseline = FileWatcher.closedFDCount
            let replacement = Self.makeTempFile(contents: "replaced")
            defer { try? FileManager.default.removeItem(at: replacement) }
            // Hoisted out of `#expect` so the String-to-C-pointer conversion
            // stays in a plain call argument position.
            let renamed = rename(replacement.path, f.path)
            #expect(renamed == 0, "rename(2) over the watched path failed: errno=\(errno)")

            await f.clock.advanceWhenSuspended(by: FileWatcher.reopenDelay - .milliseconds(1))
            #expect(f.yields.count == 1, "the re-open must not land before reopenDelay")

            await f.clock.advance(by: .milliseconds(1))
            await Self.poll("re-open notified",
                            observing: { f.yields.count }) { $0 == 2 }
            // The previous epoch's source is cancelled by the re-open, so its
            // FD is closed — the "we never leak" half of the atomic-save story.
            // Utility-QoS cancel handler, so the long deadline: load-tolerant,
            // not load-independent.
            await Self.poll("the pre-rename FD was closed (baseline \(fdBaseline))",
                            timeout: Self.fdCloseTimeout,
                            observing: { FileWatcher.closedFDCount }) { $0 == fdBaseline + 1 }

            // Still live: a write to the re-opened inode still debounces.
            // `firstWriteAfterResume: true` because `performReopen()` built and
            // resumed a BRAND NEW dispatch source, so the asynchronous kqueue
            // registration race genuinely applies again — this is the one place
            // in the suite where a retry is legitimately silent rather than
            // reported as event loss.
            await Self.writeUntilArmed(f, firstWriteAfterResume: true)
            await f.clock.advanceWhenSuspended(by: FileWatcher.debounceInterval)
            await Self.poll("re-opened stream still debounces",
                            observing: { f.yields.count }) { $0 == 3 }
        }
    }

    /// Tier 2. Teardown while a debounce timer is **armed and pending** must
    /// still complete: `onTermination` runs (live count back to baseline) and
    /// the dispatch source's cancel handler closes the FD. `closedFDCount` is
    /// the load-bearing half — deleting `src?.cancel()` from `terminate()`
    /// reddens it while leaving the live count green, since that counter is
    /// decremented on a line independent of `box.terminate()`.
    ///
    /// What this deliberately does NOT cover: "a terminated stream must not
    /// yield", i.e. the `terminated` re-check inside `yieldIfActive()`. That
    /// invariant is unobservable from outside the box, because the only observer
    /// of a yield is a consumer that by then no longer exists — cancelling it
    /// and awaiting its value is precisely what guarantees its `for await` loop
    /// has exited, so any notification counter is frozen before the assertion
    /// runs and cannot distinguish a correct drop from a stale yield into the
    /// void. Observing it would need a DEBUG counter at production's yield site,
    /// which is out of scope here.
    @Test func terminationWithAPendingDebounceStillClosesTheFD() async {
        let baseline = FileWatcher.liveStreamCount
        let fdBaseline = FileWatcher.closedFDCount

        await Self.withWatchedFile { f in
            await Self.writeUntilArmed(f, firstWriteAfterResume: true)

            f.consumer.cancel()
            _ = await f.consumer.value

            await Self.poll("liveStreamCount back to baseline \(baseline)",
                            observing: { FileWatcher.liveStreamCount }) { $0 == baseline }
            // Utility-QoS cancel handler, so the long deadline: the invariant is
            // exact, its observability is load-tolerant.
            await Self.poll("the watched FD was closed (baseline \(fdBaseline))",
                            timeout: Self.fdCloseTimeout,
                            observing: { FileWatcher.closedFDCount }) { $0 == fdBaseline + 1 }
        }
    }

    // MARK: - Default clock (tier 2, real time — the only test that reaches the real sleep)

    /// Tier 2 on the **production default clock**, and the only test here that
    /// actually reaches `clock.sleep` with it: construct `FileWatcher()` with no
    /// clock argument, write once, wait out the real ~150 ms window.
    ///
    /// Why it earns a real wait: every other test in this suite would stay green
    /// if the production default were swapped for a `TestClock`, or if the sleep
    /// were taken on some clock other than the injected one — the lifecycle
    /// tests never write, and the debounce tests inject their own clock. This is
    /// the only assertion that fails in either case. The wait is bounded polling
    /// for an event that MUST occur (assertion-hygiene rule 3), not a timing
    /// tolerance: the retry loop below is bounded by the production debounce
    /// itself, and the poll after it takes the suite's 8 s fast-tier hang guard
    /// — ~53× the 150 ms it is waiting on, and the cheapest budget in the suite
    /// (nothing else in this test can pay a deadline).
    @Test func defaultClockDeliversOneRealDebouncedNotification() async {
        let url = Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let yields = Counter()
        let watcher = FileWatcher()  // No clock argument: this is the point of the test.
        let stream = watcher.changes(for: url.path)
        let consumer = Task { for await _ in stream { yields.record() } }

        // Same `DispatchSource.resume()` registration race `writeUntilArmed`
        // exists for, but there is no arm counter behind a real clock, so the
        // retry observes the notification itself. Each attempt waits out three
        // full windows before retrying — long enough that a merely slow first
        // event has already produced its yield, so a retry racing it would show
        // up as a second notification and redden the `== 1` below rather than
        // being absorbed.
        for _ in 0..<4 {
            Self.appendByte(to: url.path)
            let attemptDeadline = ContinuousClock.now.advanced(by: FileWatcher.debounceInterval * 3)
            while yields.count == 0, ContinuousClock.now < attemptDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if yields.count > 0 { break }
        }

        await Self.poll("the real 150 ms debounce delivered exactly one notification",
                        observing: { yields.count }) { $0 == 1 }

        consumer.cancel()
        _ = await consumer.value
    }

    // MARK: - Fixture

    /// Everything a debounce test needs, all `Sendable` so the consuming `Task`
    /// and the polling helpers can share it.
    private struct Fixture: Sendable {
        let path: String
        /// The `TestClock` to advance. Production sees the `RecordingClock`
        /// wrapper around it; virtual time is this clock's.
        let clock: TestClock<Swift.Duration>
        /// Number of sleeps production has armed on the clock.
        let armed: Counter
        /// Number of `AsyncStream` elements the consumer has received.
        let yields: Counter
        let consumer: Task<Void, Never>
    }

    /// A `Clock` that delegates to a `TestClock` and counts every armed sleep.
    ///
    /// Why the count is needed: `TestClock.checkSuspension()` only answers "is
    /// *anything* suspended", so it cannot tell a superseded debounce still
    /// being cleaned up from the fresh one a later write just armed — the
    /// limitation `AppearanceDebounceTests.lateChangeRestartsWindow` documents.
    /// Counting arms turns "the FS event was delivered and the timer
    /// re-armed" into a positive, pollable fact instead of something inferred
    /// from elapsed wall time.
    ///
    /// Delegating (the `CancelOnResumeClock` shape) rather than reimplementing
    /// keeps virtual time exactly `TestClock`'s, so `advanceWhenSuspended` on
    /// the base clock behaves normally.
    private struct RecordingClock: Clock {
        let base: TestClock<Swift.Duration>
        let armed: Counter

        var now: TestClock<Swift.Duration>.Instant { base.now }
        var minimumResolution: Swift.Duration { base.minimumResolution }

        func sleep(until deadline: TestClock<Swift.Duration>.Instant,
                   tolerance: Swift.Duration?) async throws {
            armed.record()
            try await base.sleep(until: deadline, tolerance: tolerance)
        }
    }

    /// Lock-guarded counter shared between the consuming `Task` (arbitrary
    /// executor), the dispatch queue, and the test body.
    private final class Counter: Sendable {
        private let state = OSAllocatedUnfairLock<Int>(initialState: 0)
        var count: Int { state.withLock { $0 } }
        func record() { state.withLock { $0 += 1 } }
    }

    /// Real temp file + real dispatch source + injected `TestClock`, torn down
    /// unconditionally.
    ///
    /// Two one-sidednesses to keep in mind when reading any `yields.count`
    /// assertion in this suite — both make the counts a lower bound, never an
    /// exact figure:
    ///
    /// - The stream is `.bufferingNewest(1)`, so a burst of yields the consumer
    ///   has not drained yet collapses. Notification counts can therefore
    ///   *under*-report and never over-report.
    /// - The `#expect(count == 0, "must not notify early")` checks read the
    ///   counter immediately after an advance, with no settling, so a
    ///   pathologically late stale yield could arrive after the read. They can
    ///   false-PASS but never false-FAIL.
    private static func withWatchedFile(_ body: (Fixture) async -> Void) async {
        let url = makeTempFile()
        // `defer`, not a trailing call: a temp file must not survive a failing
        // body.
        defer { try? FileManager.default.removeItem(at: url) }

        let clock = TestClock<Swift.Duration>()
        let armed = Counter()
        let yields = Counter()
        let fdBaseline = FileWatcher.closedFDCount
        let watcher = FileWatcher(clock: RecordingClock(base: clock, armed: armed))
        // Built here, synchronously, and NOT inside the consuming Task:
        // `AsyncStream`'s build closure runs during `init`, so the FD is open
        // and the dispatch source resumed before the first write below. The
        // stream also buffers the newest element, so nothing is lost if the
        // consumer has not started iterating yet.
        let stream = watcher.changes(for: url.path)
        // A `Task` inheriting `@MainActor` mirrors production, where the
        // consumer is a SwiftUI `.task`.
        let consumer = Task { for await _ in stream { yields.record() } }

        await body(Fixture(path: url.path, clock: clock, armed: armed, yields: yields, consumer: consumer))

        consumer.cancel()
        _ = await consumer.value

        // Cancelling the consumer only *issues* `src.cancel()`; `close(fd)` runs
        // later, in the source's GCD cancel handler. Without waiting here every
        // debounce test would return with a `closedFDCount` increment still in
        // flight, and the lifecycle tests' strict `== fdBaseline + 1` assertions
        // would be safe only because the serialized suite happens to run them
        // first in source order — insert or reorder a test and a stray late
        // close lands mid-assertion. Waiting for quiescence removes that
        // ordering coupling.
        //
        // Quiescence, not an exact count: the number of FDs this fixture opened
        // is 1 + however many times the body provoked a re-open, which is not
        // observable from out here. So: at least one close, and the count
        // unchanged across two probes.
        //
        // 12s, not 4s: this waits on the same utility-QoS cancel handler as the
        // `fdCloseTimeout` polls, so a deadline that expires under contention
        // hands the NEXT test a baseline with a close still in flight — which
        // then reddens as a doubled count there rather than as anything about
        // this test. Not `fdCloseTimeout` itself, because this is not an
        // assertion and it has to share a 60s test with the guards that are;
        // 12s is what `writesWithinOneWindowCollapseToOneNotification` (3 armed
        // writes + a 15s handshake + a poll = 47s) leaves under the limit.
        // Costs ~20ms on the healthy path either way.
        let settleDeadline = ContinuousClock.now.advanced(by: .seconds(12))
        var previous = -1
        while ContinuousClock.now < settleDeadline {
            let current = FileWatcher.closedFDCount
            if current == previous, current > fdBaseline { break }
            previous = current
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Helpers

    private static func makeTempFile(contents: String = "hi",
                                     sourceLocation: SourceLocation = #_sourceLocation) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filewatcher-test-\(UUID().uuidString).txt")
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8)),
                sourceLocation: sourceLocation)
        return url
    }

    /// Appends a byte to the watched file, retrying until the watcher has armed
    /// a **new** sleep on the clock.
    ///
    /// Why a loop and not a single write: `DispatchSource.resume()` registers
    /// its kqueue filter asynchronously on the source's own queue, so a write
    /// issued right after `changes(for:)` returns can land before the source is
    /// watching and be lost forever — which would leave the following
    /// `advanceWhenSuspended` waiting out its whole hang guard. This is bounded
    /// polling on real IO (assertion-hygiene rule 3), not a timing assertion.
    ///
    /// Timing-neutral by construction: virtual time does not move here, and the
    /// debounce is trailing-edge, so each extra write merely re-arms a timer at
    /// the same virtual deadline.
    ///
    /// **What returning establishes, exactly**: the FS event was delivered and
    /// production entered `clock.sleep` for a *new* timer — `RecordingClock`
    /// records the arm on ENTRY to `sleep`. It does **not** establish that a
    /// superseded timer has already been cancelled: that `cancel()` happens in
    /// `scheduleDebouncedNotify`'s `inner.withLock` on the dispatch queue,
    /// concurrently with the new task's body. Nor does the counter discriminate
    /// producers — it counts *every* sleep armed on the clock, re-open sleeps
    /// included, so it conflates them the same way a raw yield count would.
    /// Measured here, one `appendByte` usually arms **twice**, because `.write`
    /// and `.extend` arrive as two handler invocations. So this is a liveness
    /// signal, not a write count; only "strictly more than before" is meaningful.
    ///
    /// - Parameter firstWriteAfterResume: pass `true` only for the first write
    ///   against a freshly-`resume()`d dispatch source (stream start, or just
    ///   after a re-open installed a new source), where losing the event is the
    ///   documented GCD registration race above and retrying is legitimate. For
    ///   any later write the source has already proven it delivers, so a dropped
    ///   event is a production defect — see the `Issue` below. Defaults to the
    ///   strict reading so a new call site does not silently paper over one.
    private static func writeUntilArmed(_ f: Fixture,
                                        firstWriteAfterResume: Bool = false,
                                        // 8s, matching `poll`'s default: the arm this waits for is
                                        // recorded by a `Task` that the dispatch source's event
                                        // handler creates, so it inherits utility QoS and is starved
                                        // by the same CI contention. Sized against the tightest test
                                        // that chains three of these — see the suite header.
                                        timeout: Duration = .seconds(8),
                                        pollInterval: Duration = .milliseconds(25),
                                        sourceLocation: SourceLocation = #_sourceLocation) async {
        let before = f.armed.count
        let deadline = ContinuousClock.now.advanced(by: timeout)
        // Per-write settling window, and the load-sensitive number in this
        // helper: exceeding it does not just cost a retry, it *records the
        // event-loss Issue below*. At 250 ms that made it a wall-clock tolerance
        // window on real GCD delivery (assertion-hygiene rule 2) — healthy
        // delivery is low single-digit milliseconds, but the CI contention that
        // reddened this suite inflated sub-second siblings to 22.9 s, so a merely
        // slow delivery would have been reported as production event loss. 4 s
        // is a threshold for "the event is gone", not a latency budget, and still
        // affords a second attempt inside `timeout`.
        let attemptWindow: Duration = .seconds(4)
        var writes = 0
        repeat {
            appendByte(to: f.path, sourceLocation: sourceLocation)
            writes += 1
            // Each write gets its own settling window before we consider it lost.
            // Probing `armed` synchronously right after the write would always
            // read stale — GCD delivers the event on the source's own queue — so
            // a retry would be the NORMAL path and the event-loss Issue below
            // would be pure noise. (It was, until this loop was reshaped.)
            let attemptDeadline = min(ContinuousClock.now.advanced(by: attemptWindow), deadline)
            while f.armed.count <= before, ContinuousClock.now < attemptDeadline {
                try? await Task.sleep(for: pollInterval)
            }
            if f.armed.count > before { return }
            if writes == 1, !firstWriteAfterResume {
                // Not the registration race: this source has already delivered
                // at least one event, so a lost write is production event loss —
                // exactly what this suite exists to catch. Reported once, and the
                // loop still retries, so the test fails here with a diagnosis
                // instead of wedging on the next `advanceWhenSuspended`.
                Issue.record(
                    Failure("""
                        FileWatcher missed a write against an already-registered dispatch source \
                        (\(f.path)) within \(attemptWindow): armed count is still \(before). \
                        Retrying, but this is event loss, not the resume() registration race.
                        """),
                    sourceLocation: sourceLocation
                )
            }
        } while ContinuousClock.now < deadline
        Issue.record(
            Failure("""
                FileWatcher armed no new timer within \(timeout): armed count is \
                \(f.armed.count), was \(before) before \(writes) write(s) to \(f.path). \
                The dispatch source never delivered the write event.
                """),
            sourceLocation: sourceLocation
        )
    }

    private static func appendByte(to path: String,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        guard let handle = FileHandle(forWritingAtPath: path) else {
            Issue.record("could not open \(path) for writing", sourceLocation: sourceLocation)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("x".utf8))
    }

    /// Bounded poll for a condition driven by real scheduling or real GCD
    /// teardown (cancel handlers, `onTermination`, `AsyncStream` delivery).
    ///
    /// `timeout` is a **hang guard, not a tolerance window**: the healthy path
    /// exits on the first probe, and only genuinely broken teardown ever pays
    /// the full deadline. The loops this replaces polled `10 × 20 ms = 200 ms`,
    /// which *was* a tolerance window — thin enough to lose under CI load
    /// (assertion-hygiene rule 2).
    ///
    /// The 8 s default covers the fast counters, whose producer is the consuming
    /// `Task` and the `AsyncStream` machinery. Callers waiting on `close(fd)`
    /// pass `fdCloseTimeout` instead — that one runs on a utility-QoS queue and
    /// is starved an order of magnitude harder. Both values, and the per-test
    /// arithmetic they come from, are in the suite header.
    ///
    /// Failure is recorded as an **error**, not as `#expect(cond, "…")` and not
    /// as `Issue.record("…")`: both of those render their message on a separate
    /// `↳` continuation line, and CI summaries quote only the primary line. That
    /// is why the real CI failure this budget was written for read
    ///
    ///     Expectation failed: condition(value → 0)
    ///
    /// which carries the observed value but names neither the counter nor what
    /// it was waiting for — two adjacent polls in the same test are then
    /// distinguishable only by column number. `Issue.record(_: some Error)`
    /// renders as `Caught error: <description>`, so description *and* observed
    /// value land in the primary line (rule 4, the `fileBytesUnmatched` shape).
    private static func poll(_ description: String,
                             timeout: Duration = .seconds(8),
                             pollInterval: Duration = .milliseconds(25),
                             sourceLocation: SourceLocation = #_sourceLocation,
                             observing observed: () -> Int,
                             satisfies condition: (Int) -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var value = observed()
        while !condition(value), ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            value = observed()
        }
        guard !condition(value) else { return }
        Issue.record(
            Failure("FileWatcher: \(description) — observed \(value) after polling up to \(timeout)"),
            sourceLocation: sourceLocation
        )
    }

    /// Failure payload for `Issue.record(_: some Error)`, whose primary console
    /// line is `Caught error: <description>`. See `poll` for why the message
    /// has to travel as an error rather than as a comment.
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
