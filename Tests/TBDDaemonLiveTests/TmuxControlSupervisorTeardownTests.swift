import Darwin
import Foundation
import TestSupport
import Testing

@testable import TBDDaemonLib

/// R5-M1: a fatal-error teardown's blocking `stop()` (up to ~2 s of SIGTERM →
/// SIGKILL escalation) must run OFF the supervisor actor — otherwise every
/// supervisor call for every worktree stalls behind one wedged connection.
///
/// ## Why this is tier 3
///
/// Every test here spawns a real child over a real pty — a stub standing in
/// for `tmux -CC` — and then races a wall-clock deadline for a handshake that
/// crosses three executors (the correlator's `onFatalError` → a fresh
/// unstructured `Task` → the supervisor actor → `DispatchQueue.global`). That
/// is the target's own admission criterion verbatim: "a spawned child racing a
/// deadline" (`Package.swift`), the same one `ClaudeCloudSpawnerTimeoutTests`
/// cites, and the sibling `TmuxControlConnectionTeardownTests` already sits
/// here on it.
///
/// It was in the fast parallel pass instead, and that is where it went red. In
/// the week to 2026-08-28 it took 4–5 of its 5 tests down in 3 of the 5 red
/// runs on `main`, always on the FIRST handshake wait and never on anything
/// downstream of it. The measurements say the deadline was reading contention,
/// not the supervisor:
///
/// - Every failing test recorded exactly ONE issue. In
///   `ensureConnectionWaitsForInFlightStop` the first 90 s wait timed out while
///   the *later* 90 s wait — for a strictly longer chain: gate released →
///   `stop()` returned → the parked `ensureConnection` resumed → a successor
///   was created — passed, along with every assertion after it. The work was in
///   flight, not absent.
/// - The waiter could not be scheduled to observe its own expiry: the issue
///   landed at 122.77 s of test time, well past when a 90 s deadline armed at
///   the top of the test could have fired.
/// - In that pass the median test's own reported span was 85.8 s (p90 112.1,
///   max 132.8) and 47% of its 4359 tests spanned longer than the whole
///   deadline — the same figures on the green run either side of it, so the
///   colour of a run was luck.
///
/// Here the pass is `--no-parallel` on an otherwise idle machine, the
/// handshakes settle in milliseconds, and the bound below goes back to being
/// what it is meant to be: a hang-catcher that asserts nothing.
/// ## Why an explicit `.timeLimit`, and why 7 minutes
///
/// Tier-3 suites pin their own rather than inheriting `.clockDriven`, whose
/// value is sized for the fast parallel pass (`Tests/CLAUDE.md`). Not every
/// wait here is bounded: the bare `await`s on the supervisor actor — the
/// `command(server:)` probes taken while stops are held, and each closing
/// `stopAll()` — are calls on the very actor whose wedging is the regression
/// under test, so a real regression hangs the quiet-pass step to its
/// 15-minute `timeout-minutes` with no test named.
///
/// The number is sized above this suite's worst-case chain, the way
/// `ProviderEventsSupervisorTests` sizes its own. `stopAllDoesNotBlockActor`
/// chains FOUR `teardownWaitDeadline` waits — 360 s — and the gate holds run
/// concurrently on GCD threads rather than adding to that. A 4-minute limit
/// would sit under the chain, and the failure that produced would be the worst
/// kind: a generic time-limit expiry with no named diagnostic, reached on
/// waits that were merely slow rather than wrong. 7 minutes clears 360 s with
/// margin, stays well inside the quiet pass's 15-minute step budget, and still
/// clears the 1.97 s this suite actually takes by two orders of magnitude.
///
/// If that chain ever needs to grow, shorten it rather than raising this
/// again — the standing remedy in `Tests/CLAUDE.md`.
@Suite("TmuxControlSupervisor teardown isolation", .timeLimit(.minutes(7)))
struct TmuxControlSupervisorTeardownTests {

    /// Write an executable stub "tmux" that ignores its args and sleeps, so a
    /// real `TmuxControlConnection` can start (pty + process) without tmux.
    private func makeStubBinary() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-teardown-stub-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("stub-tmux.sh").path
        try "#!/bin/sh\nexec sleep 300\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test("a slow connection stop does not block unrelated supervisor calls")
    func slowStopDoesNotBlockActor() async throws {
        let stub = try makeStubBinary()
        defer { try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent) }

