import Foundation
import TestSupport
import Testing

@testable import TBDDaemonLib

/// Shared helpers for the control-mode test suites (attach orchestration,
/// replay fence, pane repair, input router/health, resize coordinator). All
/// of them fake tmux the same way: a real `TmuxControlCommandClient` whose
/// `writeLine` records stream writes synchronously, with reply blocks fed by
/// hand through `client.handle(...)` — the correlator is exercised, only its
/// stdout is faked.

/// Generous positive-wait poll deadline that only elapses on failure; sized
/// for loaded parallel CI (PR #379: cooperative-pool starvation stretched
/// sub-second async-drain deliveries past a 5 s poll). Passing runs still
/// complete in milliseconds.
///
/// ## This is a hang-catcher, not a timing budget
///
/// "Raise a timeout" reads as a cover-up, so state the case plainly. No test
/// that consumes this value asserts a timing property. They assert that a
/// fake-tmux reply block eventually reaches the stream — the deadline exists
/// only so a reply that never arrives fails with a named diagnostic instead of
/// hanging the run. On success it costs nothing: the poll returns as soon as
/// the condition holds.
///
/// The repo already has the precedent. PR #415 raised `bridge`'s `readyTimeout`
/// from 5 s to an effectively-infinite 600 s for exactly this reason — "the
/// ready-timeout is incidental machinery in every orchestration test here" —
/// and the one test that genuinely exercises the timeout passes its own short
/// value explicitly. That default is still live at
/// `Tests/TBDDaemonTests/AttachRPCTests.swift:137`.
///
/// ## Sizing
///
/// Swift Testing runs the whole fast pass in one process with no concurrency
/// cap, so per-test scheduling latency scales with the pass's population, not
/// with this suite. A deadline inside that latency is a coin flip, not a
/// signal: in CI the whole `ControlModeInputHealth` suite was observed
/// finishing green at 45.8 s / 47.4 s and red at 47.9 s against a 30 s
/// deadline, and the failures burned the *full* 30 s, so the deadline was the
/// binding constraint rather than an incidental one.
///
/// The pass that binds this value is fast pass 2 (everything but the two
/// daemon targets, ~7200 tests). Measured on two green runs of one commit,
/// its slowest test reported 101.7 s on one (p50 9.9 s, p90 88.2 s, p99
/// 100.5 s) and 82.4 s on the other (p90 72.3 s) — runner noise alone moves
/// the tail by about twenty seconds — and about 30% of its tests report over
/// 45 s on every run measured. Fast passes 1a and 1b report longer tails (on
/// the second run, max 111.7 s and 107.4 s, p50 84.0 s and 63.6 s), but a
/// reported duration there includes the time a test waits for its body to
/// start, which a wait inside the body never pays, so those figures bound a
/// wait only loosely. The record agrees: across five CI attempts of that
/// commit no bounded wait timed out in pass 1a or 1b. In pass 2 a healthy wait
/// itself comes close to the bound: on a green run a test whose only wait
/// succeeded (`ThemeStoreTests.watcherReloadsOnExternalAdd`, which needs the
/// main actor) reported 87.6 s, within 2.4 s of a 90 s bound, and passing
/// tests on a run of `main` reached 97.2 s.
///
/// 120 s clears pass 2's green maximum by ~18 s, and the deadline still
/// elapses only on a genuine hang.
///
/// ## The interaction with `.clockDriven` — read before changing either value
///
/// Two suites that consume this value ARE `.clockDriven`, so its time limit and
/// this deadline race each other: `AttachRPCOrchestrationTests`
/// (`Tests/TBDDaemonTests/AttachRPCTests.swift`, 13 `waitFor` call sites) and
/// `PaneRepairCoordinatorTests` (31 call sites).
///
/// All 44 of those call sites are **unguarded**. They read
/// `try await waitFor(…)`, but `waitFor` is `@discardableResult` and does not
/// throw on timeout — it records an `Issue` and returns `false`, and the `try`
/// covers only the inner `Task.sleep`. Execution therefore continues past a
/// timeout and chained waits are real. (Contrast `ControlModeInputHealthTests`,
/// whose sites are `try #require(await waitFor…)` and so abort at the first
/// timeout.)
///
/// The invariant is **not** "all N chained waits must fit inside the suite
/// limit". That was never satisfiable and is not a property this change gives
/// up: the deepest chain is 6 waits in one `PaneRepairCoordinator` test (the
/// one whose name begins "swallowed successor overflow: gen-2's signal
/// dedup…"), and 6 x 30 s = 180 s already blew the old `.minutes(1)` limit.
///
/// The operative invariant is: **the suite limit must afford the first full
/// deadline plus the rest of an ordinary test.** The first timeout's
/// `Issue.record` fires immediately and carries the named diagnostic, so it
/// always survives even if the limit later truncates the test. Chains beyond
/// the first belong to a test that is already failing; truncating those is
/// acceptable and deliberate.
///
/// Checked against `.clockDriven`'s 5-minute (300 s) limit:
/// - one `waitFor` (120 s) + one arming wait (45 s) = 165 s ✓
/// - two `waitFor` = 240 s ✓
/// - two arming waits = 90 s ✓ (preserves the "a test that waits twice must
///   afford both waits" property the old pairing reasoned about)
///
/// The margin past that is thin, and the 6-deep chain is not the only case that
/// overruns: counting each wait on this value — `waitFor` and the suite's own
/// `readUntil` — at 120 s and each clock wait at 45 s, **10 of the 13**
/// `PaneRepairCoordinatorTests` have a worst case above 300 s (the 6-deep one,
/// with its two `readUntil` reads, needs 960 s). All of them are consistent
/// with the invariant above — only an already-failing test walks a full chain
/// of timeouts, and the first timeout's diagnostic has already been recorded by
/// then — but none of them has spare room. **If they start tripping, shorten
/// the chains; do not raise 300 s.** A longer limit only buys time for tests
/// that are already failing, while making every genuine wedge that much slower
/// to attribute.
///
/// ## Why not `@Suite(.serialized)`
///
/// It was considered and it is not the remedy here. `ArchivedWorktreeSearchTests`
/// "Archived search debounce" is *already* `.clockDriven, .serialized` and
/// still failed twice in CI, because the contention is process-global: every
/// target compiles into one process and Swift Testing parallelizes across all
/// of them, so serializing one suite does not reduce the number of runnable
/// tasks its waiter is queued behind. `Tests/CLAUDE.md` advises reaching for
/// `.serialized` before a longer timeout; that advice is about a suite starving
/// *itself* (its own tests megaYielding against each other) and does not cover
/// this case.
///
/// ## The value is shared; this is where its derivation lives
///
/// The number itself is `TestDeadlines.saturatedPass`
/// (`Tests/TestSupport/BoundedGateSupport.swift`), because
/// `Tests/TBDDaemonLiveTests` cannot import this symbol and two waits there
/// need the same budget. Keeping one literal is what stops the three from
/// drifting apart unnoticed; the reasoning above is what re-derives it, and it
/// stays here. Re-derive it together with `TestGate.deadline`, which must
/// dominate it, and with the clock's arming waits and `.clockDriven`.
let ciSafeDeadline: Duration = TestDeadlines.saturatedPass

