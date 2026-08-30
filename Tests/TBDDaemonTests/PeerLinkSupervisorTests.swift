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

    // MARK: - Keepalive cadence

    /// **A frame that lands mid-interval must MOVE the next ping, not skip
    /// it.** The obligation is one outbound line at least every
    /// `keepaliveInterval` while otherwise idle, against a far-side silence
    /// limit of three times that.
    ///
    /// A keepalive that woke on a fixed cadence and merely returned early
    /// whenever the link had been quiet for less than a full interval spent
    /// that whole margin. This is the shape that did it: a frame goes out just
    /// after one wake, the wake after it still sees less than a full interval
    /// of silence and skips, and the ping does not come until the wake after
    /// *that* — nearly two intervals between outbound lines, a 1:1.5 safety
    /// factor rather than 1:3.
    ///
    /// The numbers, at a 10 s interval and a frame 4 s into the first one: the
    /// wake at 10 s sees 6 s of silence, so a rescheduling keepalive waits the
    /// remaining 4 and pings at 14 — ten seconds after the frame, exactly the
    /// obligation — while a fixed cadence skips to 20 and pings there, sixteen.
    /// The assertion sits between the two.
    ///
    /// Driven on **both** seams. The keepalive sleeps on the clock and measures
    /// idleness on the date source, so moving only one would prove nothing
    /// about a keepalive that read the wall clock. `silenceLimit` is widened
    /// well past the interval so the watchdog cannot kill the child part-way
    /// through the window this measures — the cadence is what is under test
    /// here, and the watchdog has its own test above.
    @Test func aMidIntervalFrameMovesTheNextPingRatherThanSkippingIt() async throws {
        let stub = try Stub("keepalive-cadence", body: """
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            while IFS= read -r line; do printf '%s\\n' "$line" >> "$STDIN_LOG"; done
            """)
        defer { stub.remove() }
        let clock = TestClock<Duration>()
        let date = TestDateSource()
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: LinkRecorder(), silenceLimit: 120, keepaliveInterval: 10,
            healthyResetUptime: 3600, clock: clock, now: date.provider)
        await supervisor.start()

        _ = try await waitFor(
            "the link to come up on the provider's hello",
            observed: { let seen = await supervisor.state; return "state=\(seen)" }
        ) { await supervisor.state == .up }

        // The first ping, which is what anchors everything after it: a wake
        // that pings stamps the link's last outbound write at that instant, so
        // the interval this test places a frame inside starts exactly there —
        // no arithmetic about when the supervisor first armed its wait.
        let toFirstPing = await advanceLockstep(
            clock, date, until: "the first keepalive ping on an idle link",
            limit: 30,
            observed: { "sent=\(await supervisor.counters.framesSent) lines=\(stub.stdinLines())" }
        ) { await supervisor.counters.framesSent >= 2 }
        // Recorded rather than required: `advanceLockstep` has already reported
        // the miss, and throwing here would skip the `stop()` that takes the
        // stub child down with it.
        #expect(
            toFirstPing != nil,
            "an idle link never pinged, so there is no interval to place a frame inside")

        // Four seconds into the interval that ping opened, an ordinary outbound
        // frame — the mid-interval traffic the old cadence swallowed a whole
        // interval for.
        await advanceLockstep(clock, date, by: 4)
        try await supervisor.send(.peer(PeerBridgePeer(
            handle: "h-mid", name: "acme-laptop:mid-interval %1", status: "working",
            peerProtocol: PeerBridgeFrameCodec.peerProtocol)))
        let sentBeforeNextPing = await supervisor.counters.framesSent

        let gap = await advanceLockstep(
            clock, date, until: "the keepalive ping that follows the mid-interval frame",
            limit: 18,
            observed: { "sent=\(await supervisor.counters.framesSent) lines=\(stub.stdinLines())" }
        ) { await supervisor.counters.framesSent > sentBeforeNextPing }

        // The positive control, on real time rather than virtual: without it a
        // supervisor that counted a frame it never wrote — or wrote something
        // other than a ping — would satisfy every measurement above. Skipped
        // when the measurement itself came back empty, where waiting out a full
        // real-time deadline would only rediscover the failure `#require`
        // already reports below.
        if gap != nil {
            _ = try await waitFor(
                "both keepalive pings to reach the child's stdin",
                observed: { "lines=\(stub.stdinLines())" }
            ) { stub.stdinLines().filter { $0.contains("\"kind\":\"ping\"") }.count >= 2 }
        }
        let lines = stub.stdinLines()
        let pings = lines.filter { $0.contains("\"kind\":\"ping\"") }.count

        await stopDriven(supervisor, clock)

        let measured = try #require(
            gap, "no ping followed the mid-interval frame within 18 virtual seconds")
        #expect(
            measured < 13,
            """
            a mid-interval frame must move the next ping to one interval after \
            itself, not defer it to the wake after next: measured \(measured)s \
            against a 10 s keepalive interval and a 30 s far-side silence limit
            """)
        #expect(
            pings >= 2,
            "both keepalives must have reached the wire as pings; got \(lines)")
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

    /// **A frame bigger than the pipe buffer is the ordinary case, not a
    /// pathology.** POSIX lets a non-blocking write of more than `PIPE_BUF`
    /// transfer only part of the buffer, and Darwin's pipe holds at most 64 KB
    /// — so one `write(2)` of a quarter-megabyte frame is *guaranteed* to come
    /// back short. Reading that as a desync cost the provider half a JSON line,
    /// SIGTERMed its child, and unpublished every shadow peer behind that link,
    /// on every message this size and on every retry of it.
    ///
    /// Both halves of the assertion carry weight. The frame must arrive
    /// **whole** — decoded and compared against what was sent, so a clip at any
    /// chunk boundary fails rather than merely looking long enough — and the
    /// link must still be **up**, with no `.down` transition and no reconnect
    /// behind it.
    @Test func aFrameLargerThanThePipeBufferCrossesWholeAndKeepsTheLinkUp() async throws {
        // `cat` rather than a `read` loop: the body has to drain a 256 KB line
        // as it arrives, and bash's `read` takes a pipe one byte per syscall.
        let stub = try Stub("large-frame", body: """
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            cat >> "$STDIN_LOG"
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
            "the link to come up",
            observed: { let seen = await supervisor.state; return "state=\(seen)" }) { await supervisor.state == .up }

        // Four times the most a Darwin pipe ever buffers, and well under the
        // codec's 512 KB cap: a size no single write could ever hand over.
        let big = PeerBridgeFrame.message(PeerBridgeMessage(
            id: "m-big", to: "h-far", from: "h-near",
            content: String(repeating: "a", count: 256 * 1024)))
        let encoded = try PeerBridgeFrameCodec.encodeLine(big)
        #expect(
            encoded.utf8.count > 64 * 1024,
            "the frame must exceed any Darwin pipe buffer or this test proves nothing")

        // In its own task because the send suspends between chunks on the
        // injected clock, and the clock is driven from here.
        let outcome = SendOutcome()
        let sender = Task {
            do {
                try await supervisor.send(big)
                await outcome.record(nil)
            } catch {
                await outcome.record(error)
            }
        }
        _ = await advanceVirtualTime(
            clock, until: "the large frame to finish crossing the pipe",
            observed: {
                let finished = await outcome.finished
                return "finished=\(finished) bytes=\(stub.stdinByteCount()) of \(encoded.utf8.count)"
            }
        ) { await outcome.finished }
        await sender.value
        _ = try await waitFor(
            "the whole line to reach the child's log",
            observed: { "bytes=\(stub.stdinByteCount()) of \(encoded.utf8.count)" }
        ) { stub.stdinLines().contains { $0.utf8.count >= encoded.utf8.count - 1 } }

        // Captured before the stop, as `linkGoesUpOnHelloExchangeAndDownOnChildExit`
        // explains: `stopDriven` advances the clock and can open a connection.
        let failure = await outcome.failure
        let transitions = await recorder.transitions
        let dropped = await supervisor.counters.sendsDropped
        let spawns = stub.spawnCount()
        let landed = stub.stdinLines().first { $0.contains("m-big") }
        await stopDriven(supervisor, clock)

        #expect(
            failure == nil,
            "a frame the pipe can only take in chunks must still be delivered; got \(String(describing: failure))")
        let line = try #require(
            landed,
            "the large frame never reached the child; the log holds \(stub.stdinByteCount()) bytes")
        #expect(
            PeerBridgeFrameCodec.decode(
                line: line, negotiatedProtocol: PeerBridgeFrameCodec.peerProtocol) == .frame(big),
            "the frame must arrive whole and byte-identical, not clipped at a chunk boundary")
        #expect(dropped == 0)
        #expect(
            transitions == [.up],
            "a short write is not a desync when the rest follows; the link must stay up, got \(transitions)")
        #expect(spawns == 1, "nothing may have torn the connection down and reconnected")
    }

    /// A **genuine** would-block — the pipe full, with no room for even the
    /// first byte — is the failure this channel is designed around, and it is
    /// the opposite of a short write: the frame is dropped and counted, and the
    /// link survives, because nothing of it ever reached the wire.
    ///
    /// The stub never reads its stdin, so the pipe fills and stays full. Every
    /// fill frame is under Darwin's 512-byte `PIPE_BUF`, where POSIX makes a
    /// write all-or-nothing — which is what makes "zero bytes across"
    /// reproducible here instead of a race with the reader.
    ///
    /// `writeStallLimit` is injected at three retry intervals so the budget is
    /// crossed in a couple of advances rather than two hundred
    /// (`Tests/CLAUDE.md`, "Keep advance chains short"). The frozen date source
    /// is what keeps the advances harmless: neither the keepalive nor the
    /// silence watchdog compares against the clock those advances move.
    @Test func aFullPipeDropsTheFrameAndLeavesTheLinkUp() async throws {
        let stub = try Stub("full-pipe", body: """
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            sleep 300 &
            child=$!
            trap 'kill "$child" 2>/dev/null; exit 143' TERM INT
            wait "$child"
            """)
        defer { stub.remove() }
        let clock = TestClock<Duration>()
        let recorder = LinkRecorder()
        let supervisor = PeerLinkSupervisor(
            config: stub.config, contractVersion: 2, origin: "acme-laptop",
            handler: recorder, healthyResetUptime: 3600, writeStallLimit: 0.015,
            clock: clock, now: TestDateSource().provider)
        await supervisor.start()
        _ = try await waitFor(
            "the link to come up",
            observed: { let seen = await supervisor.state; return "state=\(seen)" }) { await supervisor.state == .up }
        let pid = try #require(stub.pids().first)

        @Sendable func fillFrame(_ index: Int) -> PeerBridgeFrame {
            .peer(PeerBridgePeer(
                handle: "h-\(index)", name: "acme-laptop:fill %\(index)",
                status: "working", peerProtocol: PeerBridgeFrameCodec.peerProtocol))
        }
        // The premise, checked rather than assumed: POSIX only promises an
        // all-or-nothing pipe write at or below PIPE_BUF, which is 512 bytes on
        // Darwin. A fatter fill frame could come back short instead of refused,
        // and this test would then be measuring the desync path.
        let fillProbe = try PeerBridgeFrameCodec.encodeLine(fillFrame(0))
        #expect(
            fillProbe.utf8.count < 512,
            "a fill frame over PIPE_BUF could come back short instead of refused")

        let outcome = SendOutcome()
        let filler = Task {
            // Far more than a 16 KB pipe holds at ~100 bytes a frame; the loop
            // is expected to end in a refusal long before it runs out.
            for index in 0..<4_000 {
                do {
                    try await supervisor.send(fillFrame(index))
                } catch {
                    await outcome.record(error)
                    return
                }
            }
            await outcome.record(nil)
        }
        _ = await advanceVirtualTime(
            clock, until: "a send to be refused by the full pipe",
            observed: {
                let sent = await supervisor.counters.framesSent
                let finished = await outcome.finished
                return "finished=\(finished) framesSent=\(sent)"
            }
        ) { await outcome.finished }
        await filler.value

        let failure = await outcome.failure
        let transitions = await recorder.transitions
        let state = await supervisor.state
        let dropped = await supervisor.counters.sendsDropped
        let spawns = stub.spawnCount()
        let alive = kill(-pid, 0) == 0
        await stopDriven(supervisor, clock)

        let refusal = try #require(
            failure as? PeerLinkSendFailure,
            "the fill loop must end in a send failure, not by exhausting its range; got \(String(describing: failure))")
        if case .wouldBlock(let bytes) = refusal {
            #expect(bytes > 0)
        } else {
            Issue.record(
                "a full pipe must refuse the frame whole rather than desync the stream; got \(refusal)")
        }
        #expect(dropped == 1, "exactly the refused frame is counted as loss")
        #expect(state == .up, "a would-block costs one frame, never the link")
        #expect(
            transitions == [.up],
            "nothing may publish the link down over a frame that never reached the wire; got \(transitions)")
        #expect(spawns == 1, "the child must not have been torn down and replaced")
        #expect(alive, "the child's process group must survive a refused frame")
    }

    /// **Two concurrent sends must never interleave their bytes.** `write`
    /// suspends between chunks of a frame the pipe cannot take whole, and an
    /// actor is re-entrant across every suspension — so without
    /// `writeInFlightGeneration` a `send` arriving in that window splices its
    /// own line into the middle of the stalled one and produces exactly the
    /// desynced NDJSON the refill loop exists to prevent. Nothing else in this
    /// suite opens that window.
    ///
    /// **The window is held open by the stub, not by timing.** The child reads
    /// nothing until this test creates a gate file, so whichever frame reaches
    /// the pipe first fills it and stays stalled there for as long as the test
    /// wants, and the other necessarily arrives mid-transfer. Both frames are
    /// twice the most a Darwin pipe ever buffers, so neither can slip across
    /// whole — which is what makes both orderings equivalent, and why nothing
    /// below has to know which of the two won the race.
    ///
    /// The clock is deliberately left alone until the gate opens: the stalled
    /// frame cannot spend a single one of its refill waits while the second
    /// send is being judged, so the refusal observed here is the guard's and
    /// not the stall budget's.
    ///
    /// Against an unguarded `write` this fails twice over — the second send
    /// parks in the refill loop instead of coming back at once, and once the
    /// gate opens the two frames land spliced together, so the decode
    /// assertion goes red as well.
    @Test func concurrentSendsNeverInterleaveIntoOneFrame() async throws {
        // Created by the test once both sends are in play. Until then the child
        // reads nothing, so the pipe fills and stays full.
        let gate = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-link-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gate) }
        let stub = try Stub("interleave", body: """
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            while [ ! -e "\(gate.path)" ]; do sleep 0.02; done
            cat >> "$STDIN_LOG"
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
            "the link to come up",
            observed: { let seen = await supervisor.state; return "state=\(seen)" }) { await supervisor.state == .up }

        // Same length on the wire, so the refusal's reported byte count is the
        // same whichever of the two is refused.
        func bigFrame(id: String) -> PeerBridgeFrame {
            .message(PeerBridgeMessage(
                id: id, to: "h-far", from: "h-near",
                content: String(repeating: "a", count: 128 * 1024)))
        }
        let alphaID = "m-one"
        let betaID = "m-two"
        let alpha = bigFrame(id: alphaID)
        let beta = bigFrame(id: betaID)
        let encoded = try PeerBridgeFrameCodec.encodeLine(alpha)
        #expect(
            encoded.utf8.count > 64 * 1024,
            "each frame must exceed any Darwin pipe buffer, or neither send ever stalls and this test proves nothing")
        let betaEncoded = try PeerBridgeFrameCodec.encodeLine(beta)
        #expect(
            betaEncoded.utf8.count == encoded.utf8.count,
            "the two frames must weigh the same on the wire, so the refusal's byte count is the same either way")

        func sendInBackground(_ frame: PeerBridgeFrame, into outcome: SendOutcome) -> Task<Void, Never> {
            Task {
                do {
                    try await supervisor.send(frame)
                    await outcome.record(nil)
                } catch {
                    await outcome.record(error)
                }
            }
        }
        let alphaOutcome = SendOutcome()
        let betaOutcome = SendOutcome()
        let alphaSender = sendInBackground(alpha, into: alphaOutcome)
        let betaSender = sendInBackground(beta, into: betaOutcome)

        // No clock advance anywhere in this stretch: the loser must come back on
        // the guard alone.
        _ = try await waitFor(
            "the send that arrived mid-transfer to be refused at once",
            observed: {
                let a = await alphaOutcome.finished
                let b = await betaOutcome.finished
                return "alphaFinished=\(a) betaFinished=\(b)"
            }
        ) {
            // Hoisted: `||` takes its right operand as a NON-async autoclosure,
            // so an `await` there does not compile.
            let alphaDone = await alphaOutcome.finished
            let betaDone = await betaOutcome.finished
            return alphaDone || betaDone
        }
        let alphaWasRefused = await alphaOutcome.finished
        let betaWasRefused = await betaOutcome.finished
        #expect(
            alphaWasRefused != betaWasRefused,
            "only the frame that lost the race to the pipe may come back while the other is still mid-transfer")
        let earlyFailure = alphaWasRefused ? await alphaOutcome.failure : await betaOutcome.failure
        let refusal = try #require(
            earlyFailure as? PeerLinkSendFailure,
            "a send arriving mid-transfer must be refused, never queued behind the frame in flight")
        if case .wouldBlock(let bytes) = refusal {
            #expect(bytes == encoded.utf8.count, "the whole frame is refused, not a remainder of it")
        } else {
            Issue.record(
                "a send arriving mid-transfer must be refused as a would-block; got \(refusal)")
        }

        // Open the gate: the child starts draining and the stalled frame can
        // finish. This is the first virtual time anything here spends.
        #expect(FileManager.default.createFile(atPath: gate.path, contents: nil))
        _ = await advanceVirtualTime(
            clock, until: "the stalled frame to finish crossing the pipe",
            observed: {
                let a = await alphaOutcome.finished
                let b = await betaOutcome.finished
                return "alphaFinished=\(a) betaFinished=\(b) bytes=\(stub.stdinByteCount())"
            }
        ) {
            // Hoisted for the same reason as above: `&&`'s right operand is a
            // non-async autoclosure.
            let alphaDone = await alphaOutcome.finished
            let betaDone = await betaOutcome.finished
            return alphaDone && betaDone
        }
        await alphaSender.value
        await betaSender.value
        _ = try await waitFor(
            "the surviving frame's whole line to reach the child's log",
            observed: { "bytes=\(stub.stdinByteCount()) of \(encoded.utf8.count)" }
        ) { stub.stdinLines().contains { $0.utf8.count >= encoded.utf8.count - 1 } }

        // Captured before the stop, as `linkGoesUpOnHelloExchangeAndDownOnChildExit`
        // explains: `stopDriven` advances the clock and can open a connection.
        let survivorFailure = alphaWasRefused ? await betaOutcome.failure : await alphaOutcome.failure
        let lines = stub.stdinLines()
        let sent = await supervisor.counters.framesSent
        let dropped = await supervisor.counters.sendsDropped
        let transitions = await recorder.transitions
        let spawns = stub.spawnCount()
        await stopDriven(supervisor, clock)

        #expect(
            survivorFailure == nil,
            "the frame that was mid-transfer must still be delivered whole; got \(String(describing: survivorFailure))")
        // The property this test exists for: every line the child received is a
        // frame, entire. A splice shows up here as a line that will not decode.
        let undecodable = lines.filter { line in
            guard case .frame = PeerBridgeFrameCodec.decode(
                line: line, negotiatedProtocol: PeerBridgeFrameCodec.peerProtocol) else { return true }
            return false
        }
        #expect(
            undecodable.isEmpty,
            """
            every line the child receives must decode as a whole frame; \(undecodable.count) of \
            \(lines.count) did not — first offender begins \(undecodable.first?.prefix(120) ?? "")
            """)
        #expect(
            lines.count == 2,
            "the hello and exactly one message, with nothing spliced between them; got \(lines.count) line(s)")
        let refusedID = alphaWasRefused ? alphaID : betaID
        #expect(
            !lines.contains(where: { $0.contains(refusedID) }),
            "a refused frame is dropped, never written in pieces; \(refusedID) reached the child")
        let survivor = alphaWasRefused ? beta : alpha
        let survivorLine = try #require(
            lines.first(where: { $0.contains(alphaWasRefused ? betaID : alphaID) }),
            "the surviving frame never reached the child; the log holds \(stub.stdinByteCount()) bytes")
        #expect(
            PeerBridgeFrameCodec.decode(
                line: survivorLine, negotiatedProtocol: PeerBridgeFrameCodec.peerProtocol) == .frame(survivor),
            "the surviving frame must arrive byte-identical, not clipped or padded by the refused one")
        #expect(sent == 2, "the opening hello and the surviving message, and nothing else; got \(sent)")
        #expect(dropped == 1, "exactly the refused frame is counted as loss")
        #expect(
            transitions == [.up],
            "refusing a concurrent send costs one frame, never the link; got \(transitions)")
        #expect(spawns == 1, "nothing may have torn the connection down and reconnected")
    }

    /// **A stalled write must never resume onto an fd its own connection has
    /// already closed.** `write` captures the file descriptor once and then
    /// suspends between chunks; `runOnce`'s teardown closes that handle and
    /// hands the fd *number* back to the process, where anything else in the
    /// daemon may be given it. The post-sleep recheck of `generation` and
    /// `stdinHandle` identity is what stops the remaining bytes going there.
    ///
    /// Three things make this deterministic rather than a race:
    ///
    /// - the stub consumes exactly 1000 bytes off its stdin and then stops
    ///   reading, so the log reaching 1000 bytes is positive proof the frame is
    ///   **mid-transfer** rather than not yet started. Without that proof the
    ///   test would pass for the wrong reason: a send that has not started yet
    ///   fails at `send`'s own `state == .up` gate and never reaches the
    ///   recheck at all;
    /// - the stub then closes its stdout while staying alive — the documented
    ///   "provider that closes stdout but keeps running" case. The line stream
    ///   ends, `runOnce` tears the connection down, and because that is driven
    ///   by the readability handler rather than by the clock, `.down` is
    ///   observable with nothing advanced. The child staying alive is what
    ///   keeps the stdin pipe's read end open, so the only thing wrong with the
    ///   captured fd is that this side closed it;
    /// - only then is the clock advanced, so the stalled frame's very first act
    ///   on resuming is the recheck.
    ///
    /// It must come back `linkDown`: the connection ended under the frame, so
    /// there is no stream left to resync and nothing to tear down. Against an
    /// unguarded `write` the resumed loop writes into the closed descriptor and
    /// the failure is a `writeFailed(EBADF)` instead.
    ///
    /// The recheck is one `guard` over two facts, and this reaches it by the
    /// handle-identity half — teardown nils `stdinHandle` while `generation`
    /// still matches. The generation half covers the same window one connection
    /// later and cannot be separated from it here: both sleep on the same
    /// clock, and the stalled frame's 5 ms retry always fires before a
    /// reconnect's backoff.
    @Test func aStalledWriteRefusesToResumeOntoAClosedConnection() async throws {
        let stub = try Stub("stall-across-teardown", body: """
            printf '%s\\n' '{"kind":"hello","origin":"acme-remote","protocol":1}'
            dd bs=1 count=1000 >> "$STDIN_LOG" 2>/dev/null
            exec 1>&-
            sleep 300 &
            child=$!
            trap 'kill "$child" 2>/dev/null; exit 143' TERM INT
            wait "$child"
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
            "the link to come up",
            observed: { let seen = await supervisor.state; return "state=\(seen)" }) { await supervisor.state == .up }

        let big = PeerBridgeFrame.message(PeerBridgeMessage(
            id: "m-stalled", to: "h-far", from: "h-near",
            content: String(repeating: "a", count: 128 * 1024)))
        let encoded = try PeerBridgeFrameCodec.encodeLine(big)
        #expect(
            encoded.utf8.count > 64 * 1024,
            "the frame must exceed any Darwin pipe buffer, or it never stalls and this test proves nothing")

        let outcome = SendOutcome()
        let sender = Task {
            do {
                try await supervisor.send(big)
                await outcome.record(nil)
            } catch {
                await outcome.record(error)
            }
        }
        // 1000 bytes off the pipe is more than the opening hello, so the frame
        // has begun; it is far less than the frame, and the child reads no more
        // after this, so the frame cannot have finished.
        _ = try await waitFor(
            "the frame to be mid-transfer, proven by the bytes the child consumed",
            observed: {
                let finished = await outcome.finished
                return "consumed=\(stub.stdinByteCount()) of \(encoded.utf8.count) finished=\(finished)"
            }
        ) { stub.stdinByteCount() >= 1000 }
        _ = try await waitFor(
            "the connection to end under the stalled frame",
            observed: { let seen = await supervisor.state; return "state=\(seen)" }
        ) { await supervisor.state == .down }
        let finishedBeforeAnyAdvance = await outcome.finished
        #expect(
            finishedBeforeAnyAdvance == false,
            "the frame must still be parked mid-transfer: nothing has advanced the clock it sleeps on")

        _ = await advanceVirtualTime(
            clock, until: "the stalled frame to notice its connection is gone",
            observed: { let finished = await outcome.finished; return "finished=\(finished)" }
        ) { await outcome.finished }
        await sender.value

        // Captured before the stop, which advances the clock and can reconnect.
        let failure = await outcome.failure
        let dropped = await supervisor.counters.sendsDropped
        await stopDriven(supervisor, clock)

        let refusal = failure as? PeerLinkSendFailure
        #expect(
            refusal == .linkDown,
            """
            a write that stalls across its own connection's teardown must give up rather than \
            resume onto the fd that teardown closed; got \(String(describing: failure))
            """)
        #expect(dropped == 1, "the lost frame is counted as loss exactly once")
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

/// How one `send` finished, for a test that has to keep driving the clock while
/// that send is still in flight — which is every send big enough to need more
/// than one `write(2)`.
private actor SendOutcome {
    private(set) var finished = false
    private(set) var failure: (any Error)?

    func record(_ error: (any Error)?) {
        failure = error
        finished = true
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

    /// Total bytes recorded off stdin. The observable for a frame that crosses
    /// the pipe in several chunks, where a line count says nothing until the
    /// last one lands.
    func stdinByteCount() -> Int { (try? Data(contentsOf: stdinLog))?.count ?? 0 }

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

/// `advanceVirtualTime`'s two-seam sibling, for the keepalive — the one
/// subsystem here that sleeps on the clock and then makes a decision by reading
/// the date. Advances both together in `step`s until `condition` holds, and
/// returns the virtual seconds it took (`nil` if `limit` virtual seconds or the
/// real-time `timeout` ran out first).
///
/// Three properties, each load-bearing.
///
/// **Both seams move**, so a keepalive that consulted the wall clock instead of
/// its injected date source could not pass — moving only the clock would leave
/// every interval reading as zero idleness.
///
/// **The date moves first** within a step, so an interval that has just fully
/// elapsed on the clock is never read as an idle gap one step short of it.
///
/// **Each step settles in real time before the next.** A woken sleeper re-arms
/// at whatever `clock.now` says when it calls `sleep` again, so advancing
/// before it gets there silently pushes its next deadline out and moves the
/// beat this test computes its expectations from. The settle is what keeps the
/// cadence deterministic rather than a race against the scheduler.
@discardableResult
private func advanceLockstep(
    _ clock: TestClock<Duration>,
    _ date: TestDateSource,
    until what: String,
    step: Double = 0.5,
    limit: Double,
    settle: Swift.Duration = .milliseconds(25),
    timeout: Swift.Duration = .seconds(45),
    observed: @Sendable () async -> String = { "nothing" },
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async -> Double? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var advances = 0
    var virtual = 0.0
    while virtual < limit, ContinuousClock.now < deadline {
        if await condition() { return virtual }
        guard await isArmed(clock) else {
            try? await Task.sleep(for: settle)
            continue
        }
        date.advance(by: step)
        await clock.advance(by: .seconds(step))
        advances += 1
        virtual += step
        try? await Task.sleep(for: settle)
    }
    if await condition() { return virtual }
    let seen = await observed()
    if await condition() { return virtual }
    Issue.record(
        PeerLinkAdvanceTimeout(
            what: what, advances: advances, virtualSeconds: virtual, observed: seen),
        sourceLocation: sourceLocation)
    return nil
}

/// Moves both seams forward by a fixed amount, settling between steps for the
/// reason above. Placement rather than a wait, so it asserts nothing: the
/// caller is putting an event at a chosen offset inside an interval, not
/// waiting for one.
private func advanceLockstep(
    _ clock: TestClock<Duration>,
    _ date: TestDateSource,
    by seconds: Double,
    step: Double = 0.5,
    settle: Swift.Duration = .milliseconds(25)
) async {
    var moved = 0.0
    while moved < seconds {
        let next = min(step, seconds - moved)
        date.advance(by: next)
        await clock.advance(by: .seconds(next))
        moved += next
        try? await Task.sleep(for: settle)
    }
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