        // The stop seam blocks until the TEST releases it, so "teardown is
        // mid-stop" is a deterministic state, not a timing window.
        let stopStarted = EventCounter()
        // `stopConnection` runs on `DispatchQueue.global(qos: .utility)` — the
        // production code puts blocking stops off the actor deliberately — so
        // this gate never parks a cooperative-pool thread and needs no
        // `gateHoldingTask`. The same holds for the other two gates below.
        let stopGate = DispatchSemaphore(value: 0)
        let supervisor = TmuxControlSupervisor(
            makeConnection: { TmuxControlConnection(serverName: $0, tmuxBinary: stub) },
            stopConnection: { connection in
                stopStarted.increment()
                // Gate ONLY the teardown under test. The test's closing
                // `stopAll()` cleanup re-enters this seam for the successor
                // connection; gating that call too would deadlock the test
                // against its own semaphore (the defer below can't run while
                // the body is awaiting stopAll).
                if stopStarted.count == 1 {
                    stopGate.waitForGate("TmuxControlSupervisor slow-stop teardown held mid-stop")
                }
                connection.stop()
            })
        defer { stopGate.signal() }  // never leave the stop thread parked on failure

        await supervisor.ensureConnection(serverName: "srv-slow")
        let client = try #require(await supervisor.command(server: "srv-slow"))

