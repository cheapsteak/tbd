import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2: short-lived local stub scripts this suite fully controls, driven
/// entirely on virtual time.
///
/// The stubs are real `bash` children — a duplex NDJSON stream over two real
/// pipes is the thing under test, and a fake would test the fake. Everything
/// that *waits*, though, is on the injected `TestClock`: backoff, the keepalive
/// cadence, the silence watchdog and the SIGTERM→SIGKILL grace. No test here
/// waits out a production interval in real time.
///
/// `.serialized` because each test spawns children and drives a clock; running
/// them against each other floods the pool with exactly the low-priority work
/// each `checkSuspension` is waiting on (`Tests/CLAUDE.md`, "Clock and date
/// seams").
///
/// Contract under test: `docs/remote-provider-contract.md` § `messages`, and
/// `docs/specs/2026-08-29-remote-peer-messaging-design.md`.
@Suite("PeerLinkSupervisor", .clockDriven, .serialized)
struct PeerLinkSupervisorTests {

    /// Mirrors the daemon's process-wide SIGPIPE stance (`Sources/TBDDaemon/main.swift`),
    /// which `PeerLinkSupervisor` depends on: every one of these stubs exits
    /// while the supervisor may still be writing `hello` or a keepalive into its
    /// stdin, and a raw SIGPIPE would kill the whole test process rather than
    /// returning EPIPE to the write. Same precedent as `BoundedProcessRunnerTests`.
    init() {
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - hello

    /// **Resync is by `hello`, not by cursor.** Every connection — the first and
    /// every reconnect alike — opens with TBD's `hello` declaring the origin and
    /// the protocol. Nothing is carried across a reconnect, so a supervisor that
    /// wrote `hello` only on the first connection would leave every later
    /// connection unnegotiated and every shadow peer unannounced.
    ///
    /// The stub records the first line it is given and exits, so each recorded
    /// line belongs to a distinct connection.
    @Test func helloIsWrittenOnConnectAndOnEveryReconnect() async throws {
        let stub = try Stub("hello-per-connect", body: """
            IFS= read -r line && printf '%s\\n' "$line" >> "$STDIN_LOG"
            exit 0
            """)
        defer { stub.remove() }
        let clock = TestClock<Duration>()
        let recorder = LinkRecorder()
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: recorder, healthyResetUptime: 3600, clock: clock,
            now: TestDateSource().provider)
        await supervisor.start()

        _ = try await waitFor(
            "the first messages child to spawn",
            observed: { "spawns=\(stub.spawnCount())" }) { stub.spawnCount() >= 1 }
        // No advance yet: the child is already gone, so a supervisor that
        // reconnected without waiting on its clock would be at 2 by now.
        #expect(stub.spawnCount() == 1, "the reconnect must wait on the injected clock, not spin")

        _ = await advanceVirtualTime(
            clock, until: "the second connection",
            observed: { "spawns=\(stub.spawnCount())" }) { stub.spawnCount() >= 2 }
        _ = try await waitFor(
            "both connections to record their opening line",
            observed: { "lines=\(stub.stdinLines())" }) { stub.stdinLines().count >= 2 }

        await stopDriven(supervisor, clock)

        let lines = stub.stdinLines()
        #expect(lines.count >= 2, "observed \(lines)")
        for line in lines.prefix(2) {
            let decoded = PeerBridgeFrameCodec.decode(
                line: line, negotiatedProtocol: PeerBridgeFrameCodec.peerProtocol)
            #expect(
                decoded == .frame(.hello(
                    origin: "acme-laptop", peerProtocol: PeerBridgeFrameCodec.peerProtocol)),
                "every connection must open with TBD's hello; got \(decoded)")
        }
    }

    // MARK: - Backoff

    /// A child that exits immediately must not be respawned in a hot loop, and
    /// the wait must **grow**. Measured in virtual seconds, which is what makes
    /// this exact rather than a tolerance window.
    ///
    /// **The two samples are compared to each other, never against an absolute
    /// bound.** Each sample is the virtual time from one connection appearing
    /// to the next, so each carries the same per-connection overhead: the 50 ms
    /// drain grace, at most one 500 ms kill grace, and — the term that
    /// dominates — every 0.25 s advance the driver spends while the previous
    /// connection's watchdog and keepalive sleeps are still armed and the
    /// child's EOF has not yet worked its way through to the supervisor. That
    /// last term is paced by real time on a shared machine, so it is not
    /// bounded by any constant in `PeerLinkSupervisor`: a bound derived from
    /// the two graces alone comes to roughly half a second, and that is wrong
    /// by a factor of four — a sample has been observed spending 3.25 virtual
    /// seconds to reach connection 2, where that arithmetic predicts at most
    /// 2.0. What *is* true of the term is that both windows draw it from the
    /// same distribution, so it cancels in the difference — which is why the
    /// assertion below subtracts.
    ///
    /// The backoff inside each sample is disjoint: the wait before connection 2
    /// is `2^0` seconds ±20% (0.8–1.2), the wait before connection 4 is `2^2`
    /// ±20% (3.2–4.8), each rounded up to the 0.25 s advance granularity, so
    /// at least 3.25 against at most 1.25. The difference therefore contains at
    /// least **2.0** virtual seconds of growth, and a `1.0` margin leaves a full
    /// second — four advances — for the two windows' overheads to disagree.
    /// Failing it means the difference collapsed toward the overhead noise
    /// around zero: backoff went flat, which is the regression this test exists
    /// to catch.
    ///
    /// `healthyResetUptime` is 3600 against a frozen date source, so the attempt
    /// counter cannot reset mid-test and turn the growth back into a flat line.
    @Test func reconnectBackoffGrowsAcrossRepeatedChildExit() async throws {
        let stub = try Stub("backoff", body: "exit 0")
        defer { stub.remove() }
        let clock = TestClock<Duration>()
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: LinkRecorder(), healthyResetUptime: 3600, clock: clock,
            now: TestDateSource().provider)
        await supervisor.start()

        _ = try await waitFor(
            "the first messages child to spawn",
            observed: { "spawns=\(stub.spawnCount())" }) { stub.spawnCount() >= 1 }

        let toSecond = await advanceVirtualTime(
            clock, until: "connection 2",
            observed: { "spawns=\(stub.spawnCount())" }) { stub.spawnCount() >= 2 }
        let toThird = await advanceVirtualTime(
            clock, until: "connection 3",
            observed: { "spawns=\(stub.spawnCount())" }) { stub.spawnCount() >= 3 }
        let toFourth = await advanceVirtualTime(
            clock, until: "connection 4",
            observed: { "spawns=\(stub.spawnCount())" }) { stub.spawnCount() >= 4 }

        await stopDriven(supervisor, clock)

        let second = try #require(toSecond)
        let fourth = try #require(toFourth)
        #expect(
            fourth - second > 1.0,
            """
            backoff must grow: the third reconnect waits ~4 virtual seconds where the \
            first waits ~1, so the two samples must differ by at least a second once \
            their shared per-connection overhead cancels; spent second=\(second)s \
            fourth=\(fourth)s (third=\(String(describing: toThird)))
            """)
    }

    // MARK: - Silence watchdog

    /// A provider that completes the handshake and then goes quiet is dead, and
    /// the watchdog must replace it. Detection latency is the entire bound on how
    /// long a shadow peer can lie about being reachable, which is why this stream
    /// runs a tighter limit than `events`.
    ///
    /// Both seams move: the date source is what `lastActivity` is compared
    /// against (wall-clock, so it counts across system sleep), and the clock is
    /// what the watchdog's poll interval sleeps on. Advancing only one of them
    /// proves nothing — a watchdog that read the real wall clock would never fire
    /// inside a test, and one that never slept would spin.
    @Test func silenceWatchdogKillsASilentChild() async throws {
        // Backgrounded sleep plus a TERM trap that kills it: SIGTERM to this
        // shell takes its child down with it. A bash parked in a FOREGROUND
        // `sleep` defers SIGTERM until the sleep finishes, which would outlive
        // the test by ten minutes.
        let stub = try Stub("silent", body: """
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            sleep 300 &
            child=$!
            trap 'kill "$child" 2>/dev/null; exit 143' TERM INT
            wait "$child"
            """)
        defer { stub.remove() }
        let clock = TestClock<Duration>()
        let date = TestDateSource()
        let recorder = LinkRecorder()
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: recorder, silenceLimit: 3, keepaliveInterval: 3,
            healthyResetUptime: 3600, clock: clock, now: date.provider)
        await supervisor.start()

        _ = try await waitFor(
            "the link to come up on the provider's hello",
            observed: { let seen = await supervisor.state; return "state=\(seen) spawns=\(stub.spawnCount())" }
        ) { await supervisor.state == .up }
        let firstPID = try #require(stub.pids().first)

        // Past the 3 s silence limit on the seam the watchdog compares against.
        date.advance(by: 4)
        _ = await advanceVirtualTime(
            clock, until: "the watchdog to replace the silent child", step: 0.5,
            observed: { let seen = await supervisor.state; return "spawns=\(stub.spawnCount()) state=\(seen)" }
        ) { stub.spawnCount() >= 2 }

        _ = try await waitFor(
            "the silent child's process group to die",
            observed: { "group \(firstPID) alive=\(kill(-firstPID, 0) == 0)" }
        ) { kill(-firstPID, 0) != 0 }

        let transitions = await recorder.transitions
        await stopDriven(supervisor, clock)
        #expect(stub.spawnCount() >= 2, "the silent child was killed but never replaced")
        #expect(
            Array(transitions.prefix(2)) == [.up, .down],
            "the link must be published down when the watchdog kills its child; got \(transitions)")
    }

    /// The tighter limit is not a local constant. Both halves of the link read
    /// one number, and it is the codec's — a supervisor that redefined it would
    /// disagree with the frames it encodes and with any provider conforming to
    /// the documented figure.
    @Test func silenceAndKeepaliveDefaultToTheCodecConstants() async throws {
        let stub = try Stub("defaults", body: "exit 0")
        defer { stub.remove() }
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: LinkRecorder(), clock: TestClock<Duration>())
        #expect(await supervisor.silenceLimit == PeerBridgeFrameCodec.silenceLimit)
        #expect(await supervisor.keepaliveInterval == PeerBridgeFrameCodec.keepaliveInterval)
        // The whole point of the constant: a third of what `events` runs at.
        #expect(PeerBridgeFrameCodec.silenceLimit < 90)
    }

    // MARK: - Link state

    /// Link state is an output, not an internal detail: shadow peers must stop
    /// existing while the link is down, so the transition has to reach the
    /// delegate — and `.up` must come from the handshake completing, never from
    /// the child merely being alive.
    @Test func linkGoesUpOnHelloExchangeAndDownOnChildExit() async throws {
        let stub = try Stub("transitions", body: """
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            exit 0
            """)
        defer { stub.remove() }
        let clock = TestClock<Duration>()
        let recorder = LinkRecorder()
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: recorder, healthyResetUptime: 3600, clock: clock,
            now: TestDateSource().provider)
        await supervisor.start()

        // The clock is never advanced, so the supervisor parks in backoff after
        // this one connection and the recorded transitions stay exactly the ones
        // this connection produced.
        _ = try await waitFor(
            "the link to go up then down over one connection",
            observed: { let seen = await recorder.transitions; return "transitions=\(seen)" }
        ) { await recorder.transitions.count >= 2 }
        // Captured BEFORE the stop: `stopDriven` advances the clock, and the
        // supervision task is parked in backoff by now — an advance can let a
        // second connection open and append its own transitions.
        let transitions = await recorder.transitions
        let frames = await recorder.frames
        await stopDriven(supervisor, clock)

        #expect(transitions == [.up, .down])
        #expect(
            frames.first == .hello(origin: "acme-remote", peerProtocol: 1),
            "the provider's hello is delivered after the .up it produced; got \(frames)")
    }

    /// A line that arrives before the provider's `hello` is a protocol violation
    /// ("Neither side may write any other line before it"), and must be dropped
    /// and counted rather than acted on — a `peer` accepted ahead of the
    /// handshake would publish a shadow against an unnegotiated link.
    @Test func aPeerLineAheadOfTheHandshakeIsDroppedAndCounted() async throws {
        let stub = try Stub("premature-peer", body: """
            printf '%s\\n' '{"kind":"peer","handle":"h-1","name":"acme-remote:x","status":"working","protocol":1}'
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            exit 0
            """)
        defer { stub.remove() }
        let clock = TestClock<Duration>()
        let recorder = LinkRecorder()
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: recorder, healthyResetUptime: 3600, clock: clock,
            now: TestDateSource().provider)
        await supervisor.start()

        _ = try await waitFor(
            "the connection to end after its hello",
            observed: { let seen = await recorder.transitions; return "transitions=\(seen)" }
        ) { await recorder.transitions.count >= 2 }
        // Captured before the stop, for the reason
        // `linkGoesUpOnHelloExchangeAndDownOnChildExit` gives: advancing the
        // clock can open a second connection, and its own premature `peer` line
        // would take the count to 2.
        let frames = await recorder.frames
        let prematureDrops = await supervisor.counters.linesBeforeHandshake
        await stopDriven(supervisor, clock)

        #expect(
            !frames.contains(where: { $0.kind == .peer }),
            "a peer line ahead of the hello must never reach the handler; got \(frames)")
        #expect(prematureDrops == 1)
    }

    // MARK: - Sending

    /// **Clean failure, no buffering, anywhere.** A send on a down link fails,
    /// and the frame is gone — not parked for the next connection. The positive
    /// control matters as much as the refusal: without a frame that *does* reach
    /// the wire, "the dropped one never appeared" would also pass against a link
    /// that delivers nothing at all.
    @Test func aSendWhileDownFailsAndIsNotQueued() async throws {
        let stub = try Stub("send-while-down", body: """
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            while IFS= read -r line; do printf '%s\\n' "$line" >> "$STDIN_LOG"; done
            """)
        defer { stub.remove() }
        let clock = TestClock<Duration>()
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: LinkRecorder(), healthyResetUptime: 3600, clock: clock,
            now: TestDateSource().provider)

        let dropped = PeerBridgeFrame.peer(PeerBridgePeer(
            handle: "h-dropped", name: "acme-laptop:never %1", status: "working",
            peerProtocol: PeerBridgeFrameCodec.peerProtocol))
        await #expect(throws: PeerLinkSendFailure.linkDown) {
            try await supervisor.send(dropped)
        }
        #expect(await supervisor.counters.sendsDropped == 1)

        await supervisor.start()
        _ = try await waitFor(
            "the link to come up",
            observed: { let seen = await supervisor.state; return "state=\(seen)" }) { await supervisor.state == .up }

        let delivered = PeerBridgeFrame.peer(PeerBridgePeer(
            handle: "h-delivered", name: "acme-laptop:live %2", status: "working",
            peerProtocol: PeerBridgeFrameCodec.peerProtocol))
        try await supervisor.send(delivered)
        _ = try await waitFor(
            "the live frame to reach the child's stdin",
            observed: { "lines=\(stub.stdinLines())" }
        ) { stub.stdinLines().contains(where: { $0.contains("h-delivered") }) }

        await stopDriven(supervisor, clock)

        let lines = stub.stdinLines()
        #expect(
            !lines.contains(where: { $0.contains("h-dropped") }),
            "a frame refused while down must never be replayed onto a later connection; got \(lines)")
    }

    /// `peer-inventory` is provider-to-TBD only. Refusing it here — rather than
    /// trusting every call site to remember — is what `isProviderToTBDOnly`
    /// exists for.
    @Test func peerInventoryIsRefusedOutbound() async throws {
        let stub = try Stub("inventory", body: """
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            while IFS= read -r line; do printf '%s\\n' "$line" >> "$STDIN_LOG"; done
            """)
        defer { stub.remove() }
        let clock = TestClock<Duration>()
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: LinkRecorder(), healthyResetUptime: 3600, clock: clock,
            now: TestDateSource().provider)
        await supervisor.start()
        _ = try await waitFor(
            "the link to come up",
            observed: { let seen = await supervisor.state; return "state=\(seen)" }) { await supervisor.state == .up }

        await #expect(throws: PeerLinkSendFailure.notOutbound(.peerInventory)) {
            try await supervisor.send(.peerInventory(handles: ["h-1"]))
        }
        await stopDriven(supervisor, clock)
        #expect(!stub.stdinLines().contains(where: { $0.contains("peer-inventory") }))
    }

    // MARK: - Teardown

    /// `stop()` is deterministic: when it returns the child tree is dead, the
    /// supervision task has finished, and **no respawn can follow** — proven by
    /// advancing far more virtual time than any backoff would need and finding
    /// the connection count unchanged.
    @Test func stopIsDeterministicAndNothingRespawnsAfterIt() async throws {
        let stub = try Stub("stop", body: """
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            sleep 300 &
            child=$!
            trap 'kill "$child" 2>/dev/null; exit 143' TERM INT
            wait "$child"
            """)
        defer { stub.remove() }
        let clock = TestClock<Duration>()
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: LinkRecorder(), healthyResetUptime: 3600, clock: clock,
            now: TestDateSource().provider)
        await supervisor.start()
        _ = try await waitFor(
            "the link to come up",
            observed: { let seen = await supervisor.state; return "state=\(seen)" }) { await supervisor.state == .up }
        let pid = try #require(stub.pids().first)

        await stopDriven(supervisor, clock)
        let spawnsAtStop = stub.spawnCount()

        // Far past `backoffCap`, on a clock nobody is supposed to be sleeping on
        // any more.
        await clock.advance(by: .seconds(600))
        await clock.advance(by: .seconds(600))
        #expect(
            stub.spawnCount() == spawnsAtStop,
            "stop() must leave nothing that can respawn; spawns went \(spawnsAtStop) -> \(stub.spawnCount())")

        // Bounded poll because an orphaned grandchild is reaped by launchd, not
        // by us, and `kill(pid, 0)` keeps succeeding on a zombie until then.
        _ = try await waitFor(
            "the stub's process group to die",
            observed: { "group \(pid) alive=\(kill(-pid, 0) == 0)" }) { kill(-pid, 0) != 0 }
    }
}

