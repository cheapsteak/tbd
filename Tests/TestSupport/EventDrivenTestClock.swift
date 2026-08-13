import Foundation
import Testing

// A megaYield-free virtual clock, plus the awaitable recorder that goes with it.
//
// Design and rationale:
// `docs/specs/2026-08-11-event-driven-test-clock-design.md`.
//
// The short version, because it explains every API choice below. `TestClock`
// (swift-clocks) makes a clock-driven suite load-*tolerant*, not
// load-*independent*, and both halves of its test<->clock handshake are the
// reason:
//
// - **Arming is polled.** The only way to observe "a sleeper is registered" on
//   a `TestClock` is `checkSuspension()`, which opens with `Task.megaYield()` —
//   20 serially-awaited background-QoS detached tasks per probe. Under
//   process-global saturation macOS starves background QoS, so the probe both
//   fails to see the arming *and* floods the pool with more of exactly the work
//   that is starving. Field signature: `Issue recorded` at the
//   `advanceWhenSuspended` call site, then an empty fired-values array.
// - **Firing is asserted synchronously.** `TestClock.advance(to:)` megaYields
//   after finishing a sleeper's continuation, which is the only thing that
//   *usually* lets the resumed task run its post-sleep code before `advance`
//   returns. That is a scheduling accident, not a guarantee.
//
// This file makes both directions event-driven. `EventDrivenTestClock` signals
// arming from inside the same critical section that registers the sleeper, and
// `FireRecorder` turns "the effect happened" into something a test can await
// instead of guess at. Under arbitrary load a green test here gets slower,
// never red.
//
// This is an *addition*, not a replacement: `TestClock` and
// `ClockTestSupport`'s `advanceWhenSuspended` / `waitForSuspension` stay for
// their existing consumers, and suites migrate on field evidence rather than
// wholesale.

// MARK: - EventDrivenTestClock

/// A deterministic virtual clock whose arming handshake is a signal, not a poll.
///
/// Drop-in for `TestClock` in a tier-1 suite: it conforms to
/// `Clock` with `Duration == Swift.Duration`, so it satisfies the production
/// `clock: any Clock<Duration>` seam unchanged. The differences are the two that
/// matter under load:
///
/// - `advanceWhenArmed(by:)` replaces `advanceWhenSuspended(by:)`. It parks on a
///   continuation that the *clock itself* resumes when a sleeper registers, so
///   there is no probe, no megaYield and no busy budget to exhaust.
/// - `advance(by:)` performs **no** yielding of any kind. It moves virtual time
///   and resumes due sleepers, and that is all — so a test must await
///   ``FireRecorder/next(timeout:sourceLocation:)`` for any *positive*
///   assertion about what a resumed task did. See `advance(to:)`.
///
/// The correctness property worth stating explicitly, because it is why this is
/// a clock rather than a wrapper around `TestClock`: the arming signal is
/// emitted **after** the suspension has been appended to the ledger, under the
/// same lock. A waiter can therefore never be released into a world where the
/// sleeper it was told about is not yet registered — which is exactly the gap
/// that makes a signalling *wrapper* around `TestClock` unsound, since that
/// registration happens inside `TestClock`'s own lock where no wrapper can
/// interpose.
///
/// Usage:
///
/// ```swift
/// let clock = EventDrivenTestClock()
/// let fired = FireRecorder<String>()
/// let debouncer = SearchQueryDebouncer(interval: .milliseconds(250), clock: clock)
///
/// debouncer.schedule("wolv") { fired.record($0) }
/// await clock.advanceWhenArmed(by: .milliseconds(250))
/// #expect(await fired.next() == "wolv")
/// ```
///
/// Full rationale: `docs/specs/2026-08-11-event-driven-test-clock-design.md`.
public final class EventDrivenTestClock: Clock, @unchecked Sendable {
    /// Offset-based virtual instant, mirroring `TestClock.Instant`.
    ///
    /// Virtual time starts at offset zero and only ever moves where a test
    /// moves it, so failure output reads as exact durations from the start of
    /// the test rather than as wall-clock noise.
    public struct Instant: InstantProtocol {
        /// Distance from the clock's origin. Exposed because assertions and
        /// diagnostics read better as an offset than as an opaque instant.
        public let offset: Swift.Duration

