import Foundation
import TestSupport
import Testing

/// Tier 1 — proof that the shared clock machinery in
/// `Tests/TestSupport/EventDrivenTestClock.swift` does what the suites relying
/// on it assume. In-process state only: no filesystem, no subprocess, no
/// `~/tbd`, and the only real sleeps are the scheduling handshake itself
/// (bounded polling, `Tests/CLAUDE.md` assertion-hygiene rule 3) plus the
/// deliberately tiny hang-guard timeouts two tests drive to their diagnostic.
///
/// Why a self-test suite exists at all: this clock's whole value is that its
/// arming signal is emitted **after** the sleeper is registered, and that its
/// `advance` resumes due sleepers without relying on a megaYield to do it. Both
/// are invisible properties — a clock that silently stopped signalling would
/// look identical to a working one until some unrelated suite started timing
/// out at 45 s. Same reasoning as `FlakyQuarantineSelfTests`, which lives here
/// for the same reason (`TestSupport` machinery, proven in the daemon target).
///
/// Design: `docs/specs/2026-08-11-event-driven-test-clock-design.md`.
@Suite("EventDrivenTestClock self-tests", .clockDriven)
struct EventDrivenTestClockSelfTests {
    // MARK: Helpers

    /// Bounded poll on an in-process condition, for the handshake only.
    ///
    /// Real `Task.sleep` rather than `Task.yield()`: yielding keeps this task
    /// runnable and re-queues it behind the very task it is waiting for (see
    /// `ClockTestSupport.waitForSuspension`'s long note). Non-throwing with a
    /// named diagnostic on timeout, so a wedged handshake is attributed here
    /// instead of hanging.
    private static func waitUntil(_ what: String,
                                  timeout: Swift.Duration = .seconds(30),
                                  sourceLocation: SourceLocation = #_sourceLocation,
                                  _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(
            HandshakeTimeout(what: what, timeout: timeout),
            sourceLocation: sourceLocation
        )
    }

    /// Lock-guarded latch for observing a specific issue from
    /// `withKnownIssue`'s matcher, which runs outside the test body and is not
    /// a place to mutate a captured `var`.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var latched = false