// MARK: - Support

/// Records what the supervisor publishes, in order.
private actor LinkRecorder: PeerLinkHandler {
    private(set) var frames: [PeerBridgeFrame] = []
    private(set) var transitions: [PeerLinkState] = []

    func handle(_ frame: PeerBridgeFrame) async {
        frames.append(frame)
    }

    func linkStateChanged(to state: PeerLinkState) async {
        transitions.append(state)
    }
}

/// A `messages`-speaking stub provider in a temp directory of its own.
///
/// Two append-only logs make the child's behaviour observable from the test
/// without any screen scraping: the preamble appends the child's pid to `pids`
/// on every invocation (so its line count is the connection count and its first
/// entry is the first child's process group), and `$STDIN_LOG` — exported for
/// the body — collects whatever the body chooses to record off stdin.
private struct Stub {
    let dir: URL
    let script: URL
    let pidLog: URL
    let stdinLog: URL

    var config: RemoteProviderConfig { RemoteProviderConfig(name: "peer-stub", exec: script.path) }

    init(_ label: String, body: String) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-link-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        script = dir.appendingPathComponent("messages-stub.sh")
        pidLog = dir.appendingPathComponent("pids")
        stdinLog = dir.appendingPathComponent("stdin")
        try """
        #!/bin/bash
        if [ "$1" != "messages" ]; then echo '{"sessions": []}'; exit 0; fi
        STDIN_LOG="\(stdinLog.path)"
        echo $$ >> "\(pidLog.path)"
        \(body)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// One line per invocation, so this is the number of connections opened.
    func spawnCount() -> Int { lines(of: pidLog).count }

    func pids() -> [Int32] { lines(of: pidLog).compactMap { Int32($0) } }

    func stdinLines() -> [String] { lines(of: stdinLog) }

    func remove() { try? FileManager.default.removeItem(at: dir) }

    private func lines(of url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// A clock-driven wait that never saw its effect, on the **primary** failure
/// line (`Tests/CLAUDE.md` assertion-hygiene rule 4 — only
/// `Issue.record(_: some Error)` survives into a CI summary).
private struct PeerLinkAdvanceTimeout: Error, CustomStringConvertible {
    let what: String
    let advances: Int
    let virtualSeconds: Double
    let observed: String

    var description: String {
        """
        timed out waiting for \(what) — spent \(virtualSeconds)s of virtual time over \
        \(advances) advance(s); observed \(observed)
        """
    }
}

/// Advances virtual time in `step`s for as long as the code under test keeps
/// **re-arming** a sleep, until `condition` holds, and returns the virtual
/// seconds it spent getting there (`nil` on timeout).
///
/// The returned total is why this exists rather than `TestClock.advanceUntil`:
/// "how much virtual time did the supervisor insist on before reconnecting" is
/// the backoff assertion, and it has to be measured rather than tolerated.
///
/// Each step is gated on something actually being armed, so no advance is spent
/// on an empty clock and virtual time never runs ahead of a sleeper that has not
/// arrived yet — the desync that turns a missed advance into a permanent hang.
@discardableResult
private func advanceVirtualTime(
    _ clock: TestClock<Duration>,
    until what: String,
    step: Double = 0.25,
    timeout: Swift.Duration = .seconds(45),
    pollInterval: Swift.Duration = .milliseconds(25),
    observed: @Sendable () async -> String = { "nothing" },
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async -> Double? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var advances = 0
    var virtual = 0.0
    repeat {
        if await condition() { return virtual }
        if await isArmed(clock) {
            await clock.advance(by: .seconds(step))
            advances += 1
            virtual += step
        } else {
            try? await Task.sleep(for: pollInterval)
        }
    } while ContinuousClock.now < deadline
    if await condition() { return virtual }
    let seen = await observed()
    if await condition() { return virtual }
    Issue.record(
        PeerLinkAdvanceTimeout(
            what: what, advances: advances, virtualSeconds: virtual, observed: seen),
        sourceLocation: sourceLocation)
    return nil
}

/// Whether a task is suspended on this clock right now. Detection is inverted
/// from how it reads: `checkSuspension()` **throws** when a sleeper *is*
/// registered.
private func isArmed(_ clock: TestClock<Duration>) async -> Bool {
    do {
        try await clock.checkSuspension()
        return false
    } catch {
        return true
    }
}

/// `stop()` while driving the clock it may park on.
///
/// `stop()` escalates SIGTERM→SIGKILL with a grace period, and that grace is on
/// the injected clock — so calling it straight from a test whose clock nobody
/// advances would hang for the suite's whole time limit. Running it in a task
/// and advancing while it is armed is the whole trick; when it needs no sleep at
/// all (an already-exited child), the first condition check returns immediately.
private func stopDriven(_ supervisor: PeerLinkSupervisor, _ clock: TestClock<Duration>) async {
    let finished = Latch()
    let task = Task {
        await supervisor.stop()
        finished.signal()
    }
    _ = await advanceVirtualTime(
        clock, until: "stop() to return",
        observed: { "stop() still running" }) { finished.isSet }
    await task.value
}

/// One-way flag, readable from a `@Sendable` condition closure.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func signal() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