        public init(offset: Swift.Duration = .zero) {
            self.offset = offset
        }

        public func advanced(by duration: Swift.Duration) -> Self {
            .init(offset: offset + duration)
        }

        public func duration(to other: Self) -> Swift.Duration {
            other.offset - offset
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    /// Per-sleep state shared by the sleeping task's continuation body and its
    /// cancellation handler, which can run concurrently and in either order.
    ///
    /// It is a class so both closures see the same box without a clock-wide
    /// registry keyed by id — a registry would have to remember every id that
    /// ever settled in order to recognise a late cancellation, and would grow
    /// for the life of the test. Every field is guarded by the clock's lock.
    private final class SleepBox: @unchecked Sendable {
        /// Non-nil exactly while the sleeper is parked and unsettled.
        var continuation: CheckedContinuation<Void, any Error>?
        /// Set once the sleeper has been resumed (fired or cancelled). Guards
        /// the resume-exactly-once invariant.
        var isSettled = false
        /// Set when cancellation arrives *before* the continuation is installed.
        /// The continuation body consumes it and throws instead of registering.
        var isCancelledEarly = false
    }

    private struct Suspension {
        let id: UUID
        let deadline: Instant
        let box: SleepBox
    }

    /// A parked `sleeperArmed` waiter. The continuation carries *why* it was
    /// resumed — `true` for "a sleeper registered", `false` for "the hang guard
    /// gave up" — which is what lets the waiter's own result be the
    /// authoritative verdict no matter which task the group sees finish first.
    private struct ArmingWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// One outcome of `sleeperArmed`'s two-task race, tagged by which task
    /// produced it. Only the waiter's verdict is authoritative: the hang guard
    /// finishing first says nothing about how the waiter settled.
    private enum ArmingRace {
        case waiter(timedOut: Bool)
        case hangGuard
    }

    /// Virtual time has no resolution floor: a test may advance by any duration.
    public let minimumResolution: Swift.Duration = .zero

    private let lock = NSLock()
    private var currentNow: Instant
    private var suspensions: [Suspension] = []
    private var armingWaiters: [ArmingWaiter] = []
    /// Waiter ids whose hang guard expired *before* the waiter reached its park.
    /// Without this, the guard would resume nobody and the waiter would then
    /// park on a continuation no one is watching any more — a hang, not a
    /// diagnostic. Each id is consumed by its own park, and every call removes
    /// its id on the way out, so the set never grows across calls.
    private var expiredArmingWaiters: Set<UUID> = []

    /// - Parameter now: starting instant, offset zero by default.
    public init(now: Instant = .init()) {
        currentNow = now
    }

    public var now: Instant {
        lock.withLock { currentNow }
    }

    /// Whether at least one task is currently suspended on this clock.
    ///
    /// The negative direction is the useful one — "the code under test armed no
    /// timer at all" — and it is the reason this exists as a property rather
    /// than as `TestClock`'s throwing `checkSuspension()`. Reading it is a
    /// synchronous snapshot with no megaYield, so a *negative* assertion on it
    /// is one-sided in the usual way: it proves nothing was armed *by the time
    /// you looked*. Pair it with a short real settle when the thing you are
    /// ruling out would need a scheduling turn to appear.
    public var hasSleeper: Bool {
        sleeperCount > 0
    }

    /// How many tasks are currently suspended on this clock.
    ///
    /// Needed when a test has to get *several* sleepers registered before
    /// advancing — `sleeperArmed` is satisfied by the first one, so it cannot
    /// express "all three are armed". Same one-sidedness as ``hasSleeper``.
    public var sleeperCount: Int {
        lock.withLock { suspensions.count }
    }

    /// Whether a `sleeperArmed` waiter is currently parked.
    ///
    /// Exists for the clock's own self-tests, which have to get a waiter parked
    /// *before* the first sleep registers in order to prove that the
    /// registration is what releases it. Production tests should not need this.
    public var hasParkedArmingWaiter: Bool {
        lock.withLock { !armingWaiters.isEmpty }
    }

    // MARK: Clock

    /// Suspends until virtual time reaches `deadline`, or throws
    /// `CancellationError`.
    ///
    /// Semantics mirror `TestClock.sleep(until:tolerance:)`, and two of them are
    /// load-bearing rather than incidental:
    ///
    /// - **`Task.checkCancellation()` comes first.** A task cancelled before it
    ///   ever ran must not register a sleeper, and must throw rather than
    ///   return normally. Cancel-and-replace debouncers depend on this: a burst
    ///   of keystrokes cancels tasks that have not started, and a sleep that
    ///   returned *successfully* in one of them would fire a superseded value.
    ///   It is also the only enforcement on the already-elapsed-deadline path
    ///   below, which returns without consulting cancellation at all.
    /// - **The arming signal follows the ledger append**, inside the same
    ///   critical section discipline: waiters are collected under the lock after
    ///   the suspension is appended, and resumed once the lock is released. No
    ///   waiter can observe "armed" while the sleeper is unregistered, and no
    ///   continuation is resumed with the lock held.
    ///
    /// A deadline at or before `now` returns immediately without registering and
    /// without signalling — there is nothing to wait for, and signalling would
    /// tell a waiter about a sleeper that does not exist.
    public func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        try Task.checkCancellation()
        if lock.withLock({ deadline <= currentNow }) { return }

        let id = UUID()
        let box = SleepBox()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if box.isCancelledEarly {
                    // Cancellation beat us to the lock: settle here, register
                    // nothing, signal nobody.
                    box.isSettled = true
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                box.continuation = continuation
                suspensions.append(Suspension(id: id, deadline: deadline, box: box))
                let waiters = armingWaiters
                armingWaiters.removeAll()
                lock.unlock()
                // Outside the lock: a waiter resumes into arbitrary user code.
                // Draining the ledger and resuming what was drained are one
                // obligation — a waiter removed here but not resumed parks
                // forever, and its own timeout task cannot rescue it because
                // that task recognises a stranded waiter by finding it still in
                // the ledger.
                for waiter in waiters { waiter.continuation.resume(returning: true) }
            }
        } onCancel: {
            lock.lock()
            guard !box.isSettled else {
                lock.unlock()
                return
            }
            guard let continuation = box.continuation else {
                // The continuation is not installed yet — hand the decision to
                // the body, which runs next and will throw instead of
                // registering.
                box.isCancelledEarly = true
                lock.unlock()
                return
            }
            box.isSettled = true
            box.continuation = nil
            suspensions.removeAll { $0.id == id }
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: Arming

    /// Waits until at least one task is suspended on this clock.
    ///
    /// Returns immediately if a sleeper is already registered; otherwise parks
    /// on a continuation that ``sleep(until:tolerance:)`` resumes the moment it
    /// appends its suspension. There is no probe loop, so a healthy handshake
    /// costs one scheduling hop and a loaded machine costs a slower hop — never
    /// a red test.
    ///
    /// - Parameters:
    ///   - timeout: hang guard **only**. It exists so a timer that genuinely
    ///     never arms fails with a named diagnostic instead of parking until the
    ///     suite time limit reports an uninformative "wedged". It is implemented
    ///     as a race against a single real `Task.sleep` that never fires on a
    ///     healthy path, so a passing run pays nothing for it. 45 s carries over
    ///     from `waitForSuspension`, whose derivation against `.clockDriven`'s
    ///     240 s limit is documented in `ClockTestSupport.swift` and
    ///     `Tests/CLAUDE.md` ("Population is the scheduler"); the value is kept
    ///     so that a chain of these still tallies the same way. **On task
    ///     cancellation the wait ends without a diagnostic**: the waiter is
    ///     still released, but the failure belongs to whatever cancelled the
    ///     test, not to this call site.
    ///   - sourceLocation: reported location of the diagnostic, so it lands on
    ///     the caller's line rather than in this file.
    ///
    /// Non-throwing, like the helpers it replaces: a missing sleeper is an
    /// `Issue.record` at the caller's location and execution continues, so call
    /// sites stay free of `try` noise. That is safe only because it returns
    /// nothing — see `Tests/CLAUDE.md` on non-throwing waiters that *do* return
    /// a value.
    public func sleeperArmed(timeout: Swift.Duration = .seconds(45),
                             sourceLocation: SourceLocation = #_sourceLocation) async {
        if hasSleeper { return }

        let waiterID = UUID()
        let timedOut = await withTaskGroup(of: ArmingRace.self, returning: Bool.self) { group in
            group.addTask { [self] in
                let armed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    lock.lock()
                    // Re-check under the lock: a sleeper may have registered
                    // between the fast path above and this park.
                    if !suspensions.isEmpty {
                        lock.unlock()
                        continuation.resume(returning: true)
                        return
                    }
                    if expiredArmingWaiters.remove(waiterID) != nil {
                        // The hang guard already gave up on a waiter that had
                        // not parked yet, so nothing is left watching for this
                        // continuation. Settle here instead of parking forever.
                        lock.unlock()
                        continuation.resume(returning: false)
                        return
                    }
                    armingWaiters.append(ArmingWaiter(id: waiterID, continuation: continuation))
                    lock.unlock()
                }
                return .waiter(timedOut: !armed)
            }
            group.addTask { [self] in
                // `try?`, so a *cancelled* guard still runs the rescue below: a
                // waiter parked on a continuation nobody is watching hangs, and
                // that stays true when the reason the guard woke early is
                // cancellation rather than expiry. Whether the wait *reports*
                // anything is decided by the caller, which can tell the two
                // apart; this child cannot, because the group's own
                // `cancelAll()` cancels it on the healthy path too.
                try? await Task.sleep(for: timeout)
                // Deregistering is what makes this safe: whoever removes the
                // waiter owns resuming it, so a signal arriving after the
                // timeout finds nothing to resume. Three cases here, and the
                // last is why the expiry marker exists: the waiter is parked
                // (strand it), the waiter already settled (nothing owed), or
                // the waiter has not reached its park yet — where an unmarked
                // give-up would leave it to park on a dead continuation.
                let stranded: ArmingWaiter? = lock.withLock {
                    guard let index = armingWaiters.firstIndex(where: { $0.id == waiterID }) else {
                        expiredArmingWaiters.insert(waiterID)
                        return nil
                    }
                    return armingWaiters.remove(at: index)
                }
                stranded?.continuation.resume(returning: false)
                return .hangGuard
            }
            // Consume results until the waiter's, which is the only
            // authoritative one — the guard can finish first without knowing
            // how the waiter settled. Defaulting to "timed out" keeps an
            // impossible group (a waiter that never returns) loud rather than
            // silently green.
            var verdict = true
            while let outcome = await group.next() {
                if case .waiter(let waiterTimedOut) = outcome {
                    verdict = waiterTimedOut
                    break
                }
            }
            group.cancelAll()
            return verdict
        }
        // The guard may have marked an id whose waiter had already settled. The
        // group has awaited both children by now, so this is the last word: no
        // call leaves an entry behind for the next one to trip over.
        lock.withLock { _ = expiredArmingWaiters.remove(waiterID) }

        // Cancellation is not expiry. A cancelled enclosing task — `.clockDriven`'s
        // time limit firing, a sibling's `cancelAll()` — cancels the hang guard's
        // sleep, so the waiter is released early and `timedOut` says `true` for a
        // timer that may well have been about to arm. Reporting that would put a
        // fabricated "within 45 s" on an innocent call site and hide the real
        // cause, so the diagnostic is suppressed and the attribution left to
        // whatever did the cancelling. The check belongs *here* rather than in
        // the guard child: cancellation is monotonic, so the enclosing task's
        // flag is unambiguous, while the child cannot distinguish its parent's
        // cancellation from the group's own `cancelAll()` on the healthy path.
        if timedOut && !Task.isCancelled {
            Issue.record(
                NoSleeperArmed(timeout: timeout, virtualNow: now),
                sourceLocation: sourceLocation
            )
        }
    }

