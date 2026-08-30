import Darwin
import Foundation
import os
import TBDShared

private let peerBridgeLogger = Logger(subsystem: "com.tbd.daemon", category: "peer-bridge")

// MARK: - The seam consumers code against

/// Whether the peer link to one provider is carrying traffic right now.
///
/// First-class output rather than an internal detail, because the whole design
/// keys on it: a shadow peer must not exist while the link is down (a listening
/// socket cannot decline a connect, so a shadow that outlives its link accepts
/// every message and discards it — `docs/specs/2026-08-29-remote-peer-messaging-design.md`,
/// "Failure semantics"). Consumers therefore need transitions promptly and
/// reliably, not by polling.
public enum PeerLinkState: Sendable, Equatable {
    case up
    case down
}

/// The outbound half of a peer link, narrowed to what a consumer needs.
///
/// Separate from `PeerLinkSupervisor` so `ShadowPeerManager` can be built and
/// tested against a stub, and so nothing downstream can reach the supervisor's
/// lifecycle controls.
public protocol PeerLinkSending: Sendable {
    /// Bounded, and never parked on a wedged child: a frame waits at most one
    /// write budget for room in the far side's stdin, and is then dropped and
    /// counted rather than queued. Throws if the link is down, if the frame
    /// never got a byte across, or if it got partway and stalled.
    func send(_ frame: PeerBridgeFrame) async throws
}

/// Inbound delivery and link-state transitions.
///
/// **Chosen shape: an awaited handler protocol, not an `AsyncStream`.** Three
/// reasons, all of them properties this link needs rather than taste:
///
/// - **Ordering with the state transitions.** A `peer` line and the `.down`
///   that invalidates it must arrive in the order the link observed them. Two
///   `AsyncStream`s cannot express that ordering at all, and one stream of a
///   merged enum makes every consumer switch over a union it did not ask for.
/// - **Delivery is not optional.** An `AsyncStream` whose consumer task has not
///   started yet, or has ended, buffers or silently discards. A link-down
///   transition that nobody observes leaves shadow peers published against a
///   dead link, which is the exact failure "close and unlink on link loss"
///   exists to prevent.
/// - **Backpressure for free.** The read loop awaits each call, so a slow
///   consumer slows the loop instead of growing an unbounded buffer.
///
/// Every method is `async` and is called from the supervisor's read loop in
/// stream order. Re-entrancy is fine and expected: the supervisor is suspended
/// at the `await`, so a handler that calls back into `send` proceeds normally.
public protocol PeerLinkHandler: Sendable {
    /// One frame the provider sent, after decoding, the protocol gate, and the
    /// handshake gate. `hello` is delivered too (it tells the handler a fresh
    /// connection opened and every handle from the previous one is void);
    /// `ping` is not, since it carries nothing but liveness.
    ///
    /// No `provider` parameter: one handler belongs to one link, so the name
    /// would be a constant the handler already holds.
    func handle(_ frame: PeerBridgeFrame) async
    /// A link-state transition. Emitted on change only, and `.up` is emitted
    /// **before** the `hello` that produced it is delivered.
    func linkStateChanged(to state: PeerLinkState) async
}

/// Why one outbound frame was not written. Every case is a frame that was
/// dropped rather than queued — there is no mailbox on this channel.
public enum PeerLinkSendFailure: LocalizedError, Equatable, Sendable {
    /// No live stream, or the `hello` handshake has not completed. Same failure
    /// a caller sees messaging a local session that has exited.
    case linkDown
    /// The child's stdin pipe stayed full for this frame's whole write budget
    /// without accepting a single byte. Refused rather than parked: a wedged
    /// provider would otherwise block whichever actor called `send`, which is
    /// the `waitUntilExit` starvation class this file avoids everywhere else.
    ///
    /// **Nothing reached the wire**, which is what makes this the survivable
    /// failure: the stream is still in sync, so the frame is dropped and the
    /// link stays up.
    case wouldBlock(bytes: Int)
    /// `write(2)` failed for a reason other than EAGAIN — EPIPE when the child
    /// is already gone, most often.
    case writeFailed(errno: Int32)
    /// A short write: part of a frame reached the wire and the rest could not
    /// follow inside the frame's write budget. NDJSON has no way to retract
    /// half a line, so the link is torn down and reconnected rather than
    /// continued — the next `hello` resyncs everything.
    ///
    /// An ordinary large frame does **not** come here: `write` refills the pipe
    /// as it drains. Reaching this means the far side did not take the rest of
    /// one frame inside that frame's whole write budget — it stopped reading
    /// and stayed stopped, or it read the whole time but slower than
    /// `writeStallLimit` allows for a frame this size. See that property for
    /// the floor and why it bounds the frame rather than each stall.
    case truncated(wrote: Int, of: Int)
    /// A kind this side may not send. `peer-inventory` is provider-to-TBD only.
    case notOutbound(PeerBridgeFrame.Kind)

    public var errorDescription: String? {
        switch self {
        case .linkDown:
            return "peer link is down; frame dropped rather than queued"
        case .wouldBlock(let bytes):
            return "peer link stdin would block on \(bytes) bytes; frame dropped rather than queued"
        case .writeFailed(let code):
            return "peer link stdin write failed with errno \(code); frame dropped"
        case .truncated(let wrote, let total):
            return "peer link stdin wrote \(wrote) of \(total) bytes; stream desynced, link torn down"
        case .notOutbound(let kind):
            return "peer bridge line kind '\(kind.rawValue)' travels provider-to-TBD only; refused"
        }
    }
}

