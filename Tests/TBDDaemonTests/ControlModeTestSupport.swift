import Foundation
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
/// ## Sizing (30 s -> 90 s)
///
/// 30 s was sized against a ~3000-test population. The population is now 4536
/// and Swift Testing runs all of it in one process with no concurrency cap, so
/// per-test scheduling latency scales with the total, not with this suite. In
/// CI the whole `ControlModeInputHealth` suite has been observed finishing
/// green at 45.8 s / 47.4 s and red at 47.9 s — a ~2 s band on either side of
/// a fixed 30 s wall-clock deadline, which is a coin flip, not a signal. The
/// observed failures burned the *full* 30 s deadline, so the old value was the
/// binding constraint rather than an incidental one.
///
/// 90 s is 3x that deadline, and it is spent against a tail that sharding the
/// fast pass independently roughly halves (p90 26.4 s -> 14.6 s, means over 5
/// iterations, measured interleaved under induced load with population held
/// constant). Two compounding
/// changes, so the effective headroom is well past 3x — and the deadline still
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
/// Checked against `.clockDriven`'s 4-minute (240 s) limit:
/// - one `waitFor` (90 s) + one `waitForSuspension` (45 s) = 135 s ✓
/// - two `waitFor` = 180 s ✓
/// - two `waitForSuspension` = 90 s ✓ (preserves the "a test that waits twice
///   must afford both waits" property the old pairing reasoned about)
///
/// The margin past that is thin, and the 6-deep chain is not the only case that
/// overruns: counting `waitFor` at 90 s and each clock wait at 45 s, **6 of the
/// 13** `PaneRepairCoordinatorTests` have a worst case above 240 s (the 6-deep
/// one needs 540 s). All of them are consistent with the invariant above — only
/// an already-failing test walks a full chain of timeouts, and the first
/// timeout's diagnostic has already been recorded by then — but none of them
/// has spare room. **If they start tripping, shorten the chains; do not raise
/// 240 s again.** A longer limit only buys time for tests that are already
/// failing, while making every genuine wedge that much slower to attribute.
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
/// ## Two copies live outside this target
///
/// `Tests/TBDDaemonLiveTests` cannot import this symbol, so
/// `ProviderEventsSupervisorTests.saturatedWaitDeadline` and
/// `TmuxControlSupervisorTeardownTests.teardownWaitDeadline` each carry the
/// same 90 s as a local literal. Nothing detects divergence between the three,
/// so re-derive them together — and note that the two copies sit in the quiet
/// pass, which never sees the saturation this value is sized against, so they
/// have room this one does not.
let ciSafeDeadline: Duration = .seconds(90)

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

/// Carries a bounded wait's OBSERVED state on the primary failure line
/// (assertion-hygiene rule 4: `#expect(cond, "…")` and `Issue.record(String)`
/// both demote the message to a trailing `↳` line that CI summaries drop; only
/// `Issue.record(_: some Error)` survives). `observed` is nil when the caller
/// supplied no reporter — the text then matches the pre-#494 wording exactly.
struct ControlModeWaitTimeout: Error, CustomStringConvertible {
    let what: String
    let observed: String?
    let deadline: Duration

    var description: String {
        let seen = observed.map { " — observed \($0)" } ?? ""
        return "timed out waiting for \(what)\(seen) after polling up to \(deadline)"
    }
}

/// Poll every 10 ms until `condition`, recording an Issue at the caller's
/// source location after `deadline`. A final post-deadline re-check absorbs
/// sleep slices that overshoot the deadline AFTER the condition became true
/// (observed live as `timedOut(got: N, want: N)` at loadavg ~40).
///
/// `observed` renders what the waiter actually saw at the moment it gave up; it
/// is evaluated only on the failing path. Supply it for any wait whose
/// condition is uninformative on its own ("2 health events" says nothing about
/// how many arrived).
///
/// **The diagnostic reports the state that decided the failure, not the state
/// at report time** (assertion-hygiene rule 4 — the
/// `fileBytesMismatch(expected: 6150, actual: 6150)` shape). `observed` and
/// `condition` are two closures over the same growing state, so reading
/// `observed` *after* the last `condition()` lets an event that lands in the
/// gap print the self-contradictory `timed out waiting for 2 health events —
/// observed 2`. The order below closes that: `observed` is captured first, and
/// the condition is then re-checked once more, so anything that arrived while
/// the diagnostic was being composed makes this a PASS rather than a
/// contradictory failure. The counters these waits watch are monotone, so a
/// condition that is false after the capture was false at the capture too —
/// the reported state and the verdict are consistent by construction.
///
/// Returns whether the condition was met (false on timeout) so callers that
/// index into results afterwards can abort via `#require` instead of trapping
/// out of range; count/equality-checking callers may ignore the result.
@discardableResult
func waitFor(
    _ what: String, deadline: Duration = ciSafeDeadline,
    observed: (@Sendable () async -> String)? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async throws -> Bool {
    let end = ContinuousClock.now + deadline
    while ContinuousClock.now < end {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    if await condition() { return true }
    // Capture BEFORE deciding to fail, then re-check: see the doc comment.
    let seen = await observed?()
    if await condition() { return true }
    Issue.record(
        ControlModeWaitTimeout(what: what, observed: seen, deadline: deadline),
        sourceLocation: sourceLocation)
    return false
}

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
        self.drain = Task {
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
