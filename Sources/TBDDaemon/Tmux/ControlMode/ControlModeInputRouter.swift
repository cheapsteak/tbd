import Foundation
import TBDShared
import os

/// Routes app → daemon input frames (from the framed sidecar, M2.1) to
/// `send-keys -H` commands on the correct tmux server's FIFO correlator
/// (addendum §2, the daemon input path).
///
/// **Ordering is correctness.** Keystrokes must reach tmux in the exact order
/// the app produced them. `enqueue` (called on the sidecar receive thread) is
/// non-blocking: it stamps a timestamp and hands the frame to an unbounded
/// `AsyncStream`. A SINGLE long-lived consumer task drains that stream
/// sequentially — one task per frame would let the scheduler reorder the
/// keystroke stream. Each item is fully delivered (its `sendList` awaited)
/// before the next is dequeued.
///
/// The registry maps `(worktreeID, paneID) → tmux server`; `paneID` alone is
/// only unique within one server. Unknown panes (never attached, or detached)
/// and servers whose connection is down are debug-logged and dropped — input
/// for a dead pane is a race, not an error.
final class ControlModeInputRouter: @unchecked Sendable {
    private struct InputKey: Hashable {
        let worktreeID: UUID
        let paneID: String
    }
    /// Whether a queued item is a keystroke batch or a bulk paste. Both ride the
    /// SAME ordered stream so a keystroke enqueued after a paste is delivered
    /// strictly after the paste's `paste-buffer` completes (the M2 ruling's
    /// ordering guarantee).
    private enum Kind {
        case input
        case paste
    }
    private struct Item {
        let kind: Kind
        let header: SidecarInputHeader
        let bytes: Data
        let receivedAt: ContinuousClock.Instant
    }

    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")
    /// Resolves a server name to its FIFO correlator. Production passes
    /// `{ await supervisor.command(server: $0) }`; tests inject a fake.
    private let commandProvider: @Sendable (String) async -> TmuxControlCommandClient?
    /// Sink for per-pane input-delivery health TRANSITIONS (#318 polish
    /// ruling). Called with `(worktreeID, paneID, healthy)` exactly once per
    /// edge — into failing, back to healthy — never per keystroke. The daemon
    /// wires this to a `StateDelta.controlModeInputHealthChanged` broadcast;
    /// tests inject a recorder; the default is a no-op.
    private let onHealthChange: @Sendable (UUID, String, Bool) -> Void
    private let latency: InputLatencyRecorder
    private let chunkSize: Int

    private let lock = NSLock()
    private var servers: [InputKey: String] = [:]
    /// Panes currently considered input-failing, for edge-triggering health
    /// notifications. Guarded by `lock`. Delivery outcomes are reported from
    /// two places — the consumer task (no command client) and the correlator
    /// actor (per-command completions, which are FIFO per client) — so the
    /// set, not the reporter, is the single source of truth for edges.
    private var failingPanes: Set<InputKey> = []

    private let continuation: AsyncStream<Item>.Continuation
    /// The single sequential consumer. Retained so it lives as long as the
    /// router. Optional only so it can be started AFTER every stored property
    /// is initialized (its closure captures `self`).
    private var consumer: Task<Void, Never>?

    init(commandProvider: @escaping @Sendable (String) async -> TmuxControlCommandClient?,
         latency: InputLatencyRecorder = InputLatencyRecorder(),
         chunkSize: Int = 330,
         onHealthChange: @escaping @Sendable (UUID, String, Bool) -> Void = { _, _, _ in }) {
        self.commandProvider = commandProvider
        self.latency = latency
        self.chunkSize = chunkSize
        self.onHealthChange = onHealthChange

        var escapedContinuation: AsyncStream<Item>.Continuation!
        let stream = AsyncStream<Item>(bufferingPolicy: .unbounded) { escapedContinuation = $0 }
        self.continuation = escapedContinuation

        // One consumer, draining in order. `[weak self]` breaks the retain
        // cycle (self holds the task, the task references self); on `shutdown`
        // the stream finishes, the loop exits, and self is released.
        self.consumer = Task { [weak self] in
            for await item in stream {
                await self?.deliver(item)
            }
        }
    }

    /// Register the server that owns `(worktreeID, paneID)` so its input frames
    /// can be routed. Called after a successful attach. Also drops any tracked
    /// failing flag for the pane — SILENTLY, like `unregister` — so a stale
    /// flag cannot survive into a new attach when the detach's `pane.detach`
    /// RPC (and thus its unregister) was lost: the fresh attach starts from a
    /// healthy baseline and its first real failure re-fires the edge.
    func register(worktreeID: UUID, paneID: String, server: String) {
        let key = InputKey(worktreeID: worktreeID, paneID: paneID)
        lock.lock()
        servers[key] = server
        failingPanes.remove(key)
        lock.unlock()
    }

    /// Forget a pane's routing (on detach). Idempotent. Also drops the pane's
    /// tracked input health SILENTLY (no recovery notification): the app
    /// clears its indicator on detach itself, and a later re-attach must
    /// start from a clean healthy baseline so a fresh failure re-fires.
    func unregister(worktreeID: UUID, paneID: String) {
        let key = InputKey(worktreeID: worktreeID, paneID: paneID)
        lock.lock()
        servers.removeValue(forKey: key)
        failingPanes.remove(key)
        lock.unlock()
    }

    /// Non-blocking entry point for the sidecar receive thread. Stamps receipt
    /// time and yields into the ordered stream; the consumer does the work.
    func enqueue(header: SidecarInputHeader, bytes: Data) {
        continuation.yield(Item(kind: .input, header: header, bytes: bytes, receivedAt: ContinuousClock.now))
    }