/// What this link has done and lost since it was constructed.
///
/// Loss on this channel is unreported to the sender in every case (no reply
/// path), so counting it is the only way it becomes observable — these are what
/// `tbd peer list` reads. Cumulative across reconnects on purpose: a link that
/// drops a frame per reconnect is the shape worth seeing.
public struct PeerLinkCounters: Sendable, Equatable {
    /// Frames written whole to the child's stdin.
    public var framesSent = 0
    /// Frames decoded off the child's stdout and delivered to the handler.
    public var framesReceived = 0
    /// Outbound frames dropped — oversized, would-block, refused, or truncated.
    public var sendsDropped = 0
    /// Inbound lines refused: malformed, oversized, or a protocol mismatch.
    public var linesRejected = 0
    /// Inbound lines skipped as forward compatibility (blank, unknown kind).
    public var linesSkipped = 0
    /// Inbound frames dropped for arriving before the provider's `hello`.
    public var linesBeforeHandshake = 0
    /// Completed `hello` handshakes — one per time the link came up.
    public var handshakes = 0
    /// `messages` children spawned.
    public var spawns = 0

    public init() {}
}

// MARK: - Supervisor

/// Supervises one provider's long-running `messages` process: spawn, write the
/// opening `hello`, carry frames both ways, keep the stream alive, watchdog
/// silence, and restart with backoff.
///
/// This is `ProviderEventsSupervisor`'s duplex sibling and deliberately copies
/// its structure — generation-guarded teardown, exponential backoff with
/// jitter, healthy-uptime reset, a silence watchdog, SIGTERM→SIGKILL against
/// the whole process group, and a `readabilityHandler`-driven line reader. Read
/// that file for the full rationale behind each of those; the comments here
/// cover only what differs.
///
/// Four things differ, all load-bearing:
///
/// - **Duplex.** `events` is stdout-only. This also writes frames to the
///   child's stdin, on a non-blocking fd: a frame is handed over in as many
///   `write(2)`s as the pipe has room for, waiting on the injected clock
///   between them, and a frame that cannot finish inside a bounded budget
///   fails rather than parking the caller. A wedged child whose stdin pipe has
///   filled would otherwise starve whichever actor called `send`. See `write`
///   for why the refill loop is mandatory rather than an optimisation.
/// - **A tighter silence limit**, `PeerBridgeFrameCodec.silenceLimit` (30 s
///   against `events`' 90 s), with a matching `ping` cadence of
///   `PeerBridgeFrameCodec.keepaliveInterval`. Detection latency here bounds how
///   long a shadow peer can lie about being reachable.
/// - **Link state is an output**, published to the handler on change.
/// - **Resync is by `hello`, not by cursor.** Every connection opens with our
///   `hello` and completes when the provider answers with its own. Nothing is
///   carried across a reconnect: the far side unlinks everything when the stream
///   ends, and the roster is re-announced from scratch.
public actor PeerLinkSupervisor: PeerLinkSending {
    private let config: RemoteProviderConfig
    /// The contract major `RemoteProviderManager` negotiated for this provider,
    /// captured at construction — the supervisor's lifetime belongs to one
    /// `describe`, exactly as on the `events` stream.
    private let contractVersion: Int
    /// The origin label this side declares in `hello`. Names the machine these
    /// local sessions live on, and is the namespace the provider must scope its
    /// reverse names by.
    private let origin: String
    /// The peer protocol this link speaks, in both the `hello` it writes and the
    /// gate every inbound line is decoded against.
    private let peerProtocol: Int
    /// Held STRONGLY, for the reason `ProviderEventsSupervisor` holds its
    /// manager strongly: ownership runs the other way (the consumer owns its
    /// links and drops them after `stop()`), and a `weak` handler would produce
    /// a supervisor that keeps spawning provider children forever while every
    /// frame it decodes reaches nobody, silently.
    private let handler: any PeerLinkHandler

    private var supervision: Task<Void, Never>?
    private var currentProcess: Process?
    /// The parent's write end of the child's stdin. Non-`nil` exactly while a
    /// child is running, and the gate every outbound write goes through.
    private var stdinHandle: FileHandle?
    /// Incremented per `runOnce`, so a previous run's teardown can never nil out
    /// or kill the *current* run's process after a `stop()`/`start()` cycle.
    private var generation = 0
    /// The `generation` whose stdin has a frame part-way across it, if any.
    ///
    /// `write` can suspend between chunks of one frame, and an actor is
    /// re-entrant across every suspension — so without this, a `send` arriving
    /// while a large frame waits for the pipe to drain would interleave its own
    /// bytes into the middle of that frame and produce exactly the desynced
    /// NDJSON the refill loop exists to prevent. The arriving frame is refused
    /// as a would-block, never queued behind the one in flight: congestion has
    /// one answer on this channel and it is clean failure. The window is only
    /// ever open for a frame that actually stalled — a frame the pipe takes
    /// whole never suspends, so nothing can observe this set.
    ///
    /// A *generation* rather than a flag because the hazard is per-connection:
    /// a frame still in flight from a previous run wrote into a pipe that is
    /// now closed, so it can no longer interleave with anything, and a plain
    /// flag would have let its unfinished write refuse the next connection's
    /// opening `hello`.
    private var writeInFlightGeneration: Int?
    private var lastActivity = Date()
    private var lastOutboundAt = Date()
    /// When the current connection was opened — the start of the `hello`
    /// handshake, which the watchdog bounds separately from stream silence.
    private var connectionOpenedAt: Date

    /// Link state, published on change. `.down` until the provider answers our
    /// `hello`, and `.down` again the moment the stream ends.
    public private(set) var state: PeerLinkState = .down
    /// Cumulative traffic and loss. See `PeerLinkCounters`.
    public private(set) var counters = PeerLinkCounters()

    /// Injectable timing. The two defaults that matter come from the codec, so
    /// both halves of the link read one number and nothing here redefines them.
    let silenceLimit: TimeInterval
    let keepaliveInterval: TimeInterval
    let backoffCap: TimeInterval
    let healthyResetUptime: TimeInterval
    /// How long one outbound frame may spend waiting for room in the child's
    /// stdin before the link gives up on it. Bounded by construction — the
    /// whole point of the non-blocking fd is that no provider can park a caller
    /// indefinitely — and injected so a test crosses it in two or three
    /// advances instead of two hundred (`Tests/CLAUDE.md`, "Keep advance chains
    /// short").
    ///
    /// **Total seconds of backpressure per frame, not per stall.** The stall
    /// counter is never reset when bytes make progress, so the default's 200
    /// waits at the 5 ms retry step are shared across every time that one frame
    /// has to wait for room — not granted afresh each time.
    ///
    /// How far that goes is set by how the far side reads, and the two shapes
    /// differ by more than they look:
    ///
    /// - **A provider that drains the pipe between waits** returns the whole
    ///   buffer each time, so a frame at the codec's 512 KB cap crosses a 64 KB
    ///   pipe in about eight waits. The default is roughly twenty-five times
    ///   that, which is the headroom it is chosen for.
    /// - **A provider that reads steadily but slowly** is bounded by its own
    ///   rate: at 2 KB a wait, that same frame needs ~256 waits, runs out of
    ///   budget with `sent > 0`, and lands on `truncated` — which tears the
    ///   link down and unpublishes every shadow peer for the provider. So this
    ///   knob is not only a wedged-provider guard; it is also a **throughput
    ///   floor**, and a reader below it loses its link rather than merely
    ///   running slowly.
    ///
    /// The floor is per frame, so it scales with the frame: `bytes /
    /// writeStallLimit`, which at the default is ~512 KB/s for a frame at the
    /// cap and ~8 KB/s for an 8 KB one. Ordinary message traffic therefore
    /// never approaches it; only a near-cap frame to a slow reader does.
    ///
    /// A second's budget is generous against the shape it is really defending
    /// against — the alternative to waiting is a torn-down link and every
    /// shadow peer for this provider unpublished, which costs far more than a
    /// millisecond. Resetting the counter on progress is the obvious way to
    /// exempt a slow reader, and it is not what this does, because the frame in
    /// flight holds `writeInFlightGeneration` for its whole transfer: every
    /// other frame on the link is refused until it finishes, so an unbounded
    /// frame is unbounded head-of-line blocking on the channel rather than one
    /// slow message. The bound on the *whole* frame is what keeps that finite.
    /// If a slow reader needs more room, the lever is this number — or making
    /// it proportional to the frame — and not the reset.
    let writeStallLimit: TimeInterval
    private let clock: any Clock<Duration>
    /// The date seam. Separate from `clock` for the reason the root `CLAUDE.md`
    /// gives — `Duration` is behavior, `Date` is data — and it covers the two
    /// wall-clock comparisons the watchdog makes: stream silence and handshake
    /// age. Both are deliberately wall-clock rather than monotonic, because
    /// `Date` counts across system sleep, so the first watchdog tick after wake
    /// already finds a dead stream and replaces it. No wake handler is needed or
    /// available (the daemon has no AppKit run loop).
    private let now: @Sendable () -> Date

    /// Grace between SIGTERM and SIGKILL, and between observing the child's exit
    /// and finishing the line stream (so late bytes still get applied).
    private static let killGrace: Duration = .milliseconds(500)
    private static let drainGrace: Duration = .milliseconds(50)

    /// The cadence `write` re-attempts a stalled frame on, and so the
    /// granularity of `writeStallLimit`. Not injected: a test shortens the
    /// budget rather than the step, which keeps one knob rather than two that
    /// can disagree. At this step a frame at the codec's cap crosses a 64 KB
    /// pipe in roughly 40 ms, which is the throughput ceiling this channel
    /// trades for never spinning on a full pipe.
    private static let writeRetryInterval: TimeInterval = 0.005

    /// How many refill waits `writeStallLimit` buys. Zero is a meaningful
    /// value — it is the single-shot write, useful to a test that wants the
    /// stall outcome without driving a clock at all.
    private var writeRetryLimit: Int {
        let steps = (writeStallLimit / Self.writeRetryInterval).rounded(.up)
        guard steps.isFinite, steps > 0 else { return 0 }
        return Int(min(steps, 1_000_000))
    }

    public init(config: RemoteProviderConfig,
                contractVersion: Int,
                origin: String,
                handler: any PeerLinkHandler,
                peerProtocol: Int = PeerBridgeFrameCodec.peerProtocol,
                silenceLimit: TimeInterval = PeerBridgeFrameCodec.silenceLimit,
                keepaliveInterval: TimeInterval = PeerBridgeFrameCodec.keepaliveInterval,
                backoffCap: TimeInterval = 60,
                healthyResetUptime: TimeInterval = 300,
                writeStallLimit: TimeInterval = 1,
                clock: any Clock<Duration> = ContinuousClock(),
                now: @Sendable @escaping () -> Date = { Date() }) {
        self.config = config
        self.contractVersion = contractVersion
        self.origin = origin
        self.handler = handler
        self.peerProtocol = peerProtocol
        self.silenceLimit = silenceLimit
        self.keepaliveInterval = keepaliveInterval
        self.backoffCap = backoffCap
        self.healthyResetUptime = healthyResetUptime
        self.writeStallLimit = writeStallLimit
        self.clock = clock
        self.now = now
        self.connectionOpenedAt = now()
        self.lastActivity = now()
        self.lastOutboundAt = now()
    }

    // MARK: Lifecycle

    public func start() {
        guard supervision == nil else { return }
        supervision = Task { await superviseForever() }
    }

    /// Deterministic teardown: when this returns, the child (and its whole
    /// process group) is dead, the supervision task has finished, so no respawn
    /// can follow, and the link has been published as `.down`. Kill and join in
    /// that order — the supervision task is parked on the line stream, which
    /// only ends once the child is gone.
    public func stop() async {
        guard let task = supervision else { return }
        supervision = nil
        task.cancel()
        if let process = currentProcess {
            await killTree(process)
        }
        // No unconditional `currentProcess = nil` here, for the reason
        // `ProviderEventsSupervisor.stop()` documents at length: `runOnce`'s own
        // post-run teardown clears it under the generation guard, and wiping it
        // from here would strip a concurrently-started NEW generation of the
        // process its watchdog needs to kill.
        await task.value
    }

    private func superviseForever() async {
        var attempt = 0
        while !Task.isCancelled {
            let started = now()
            await runOnce()
            if Task.isCancelled { return }
            if now().timeIntervalSince(started) > healthyResetUptime { attempt = 0 }
            attempt += 1
            let base = min(backoffCap, pow(2.0, Double(attempt - 1)))
            let jitter = base * Double.random(in: -0.2...0.2)
            let delay = max(0.1, base + jitter)
            peerBridgeLogger.debug(
                "messages \(self.config.name, privacy: .public) ended; reconnect in \(delay, privacy: .public)s")
            try? await clock.sleep(for: .seconds(delay))
        }
    }

    /// One process lifetime: spawn `messages`, write `hello`, carry frames both
    /// ways, and return once the stream is over.
    ///
    /// Bounded by construction, the same way the `events` run is: the stream
    /// ends at EOF, at child exit, or when the silence watchdog kills the child,
    /// and every kill escalates SIGTERM→SIGKILL against the whole process group.
    /// Any failure just returns; the outer loop reconnects, and the new
    /// connection's `hello` is the entire resync mechanism.
    private func runOnce() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.exec)
        process.arguments = (config.args ?? []) + ["messages"]
        // Shared with the `events` stream on purpose: the two daemon stream
        // emitters agreeing about the child's environment is a property worth
        // asserting without a spawn, which is why that helper is pure and static.
        process.environment = ProviderEventsSupervisor.streamEnvironment(
            base: ProcessInfo.processInfo.environment, contractVersion: contractVersion)
        let outPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardInput = inPipe
        process.standardError = FileHandle.nullDevice

        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        let reader = PeerLinkLineReader(continuation: continuation)
        let readHandle = outPipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            if !reader.readAvailable(from: handle) {
                handle.readabilityHandler = nil
                reader.finish(handle: handle)
            }
        }
        @Sendable func endStream() {
            readHandle.readabilityHandler = nil
            reader.finish(handle: readHandle)
        }

        let exitGate = PeerLinkExitGate()
        process.terminationHandler = { _ in exitGate.markExited() }

        let writeHandle = inPipe.fileHandleForWriting
        do {
            connectionOpenedAt = now()
            try process.run()
        } catch {
            peerBridgeLogger.error(
                "messages spawn failed for \(self.config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            endStream()
            try? writeHandle.close()
            return
        }
        generation += 1
        let myGeneration = generation
        currentProcess = process
        counters.spawns += 1
        lastActivity = now()
        lastOutboundAt = now()

        // Every outbound write on this link is non-blocking, so the pipe is put
        // in that mode once, here, rather than per write.
        let fd = writeHandle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        stdinHandle = writeHandle

        // Resync is by `hello`. The first line on every connection — first and
        // every reconnect alike — declares this origin and the protocol it
        // speaks, and nothing this side sends is valid before it.
        try? await write(.hello(origin: origin, peerProtocol: peerProtocol), to: writeHandle)

        // Teardown is driven by process EXIT, not by pipe EOF: a provider that
        // leaves a grandchild holding the pipe's write end never delivers EOF,
        // so waiting for it would wedge this supervisor permanently. The short
        // grace lets bytes already in the kernel buffer land first. Same hazard
        // and same remedy as `ProviderEventsSupervisor`.
        let exitWatcher = Task { [clock] in
            await exitGate.wait()
            try? await clock.sleep(for: Self.drainGrace)
            endStream()
        }
        let watchdog = startWatchdog(generation: myGeneration)
        let keepalive = startKeepalive(generation: myGeneration)

        for await line in lines {
            lastActivity = now()
            await ingest(line: line)
        }

        watchdog.cancel()
        exitWatcher.cancel()
        keepalive.cancel()
        // Closed unconditionally, ahead of the generation guard: this handle
        // belongs to THIS run whatever the current generation is, so skipping it
        // would leak an fd for the daemon's lifetime. Closing the write end is
        // also what a still-running child sees as EOF, and the far side's
        // contract obligation is to unlink every peer it published for us when
        // the stream ends.
        try? writeHandle.close()
        // Published BEFORE the kill below, not after it, because the link is
        // down the moment the stream ends — which is what `state`'s own
        // contract says. `killTree` spends up to `killGrace` between SIGTERM
        // and SIGKILL, and holding the transition behind that grace leaves the
        // link reporting `.up` with a live `stdinHandle` for half a second
        // after the last frame it can ever carry: a `send` in that window is
        // accepted and written into a child nobody is reading from. That is
        // exactly the shadow-peer-lying-about-reachability window the tighter
        // silence limit on this stream exists to bound, so it is closed here
        // rather than widened by our own teardown. Same order, same reason, as
        // `tearDownDesyncedStream`.
        if generation == myGeneration {
            currentProcess = nil
            stdinHandle = nil
            await publish(.down)
        }
        // The stream is over, so this run is over: make sure the child tree is
        // actually gone before the outer loop can spawn a replacement (a
        // provider that closes stdout but keeps running would otherwise
        // accumulate one live process per reconnect).
        if process.isRunning {
            await killTree(process)
        }
        endStream()
    }

    // MARK: Outbound

    /// Bounded by `writeStallLimit` and never parked on a wedged child. Throws
    /// — and counts a drop — rather than queueing, in every failure. See
    /// `PeerLinkSendFailure`.
    public func send(_ frame: PeerBridgeFrame) async throws {
        guard !frame.isProviderToTBDOnly else {
            counters.sendsDropped += 1
            peerBridgeLogger.error(
                "messages \(self.config.name, privacy: .public) refused outbound \(frame.kind.rawValue, privacy: .public); provider-to-TBD only")
            throw PeerLinkSendFailure.notOutbound(frame.kind)
        }
        // The handshake gate is deliberately part of the public send path and
        // not of `write`: `hello` and `ping` legitimately travel while the link
        // is still down, and everything else must not.
        guard state == .up, let handle = stdinHandle else {
            counters.sendsDropped += 1
            throw PeerLinkSendFailure.linkDown
        }
        do {
            try await write(frame, to: handle)
        } catch PeerLinkSendFailure.truncated(let wrote, let total) {
            // Half a line reached the wire and NDJSON cannot retract it. Drop
            // the connection so the next one opens with a fresh `hello`.
            await tearDownDesyncedStream()
            throw PeerLinkSendFailure.truncated(wrote: wrote, of: total)
        }
    }

    /// Writes one encoded line to the child's stdin, refilling the pipe as it
    /// drains until the whole frame is across.
    ///
    /// **The loop is mandatory, not a tuning choice.** The fd is `O_NONBLOCK`
    /// so that no wedged provider can park a caller, and POSIX gives a
    /// non-blocking pipe write of more than `PIPE_BUF` bytes leave to transfer
    /// only *part* of the buffer and report how much. Darwin's `PIPE_BUF` is
    /// 512 bytes and a pipe holds 16–64 KB, while the codec caps a frame at
    /// `PeerBridgeFrameCodec.maxFrameBytes` — 512 KB. A single `write(2)` of a
    /// large frame therefore does not merely *risk* a short write, it
    /// guarantees one, and reading that as a desync tore the link down (and
    /// unpublished every shadow peer for the provider) on every message bigger
    /// than the pipe buffer.
    ///
    /// **Reconciling the cap with the pipe is not the alternative.** No cap
    /// above `PIPE_BUF` makes one write atomic, and even at the cap the pipe's
    /// free space is whatever the provider has not yet read, so "it fits" is
    /// never a static property of a frame. A cap this channel could hand over
    /// in one write would have to be 512 bytes, far below one message. So the
    /// cap stays where the *reader's* buffer sets it and the writer loops.
    ///
    /// What each bound means:
    ///
    /// - **A frame that never got a byte across is a would-block.** The pipe
    ///   was full for the whole budget; the frame is dropped and counted and
    ///   the link stays up, because nothing reached the wire to resync from.
    /// - **A frame that got partway and then ran out of budget is fatal**:
    ///   NDJSON cannot retract half a line. No ordinary large frame reaches
    ///   that path — only one whose far side did not take the remainder within
    ///   `writeStallLimit`, which the budget bounds per frame rather than per
    ///   stall (see that property).
    /// - **The wait is on the injected clock**, never on a blocking write or a
    ///   `poll` with a timeout: both park the executor thread, which is the
    ///   starvation this file avoids everywhere. (A zero-timeout `poll` would
    ///   add nothing over the `EAGAIN` the write already returns, and `POLLOUT`
    ///   on a pipe promises only `PIPE_BUF` bytes of room anyway — so it could
    ///   not tell us a frame will fit even if it were free.)
    ///
    /// Every throw counts a drop first, because loss on this channel is
    /// unreported to the sender and a count is the only trace it leaves.
    private func write(_ frame: PeerBridgeFrame, to handle: FileHandle) async throws {
        let line: String
        do {
            line = try PeerBridgeFrameCodec.encodeLine(frame)
        } catch {
            counters.sendsDropped += 1
            peerBridgeLogger.error(
                "messages \(self.config.name, privacy: .public) dropped an outbound frame: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let bytes = [UInt8](line.utf8)
        // Captured so a stall that outlives this connection cannot keep writing
        // into a handle `runOnce` has closed — whose fd NUMBER another part of
        // the daemon may by then have been handed for something else entirely.
        let myGeneration = generation
        guard writeInFlightGeneration != myGeneration else {
            counters.sendsDropped += 1
            peerBridgeLogger.error(
                "messages \(self.config.name, privacy: .public) dropped a \(bytes.count, privacy: .public)-byte \(frame.kind.rawValue, privacy: .public) frame; another frame is mid-transfer")
            throw PeerLinkSendFailure.wouldBlock(bytes: bytes.count)
        }
        writeInFlightGeneration = myGeneration
        // Only if a newer connection has not since claimed it: that one is
        // still mid-transfer and owns the marker.
        defer { if writeInFlightGeneration == myGeneration { writeInFlightGeneration = nil } }
        let fd = handle.fileDescriptor
        let retryLimit = writeRetryLimit
        var sent = 0
        var stalls = 0
        var connectionEnded = false
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(fd, base + sent, buffer.count - sent)
            }
            let failure = errno
            if n > 0 {
                sent += n
                continue
            }
            if n < 0 && failure == EINTR { continue }
            if n < 0 && failure != EAGAIN && failure != EWOULDBLOCK {
                counters.sendsDropped += 1
                peerBridgeLogger.error(
                    "messages \(self.config.name, privacy: .public) stdin write failed errno=\(failure, privacy: .public) after \(sent, privacy: .public)/\(bytes.count, privacy: .public) bytes")
                throw PeerLinkSendFailure.writeFailed(errno: failure)
            }
            // EAGAIN — or a zero-length transfer, which a pipe should never
            // report but which is counted against the same budget so it can
            // never spin. Either way there is no room right now.
            guard stalls < retryLimit else { break }
            stalls += 1
            var cancelled = false
            do {
                try await clock.sleep(for: .seconds(Self.writeRetryInterval))
            } catch {
                // A cancelled caller stops waiting immediately, which is the
                // right degradation: whatever is already on the wire decides
                // below whether this was a clean drop or a desync.
                cancelled = true
            }
            if cancelled { break }
            guard generation == myGeneration, stdinHandle === handle else {
                connectionEnded = true
                break
            }
        }
        if connectionEnded {
            // The run this frame belonged to is over, so its half-written line
            // died with the pipe. No teardown to ask for — `runOnce` has
            // already published `.down` and the next `hello` resyncs.
            counters.sendsDropped += 1
            peerBridgeLogger.error(
                "messages \(self.config.name, privacy: .public) lost a \(frame.kind.rawValue, privacy: .public) frame; the connection ended mid-transfer")
            throw PeerLinkSendFailure.linkDown
        }
        if sent == bytes.count {
            counters.framesSent += 1
            lastOutboundAt = now()
            return
        }
        counters.sendsDropped += 1
        if sent == 0 {
            peerBridgeLogger.error(
                "messages \(self.config.name, privacy: .public) stdin full for \(self.writeStallLimit, privacy: .public)s; dropped a \(bytes.count, privacy: .public)-byte \(frame.kind.rawValue, privacy: .public) frame")
            throw PeerLinkSendFailure.wouldBlock(bytes: bytes.count)
        }
        peerBridgeLogger.error(
            "messages \(self.config.name, privacy: .public) wrote \(sent, privacy: .public)/\(bytes.count, privacy: .public) bytes; stream desynced")
        throw PeerLinkSendFailure.truncated(wrote: sent, of: bytes.count)
    }

    /// A short write left half a line on the wire. Publish the link down at once
    /// (so no shadow peer keeps claiming to be reachable) and signal the child's
    /// group without waiting out the kill grace — `runOnce`'s own post-stream
    /// teardown escalates to SIGKILL if this is ignored.
    private func tearDownDesyncedStream() async {
        await publish(.down)
        if let process = currentProcess, process.isRunning {
            signalTree(process.processIdentifier, SIGTERM)
        }
    }

    // MARK: Inbound

    private func ingest(line: String) async {
        switch PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: peerProtocol) {
        case .skipped(let skip):
            counters.linesSkipped += 1
            peerBridgeLogger.debug(
                "messages \(self.config.name, privacy: .public) skipped a line: \(skip.localizedDescription, privacy: .public)")
        case .rejected(let rejection):
            // Loss the far side is never told about — logged and counted, which
            // is the whole reporting story this channel has.
            counters.linesRejected += 1
            peerBridgeLogger.error(
                "messages \(self.config.name, privacy: .public) dropped an inbound line: \(rejection.localizedDescription, privacy: .public)")
        case .frame(let frame):
            await deliver(frame)
        }
    }

    private func deliver(_ frame: PeerBridgeFrame) async {
        switch frame {
        case .hello:
            // The protocol number was already gated by the codec, so an answer
            // that reaches here matched. This is the handshake completing, and
            // it is the ONLY thing that brings the link up.
            counters.framesReceived += 1
            counters.handshakes += 1
            await publish(.up)
            await handler.handle(frame)
        case .ping:
            // Liveness only; `lastActivity` was stamped by the caller — and
            // stamped whatever this gate then decides, so a provider stuck
            // before its `hello` still reads as a live stream to the watchdog
            // and is killed by its handshake-stall check rather than by
            // silence.
            //
            // Gated exactly like every other non-`hello` kind: a keepalive is
            // one of the "other lines" the contract forbids ahead of the
            // handshake, so it is not an exception to the rule.
            guard state == .up else {
                dropBeforeHandshake(frame)
                return
            }
            counters.framesReceived += 1
        default:
            guard state == .up else {
                dropBeforeHandshake(frame)
                return
            }
            counters.framesReceived += 1
            await handler.handle(frame)
        }
    }

    /// "Neither side may write any other line before it" — a line ahead of the
    /// provider's `hello` is a protocol violation, dropped and counted rather
    /// than acted on.
    private func dropBeforeHandshake(_ frame: PeerBridgeFrame) {
        counters.linesBeforeHandshake += 1
        peerBridgeLogger.error(
            "messages \(self.config.name, privacy: .public) dropped a \(frame.kind.rawValue, privacy: .public) line that arrived before the provider's hello")
    }

    /// Publishes a link-state transition, on change only.
    private func publish(_ next: PeerLinkState) async {
        guard state != next else { return }
        state = next
        let label = next == .up ? "up" : "down"
        peerBridgeLogger.info(
            "messages \(self.config.name, privacy: .public) link \(label, privacy: .public)")
        await handler.linkStateChanged(to: next)
    }

    // MARK: Keepalive and watchdog

    /// Emits `ping` whenever this side has been quiet for a full keepalive
    /// interval. The contract requires one at least every 10 s while otherwise
    /// idle, and the far side's own watchdog kills the stream without it.
    ///
    /// **The wait is rescheduled, never fixed**, and that is what makes the
    /// obligation hold. On a fixed cadence a frame that goes out just after one
    /// check leaves the link quiet for the rest of that interval, is still short
    /// of a full interval of silence at the next check, and defers the ping to
    /// the check after that — nearly two intervals between outbound lines,
    /// against a far-side `silenceLimit` of three. Asking `pingIfIdle` how long
    /// is left instead means an outbound frame *moves* the next ping rather than
    /// skipping it, and the documented 1:3 margin is what actually ships.
    private func startKeepalive(generation: Int) -> Task<Void, Never> {
        Task { [weak self, keepaliveInterval, clock] in
            var wait = keepaliveInterval
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                guard let self else { return }
                wait = await self.pingIfIdle(generation: generation)
            }
        }
    }

    /// Pings if the link has been quiet for a full interval, and returns how
    /// long to wait before asking again: a full interval after a ping, and the
    /// remainder of the current one when a frame went out inside it.
    ///
    /// The remainder is strictly positive by construction — this branch is only
    /// reached with less than an interval of idleness — so the loop above can
    /// never spin. It is clamped to one interval so that a date source that
    /// jumped backwards (`Date` is wall clock, and this one counts across system
    /// sleep) cannot stretch the wait past the obligation.
    private func pingIfIdle(generation: Int) async -> TimeInterval {
        guard generation == self.generation, let handle = stdinHandle else {
            return keepaliveInterval
        }
        let idle = now().timeIntervalSince(lastOutboundAt)
        guard idle >= keepaliveInterval else {
            return min(keepaliveInterval - idle, keepaliveInterval)
        }
        // A failed keepalive is already counted and logged by `write`; there is
        // nothing further to do with it, and the watchdog covers a link that
        // stops carrying traffic in either direction.
        try? await write(.ping, to: handle)
        return keepaliveInterval
    }

    /// Polls roughly three times per silence window, as on the `events` stream —
    /// but against `PeerBridgeFrameCodec.silenceLimit` (30 s), a third of that
    /// stream's magnitude. The cost of staleness on `events` is a badge that
    /// lags; here it is a session writing into a void, so detection latency is
    /// the entire bound on how long a shadow peer can lie about being reachable.
    private func startWatchdog(generation: Int) -> Task<Void, Never> {
        Task { [weak self, silenceLimit, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(silenceLimit / 3))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.killIfStalled(generation: generation)
            }
        }
    }

    /// Two stall shapes, both fatal to the connection.
    ///
    /// The first is the `events` watchdog's: `silenceLimit` with nothing at all
    /// on the stream. The second is specific to a duplex, handshaken link — a
    /// provider that keeps pinging but never answers `hello` (an old shim, a
    /// protocol number this build does not speak) is not silent, so the first
    /// check never fires, and without the second the link would sit down
    /// forever, never reconnecting and never escalating. Those pre-handshake
    /// pings are dropped as protocol violations by `deliver`, but `lastActivity`
    /// is stamped off the stream before that gate — so they keep the first check
    /// quiet exactly as any other traffic would, and the second is what has to
    /// catch them.
    private func killIfStalled(generation: Int) async {
        guard generation == self.generation, let process = currentProcess else { return }
        let silent = now().timeIntervalSince(lastActivity) > silenceLimit
        let handshakeStalled =
            state == .down && now().timeIntervalSince(connectionOpenedAt) > silenceLimit
        guard silent || handshakeStalled else { return }
        peerBridgeLogger.debug(
            "messages \(self.config.name, privacy: .public) stalled past \(self.silenceLimit, privacy: .public)s (silent=\(silent, privacy: .public)); killing")
        await killTree(process)
    }

    // MARK: Process teardown

    /// SIGTERM the child's whole process GROUP, then SIGKILL after a grace
    /// period if anything survived. Group rather than pid for the two reasons
    /// `ProviderEventsSupervisor.killTree` documents: a `bash` parked in a
    /// foreground command defers a pid-only SIGTERM, and grandchildren holding
    /// the pipe's write end have to die for the stream to end.
    private func killTree(_ process: Process) async {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        signalTree(pid, SIGTERM)
        // A cancelled caller (the supervision task during `stop()`) skips the
        // grace and escalates immediately, which is the right degradation.
        try? await clock.sleep(for: Self.killGrace)
        if process.isRunning {
            peerBridgeLogger.debug(
                "messages \(self.config.name, privacy: .public) ignored SIGTERM; escalating to SIGKILL")
            signalTree(pid, SIGKILL)
        }
    }

    /// Foundation's `Process` makes the child its own process-group leader on
    /// Darwin, but that is checked with `getpgid` before signaling a negative
    /// pid so an unrelated group can never be hit if that changes.
    private func signalTree(_ pid: pid_t, _ signal: Int32) {
        if getpgid(pid) == pid {
            kill(-pid, signal)
        } else {
            kill(pid, signal)
        }
    }
}