        // Trigger the real fatal path: a client-originated reply block with an
        // empty queue is a correlator protocol violation → onFatalError →
        // teardown. (Reachable in production from any untolerated %error too.)
        await client.handle(.commandSucceeded(number: 1, fromClient: true, lines: []))
        #expect(await waitUntil(
            { stopStarted.count == 1 }, timeout: teardownWaitDeadline), "teardown never reached stop()")

        // While the stop is STILL blocked, unrelated supervisor calls must
        // complete. Bounded by a generous CI-safe deadline: pre-fix, the
        // actor is wedged inside stopConnection and the call never returns.
        // Unstructured on purpose — a task blocked on a wedged actor cannot
        // be cancelled, so a task group here would hang the test forever.
        let unrelatedDone = EventCounter()
        Task.detached {
            _ = await supervisor.command(server: "srv-unrelated")
            unrelatedDone.increment()
        }
        let unrelatedCompleted = await waitUntil({ unrelatedDone.count == 1 }, timeout: teardownWaitDeadline)
        #expect(unrelatedCompleted, "supervisor actor is blocked by a mid-stop teardown")
        // Pre-fix the actor stays wedged until the gate opens — unwedge so the
        // remaining assertions (and cleanup) can run instead of hanging.
        if !unrelatedCompleted { stopGate.signal() }

        // State left the maps BEFORE stop() ran (that is what un-wedges the
        // actor above), so the eviction is observable now — but a successor
        // may NOT go live until the old stop completes (R6-M4):
        // `ensureConnection` for the same server suspends instead (covered by
        // `ensureConnectionWaitsForInFlightStop` below).
        #expect(await supervisor.command(server: "srv-slow") == nil,
                "faulted connection's client must be evicted before stop()")

        stopGate.signal()   // release the held stop; it stops the stub process
        await supervisor.ensureConnection(serverName: "srv-slow")
        #expect(await supervisor.command(server: "srv-slow") != nil,
                "a successor connection must be creatable once the stop completed")
        await supervisor.stopAll()
    }

    @Test("ensureConnection cannot race an in-flight teardown into two live connections (R6-M4)")
    func ensureConnectionWaitsForInFlightStop() async throws {
        let stub = try makeStubBinary()
        defer { try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent) }

        let created = EventCounter()
        let stopStarted = EventCounter()
        let stopFinished = EventCounter()
        let stopGate = DispatchSemaphore(value: 0)
        let supervisor = TmuxControlSupervisor(
            makeConnection: { server in
                created.increment()
                return TmuxControlConnection(serverName: server, tmuxBinary: stub)
            },
            stopConnection: { connection in
                stopStarted.increment()
                // Gate ONLY the teardown under test — see
                // slowStopDoesNotBlockActor for why the closing stopAll()
                // cleanup must pass through ungated.
                if stopStarted.count == 1 {
                    stopGate.waitForGate("TmuxControlSupervisor in-flight-stop teardown held mid-stop")
                }
                connection.stop()
                stopFinished.increment()
            })
        defer { stopGate.signal() }  // never leave the stop thread parked on failure

        await supervisor.ensureConnection(serverName: "srv-race")
        #expect(created.count == 1)
        let client = try #require(await supervisor.command(server: "srv-race"))

        // Fatal correlator violation → teardown; eviction runs, stop is held.
        await client.handle(.commandSucceeded(number: 1, fromClient: true, lines: []))
        #expect(await waitUntil(
            { stopStarted.count == 1 }, timeout: teardownWaitDeadline), "teardown never reached stop()")

        // A re-attach's ensureConnection lands while the old tmux client
        // process is still dying. It must SUSPEND: `PaneFanout.route` keys by
        // (server, paneID) only, so a successor started now would leave two
        // live -CC connections routing duplicate %output into one pane pipe.
        let ensured = EventCounter()
        Task.detached {
            await supervisor.ensureConnection(serverName: "srv-race")
            ensured.increment()
        }
        // Bounded negative check: give the racing ensureConnection ample time
        // to (incorrectly) create a successor — pre-fix `created` hits 2 here.
        try await Task.sleep(for: .milliseconds(500))
        #expect(created.count == 1,
                "no successor may be created while the old connection is still stopping")
        #expect(ensured.count == 0, "ensureConnection must still be suspended mid-stop")

        // The held stop completes → the parked ensureConnection resumes and
        // creates exactly one successor.
        stopGate.signal()
        #expect(await waitUntil({ ensured.count == 1 }, timeout: teardownWaitDeadline),
                "ensureConnection must resume once the stop completed")
        #expect(stopFinished.count == 1)
        #expect(created.count == 2, "exactly one successor after the teardown finished")
        #expect(await supervisor.command(server: "srv-race") != nil)
        await supervisor.stopAll()
    }

    @Test("stopAll's blocking stops run off the actor: unrelated calls complete mid-stop (R8-M2)")
    func stopAllDoesNotBlockActor() async throws {
        let stub = try makeStubBinary()
        defer { try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent) }

        let stopStarted = EventCounter()
        let stopGate = DispatchSemaphore(value: 0)
        let supervisor = TmuxControlSupervisor(
            makeConnection: { TmuxControlConnection(serverName: $0, tmuxBinary: stub) },
            stopConnection: { connection in
                stopStarted.increment()
                // Held open until the test signals.
                stopGate.waitForGate("TmuxControlSupervisor stopAll() stop() held mid-stop")
                connection.stop()
            })
        // Never leave stop threads parked on failure (one per connection below).
        defer { for _ in 0..<3 { stopGate.signal() } }

        await supervisor.ensureConnection(serverName: "srv-a")
        await supervisor.ensureConnection(serverName: "srv-b")

        let stopAllDone = EventCounter()
        Task.detached {
            await supervisor.stopAll()
            stopAllDone.increment()
        }

        // stopAll must route through the injectable stop seam (pre-fix it
        // called connection.stop() directly ON the actor).
        #expect(await waitUntil(
            { stopStarted.count == 2 }, timeout: teardownWaitDeadline), "stopAll never reached the stop seam")

        // While BOTH stops are still held open, an unrelated actor call must
        // complete promptly — pre-fix the actor is wedged inside the stops.
        // Unstructured on purpose (see slowStopDoesNotBlockActor).
        let unrelatedDone = EventCounter()
        Task.detached {
            _ = await supervisor.command(server: "srv-third")
            unrelatedDone.increment()
        }
        #expect(await waitUntil({ unrelatedDone.count == 1 }, timeout: teardownWaitDeadline),
                "supervisor actor is blocked by a mid-stop stopAll")

        // Bookkeeping ran BEFORE the stops: both clients already evicted.
        #expect(await supervisor.command(server: "srv-a") == nil)
        #expect(await supervisor.command(server: "srv-b") == nil)

        // R6-M4 consistency: while stopAll's stops are in flight the servers
        // are marked stopping, so a racing ensureConnection must park rather
        // than start a successor beside a still-dying tmux client process.
        let ensured = EventCounter()
        Task.detached {
            await supervisor.ensureConnection(serverName: "srv-a")
            ensured.increment()
        }
        // Bounded negative check: ample time to (incorrectly) create one.
        try await Task.sleep(for: .milliseconds(500))
        #expect(ensured.count == 0, "ensureConnection must park while stopAll's stop is in flight")

        stopGate.signal()
        stopGate.signal()
        #expect(await waitUntil({ stopAllDone.count == 1 }, timeout: teardownWaitDeadline),
                "stopAll must return once its stops complete")
        // The parked ensureConnection resumes and creates a fresh connection:
        // the supervisor stays usable after stopAll (the reconnect-after-
        // stopAll contract in TmuxControlCommandClientIntegrationTests).
        #expect(await waitUntil({ ensured.count == 1 }, timeout: teardownWaitDeadline),
                "parked ensureConnection must resume after stopAll finishes")
        #expect(await supervisor.command(server: "srv-a") != nil)

        stopGate.signal()  // pre-release the successor's stop
        await supervisor.stopAll()
    }

    @Test("a fatal teardown's blocking stop runs OFF the cooperative pool (R9-H1)")
    func fatalTeardownStopsOffCooperativePool() async throws {
        let stub = try makeStubBinary()
        defer { try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent) }

        // Record the dispatch queue the stop seam runs on. `onFatalError`
        // fires the teardown from a bare `Task {}` — pre-fix the seam ran on
        // Swift concurrency's fixed-width cooperative executor (queue label
        // contains "cooperative"), where a blocked stop() starves every task
        // in the daemon. Post-fix it must run on a GCD global queue.
        let labelBox = TextBox()
        let stopSeen = EventCounter()
        let supervisor = TmuxControlSupervisor(
            makeConnection: { TmuxControlConnection(serverName: $0, tmuxBinary: stub) },
            stopConnection: { connection in
                labelBox.set(String(cString: __dispatch_queue_get_label(nil)))
                stopSeen.increment()
                connection.stop()
            })

        await supervisor.ensureConnection(serverName: "srv-pool")
        let client = try #require(await supervisor.command(server: "srv-pool"))
        await client.handle(.commandSucceeded(number: 1, fromClient: true, lines: []))

        #expect(await waitUntil({ stopSeen.count >= 1 }, timeout: teardownWaitDeadline),
                "fatal teardown never reached stop()")
        let label = labelBox.get() ?? ""
        #expect(!label.contains("cooperative"),
                "blocking stop() ran on the cooperative pool (queue: \(label))")
        await supervisor.stopAll()
    }

    @Test("a naturally-ended -CC stream still gets stop(): the pty fd is not leaked (R9-M1)")
    func naturalStreamEndStopsTheConnection() async throws {
        // Stub exits ON ITS OWN almost immediately: the event stream ends
        // naturally (no fatal teardown, no stopAll). Pre-fix nothing ever
        // called stop() on this path, leaking the pty master fd — it is
        // closed only inside stop().
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-natural-stub-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stub = dir.appendingPathComponent("stub-tmux.sh").path
        try "#!/bin/sh\nexec sleep 0.1\n".write(toFile: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
        defer { try? FileManager.default.removeItem(atPath: dir.path) }

        let stopSeen = EventCounter()
        let supervisor = TmuxControlSupervisor(
            makeConnection: { TmuxControlConnection(serverName: $0, tmuxBinary: stub) },
            stopConnection: { connection in
                stopSeen.increment()
                connection.stop()
            })

        await supervisor.ensureConnection(serverName: "srv-natural")
        #expect(await waitUntil({ stopSeen.count == 1 }, timeout: teardownWaitDeadline),
                "natural stream end must stop() the connection to release its pty fd")
        // The map entry is gone too (drain owned it at stream end).
        #expect(await supervisor.command(server: "srv-natural") == nil)
    }
}

