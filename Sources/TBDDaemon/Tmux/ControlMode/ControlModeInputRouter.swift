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
    private let latency: InputLatencyRecorder
    private let chunkSize: Int

    private let lock = NSLock()
    private var servers: [InputKey: String] = [:]

    private let continuation: AsyncStream<Item>.Continuation
    /// The single sequential consumer. Retained so it lives as long as the
    /// router. Optional only so it can be started AFTER every stored property
    /// is initialized (its closure captures `self`).
    private var consumer: Task<Void, Never>?

    init(commandProvider: @escaping @Sendable (String) async -> TmuxControlCommandClient?,
         latency: InputLatencyRecorder = InputLatencyRecorder(),
         chunkSize: Int = 330) {
        self.commandProvider = commandProvider
        self.latency = latency
        self.chunkSize = chunkSize

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
    /// can be routed. Called after a successful attach.
    func register(worktreeID: UUID, paneID: String, server: String) {
        lock.lock()
        servers[InputKey(worktreeID: worktreeID, paneID: paneID)] = server
        lock.unlock()
    }

    /// Forget a pane's routing (on detach). Idempotent.
    func unregister(worktreeID: UUID, paneID: String) {
        lock.lock()
        servers.removeValue(forKey: InputKey(worktreeID: worktreeID, paneID: paneID))
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
            logger.debug("""
                input for unregistered pane \(item.header.paneID, privacy: .public); \
                dropping \(item.bytes.count, privacy: .public) bytes
                """)
            return
        }
        guard let client = await commandProvider(server) else {
            logger.debug("no command client for server \(server, privacy: .public); dropping input")
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
        } catch {
            logger.error("""
                paste failed for pane \(item.header.paneID, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    private func deliverInput(_ item: Item, client: TmuxControlCommandClient) async {
        let commandTexts = SendKeysEncoder.commands(
            paneID: item.header.paneID, bytes: item.bytes, maxBytesPerCommand: chunkSize)
        guard !commandTexts.isEmpty else { return }

        // Every keystroke command tolerates errors: a pane dying mid-keystroke
        // is a constant race and must NOT tear down the repo's whole -CC
        // connection. Failures are logged at debug; nothing else.
        let commands = commandTexts.map { text in
            TmuxCommand(text: text, tolerateErrors: true) { [logger] result in
                if case .failure(let error) = result {
                    logger.debug("send-keys failed (pane death race): \(String(describing: error), privacy: .public)")
                }
            }
        }
        // ONE stream write for the whole input event: atomic in the FIFO.
        await client.sendList(commands)
        // sendList returns after the stream write — the addendum's "frame
        // receipt → after stream write" latency window.
        latency.record(item.receivedAt.duration(to: ContinuousClock.now))
    }
}
