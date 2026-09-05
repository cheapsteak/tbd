import Darwin
import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "holderAttach")

/// What a completed holder attach hands its caller: a `dup` of the session's
/// pty master, the generation that names this attach, and the screen that was
/// already on the session.
///
/// The descriptor's ownership passes to the caller at construction — nothing
/// here closes it. The caller either hands it to a `HolderStreamReader` (which
/// closes it when its loop exits) or closes it itself on a failure path.
struct HolderAttachment: Sendable {
    /// A `dup` of the session's pty master. **`O_NONBLOCK`**: the flag lives on
    /// the shared open file description the daemon opened, so it rides the
    /// `dup` — a blocking read loop against this spins at 100% CPU. Drain it
    /// with `HolderStreamReader`, which polls.
    let ptyFD: Int32
    /// Echoed back on `attach.ready`; the daemon refuses a holder ack without
    /// it, because confirming the wrong attach would release a reader a live
    /// attach depends on.
    let generation: UInt64
    /// The escape-sequence stream that reconstructs the session's screen. Must
    /// be fed through `Coordinator.feedSnapshot` — never a bare `feed` — and
    /// before any live output is wired to the view.
    let snapshotPreamble: Data
}

enum HolderAttachError: Error, LocalizedError {
    /// `attach.request` said "pending" but minted no generation. Impossible
    /// against a daemon that has the holder branch, and fatal to the handshake
    /// if it happens: `attach.ready` is refused without one, and an unacked
    /// attach is cancelled by the daemon's ready timeout.
    case missingGeneration

    var errorDescription: String? {
        switch self {
        case .missingGeneration:
            return "the daemon vended a holder attach with no generation"
        }
    }
}

/// The two RPC halves of a holder attach, behind a seam so a panel test can
/// drive the attach path without a daemon.
protocol HolderAttaching: Sendable {
    func attach(worktreeID: UUID, paneID: String, terminalID: UUID) async throws -> HolderAttachment
    func ready(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
    ) async throws
    func detach(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
        snapshotPreamble: Data
    ) async throws
}

/// Drives the daemon's holder attach handshake: `attach.request` for the pty
/// and the screen that was on it, then `attach.ready` once the caller is
/// draining.
///
/// The two calls are deliberately separate rather than one `attach` that does
/// both, because everything load-bearing happens *between* them: the preamble
/// is fed and the reader is wired while the daemon still holds the drain, and
/// the ack is what transfers ownership. A client that acked for its caller
/// would be acking on behalf of a reader that does not exist yet.
struct HolderAttachClient: HolderAttaching {
    let daemonClient: DaemonClient
    /// How long to wait for the vended descriptor. Matches the control-mode
    /// path's bound.
    var fdTimeout: Duration = .seconds(5)

    /// Request the pty for one holder-backed session.
    ///
    /// Ordering is `DaemonClient.openAttach`'s, for its reason: the sidecar
    /// waiter is registered SYNCHRONOUSLY before the RPC is issued, so a vend
    /// that comes back faster than this function resumes still has somewhere to
    /// land. `expectFD` is not `async` precisely so that ordering is available.
    func attach(
        worktreeID: UUID, paneID: String, terminalID: UUID
    ) async throws -> HolderAttachment {
        // Fresh nonce per attach: the daemon echoes it in the vend header, so a
        // superseded attach's stale fd can never be delivered to this one.
        let attachID = UUID()
        let promise = daemonClient.fdSidecar.expectFD(
            worktreeID: worktreeID, paneID: paneID, attachID: attachID)
        let result: AttachRequestResult
        do {
            // `windowID` is the empty string for a holder row, like every other
            // tmux coordinate on it — `terminalID` is what names the session.
            result = try await daemonClient.attachRequest(
                worktreeID: worktreeID, paneID: paneID, windowID: "",
                attachID: attachID, terminalID: terminalID)
        } catch {
            promise.cancel()
            throw error
        }
        guard result.status == "pending" else {
            promise.cancel()
            throw DaemonClientError.attachUnavailable(result.status)
        }
        guard let generation = result.generation else {
            promise.cancel()
            throw HolderAttachError.missingGeneration
        }
        let fd = try await promise.value(timeout: fdTimeout)
        return HolderAttachment(
            ptyFD: fd,
            generation: generation,
            snapshotPreamble: result.snapshotPreamble ?? Data())
    }

    /// Ack that a reader is on the descriptor. The daemon releases its own
    /// drain here and jiggles the tty size to force the program to repaint —
    /// the ioctl has one owner, and it is not the app.
    func ready(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
    ) async throws {
        try await daemonClient.attachReady(
            worktreeID: worktreeID, paneID: paneID,
            generation: generation, terminalID: terminalID)
    }

    /// Hand the session back: the viewer has stopped reading and closed its
    /// descriptor, and this carries the screen it was showing.
    ///
    /// **Send order is the whole of this call's contract**, and it lives at the
    /// caller because only the caller can honour it: the descriptor is closed
    /// first, and only then is this sent. The daemon resumes its drain on
    /// receipt, so a notify-first detach would put it on the pty while the
    /// viewer's last `read()` was still outstanding.
    func detach(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
        snapshotPreamble: Data
    ) async throws {
        try await daemonClient.paneDetach(
            worktreeID: worktreeID, paneID: paneID, generation: generation,
            terminalID: terminalID, snapshotPreamble: snapshotPreamble)
    }
}