/// Thread-safe, synchronous recorder of fake-client stream writes in call
/// order.
final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [String] = []
    func record(_ line: String) { lock.lock(); _writes.append(line); lock.unlock() }
    var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
}

/// A fake-backed correlator: a real `TmuxControlCommandClient` whose stream
/// writes land in the returned recorder (onFatalError is a no-op). Tests feed
/// reply blocks by hand through `client.handle(...)`.
func makeFakeClient() -> (TmuxControlCommandClient, LineRecorder) {
    let recorder = LineRecorder()
    let client = TmuxControlCommandClient(
        writeLine: { recorder.record($0) },
        onFatalError: {})
    return (client, recorder)
}

// `waitFor` and its `BoundedWaitTimeout` diagnostic live in
// `Tests/TestSupport/BoundedGateSupport.swift`, beside the `TestDeadlines`
// constant they default to. Two targets need them — the suites here and the
// tier-3 supervisor suites in `Tests/TBDDaemonLiveTests`, which cannot import
// this file — and one copy is what keeps the diagnostic wording and the
// capture-then-recheck ordering from drifting apart. They arrive through
// `import TestSupport` above; call sites read the same either way.

// MARK: - Ordered reply feed

/// Thread-safe weak box letting a `writeLine` closure (built before the client
/// exists) feed reply blocks back into that client.
final class ClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _client: TmuxControlCommandClient?
    var client: TmuxControlCommandClient? {
        get { lock.lock(); defer { lock.unlock() }; return _client }
        set { lock.lock(); _client = newValue; lock.unlock() }
    }
}

/// Monotone count of reply blocks fully handed to the correlator. Held
/// separately from `ReplyFeed` so the drain task can own it without capturing
/// (and thus retaining) the feed.
private final class ReplyDeliveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func increment() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}