    /// ``sleeperArmed(timeout:sourceLocation:)`` followed by
    /// ``advance(by:)`` — the drop-in replacement for
    /// `TestClock.advanceWhenSuspended(by:)`.
    ///
    /// Same convention as its predecessor: **put the advance next to the
    /// assertion it unblocks**, never in a setup block far away. And remember
    /// what advancing does not promise — for a positive assertion, follow it
    /// with `await recorder.next()`.
    public func advanceWhenArmed(by duration: Swift.Duration,
                                 sourceLocation: SourceLocation = #_sourceLocation) async {
        await sleeperArmed(sourceLocation: sourceLocation)
        await advance(by: duration)
    }

    // MARK: Advancing

    /// Advances virtual time by `duration`, firing every sleeper it passes.
    public func advance(by duration: Swift.Duration = .zero) async {
        await advance(to: lock.withLock { currentNow.advanced(by: duration) })
    }

    /// Advances virtual time to `deadline`, stepping `now` through each due
    /// sleeper's deadline in order and resuming it.
    ///
    /// **This does not yield, megaYield, or sleep.** Sleepers are resumed
    /// outside the lock and that is the end of the method's obligations, so
    /// `advance` returning means *"virtual time moved and the due continuations
    /// were resumed"* — it does **not** mean the resumed tasks have run their
    /// post-sleep code. `TestClock` appears to promise the stronger thing only
    /// because it megaYields on the way out, which is a scheduling accident that
    /// stops holding under exactly the load this clock exists for.
    ///
    /// So: pair every *positive* assertion with
    /// ``FireRecorder/next(timeout:sourceLocation:)``, which suspends the test
    /// until the effect actually lands. A *negative* assertion ("nothing fired
    /// yet") reads the snapshot directly and stays one-sided, as it always was.
    ///
    /// **Re-arming has the same consequence, and it bites harder.** A task that
    /// fires and immediately sleeps again — a poller loop — cannot possibly have
    /// re-registered by the time `advance` returns, because `advance` never
    /// yields it the chance. So after a fire, the **next** advance must go
    /// through ``advanceWhenArmed(by:sourceLocation:)``: a bare `advance` moves
    /// `now` past a deadline that is not in the ledger yet, and the sleep that
    /// registers afterwards is measured from the new `now` and never fires —
    /// permanent desync, the hang `Tests/CLAUDE.md` documents for `TestClock`
    /// under load, except here it is deterministic rather than probabilistic.
    /// This is the rule to carry into any future poller-suite migration
    /// (`GatedIntervalSleepTests`, `DaywatchRunnerTests`), where every advance
    /// after the first is a re-arm.
    ///
    /// A deadline in the past is a no-op: virtual time never moves backwards.
    public func advance(to deadline: Instant) async {
        // Scoped locking only: `NSLock.lock()`/`unlock()` are unavailable from
        // an async context. Each turn of the loop takes the lock once, decides,
        // and hands back at most one continuation to resume *after* the lock is
        // released — a continuation must never be resumed while holding it.
        while case .fired(let due) = lock.withLock({ () -> AdvanceStep in
            guard currentNow <= deadline else { return .finished }
            suspensions.sort { $0.deadline < $1.deadline }
            guard let next = suspensions.first, next.deadline <= deadline else {
                currentNow = deadline
                return .finished
            }
            // Virtual time is monotonic: a sleeper whose deadline is already in
            // the past (its task read `now` before an interleaved advance)
            // fires here without rewinding the clock under everyone else.
            currentNow = max(currentNow, next.deadline)
            suspensions.removeFirst()
            guard !next.box.isSettled else { return .fired(nil) }
            next.box.isSettled = true
            let continuation = next.box.continuation
            next.box.continuation = nil
            return .fired(continuation)
        }) {
            due?.resume()
        }
    }