// MARK: - Pipe plumbing

/// Single-fire async gate resolved by `Process.terminationHandler`, used in
/// place of `Process.waitUntilExit()` — which blocks the calling thread for the
/// child's whole lifetime and would hold this actor's executor with it.
///
/// A near-copy of `ProcessExitGate` in `ProviderEventsSupervisor.swift`, which
/// is file-private there. Sharing one type is the right end state and is left as
/// a follow-up: hoisting it is an edit to that file, and this one is written to
/// be droppable when that happens.
private final class PeerLinkExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var exited = false

    func markExited() {
        lock.lock()
        let pending = continuation
        continuation = nil
        exited = true
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// Turns the child's stdout into an ordered stream of complete lines using
/// `readabilityHandler`.
///
/// The same shape, and for the same reasons, as `PipeLineReader` in
/// `ProviderEventsSupervisor.swift` (file-private there — see `PeerLinkExitGate`
/// above for why this is a copy and not a shared type). The load-bearing part:
/// teardown has to be safe at an arbitrary moment, and on Darwin `close()`ing an
/// fd out from under a thread already parked in `read(2)` does NOT wake that
/// thread — it leaks the reader and frees the fd *number* for reuse by another
/// consumer in this same process. A `readabilityHandler` only ever reads when
/// bytes (or EOF) are already waiting, so no thread is ever parked at close time.
///
/// Lines go into an `AsyncStream` rather than individual `Task`s so ordering is
/// preserved: on this stream a `peer-gone` must never overtake the `peer` that
/// preceded it.
private final class PeerLinkLineReader: @unchecked Sendable {
    /// Twice `PeerBridgeFrameCodec.maxFrameBytes`, and the reason that cap has
    /// the value it does: this buffer is DISCARDED WHOLE once past the limit and
    /// only the first overflow per reader is reported, so every later loss here
    /// is invisible. The codec refuses an oversized frame below this line, once,
    /// with a reason the caller can count.
    private static let maxPendingBytes = 1 << 20  // 1 MB

    private let lock = NSLock()
    private let continuation: AsyncStream<String>.Continuation
    private var pending = Data()
    private var finished = false
    private var loggedOverflow = false

    init(continuation: AsyncStream<String>.Continuation) {
        self.continuation = continuation
    }

    /// `readabilityHandler` body. Returns `false` at EOF or after `finish`, so
    /// the caller detaches itself.
    func readAvailable(from handle: FileHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return false }
        emitLinesLocked(from: chunk)
        return true
    }

    /// Drains whatever is already buffered WITHOUT blocking (so frames sitting
    /// in the kernel pipe buffer at exit are still delivered rather than
    /// dropped), emits any trailing unterminated line, closes the parent's read
    /// end, and finishes the stream. Idempotent. The caller must detach the
    /// readability handler first; acquiring the lock then blocks until any
    /// in-flight handler call has finished touching the handle.
    func finish(handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                emitLinesLocked(from: Data(chunk.prefix(count)))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                // 0 = EOF; -1/EAGAIN = every buffered byte is drained.
                break
            }
        }
        if !pending.isEmpty, let line = String(data: pending, encoding: .utf8) {
            continuation.yield(line)
        }
        pending.removeAll()
        try? handle.close()
        continuation.finish()
    }

    private func emitLinesLocked(from chunk: Data) {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending = pending[pending.index(after: newline)...]
            if let line = String(data: lineData, encoding: .utf8) {
                continuation.yield(line)
            }
        }
        // Compact so the slice's dropped prefix is actually released.
        pending = Data(pending)
        if pending.count > Self.maxPendingBytes {
            if !loggedOverflow {
                loggedOverflow = true
                peerBridgeLogger.error(
                    "messages pipe buffered \(self.pending.count, privacy: .public) bytes with no newline (cap \(Self.maxPendingBytes, privacy: .public)); discarding")
            }
            pending.removeAll()
        }
    }
}
