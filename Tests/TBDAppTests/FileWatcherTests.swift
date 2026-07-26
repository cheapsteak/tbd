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
@MainActor
@Suite("FileWatcher", .clockDriven, .serialized)
struct FileWatcherTests {

    // MARK: - Lifecycle (tier 2, DEFAULT clock — but they never reach the sleep; see the suite header)

    /// Construct many watchers without ever calling `changes(for:)`.
    /// `FileWatcher` itself is a stateless factory, so this should be trivially
    /// balanced — no streams alive.
    @Test func factoryConstructionIsStateless() async {
        let baseline = FileWatcher.liveStreamCount
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
        // `changes(for:)` was never called, so no stream ever existed, and
        // releasing watchers that started nothing has no asynchronous effect
        // to settle. The re-assertion still earns its place — it says releasing
        // them must not move the counter.
        //
        // This used to be `await Task.yield()`, which was not merely redundant
        // but actively harmful: `yield()` keeps the calling task RUNNABLE and
        // re-enqueues it behind every other runnable task in a large parallel
        // target — the same non-converging spin
        // `cancellingConsumingTaskTerminatesStream` documents. Measured under a
        // full-target run it cost this one test 22.4s.
        #expect(FileWatcher.liveStreamCount == baseline)
    }

    /// Start a stream against a real temp file, drop the iterator, and confirm
    /// the stream's `onTermination` ran (live count returns to baseline).
    ///
    /// That is the whole extent of what this can currently observe:
    /// `liveStreamCount` is decremented inside `onTermination` itself, on a line
    /// independent of `box.terminate()`, so it says nothing about whether the
    /// dispatch source was cancelled or its FD closed.
    @Test func liveStreamCountReturnsToBaselineAfterIteratorDrops() async {
        let baseline = FileWatcher.liveStreamCount

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
    }

    /// Cancelling the consuming `Task` (the SwiftUI `.task` analogue) must also
    /// drive the stream's onTermination — that's the most common real-world
    /// cleanup path.
    @Test func cancellingConsumingTaskTerminatesStream() async {
        let baseline = FileWatcher.liveStreamCount

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
    }

    /// Opening a non-existent path must finish the stream cleanly — no hang, no
    /// leak. The for-await loop should exit immediately.
    @Test func nonExistentPathFinishesStreamImmediately() async {
        let baseline = FileWatcher.liveStreamCount
        let w = FileWatcher()
        let bogus = "/definitely/does/not/exist/\(UUID().uuidString)"

        var receivedAny = false
        for await _ in w.changes(for: bogus) {
            receivedAny = true
        }
        #expect(receivedAny == false)

        await Self.poll("liveStreamCount back to baseline \(baseline)",
                        observing: { FileWatcher.liveStreamCount }) { $0 == baseline }
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
    /// tolerance, and the deadlines below are hang guards sized generously
    /// because real GCD delivery plus a real debounce is the thing being waited
    /// on.
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
                        timeout: .seconds(10),
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
                                        // 4s, not 12s: `.clockDriven` kills the test at 60s, and
                                        // `atomicSaveReopensAndKeepsStreamLive` chains 2 of these,
                                        // 4 polls, and 3 fixed 15s `advanceWhenSuspended` waits. At
                                        // 12s each, a single stuck helper could sit past the suite
                                        // limit and its named diagnostic below would never print —
                                        // the uninformative "wedged" outcome `ClockTestSupport` warns
                                        // about. 4s keeps the first stuck helper's report well inside
                                        // the limit, and the healthy path never pays it.
                                        timeout: Duration = .seconds(4),
                                        pollInterval: Duration = .milliseconds(25),
                                        sourceLocation: SourceLocation = #_sourceLocation) async {
        let before = f.armed.count
        let deadline = ContinuousClock.now.advanced(by: timeout)
        // Per-write settling window: generous next to real GCD delivery (low
        // single-digit milliseconds here) yet small enough that `timeout` still
        // affords a retry or two before the hang guard fires.
        let attemptWindow: Duration = .milliseconds(250)
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
                    """
                    FileWatcher missed a write against an already-registered dispatch source \
                    (\(f.path)) within \(attemptWindow): armed count is still \(before). \
                    Retrying, but this is event loss, not the resume() registration race.
                    """,
                    sourceLocation: sourceLocation
                )
            }
        } while ContinuousClock.now < deadline
        Issue.record(
            """
            FileWatcher armed no new timer within \(timeout): armed count is \
            \(f.armed.count), was \(before) before \(writes) write(s) to \(f.path). \
            The dispatch source never delivered the write event.
            """,
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
    /// (assertion-hygiene rule 2). Failure reports the OBSERVED value, not just
    /// the expectation (rule 4).
    ///
    /// 4s rather than 12s for the same reason as `writeUntilArmed`: a test that
    /// chains several of these plus a few fixed 15s `advanceWhenSuspended` waits
    /// must get the first stuck helper's diagnostic out well inside
    /// `.clockDriven`'s 60s limit, or the suite limit fires first and reports an
    /// uninformative "wedged" instead.
    private static func poll(_ description: String,
                             timeout: Duration = .seconds(4),
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
        #expect(condition(value),
                "\(description): observed \(value) after polling up to \(timeout)",
                sourceLocation: sourceLocation)
    }
}