    /// One turn of `advance(to:)`: either virtual time reached the target, or a
    /// sleeper came due and its continuation is owed a resume outside the lock.
    private enum AdvanceStep {
        case finished
        case fired(CheckedContinuation<Void, any Error>?)
    }
}

/// Diagnostic for `sleeperArmed`'s hang guard.
///
/// Thrown-`Error` shape on purpose: only `Issue.record(_: some Error)` puts the
/// text on the **primary** failure line, where a CI summary will show it
/// (`Tests/CLAUDE.md` assertion-hygiene rule 4). It reports *observed* state —
/// what virtual time actually said when the wait gave up — rather than
/// restating the expectation.
private struct NoSleeperArmed: Error, CustomStringConvertible {
    let timeout: Swift.Duration
    let virtualNow: EventDrivenTestClock.Instant

    var description: String {
        """
        EventDrivenTestClock: no task suspended on the clock within \(timeout) — observed \
        zero registered sleepers, virtual now = \(virtualNow.offset). The code under test \
        never reached its sleep: did you start the task, cancel it first, or advance past \
        the point where it would have armed?
        """
    }
}

// MARK: - FireRecorder

/// An awaitable record of the values a debounced/delayed callback produced.
///
/// Replaces the hand-rolled `Box { var values: [String] }` that clock-driven
/// suites used to assert against immediately after `advance`. That assertion was
/// safe only because `TestClock.advance` megaYielded on the way out; with
/// ``EventDrivenTestClock`` there is no such accident, and there should not be —
/// a positive assertion should *wait* for the effect rather than hope it beat
/// the next statement.
///
/// Two reads, and they are not interchangeable:
///
/// - ``next(timeout:sourceLocation:)`` — awaits the next value not yet handed
///   out, returning a buffered one immediately if it has already arrived. This
///   is what a positive assertion uses.
/// - ``values`` — a synchronous snapshot of everything recorded so far, for
///   order and collapse assertions (`["a", "b"]`) and for negative assertions
///   ("nothing fired yet"). **Negative assertions here are one-sided**: a fire
///   that is pathologically late can make one false-*pass*, never false-fail.
///   That is unchanged from the hand-rolled boxes, and it is the reason the
///   positive half of every test must go through `next()`.
///
/// Lock-guarded rather than an actor, because ``record(_:)`` is called from a
/// synchronous callback (`@MainActor (String) -> Void`) that cannot await.
public final class FireRecorder<Value: Sendable>: @unchecked Sendable {
    /// How a parked `next()` was settled. Three verdicts rather than two,
    /// because "returned nil" is not one situation: a *displaced* consumer was
    /// released deliberately by the code that already recorded
    /// ``ConcurrentConsumers`` naming the breach, so adding a fabricated
    /// "no value was recorded within 10 s" on a call that returned in
    /// milliseconds would misdescribe what happened and point the reader at a
    /// timeout that never elapsed.
    private enum ConsumerOutcome {
        case value(Value)
        case timedOut
        case displaced
    }