/// A SINGLE-CONSUMER reply feed for the fake control-mode clients — the harness
/// half of `TmuxControlCommandClient`'s order-based correlation.
///
/// **Why this exists (#494).** The correlator matches reply blocks to commands
/// **by order**: `complete` pops `pending.removeFirst()`, trusting tmux's
/// protocol invariant that exactly one reply block arrives per command, in
/// command order. Production upholds that because `TmuxControlSupervisor.drain`
/// feeds every event from ONE loop — `for await event in connection.events {
/// … await client.handle(event) }` — so blocks reach the actor strictly in
/// stream order.
///
/// A fake `writeLine` that spawns a fresh unstructured `Task { await
/// client.handle(…) }` per write does **not** model that. Those tasks race each
/// other into the actor; their arrival order is a scheduling artifact that
/// matches creation order on an idle box and stops doing so under load. Because
/// `deliverInput` awaits only `sendList` — which returns after the stream
/// **write**, not the reply — several keystrokes are routinely in flight at
/// once, so their verdicts could be permuted onto the wrong commands. With
/// verdicts {fail, ok, ok} arriving as {ok, ok, fail}, the edge-triggered health
/// tracker fires ONE event instead of two and the waiter burns its full
/// `ciSafeDeadline`. That manufactured race — not the router — was the flake.
///
/// `ReplyFeed` restores the production shape. `enqueue` pushes **synchronously**,
/// in write order, into an unbounded `AsyncStream`; one long-lived task awaits
/// `client.handle(...)` for each in turn. Completion order therefore equals
/// write order by construction, at any load — the same single-consumer shape
/// `ControlModeInputRouter` itself uses, for the same reason.
///
/// It also provides the quiescence signal that replaces "sleep 50 ms and hope":
/// `waitForDeliveries(n)` is a real happens-before, because `reportDelivery`
/// runs synchronously inside `client.handle`, so `delivered >= n` means the
/// first `n` verdicts have already been recorded.
final class ReplyFeed: @unchecked Sendable {
    private let box = ClientBox()
    private let counter = ReplyDeliveryCounter()
    private let continuation: AsyncStream<TmuxControlEvent>.Continuation
    private let drain: Task<Void, Never>

    init() {
        var escaped: AsyncStream<TmuxControlEvent>.Continuation!
        let stream = AsyncStream<TmuxControlEvent>(bufferingPolicy: .unbounded) { escaped = $0 }
        self.continuation = escaped
        // Captures the box and counter, never `self` — so the feed can
        // deallocate, and its `deinit` can end this loop, without a cycle.
        let box = self.box
        let counter = self.counter
        // `gateHoldingTask`, not a bare `Task`: this drain is long-lived and
        // test-owned, and every reply it hands to the correlator is one hop on
        // whatever queue it was started on. On the cooperative pool that hop
        // costs the pass's own per-test latency (p50 65.6 s on a green fast
        // pass 1), which is what left the router suites reporting partial
        // progress — "observed 2 of 4 writes" — at their 90 s bounds while
        // every assertion in them was sound. Running here takes the whole feed
        // off the shared queue.
        //
        // It is STILL ONE TASK, so the single-consumer ordering this type
        // exists to provide is untouched: `handle` is awaited for each event in
        // turn, and completion order equals write order by construction exactly
        // as before. `gateHoldingTask` changes where the task runs, never how
        // many there are.
        self.drain = gateHoldingTask {
            for await event in stream {
                await box.client?.handle(event)
                counter.increment()
            }
        }
    }

    /// Backstop teardown: a feed that goes out of scope without `finish()` (an
    /// early `#require` abort, say) must not leave its drain task running.
    deinit {
        continuation.finish()
        drain.cancel()
    }

    /// Point the feed at the client whose `writeLine` fills it. Weak, so the
    /// client (which retains this feed through its `writeLine` closure) is not
    /// kept alive by it.
    func attach(_ client: TmuxControlCommandClient) { box.client = client }

    /// Queue one reply block. Synchronous and ordered: the caller's write order
    /// IS the delivery order.
    func enqueue(_ event: TmuxControlEvent) { continuation.yield(event) }

    /// Reply blocks fully processed by the correlator so far.
    var delivered: Int { counter.count }