/// Hang guard for this suite's bounded waits on teardown progress.
///
/// Deliberately unchanged at the 90 s the suite carried in the fast pass. The
/// point of the move is that the number is no longer load-bearing — in the
/// serial quiet pass a healthy handshake returns in milliseconds — so keeping
/// it makes this a pure re-tiering with no deadline re-derivation smuggled in.
/// Every wait is positive and breaks on its first satisfying probe, so the
/// value costs a passing run nothing and only a genuinely wedged one pays it.
/// `ciSafeDeadline` itself lives in `Tests/TBDDaemonTests` and is not
/// importable from this target, so the value comes from `TestSupport` — one
/// literal for all three consumers, with the derivation still recorded at
/// `ciSafeDeadline`.
private let teardownWaitDeadline: Duration = TestDeadlines.saturatedPass

/// Poll `condition` until it holds or `timeout` elapses. Returns its final
/// value. File-local twin of `Tests/TBDDaemonTests`' `waitUntil`, which this
/// target cannot import.
///
/// **Cancellation ends the wait; it does not shorten the sleep.** `Task.sleep`
/// throws `CancellationError` the instant the task is cancelled — which the
/// suite's own `.timeLimit` does — so swallowing it with `try?` would leave
/// the loop spinning with nothing to suspend on, burning its whole remaining
/// budget on a cooperative thread and then blaming the call site. That exact
/// shape cost this repo a diagnosis once already (33.7M iterations in 30 s)
/// and `Tests/CLAUDE.md` lists it as an anti-pattern to check for in any flake
/// fix. Returning the condition's current value keeps the verdict honest: a
/// cancelled wait reports what it last saw rather than a stale `false`.
private func waitUntil(
    _ condition: @Sendable () -> Bool, timeout: Duration
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            return condition()
        }
    }
    return condition()
}

/// Lock-boxed single string for cross-thread capture in seams.
private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ newValue: String) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Minimal thread-safe counter for cross-thread test signals.
private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