    /// A parked `next()`. Like the clock's arming waiter, the continuation
    /// carries the verdict, so the consumer's own result is authoritative
    /// regardless of which task the group sees finish first.
    private struct Consumer {
        let id: UUID
        let continuation: CheckedContinuation<ConsumerOutcome, Never>
    }

    /// One outcome of `next()`'s two-task race, tagged by its producer. Only
    /// the consumer's verdict is authoritative; the hang guard's is not, since
    /// it cannot see a value `record(_:)` delivered a moment earlier.
    private enum ConsumerRace {
        case consumer(ConsumerOutcome)
        case hangGuard
    }

    private let lock = NSLock()
    private var recorded: [Value] = []
    /// How many recorded values `next()` has already handed out. Kept as an
    /// index rather than draining `recorded`, so `values` stays a full history
    /// no matter how many times `next()` was called.
    private var consumed = 0
    /// At most one consumer parks at a time: these tests await sequentially.
    private var consumer: Consumer?
    /// Consumer ids whose hang guard expired *before* the consumer reached its
    /// park — the same hazard, and the same remedy, as the clock's
    /// `expiredArmingWaiters`. Each `next()` removes its id on the way out.
    private var expiredConsumers: Set<UUID> = []

    public init() {}

    /// Records a value from the code under test. Synchronous, callable from any
    /// context, and resumes a parked ``next(timeout:sourceLocation:)`` if one is
    /// waiting.
    public func record(_ value: Value) {
        lock.lock()
        recorded.append(value)
        let waiting = consumer
        consumer = nil
        if waiting != nil { consumed += 1 }
        lock.unlock()
        waiting?.continuation.resume(returning: .value(value))
    }