    /// Non-blocking entry point for a bulk `.paste` frame (the M2 paste ruling).
    /// Yields into the SAME ordered stream as `enqueue`, from the SAME sidecar
    /// receive thread — so stream order == wire order == user order. A keystroke
    /// `enqueue`d after this paste is therefore delivered strictly AFTER the
    /// paste's `paste-buffer` completes.
    func enqueuePaste(header: SidecarInputHeader, bytes: Data) {
        continuation.yield(Item(kind: .paste, header: header, bytes: bytes, receivedAt: ContinuousClock.now))
    }

    /// Finish the stream so the consumer task exits. Wire into daemon shutdown
    /// when a call site exists; otherwise harmless (the consumer just idles).
    func shutdown() {
        continuation.finish()
    }

    // MARK: - Consumer

    private func resolveServer(_ header: SidecarInputHeader) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return servers[InputKey(worktreeID: header.worktreeID, paneID: header.paneID)]
    }

    private func deliver(_ item: Item) async {
        guard let server = resolveServer(item.header) else {
            // Deliberately NOT a failing-health signal: input for an
            // unregistered pane is the normal teardown race — the app's
            // keystroke crossing the pane's detach in flight, or arriving
            // before an attach completed. It says nothing about the health
            // of a pane the user is looking at, so flagging it would show
            // the indicator on freshly-(re)attached panes for no reason.
            logger.debug("""
                input for unregistered pane \(item.header.paneID, privacy: .public); \
                dropping \(item.bytes.count, privacy: .public) bytes
                """)
            return
        }
        guard let client = await commandProvider(server) else {
            // A REGISTERED pane whose server has no live command client:
            // the -CC connection is down, the user's typing is going
            // nowhere — that IS failing health.
            logger.debug("no command client for server \(server, privacy: .public); dropping input")
            reportDelivery(header: item.header, success: false)
            return
        }
        switch item.kind {
        case .input:
            await deliverInput(item, client: client)
        case .paste:
            await deliverPaste(item, client: client)
        }
    }

    /// Deliver a bulk paste through `PasteExecutor` (load-buffer + paste-buffer
    /// -p). Awaited to completion before the consumer dequeues the next item, so
    /// a following keystroke is FIFO-behind the paste (the ruling's ordering
    /// guarantee). A paste failure is logged at error — the user sees it as a
    /// missing paste — but tears NOTHING down; no latency sample (keystroke
    /// telemetry only).
    private func deliverPaste(_ item: Item, client: TmuxControlCommandClient) async {
        do {
            try await PasteExecutor.paste(client: client, paneID: item.header.paneID, bytes: item.bytes)
            reportDelivery(header: item.header, success: true)
        } catch {
            logger.error("""
                paste failed for pane \(item.header.paneID, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            reportDelivery(header: item.header, success: false)
        }
    }

    private func deliverInput(_ item: Item, client: TmuxControlCommandClient) async {
        let commandTexts = SendKeysEncoder.commands(
            paneID: item.header.paneID, bytes: item.bytes, maxBytesPerCommand: chunkSize)
        guard !commandTexts.isEmpty else { return }

        // Every keystroke command tolerates errors: a pane dying mid-keystroke
        // is a constant race and must NOT tear down the repo's whole -CC
        // connection. Failures are logged at debug and reported to the health
        // tracker; nothing else. `[weak self]` because the client's pending
        // queue holds these closures until their reply blocks arrive.
        let header = item.header
        let commands = commandTexts.map { text in
            TmuxCommand(text: text, tolerateErrors: true) { [weak self, logger] result in
                switch result {
                case .success:
                    self?.reportDelivery(header: header, success: true)
                case .failure(let error):
                    logger.debug("send-keys failed (pane death race): \(String(describing: error), privacy: .public)")
                    self?.reportDelivery(header: header, success: false)
                }
            }
        }
        // ONE stream write for the whole input event: atomic in the FIFO.
        await client.sendList(commands)
        // sendList returns after the stream write — the addendum's "frame
        // receipt → after stream write" latency window.
        latency.record(item.receivedAt.duration(to: ContinuousClock.now))
    }

    // MARK: - Input-delivery health (#318 polish)

    /// Record one delivery outcome for a pane and fire `onHealthChange` ONLY
    /// on an edge (healthy → failing, failing → healthy).
    ///
    /// What counts as an outcome — and why COMPLETIONS, not write acceptance,
    /// are the recovery signal: `sendList` always accepts a write locally
    /// (the stream is unbounded), so "write accepted" would mark a wedged
    /// server healthy forever. The per-command completion is tmux's actual
    /// `%end`/`%error` verdict, delivered FIFO per correlator, so success
    /// there proves keys REACHED tmux. Consequences, both deliberate:
    ///   - Recovery is observed lazily, on the next delivery the user
    ///     attempts (passive indicator — nothing probes the pane).
    ///   - A chunked batch that partially fails may produce transitions in
    ///     both directions (one per edge). Steady-state failure or success
    ///     stays silent, which is the ruling's no-spam requirement.
    /// `.connectionClosed` completions flow through the same failure path.
    private func reportDelivery(header: SidecarInputHeader, success: Bool) {
        let key = InputKey(worktreeID: header.worktreeID, paneID: header.paneID)
        lock.lock()
        var transitionedToHealthy: Bool?
        if success {
            if failingPanes.remove(key) != nil { transitionedToHealthy = true }
        } else if failingPanes.insert(key).inserted {
            transitionedToHealthy = false
        }
        lock.unlock()
        guard let healthy = transitionedToHealthy else { return }
        logger.info("""
            input-delivery health for pane \(key.paneID, privacy: .public): \
            \(healthy ? "recovered" : "FAILING", privacy: .public)
            """)
        onHealthChange(key.worktreeID, key.paneID, healthy)
    }
}