        func latch() { lock.withLock { latched = true } }
        var isLatched: Bool { lock.withLock { latched } }
    }

    /// The same idea one step further: the matcher hands the *text* out, not
    /// just the fact that something matched. A test that compares two
    /// diagnostics has to hold both of them.
    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func set(_ value: String) { lock.withLock { text = value } }
        var value: String { lock.withLock { text } }
    }

    private struct HandshakeTimeout: Error, CustomStringConvertible {
        let what: String
        let timeout: Swift.Duration

        var description: String {
            "EventDrivenTestClock self-test: still not true after \(timeout) — observed: \(what)"
        }
    }

    /// A task that reaches `clock.sleep` only *after* it has been cancelled.
    ///
    /// Cancelling a freshly created `Task` races its first execution, so a test
    /// that just called `cancel()` cannot know whether the sleep saw the
    /// cancellation. Spinning on `Task.isCancelled` first removes the race: the
    /// sleep is guaranteed to be entered by an already-cancelled task.
    private static func sleepAfterCancellation(
        on clock: EventDrivenTestClock,
        for duration: Swift.Duration
    ) -> Task<String, Never> {
        Task {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
            do {
                try await clock.sleep(for: duration)
                return "returned"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other: \(error)"
            }
        }
    }

    // MARK: Arming

    /// The property the whole design turns on: a waiter that parked *before* any
    /// sleeper existed is released by the registration itself, not by a probe.
    /// The wait for `hasParkedArmingWaiter` is what makes this a real test —
    /// without it the sleeper could register first and the fast path would pass
    /// the test with the signal deleted.
    @Test("a waiter parked before any sleep is resumed by a later registration")
    func parkedWaiterIsResumedByRegistration() async {
        let clock = EventDrivenTestClock()
        let recorder = FireRecorder<String>()

        async let armed: Void = clock.sleeperArmed()
        await Self.waitUntil("an arming waiter is parked") { clock.hasParkedArmingWaiter }

        let sleeper = Task { [clock] in
            try? await clock.sleep(for: .seconds(1))
            recorder.record("woke")
        }
        await armed

        #expect(clock.hasSleeper, "the signal must not arrive before the ledger append")
        await clock.advance(by: .seconds(1))
        #expect(await recorder.next() == "woke")
        _ = await sleeper.value
    }

    @Test("sleeperArmed returns immediately when a sleeper already exists")
    func armedReturnsImmediatelyWhenSleeperExists() async {
        let clock = EventDrivenTestClock()
        let sleeper = Task { [clock] in try? await clock.sleep(for: .seconds(1)) }
        await Self.waitUntil("a sleeper is registered") { clock.hasSleeper }

        // A 50 ms hang guard: if this parked instead of taking the fast path it
        // would record a diagnostic and this test would go red.
        await clock.sleeperArmed(timeout: .milliseconds(50))

        await clock.advance(by: .seconds(1))
        _ = await sleeper.value
    }

    /// The hang guard has to be able to fire, and it has to say what it saw.
    /// Driven at 50 ms rather than the 45 s default so the proof is cheap.
    @Test("sleeperArmed records a named diagnostic when nothing ever arms")
    func armedRecordsDiagnosticOnTimeout() async {
        let clock = EventDrivenTestClock()
        await withKnownIssue("no sleeper ever registers, so the hang guard must fire") {
            await clock.sleeperArmed(timeout: .milliseconds(50))
        }
        #expect(clock.hasParkedArmingWaiter == false,
                "a stranded waiter must be deregistered, or a later signal resumes a dead continuation")
    }

    /// The hang guard and the waiter it guards are two child tasks in one
    /// group, and their order is not fixed: the guard can run its whole body
    /// *before* the waiter reaches its park. A guard that only ever rescued an
    /// already-parked waiter then resumed nobody, and the waiter parked on a
    /// continuation nothing was watching — a hang until the suite time limit
    /// rather than the named diagnostic.
    ///
    /// Reproducing that ordering takes both halves of the shape below, and a
    /// mutation check paid for the second. A zero timeout alone is not enough:
    /// with waits issued one at a time the waiter child reliably reached its
    /// park first, and a clock with the fix deleted still passed. A **burst**
    /// of concurrent waits is what puts enough waiter children behind the
    /// executor for some guard to expire first, and against the same weakened
    /// clock it hangs every time.
    ///
    /// The second half of the test is the second half of the fix: whatever the
    /// guard left behind must be cleaned up, so the *next* wait on the same
    /// clock still parks and is still released by a real registration.
    @Test("sleeperArmed survives a hang guard that expires before the waiter parks")
    func armedSurvivesGuardExpiringBeforePark() async {
        let clock = EventDrivenTestClock()
        await withKnownIssue("no sleeper ever registers, so every wait must give up",
                             isIntermittent: false) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<32 { group.addTask { await clock.sleeperArmed(timeout: .zero) } }
            }
        }
        #expect(clock.hasParkedArmingWaiter == false)

        let recorder = FireRecorder<String>()
        let sleeper = Task { [clock] in
            try? await clock.sleep(for: .seconds(1))
            recorder.record("woke")
        }
        await clock.advanceWhenArmed(by: .seconds(1))
        #expect(await recorder.next() == "woke",
                "an expired waiter must not poison the ledger for later waits")
        _ = await sleeper.value
    }

    // MARK: Strict arming

    /// The strict pair's healthy path must be indistinguishable from the soft
    /// pair's: a registration releases the wait, whether the waiter parked first
    /// or the sleeper was already there.
    @Test("requireSleeperArmed returns for a sleeper that registers after it parks")
    func requireArmedReturnsOnRegistration() async throws {
        let clock = EventDrivenTestClock()
        let recorder = FireRecorder<String>()

        async let armed: Void = clock.requireSleeperArmed()
        await Self.waitUntil("an arming waiter is parked") { clock.hasParkedArmingWaiter }

        let sleeper = Task { [clock] in
            try? await clock.sleep(for: .seconds(1))
            recorder.record("woke")
        }
        try await armed
        #expect(clock.hasSleeper)

        // And the fast path, on a clock that already has one: a 50 ms guard
        // would fire if this parked instead of returning at once.
        try await clock.requireSleeperArmed(timeout: .milliseconds(50))

        try await clock.requireAdvanceWhenArmed(by: .seconds(1))
        #expect(await recorder.next() == "woke")
        _ = await sleeper.value
    }

    /// The whole reason the strict pair exists: a chain must **stop** at the
    /// first missed arming rather than record and walk on. Two claims here, and
    /// the second is the one that keeps a chain sound — nothing advanced.
    @Test("requireAdvanceWhenArmed throws the named diagnostic and advances nothing")
    func requireAdvanceThrowsWithoutAdvancing() async {
        let clock = EventDrivenTestClock()
        var thrown: (any Error)?
        do {
            // 50 ms rather than the 45 s default, so the proof is cheap.
            try await clock.requireAdvanceWhenArmed(by: .seconds(1), timeout: .milliseconds(50))
        } catch {
            thrown = error
        }

        let text = thrown.map { String(describing: $0) } ?? "nothing was thrown"
        #expect(text.contains("no task suspended on the clock within"),
                "a missed arming must throw the NoSleeperArmed diagnostic — got: \(text)")
        #expect(text.contains("EventDrivenTestClockSelfTests.swift"),
                "the thrown diagnostic must name the step that gave up — got: \(text)")
        #expect(clock.now.offset == .zero,
                "throwing before the advance is what stops the ledger and now from desyncing")
    }

    /// One diagnostic, two deliveries — and the difference between them is
    /// exactly one line, deliberately.
    ///
    /// The two texts are **not** identical, so a test that asserted they were
    /// would be asserting something false, and one that compared a substring
    /// both happen to contain would pass through any divergence in the rest of
    /// the message — which is the only thing it could usefully catch. What is
    /// actually true is prefix-plus-known-suffix: the strict form appends the
    /// call site, because `Issue.record` already attributes the soft form to the
    /// caller's line while a thrown error is attributed to the test function.
    /// Asserting that shape catches a core that drifted *and* a suffix that
    /// changed.
    @Test("the strict diagnostic is the soft one verbatim, plus a call-site line")
    func strictAndSoftShareOneDiagnostic() async {
        let clock = EventDrivenTestClock()
        let recorded = Captured()
        await withKnownIssue("nothing ever arms, so the soft wait must record") {
            await clock.sleeperArmed(timeout: .milliseconds(50))
        } matching: { issue in
            recorded.set(issue.error.map { String(describing: $0) } ?? "")
            return true
        }
        let softText = recorded.value
        #expect(softText.contains("no task suspended on the clock within"),
                "the soft wait must record the NoSleeperArmed diagnostic — got: \(softText)")

        // Same clock, same timeout, same virtual now: every field the two texts
        // interpolate is identical, so any difference between them is shape.
        var thrownText = ""
        let callLine = #line + 2
        do {
            try await clock.requireSleeperArmed(timeout: .milliseconds(50))
        } catch {
            thrownText = String(describing: error)
        }

        #expect(thrownText.hasPrefix(softText),
                """
                the strict diagnostic must open with the recorded one verbatim — \
                recorded: \(softText) / thrown: \(thrownText)
                """)
        let addition = String(thrownText.dropFirst(softText.count))
        #expect(addition == "\nThe wait that gave up: \(#fileID):\(callLine).",
                "the strict form must add the call site and nothing else — added: \(addition)")
    }

    /// The strict advance's stated invariant — *nothing is advanced unless a
    /// sleeper is registered* — has a second way out that is easy to miss: the
    /// wait ends silently on cancellation, with nothing armed and nothing
    /// thrown. Advancing there would move virtual time against an empty ledger,
    /// so it does not.
    @Test("a cancelled requireAdvanceWhenArmed advances nothing")
    func requireAdvanceIsInertOnCancellation() async {
        let clock = EventDrivenTestClock()
        let waiter = Task { [clock] in
            // Long enough that expiry cannot be what ends this wait.
            try? await clock.requireAdvanceWhenArmed(by: .seconds(5), timeout: .seconds(120))
        }
        await Self.waitUntil("an arming waiter is parked") { clock.hasParkedArmingWaiter }

        waiter.cancel()
        _ = await waiter.value
        #expect(clock.now.offset == .zero,
                "a wait ended by cancellation must leave virtual time where it found it")
    }

    /// Cancellation is not expiry, and the strict pair keeps that treatment:
    /// the wait ends, but it neither throws nor records, because the failure
    /// belongs to whatever cancelled the test.
    @Test("a cancelled requireSleeperArmed ends without a diagnostic")
    func requireArmedIsSilentOnCancellation() async {
        let clock = EventDrivenTestClock()
        let waiter = Task { [clock] () -> String in
            do {
                // Long enough that expiry cannot be what ends this wait.
                try await clock.requireSleeperArmed(timeout: .seconds(120))
                return "returned"
            } catch {
                return "threw: \(error)"
            }
        }
        await Self.waitUntil("an arming waiter is parked") { clock.hasParkedArmingWaiter }

        waiter.cancel()
        #expect(await waiter.value == "returned",
                "attribution belongs to whatever cancelled the test, not to this call site")
    }

    // MARK: Cancellation

    /// Pre-cancellation must be invisible to the clock: no ledger entry, and no
    /// arming signal to a waiter — otherwise a test could advance past a sleeper
    /// that will never fire.
    @Test("a pre-cancelled task's sleep never registers and never signals")
    func preCancelledSleepNeverRegisters() async {
        let clock = EventDrivenTestClock()
        let task = Self.sleepAfterCancellation(on: clock, for: .seconds(1))
        task.cancel()

        await withKnownIssue("the cancelled sleep must leave the arming waiter stranded") {
            // Parked inside the block so the child task inherits the
            // known-issue scope: an `async let` created outside it would report
            // its issue from a task tree the suppression does not cover.
            async let armed: Void = clock.sleeperArmed(timeout: .milliseconds(300))
            _ = await task.value
            await armed
        }

        #expect(await task.value == "cancelled")
        #expect(clock.hasSleeper == false)
    }

    /// `checkCancellation()` at the top of `sleep` is the *only* thing enforcing
    /// cancellation on the already-elapsed-deadline path, which returns before
    /// any cancellation handler is installed. A sleep that returned normally in
    /// a cancelled task is exactly how a cancel-and-replace debouncer fires a
    /// superseded value.
    @Test("a cancelled task's sleep throws even when the deadline has already passed")
    func cancelledSleepThrowsOnElapsedDeadline() async {
        let clock = EventDrivenTestClock()
        let task = Self.sleepAfterCancellation(on: clock, for: .zero)
        task.cancel()

        #expect(await task.value == "cancelled")
        #expect(clock.hasSleeper == false)
    }

    @Test("cancelling a suspended sleeper removes its ledger entry and throws")
    func cancelWhileSuspendedRemovesEntry() async {
        let clock = EventDrivenTestClock()
        let task = Task { [clock] () -> String in
            do {
                try await clock.sleep(for: .seconds(1))
                return "returned"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other: \(error)"
            }
        }
        await Self.waitUntil("a sleeper is registered") { clock.hasSleeper }

        task.cancel()
        #expect(await task.value == "cancelled")
        #expect(clock.hasSleeper == false, "a cancelled sleeper must not leave a ledger entry behind")

        // And the vacated deadline must not fire anything.
        await clock.advance(by: .seconds(1))
        #expect(clock.now.offset == .seconds(1))
    }

    // MARK: Advancing

    @Test("advance fires sleepers in deadline order and moves now exactly")
    func advanceFiresInDeadlineOrder() async {
        let clock = EventDrivenTestClock()
        let recorder = FireRecorder<String>()
        let sleepers = [("a", 10), ("b", 20), ("c", 30)].map { name, ms in
            Task { [clock] in
                try? await clock.sleep(for: .milliseconds(ms))
                recorder.record(name)
            }
        }
        await Self.waitUntil("all three sleepers are registered") { clock.sleeperCount == 3 }

        // Stepping deadline by deadline is what makes the ordering claim
        // deterministic: three tasks resumed by one advance would then race each
        // other to `record`, and their arrival order is not a contract.
        await clock.advance(by: .milliseconds(10))
        #expect(await recorder.next() == "a")
        #expect(clock.now.offset == .milliseconds(10))
        #expect(clock.sleeperCount == 2)

        await clock.advance(by: .milliseconds(10))
        #expect(await recorder.next() == "b")
        #expect(clock.now.offset == .milliseconds(20))

        await clock.advance(by: .milliseconds(10))
        #expect(await recorder.next() == "c")
        #expect(clock.now.offset == .milliseconds(30))
        #expect(clock.sleeperCount == 0)

        for sleeper in sleepers { _ = await sleeper.value }
    }

    @Test("one advance past several deadlines fires each sleeper exactly once")
    func advancePastMultipleDeadlinesFiresEachOnce() async {
        let clock = EventDrivenTestClock()
        let recorder = FireRecorder<String>()
        let sleepers = [("a", 10), ("b", 20), ("c", 30)].map { name, ms in
            Task { [clock] in
                try? await clock.sleep(for: .milliseconds(ms))
                recorder.record(name)
            }
        }
        await Self.waitUntil("all three sleepers are registered") { clock.sleeperCount == 3 }

        await clock.advance(by: .milliseconds(30))
        for _ in 0..<3 { _ = await recorder.next() }
        for sleeper in sleepers { _ = await sleeper.value }

        // Membership, not order: one advance resumes three tasks that then race
        // to `record`, so their arrival order is an incident rather than a
        // contract (`Tests/CLAUDE.md` assertion-hygiene rule 1).
        #expect(Set(recorder.values) == ["a", "b", "c"])
        #expect(recorder.values.count == 3, "a sleeper fired twice, or a stale entry survived")
        #expect(clock.now.offset == .milliseconds(30))
        #expect(clock.sleeperCount == 0)
    }

    @Test("advancing short of a deadline moves now without firing")
    func advanceShortOfDeadlineDoesNotFire() async {
        let clock = EventDrivenTestClock()
        let recorder = FireRecorder<String>()
        let sleeper = Task { [clock] in
            try? await clock.sleep(for: .milliseconds(250))
            recorder.record("fired")
        }
        await Self.waitUntil("a sleeper is registered") { clock.hasSleeper }

        await clock.advance(by: .milliseconds(249))
        #expect(clock.now.offset == .milliseconds(249))
        #expect(clock.hasSleeper, "one millisecond short of the deadline must not fire")
        #expect(recorder.values.isEmpty)

        await clock.advance(by: .milliseconds(1))
        #expect(await recorder.next() == "fired")
        _ = await sleeper.value
    }

    @Test("a sleep whose deadline has already passed returns without registering")
    func elapsedDeadlineReturnsImmediately() async {
        let clock = EventDrivenTestClock()
        await clock.advance(by: .seconds(5))
        let clockRef = clock
        await Task { try? await clockRef.sleep(for: .zero) }.value
        #expect(clock.hasSleeper == false)
    }

    // MARK: FireRecorder

    @Test("next() hands back buffered values in order without draining values")
    func recorderReturnsBufferedValuesInOrder() async {
        let recorder = FireRecorder<String>()
        recorder.record("first")
        recorder.record("second")

        #expect(await recorder.next() == "first")
        #expect(await recorder.next() == "second")
        #expect(recorder.values == ["first", "second"],
                "`values` is a history snapshot, not a queue next() drains")
    }

    @Test("a parked next() is resumed by a later record()")
    func recorderParksUntilRecorded() async {
        let recorder = FireRecorder<String>()
        async let value = recorder.next()
        // No observable "is parked" on the recorder, so settle briefly to make
        // the parked path the one under test rather than the buffered path.
        try? await Task.sleep(for: .milliseconds(20))
        recorder.record("late")
        #expect(await value == "late")
        #expect(recorder.values == ["late"])
    }

    @Test("next() records a named diagnostic and returns nil when nothing fires")
    func recorderRecordsDiagnosticOnTimeout() async {
        let recorder = FireRecorder<String>()
        var observed: String? = "unset"
        await withKnownIssue("nothing is ever recorded, so the hang guard must fire") {
            observed = await recorder.next(timeout: .milliseconds(50))
        }
        #expect(observed == nil)

        // A stranded consumer must be deregistered: a later record() has to
        // buffer rather than resume a dead continuation.
        recorder.record("after")
        #expect(recorder.values == ["after"])
        #expect(await recorder.next() == "after")
    }

    /// The recorder's half of `armedSurvivesGuardExpiringBeforePark`: the hang
    /// guard can finish before the consumer installs itself, and "no consumer
    /// is parked" reads identically to "the consumer already settled". A guard
    /// that resumed nobody in that case left the consumer parked forever.
    ///
    /// Same burst-of-concurrent-waits shape, and for the same measured reason —
    /// see that test. **One recorder each**, though: a `FireRecorder` holds a
    /// single consumer slot and documents that callers await sequentially, so
    /// 32 consumers sharing one recorder would be testing a contract violation
    /// rather than this bug. The burst is only there to load the executor.
    ///
    /// Each recorder then takes a real record/consume pair, so a leftover
    /// expiry marker cannot pass unnoticed: it would swallow the `next()` that
    /// should have delivered.
    @Test("next() survives a hang guard that expires before the consumer parks")
    func recorderSurvivesGuardExpiringBeforePark() async {
        let recorders = (0..<32).map { _ in FireRecorder<String>() }
        // Results are hoisted out of the block and asserted after it: a
        // matcher-less `withKnownIssue` suppresses *every* issue recorded
        // inside, an `#expect` failure among them, so an assertion written in
        // there could never go red (`Tests/CLAUDE.md`, assertion hygiene).
        var results: [String?] = []
        await withKnownIssue("nothing is ever recorded, so every wait must give up",
                             isIntermittent: false) {
            results = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
                for recorder in recorders {
                    group.addTask { await recorder.next(timeout: .zero) }
                }
                var settled: [String?] = []
                while let value = await group.next() { settled.append(value) }
                return settled
            }
        }
        #expect(results.count == recorders.count)
        #expect(results.allSatisfy { $0 == nil },
                "an expired wait must return nil, not a value nobody recorded")

        for recorder in recorders {
            recorder.record("after")
            #expect(await recorder.next() == "after",
                    "an expired consumer must not poison the recorder for later waits")
            #expect(recorder.values == ["after"])
        }
    }

    /// A `FireRecorder` holds a single consumer slot and *documents* that its
    /// callers await sequentially — but documented is not enforced, and this is
    /// the enforcement. A second `next()` used to overwrite the slot in
    /// silence, orphaning the first continuation: the displaced call's own hang
    /// guard recognises a parked consumer by id, finds the newcomer's instead,
    /// and so resumes nobody. The displaced `next()` then never returns at all —
    /// a diagnostic-free hang, the worst failure shape available. It now
    /// reports the contract and releases the displaced consumer with `nil`.
    ///
    /// The deliberately generous 10 s guards are what make the displacement
    /// deterministic instead of a race against expiry: with nothing recorded,
    /// whichever call parks first is still parked when the second arrives, so
    /// exactly one displacement happens whichever order the executor picks.
    /// Neither call sits out its guard on a healthy run — the displaced one
    /// returns immediately and the `record` releases the survivor — so a
    /// regression shows up as this test hanging, not as a slow pass.
    ///
    /// Those same generous guards are what the matcher below polices. The
    /// displaced wait returns in milliseconds, so a hang-guard diagnostic from
    /// it would be pure fabrication — a "no value was recorded within 10 s" on
    /// a call that never waited ten seconds, sending a reader after a fire
    /// nobody owed. The matcher therefore accepts **only** the contract issue:
    /// any timeout issue reaching it is unmatched, which `withKnownIssue`
    /// surfaces as a real failure.
    @Test("two concurrent next() calls report the single-consumer contract instead of hanging")
    func recorderReportsConcurrentConsumers() async {
        let recorder = FireRecorder<String>()
        let sawContractIssue = Latch()
        let sawTimeoutIssue = Latch()
        var results: [String?] = []

        await withKnownIssue("a second next() displaces the first, which the contract forbids",
                             isIntermittent: false) {
            results = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
                group.addTask { await recorder.next(timeout: .seconds(10)) }
                group.addTask { await recorder.next(timeout: .seconds(10)) }
                var settled: [String?] = []
                if let displaced = await group.next() { settled.append(displaced) }
                // The displaced call is back, so the survivor is the one parked
                // in the slot: recording releases it.
                recorder.record("after-displacement")
                while let remaining = await group.next() { settled.append(remaining) }
                return settled
            }
        } matching: { issue in
            let text = (issue.error.map { String(describing: $0) } ?? "") + issue.description
            let isContract = text.contains("single-consumer slot")
            if isContract { sawContractIssue.latch() }
            if text.contains("no value was recorded within") { sawTimeoutIssue.latch() }
            return isContract
        }

        #expect(sawContractIssue.isLatched,
                "displacing a parked consumer must name the contract, not pass in silence")
        #expect(sawTimeoutIssue.isLatched == false,
                "the displaced wait returned promptly — it must not also report a hang guard it never sat out")
        #expect(results.count == 2)
        #expect(results.contains(nil), "the displaced next() must return nil rather than park forever")
        #expect(results.contains("after-displacement"), "the surviving consumer must still be served")

        // And the recorder is intact afterwards: the breach cost one wait, not
        // the recorder.
        recorder.record("after")
        #expect(await recorder.next() == "after")
        #expect(recorder.values == ["after-displacement", "after"])
    }
}