    /// A snapshot of every value recorded so far, in order. Never drained by
    /// ``next(timeout:sourceLocation:)``.
    public var values: [Value] {
        lock.withLock { recorded }
    }

    /// The next value not yet returned by a previous `next()`, awaiting one if
    /// it has not arrived.
    ///
    /// - Parameter timeout: hang guard only, in the same family as
    ///   ``EventDrivenTestClock/sleeperArmed(timeout:sourceLocation:)`` — it
    ///   turns "the effect never landed" into a named failure instead of a park
    ///   until the suite time limit. Never reached on a healthy path. **On task
    ///   cancellation the wait ends without a diagnostic**: the consumer is
    ///   still released and `nil` returned, but the failure belongs to whatever
    ///   cancelled the test rather than to this call site.
    /// - Returns: the value, or `nil` after recording a diagnostic on timeout —
    ///   or, for a wait displaced by a second concurrent `next()`, `nil` with
    ///   only the ``ConcurrentConsumers`` breach already recorded against it.
    ///   Returning an optional rather than continuing silently means a test that
    ///   asserts on the result gets a comparison against `nil` *after* the real
    ///   diagnostic has already been recorded, never instead of it.
    public func next(timeout: Swift.Duration = .seconds(45),
                     sourceLocation: SourceLocation = #_sourceLocation) async -> Value? {
        let consumerID = UUID()
        let outcome: ConsumerOutcome = await withTaskGroup(
            of: ConsumerRace.self,
            returning: ConsumerOutcome.self
        ) { group in
            group.addTask { [self] in
                let settled = await withCheckedContinuation {
                    (continuation: CheckedContinuation<ConsumerOutcome, Never>) in
                    lock.lock()
                    if consumed < recorded.count {
                        let buffered = recorded[consumed]
                        consumed += 1
                        lock.unlock()
                        continuation.resume(returning: .value(buffered))
                        return
                    }
                    if expiredConsumers.remove(consumerID) != nil {
                        // The hang guard already gave up on a consumer that had
                        // not parked yet: settle here rather than park on a
                        // continuation nothing is watching.
                        lock.unlock()
                        continuation.resume(returning: .timedOut)
                        return
                    }
                    // A consumer already parked here means two `next()` calls
                    // are in flight on one recorder, which the single-consumer
                    // contract forbids. Overwriting the slot silently would
                    // orphan that continuation — its own hang guard looks for
                    // its own id and finds this one, so it resumes nobody and
                    // the displaced `next()` never returns. Report the contract
                    // breach and release the displaced consumer instead: a
                    // diagnostic beats a hang. The displaced call returns `nil`
                    // carrying the `.displaced` verdict — **one** issue for one
                    // breach. It must not also report a hang guard it never sat
                    // out: that wait returned in milliseconds, so a "no value
                    // was recorded within 45 s" beside it would describe an
                    // elapsed timeout that never happened and send the reader
                    // hunting a fire nobody owed.
                    let displaced = consumer
                    consumer = Consumer(id: consumerID, continuation: continuation)
                    lock.unlock()
                    if let displaced {
                        Issue.record(
                            ConcurrentConsumers(),
                            sourceLocation: sourceLocation
                        )
                        displaced.continuation.resume(returning: .displaced)
                    }
                }
                return .consumer(settled)
            }
            group.addTask { [self] in
                try? await Task.sleep(for: timeout)
                // Same ownership rule, and same three cases, as the clock's
                // arming waiter: whoever removes the parked consumer owns
                // resuming it, and a consumer that has not parked yet is marked
                // expired so its own park can settle itself.
                let stranded: Consumer? = lock.withLock {
                    guard let waiting = consumer, waiting.id == consumerID else {
                        expiredConsumers.insert(consumerID)
                        return nil
                    }
                    consumer = nil
                    return waiting
                }
                stranded?.continuation.resume(returning: .timedOut)
                return .hangGuard
            }
            // The consumer's verdict is the authoritative one. Reading whichever
            // result arrived first would let the guard both report a spurious
            // timeout and *discard* a value `record(_:)` had already handed over
            // — with `consumed` already advanced, so the value is gone for good.
            var verdict: ConsumerOutcome = .timedOut
            while let raced = await group.next() {
                if case .consumer(let settled) = raced {
                    verdict = settled
                    break
                }
            }
            group.cancelAll()
            return verdict
        }
        // Both children have been awaited by now, so this is the last word on a
        // marker the guard left for a consumer that had already settled.
        lock.withLock { _ = expiredConsumers.remove(consumerID) }

        switch outcome {
        case .value(let value):
            return value
        case .displaced:
            // The breach was already reported at the moment of displacement, by
            // the call that did the displacing. Reporting again here would
            // manufacture a timeout diagnostic for a wait that returned
            // promptly.
            return nil
        case .timedOut:
            // Same rule as the clock's arming guard: a cancelled enclosing task
            // cancels this hang guard's sleep, which releases the consumer as
            // timed out for a fire that was never given its chance. The wait
            // still ends — `nil` is returned, so an assertion on the result
            // still fails — but the "within 45 s" diagnostic would name an
            // innocent call site for someone else's cancellation, so it is
            // suppressed.
            if !Task.isCancelled {
                Issue.record(
                    NoValueRecorded(timeout: timeout, observed: values),
                    sourceLocation: sourceLocation
                )
            }
            return nil
        }
    }
}

/// Diagnostic for two `next()` calls racing on one recorder. Thrown-`Error`
/// shape for the same reason as ``NoSleeperArmed``: the text has to reach the
/// primary failure line, because the symptom it explains (a `next()` that
/// returned `nil` for no visible reason) is otherwise unattributable.
private struct ConcurrentConsumers: Error, CustomStringConvertible {
    var description: String {
        """
        FireRecorder: a second next() parked while one was already waiting — this \
        recorder holds a single-consumer slot and its callers must await \
        sequentially. The displaced wait was released with nil so it does not \
        hang; await one next() at a time, or give each concurrent waiter its own \
        FireRecorder.
        """
    }
}

/// Diagnostic for `FireRecorder.next`'s hang guard. Thrown-`Error` shape for the
/// same reason as ``NoSleeperArmed``, and it reports what was actually in the
/// recorder — the most useful fact when a debounce fired the wrong number of
/// times rather than not at all.
private struct NoValueRecorded<Value: Sendable>: Error, CustomStringConvertible {
    let timeout: Swift.Duration
    let observed: [Value]