    /// Wait until at least `count` reply blocks have been fully processed. The
    /// quiescence signal for "…and nothing further happened" assertions: a
    /// fixed settle samples once and can only produce false greens.
    @discardableResult
    func waitForDeliveries(_ count: Int,
                           sourceLocation: SourceLocation = #_sourceLocation) async throws -> Bool {
        try await waitFor("\(count) reply blocks delivered",
                          observed: { "\(self.delivered)" },
                          sourceLocation: sourceLocation) {
            self.delivered >= count
        }
    }

    /// End the feed and await the drain task, so no reply delivery outlives the
    /// test that created it.
    ///
    /// **Awaiting `drain.value` is the load-bearing half, and its guarantee has
    /// one precondition worth stating exactly.** It makes "`finish()` returned"
    /// mean "every block ALREADY YIELDED into the stream has been handed to the
    /// correlator". It can do nothing for a block that has not been yielded yet:
    /// `continuation.finish()` runs first, and a `yield` onto a finished
    /// continuation is silently discarded. So the happens-before callers rest on
    /// is a joint property of this method and `makeRespondingClient`, which
    /// enqueues each reply BEFORE recording the write that a waiter can observe
    /// (see its doc comment). Given that order, a caller that reaches here on a
    /// recorded write — `pasteFailureDoesNotStall` waits for `send-keys … 5a` —
    /// necessarily has its replies in the buffer, and awaiting the drain is what
    /// delivers them. Reverse the two statements there and no amount of draining
    /// here recovers the reply.
    ///
    /// **`cancel()` does not truncate that buffer** — measured, not assumed,
    /// because the opposite is the natural assumption and it is wrong.
    /// `AsyncStream` implements task cancellation as `finish()`, and a finished
    /// stream still yields everything already buffered before `next()` returns
    /// nil; the loop body's only suspension is an actor hop, which ignores
    /// cancellation. With a deliberate backlog of all 20,000 blocks in flight
    /// at the call, every one was still delivered
    /// (`ControlModeTestSupportTests.finishDeliversBufferedReplies`, run against
    /// this exact code). So the reply to a `send(…)`-shaped command — the
    /// PasteExecutor load-buffer / paste-buffer / delete-buffer shape, whose
    /// loss would strand a `withCheckedThrowingContinuation` forever — is not at
    /// risk here. Delete `await drain.value` and it would be.
    func finish() async {
        continuation.finish()
        drain.cancel()
        await drain.value
    }
}

/// A fake correlator client that answers every command it is written with the
/// verdict `shouldFail(commandText)` chooses — `%error` when true, `%end`
/// otherwise — through an ORDERED single-consumer `ReplyFeed`.
///
/// One stream write may carry several `\n`-joined commands (`sendList`); each
/// gets its own reply block, enqueued in command order. Callers must
/// `await feed.finish()` when done.
///
/// The feed's drain runs on `GateExecutor.shared` (see `ReplyFeed.init`), so
/// the reply half of the handshake leaves the saturated pass's queue. Give the
/// router half the same treatment — `ControlModeInputRouter(executor:)` — or
/// the pipeline is only half off the pool.
///
/// **The replies are enqueued BEFORE the write is recorded, and that order is
/// load-bearing** — it is what `ReplyFeed.finish()`'s happens-before rests on.
/// Tests routinely wait on the recorded WRITE (`pasteFailureDoesNotStall` polls
/// `recorder.writes.contains("send-keys -H -t %0 5a")` every 10 ms) and then
/// tear down. With the recording first, a waiter that observes the write in the
/// gap between the two statements — one preemption of this executor thread is
/// enough — can reach `finish()` before the reply is in the buffer, so
/// `continuation.finish()` lands first and the `yield` that follows is silently
/// dropped. Enqueuing first makes "the write is visible" imply "the reply is
/// buffered", which is precisely the premise `await drain.value` needs: it
/// drains what is already enqueued, and can do nothing for a block that has not
/// been yielded yet.
func makeRespondingClient(shouldFail: @escaping @Sendable (String) -> Bool = { _ in false })
    -> (TmuxControlCommandClient, LineRecorder, ReplyFeed) {
    let recorder = LineRecorder()
    let feed = ReplyFeed()
    let client = TmuxControlCommandClient(
        writeLine: { line in
            for command in line.split(separator: "\n", omittingEmptySubsequences: false) {
                feed.enqueue(shouldFail(String(command))
                    ? .commandFailed(number: 0, fromClient: true, lines: ["no pane"])
                    : .commandSucceeded(number: 0, fromClient: true, lines: []))
            }
            recorder.record(line)
        },
        onFatalError: {})
    feed.attach(client)
    return (client, recorder, feed)
}