/// Drains a vended pty descriptor on a dedicated thread, handing each chunk to
/// a callback.
///
/// Two things separate this from `ControlModeStreamReader`, and both come from
/// what is on the other end of the descriptor:
///
/// - **It polls.** The vended fd is a `dup` of the pty master the daemon
///   opened `O_NONBLOCK`, and that flag lives on the shared open file
///   description, so it rides the `dup`. A `read()` loop against it returns
///   `EAGAIN` immediately and forever — a busy spin at 100% CPU. `poll()` is
///   what makes the wait a wait.
/// - **`stop()` is sufficient on its own.** The control-mode reader exits on
///   the EOF its paired `pane.detach` guarantees; a pty master has no such
///   EOF while the session lives, so the poll timeout is what lets the loop
///   notice the flag and release the descriptor.
///
/// The reader thread OWNS the fd and closes it when the loop exits — never
/// close it from outside, which would race fd-number reuse.
final class HolderStreamReader: @unchecked Sendable {
    private let fd: Int32
    private let label: String
    private let onChunk: @Sendable (Data) -> Void
    private let stateLock = NSLock()
    private var stopped = false
    private var thread: Thread?
    /// Raised by the reader thread after it has closed the descriptor, which is
    /// the only moment this process is provably off the pty.
    private var closed = false
    /// Callers parked in `awaitClosed()`. Resumed once, from the reader thread,
    /// after the `close`.
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    /// How long one `poll` waits before the loop re-checks `stopped`. Short
    /// enough that a closing view releases the pty promptly, long enough that
    /// an idle session costs 5 wakeups a second.
    private static let pollIntervalMilliseconds: Int32 = 200

    init(label: String, fd: Int32, onChunk: @escaping @Sendable (Data) -> Void) {
        self.label = label
        self.fd = fd
        self.onChunk = onChunk
    }

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }

    /// Whether `start()` has been called. Read by `awaitClosed()`, which must
    /// not park forever on a reader whose thread will never run.
    private var started = false

    /// Resumes once this reader's thread has closed the descriptor.
    ///
    /// **The handback's ordering rests on this.** `stop()` only raises a flag;
    /// the thread notices it up to one poll interval later and does the `close`
    /// on its way out. A detach sent on `stop()`'s return would therefore reach
    /// the daemon with this process still on the fd — two readers on one pty,
    /// which is silent byte theft — so the notification waits for this.
    ///
    /// A reader that was never started resumes immediately: its thread will
    /// never close anything, and a caller parked on it would never send its
    /// detach at all. Idempotent, and safe from any number of callers.
    func awaitClosed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateLock.lock()
            if closed || !started {
                stateLock.unlock()
                continuation.resume()
                return
            }
            closeWaiters.append(continuation)
            stateLock.unlock()
        }
    }

    /// Announces the close to everyone parked on it. Called from the reader
    /// thread, once, after `Darwin.close`.
    private func noteClosed() {
        stateLock.lock()
        closed = true
        let waiters = closeWaiters
        closeWaiters.removeAll()
        stateLock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func start() {
        precondition(thread == nil, "start called twice")
        stateLock.lock()
        started = true
        stateLock.unlock()
        let thread = Thread { [self] in self.readLoop() }
        thread.name = "holder-reader-\(label)"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    /// Ask the reader to stop and release the descriptor. Takes effect within
    /// one poll interval; the reader thread does the `close`.
    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        loop: while !isStopped {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Self.pollIntervalMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            // POLLNVAL means the descriptor is gone; POLLHUP on a pty master
            // means the last slave closed. Both are terminal — but drain what
            // POLLIN says is still buffered first, so the program's final
            // output is not thrown away.
            let revents = Int32(descriptor.revents)
            if revents & POLLNVAL != 0 { break }
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(fd, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    // Fed FIRST, and the stop is checked after. These bytes
                    // have been taken off the pty: nobody else will ever see
                    // them, so dropping them because a stop landed mid-read
                    // would lose output outright — and on the detach path it
                    // would lose exactly the output the handback preamble is
                    // about to be serialized from. One further chunk after a
                    // stop is bounded and harmless; the sink outlives the
                    // close by construction (`detachHolderSession` clears it
                    // only after `awaitClosed()`).
                    onChunk(Data(buffer[0..<count]))
                    if isStopped { break loop }
                    continue
                }
                // 0 is EOF. EIO is what a pty master reports once its last
                // slave is gone, which is the same thing said differently.
                if count == 0 { break loop }
                if errno == EINTR { continue }
                if errno == EAGAIN { break }
                break loop
            }
            if revents & POLLHUP != 0 { break }
        }
        Darwin.close(fd)
        noteClosed()
        logger.info("holder reader exited \(self.label, privacy: .public)")
    }
}