    var description: String {
        """
        FireRecorder: no value was recorded within \(timeout) — observed \(observed.count) \
        value(s) so far: \(observed.map { String(describing: $0) }). Either the code under \
        test never fired, or virtual time was never advanced past its deadline.
        """
    }
}

// MARK: - Settling

/// Hands the current executor back for a few real turns, so a fire that *would*
/// land gets the chance to before a **negative** assertion reads the recorder.
///
/// Shared by the suites on ``EventDrivenTestClock`` because its ``advance`` does
/// no yielding: where `TestClock.advance`'s trailing megaYield supplied this
/// settling incidentally, here it is explicit and bounded. From a `@MainActor`
/// test body this is what returns the main queue, which is the only way the
/// deferred work becomes observable at all (`Tests/CLAUDE.md`, "`@MainActor`
/// tests: suspend to drain, never pump").
///
/// **One-sided, and only ever worth this much:** it proves absence up to the
/// settle window and no further, so a pathologically late fire can make a
/// negative assertion false-*pass*, never false-fail. That is unchanged from
/// the synchronous read it replaces. Every *positive* assertion must still go
/// through ``FireRecorder/next(timeout:sourceLocation:)``, which waits for the
/// effect instead of hoping it arrived.
public func settle() async {
    for _ in 0..<3 { try? await Task.sleep(for: .milliseconds(10)) }
}

/// Watches for a sleeper to appear on `clock`, for a **negative** assertion of
/// the shape "the code under test must arm no timer at all".
///
/// Why this rather than ``settle()`` there. Arming takes a scheduling turn, so
/// the thing being ruled out cannot appear instantly — and a fixed settle
/// window buys its whole proof at one instant at the end of that window. Under
/// saturation the turn can land later than the window, and the negative passes
/// against production that *did* arm a timer: the assertion stops
/// discriminating exactly when the machine is busy, which is when it matters.
/// Watching instead keeps looking, so the window is a patience budget rather
/// than a single sample, and a regression is caught the moment it shows up
/// instead of only if it happens to show up early.
///
/// **Still one-sided, in the same direction as everything else here.** Absence
/// is proven only up to `window` — a pathologically late arming can make this
/// false-*pass*, never false-fail. Presence, by contrast, is detected the
/// instant it happens, which is what makes the failing direction prompt: the
/// caller learns within one poll interval rather than after the full window.
///
/// - Parameters:
///   - clock: the clock whose ledger is watched.
///   - window: how long to keep watching before concluding absence. A second is
///     ~100× the scheduling turn being ruled out, and a passing test pays it
///     only when the code under test is behaving.
/// - Returns: `true` if a sleeper appeared (assert `false` on this), `false` if
///   none appeared within `window`.
public func watchForSleeper(on clock: EventDrivenTestClock,
                            upTo window: Swift.Duration = .seconds(1)) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: window)
    repeat {
        if clock.hasSleeper { return true }
        try? await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    return clock.hasSleeper
}
