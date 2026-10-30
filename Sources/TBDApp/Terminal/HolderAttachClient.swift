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
///
/// A conformer also owns the pacing of its own resends — `resendDelays` and
/// `clock` — so there is one place they come from: the panel builds its client
/// once, from its own values, and the resend paths below read them back off
/// the client.
protocol HolderAttaching: Sendable {
    /// - Parameter attachSeq: This attach's number in the app's count, from
    ///   `HolderHandbackLedger.beginHold`; sent on `attach.request` so the
    ///   daemon's claim sweep can tell an attach the app numbered after a
    ///   sweep from one it numbered before. 0 sends none, and a claim without
    ///   one is never swept.
    func attach(
        worktreeID: UUID, paneID: String, terminalID: UUID, attachSeq: UInt64
    ) async throws -> HolderAttachment
    func ready(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
    ) async throws
    func detach(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
        snapshotPreamble: Data
    ) async throws
    /// The waits between resends of a handback or release that never reached
    /// the daemon.
    var resendDelays: [Duration] { get }
    /// What those waits sleep on.
    var clock: any Clock<Duration> { get }
}

extension HolderAttaching {
    var resendDelays: [Duration] { HolderAttachRetry.handbackResendDelays }
    var clock: any Clock<Duration> { ContinuousClock() }

    /// Send `send` — one holder request naming `generation` — and send it
    /// again while it fails in transit, waiting out each of `resendDelays`
    /// first.
    ///
    /// A handback that never reached the daemon leaves its claim standing, and
    /// nothing else clears a claim while this app lives: every later attach to
    /// the session is refused as owned by a viewer. So a failure in transit is
    /// worth a resend, and the resends carry on across a reconnect — but only
    /// for a generation `HolderAttachRetry.allowsResend` accepts. Such a
    /// generation names no claim in any other daemon process, and a daemon
    /// answers it the way it answers any generation it never minted: a
    /// `pane.detach` with success and nothing done, an `attach.ready` with a
    /// refusal. Any other generation is sent once.
    ///
    /// Returns once an attempt is accepted. An answer that is a refusal —
    /// anything `HolderAttachRetry.isTransportFailure` rejects — is rethrown
    /// at once; the last failure in transit is rethrown once the schedule runs
    /// out or a wait is cancelled.
    ///
    /// - Parameter failure: The failure of an attempt the caller already made,
    ///   so the first send here waits its turn; nil sends at once.
    func resendingInTransit(
        _ request: String, terminalID: UUID, generation: UInt64,
        after failure: (any Error)? = nil,
        _ send: () async throws -> Void
    ) async throws {
        var lastFailure: any Error
        if let failure {
            lastFailure = failure
        } else {
            do {
                try await send()
                return
            } catch where HolderAttachRetry.isTransportFailure(error) {
                lastFailure = error
            }
        }
        guard HolderAttachRetry.allowsResend(of: generation) else { throw lastFailure }
        let clock = self.clock
        for (index, delay) in resendDelays.enumerated() {
            let resend = index + 1
            let cause = lastFailure.localizedDescription
            logger.info("""
                holder \(request, privacy: .public) for attach \(generation, privacy: .public) of \
                terminal \(terminalID, privacy: .public) never reached the daemon \
                (\(cause, privacy: .public)); resend \(resend, privacy: .public) in \
                \(String(describing: delay), privacy: .public)
                """)
            do {
                try await clock.sleep(for: delay)
            } catch {
                throw lastFailure
            }
            do {
                try await send()
                return
            } catch where HolderAttachRetry.isTransportFailure(error) {
                lastFailure = error
            }
        }
        throw lastFailure
    }

    /// Send each of `requests` — one holder handback sequence naming
    /// `generation` — once, in order, and resend in the background the ones
    /// that never reached the daemon.
    ///
    /// The one sequence behind a live panel's handback (`pane.detach` alone)
    /// and the release of an unconfirmed attach (`attach.ready`, then
    /// `pane.detach`). Returns after the first pass, so a caller holding the
    /// handback ledger can settle it then. The background pass starts at the
    /// first request lost in transit and resends it on `resendingInTransit`'s
    /// schedule; once it has an answer — accepted or refused, either way the
    /// daemon has it — every request after it is sent again too, because what
    /// it does depends on what came before (a detach after an ack that only
    /// now arrived hands back a claim the first detach could not). A resend
    /// that never gets through ends the pass. A generation
    /// `HolderAttachRetry.allowsResend` refuses gets the first pass only.
    ///
    /// - Parameter kind: Names the sequence in the log lines ("handback",
    ///   "undelivered", "abandoned").
    /// - Returns: The background pass, when there is one; nil otherwise.
    func sendResendingInBackground(
        _ requests: [HolderHandbackRequest], kind: String, terminalID: UUID, generation: UInt64
    ) async -> Task<Void, Never>? {
        var firstLost: (index: Int, failure: any Error)?
        for (index, request) in requests.enumerated() {
            do {
                try await request.send()
                logger.info("""
                    holder \(kind, privacy: .public) attach \(generation, privacy: .public) of \
                    terminal \(terminalID, privacy: .public): sent \(request.name, privacy: .public)
                    """)
            } catch {
                let lost = HolderAttachRetry.isTransportFailure(error)
                if lost, firstLost == nil { firstLost = (index, error) }
                logger.error("""
                    holder \(kind, privacy: .public) attach \(generation, privacy: .public) of \
                    terminal \(terminalID, privacy: .public): \(request.name, privacy: .public) \
                    \(lost ? "never reached the daemon" : "was refused", privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        guard let firstLost else { return nil }
        guard HolderAttachRetry.allowsResend(of: generation) else {
            logger.error("""
                holder \(kind, privacy: .public) attach \(generation, privacy: .public) of \
                terminal \(terminalID, privacy: .public) is not resent: a generation below the \
                unique floor may name a claim in another daemon, so any claim under it stands
                """)
            return nil
        }
        return Task {
            for index in firstLost.index..<requests.count {
                let request = requests[index]
                do {
                    try await self.resendingInTransit(
                        request.name, terminalID: terminalID, generation: generation,
                        after: index == firstLost.index ? firstLost.failure : nil,
                        request.send)
                } catch where HolderAttachRetry.isTransportFailure(error) {
                    logger.error("""
                        holder \(kind, privacy: .public) attach \(generation, privacy: .public) of \
                        terminal \(terminalID, privacy: .public): \(request.name, privacy: .public) \
                        never reached the daemon, so any claim under this generation still stands: \
                        \(error.localizedDescription, privacy: .public)
                        """)
                    return
                } catch {
                    // Refused: an answer, which is all the next request needs.
                }
            }
        }
    }

    /// Hand a session back: `pane.detach` once and, if it never reached the
    /// daemon, again in the background (`sendResendingInBackground`).
    ///
    /// Returns after the first attempt. By that point this app is off the
    /// descriptor, which is all a successor panel has to wait for: while a
    /// resend is still owed the daemon refuses the successor's attach, the
    /// successor's own retries cover that, and a resend of this generation
    /// cannot touch the successor's newer one.
    ///
    /// - Returns: The background resend, when there is one; nil otherwise.
    @discardableResult
    func detachResendingInBackground(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
        snapshotPreamble: Data
    ) async -> Task<Void, Never>? {
        await sendResendingInBackground(
            [HolderHandbackRequest(name: "pane.detach") {
                try await self.detach(
                    worktreeID: worktreeID, paneID: paneID, terminalID: terminalID,
                    generation: generation, snapshotPreamble: snapshotPreamble)
            }],
            kind: "handback", terminalID: terminalID, generation: generation)
    }

    /// Release an attach the daemon minted but this app never confirmed:
    /// `attach.ready`, then `pane.detach` with an empty preamble, through
    /// `sendResendingInBackground`. The one sequence behind every such
    /// release — an attach whose descriptor never arrived, and one a panel
    /// abandoned before or at its ack.
    ///
    /// The ack goes first because the daemon holds the attach as pending and a
    /// detach naming a pending attach does not clear it. Acking turns it into
    /// a claim — or, past the daemon's ready timeout, is refused with the
    /// timeout's claim already recorded, or, for a superseded attach, is
    /// refused with nothing standing — and the detach then hands back
    /// whichever claim resulted. Re-sending an ack is safe on every one of
    /// those branches, and a refusal is an answer: the detach follows it. An
    /// ack lost in transit is resent, and a fresh detach follows it, because
    /// until the ack lands the attach can still be pending, and the daemon's
    /// ready timeout would record a claim after the first detach went by. The
    /// preamble is empty because the caller either never painted live output
    /// or is no longer showing it, so the daemon resumes from the screen its
    /// own reader kept.
    ///
    /// **The caller must already be off the descriptor**: the daemon resumes
    /// its drain on receipt of the detach. The daemon answers a detach `ok`
    /// whether or not it found a claim to clear, so a detach error means the
    /// request never reached it, and a success proves only that it arrived.
    ///
    /// - Parameter kind: Names the release in the log lines — what kind of
    ///   attach this was ("undelivered", "abandoned").
    /// - Returns: The background resend, when there is one; nil otherwise.
    @discardableResult
    func releaseUnconfirmedAttach(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
        kind: String
    ) async -> Task<Void, Never>? {
        await sendResendingInBackground(
            [
                HolderHandbackRequest(name: "attach.ready") {
                    try await self.ready(
                        worktreeID: worktreeID, paneID: paneID, terminalID: terminalID,
                        generation: generation)
                },
                HolderHandbackRequest(name: "pane.detach") {
                    try await self.detach(
                        worktreeID: worktreeID, paneID: paneID, terminalID: terminalID,
                        generation: generation, snapshotPreamble: Data())
                },
            ],
            kind: kind, terminalID: terminalID, generation: generation)
    }
}

/// One request of a holder handback sequence, for
/// `HolderAttaching.sendResendingInBackground`.
struct HolderHandbackRequest: Sendable {
    let name: String
    let send: @Sendable () async throws -> Void
}

/// An attach whose descriptor never arrived, thrown with the background resend
/// of its release when a first attempt of that release never reached the
/// daemon. The panel records `releaseResend` with its handback ledger, so it —
/// out of retries — or a successor waits for the claim to clear before giving
/// up, and so the attempt's hold lasts until the release has ended.
struct HolderAttachUndelivered: Error, LocalizedError {
    let cause: any Error
    let releaseResend: Task<Void, Never>

    var errorDescription: String? { cause.localizedDescription }
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
    /// The waits between resends of a handback or release; see
    /// `HolderAttaching.resendDelays`.
    var resendDelays: [Duration] = HolderAttachRetry.handbackResendDelays
    /// What those resends wait on. The panel that builds this client passes
    /// its own clock, so one retry sequence runs on one clock.
    var clock: any Clock<Duration> = ContinuousClock()

    /// Request the pty for one holder-backed session.
    ///
    /// Ordering is `DaemonClient.openAttach`'s, for its reason: the sidecar
    /// waiter is registered SYNCHRONOUSLY before the RPC is issued, so a vend
    /// that comes back faster than this function resumes still has somewhere to
    /// land. `expectFD` is not `async` precisely so that ordering is available.
    ///
    /// `attachSeq` defaults to 0, which sends none: the panel always passes
    /// the seq its hold minted, and a caller with no hold has nothing a sweep
    /// should be allowed to take back.
    func attach(
        worktreeID: UUID, paneID: String, terminalID: UUID, attachSeq: UInt64 = 0
    ) async throws -> HolderAttachment {
        // Fresh nonce per attach: the daemon echoes it in the vend header, so a
        // superseded attach's stale fd can never be delivered to this one.
        let attachID = UUID()
        // The descriptor comes back over the sidecar, so a sidecar that
        // dropped on its own has to come back first: the daemon would refuse
        // this attach for want of somewhere to vend it. Paced inside, so a
        // panel's retries cannot turn this into a reconnect loop.
        await daemonClient.reconnectSidecarIfDown(.attach)
        let promise = daemonClient.fdSidecar.expectFD(
            worktreeID: worktreeID, paneID: paneID, attachID: attachID)
        let result: AttachRequestResult
        do {
            // `windowID` is the empty string for a holder row, like every other
            // tmux coordinate on it — `terminalID` is what names the session.
            result = try await daemonClient.attachRequest(
                worktreeID: worktreeID, paneID: paneID, windowID: "",
                attachID: attachID, terminalID: terminalID,
                attachSeq: attachSeq == 0 ? nil : attachSeq)
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
        let fd: Int32
        do {
            fd = try await promise.value(timeout: fdTimeout)
        } catch {
            // **The daemon holds this attach as pending under `generation`,
            // and this throw is the last place that number exists.** The
            // caller never receives it, so nothing it does on failure can
            // release the attach — and the daemon's ready timeout turns a
            // pending attach into a viewer claim on its own, which refuses
            // every later attach to the session while this app lives. So the
            // release happens here, before the throw.
            //
            // No descriptor is held to close first: the promise settled
            // without one, and settling deregistered the waiter, so a vend
            // that lands later is closed by the sidecar's no-waiter path.
            //
            // When that release is still being resent, the resend rides the
            // throw (`HolderAttachUndelivered`), so the panel can record it
            // with its ledger and wait for it before it gives up.
            if let resend = await releaseUndeliveredAttach(
                worktreeID: worktreeID, paneID: paneID, terminalID: terminalID,
                generation: generation, cause: error
            ) {
                throw HolderAttachUndelivered(cause: error, releaseResend: resend)
            }
            throw error
        }
        // Ends any run of attach-time sidecar reconnects: one that was
        // followed by a delivered attach was not fighting anybody.
        await daemonClient.noteHolderAttachDelivered()
        return HolderAttachment(
            ptyFD: fd,
            generation: generation,
            snapshotPreamble: result.snapshotPreamble ?? Data())
    }

    /// Release an attach `attach.request` minted but whose descriptor never
    /// reached this client, through `releaseUnconfirmedAttach` — nothing was
    /// ever painted, so the empty preamble it sends loses nothing.
    ///
    /// Run in an unstructured task and awaited, so a cancelled caller still
    /// sends both RPCs: cancellation is one of the ways the descriptor fails
    /// to arrive. The caller is already failing with the error that matters.
    /// Returns once each request has been sent once.
    ///
    /// - Returns: The background resend of a request that never reached the
    ///   daemon, when there is one.
    private func releaseUndeliveredAttach(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
        cause: any Error
    ) async -> Task<Void, Never>? {
        logger.info("""
            holder attach \(generation, privacy: .public) for terminal \
            \(terminalID, privacy: .public) never received its descriptor \
            (\(cause.localizedDescription, privacy: .public)); releasing it
            """)
        let client = self
        return await Task {
            await client.releaseUnconfirmedAttach(
                worktreeID: worktreeID, paneID: paneID, terminalID: terminalID,
                generation: generation, kind: "undelivered")
        }.value
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
    /// Runs on the reader thread after the loop has exited and immediately
    /// before the descriptor is closed. Unset in production.
    ///
    /// A seam because the close is the one event the handback's ordering is
    /// about, and in production it lands within one poll interval of the stop
    /// — so a detach that skipped `awaitClosed()` usually reaches its peer
    /// *after* the close anyway, under any scheduling delay at all, and a test
    /// that only probes the descriptor at detach time passes whether or not
    /// the wait is there. A test holds the close here to make "the detach
    /// waited for it" the only way the detach can arrive after it.
    private let beforeClose: (@Sendable (HolderStreamReader) -> Void)?
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

    init(
        label: String, fd: Int32,
        beforeClose: (@Sendable (HolderStreamReader) -> Void)? = nil,
        onChunk: @escaping @Sendable (Data) -> Void
    ) {
        self.label = label
        self.fd = fd
        self.beforeClose = beforeClose
        self.onChunk = onChunk
    }

    /// Whether anyone is parked in `awaitClosed()` right now. For tests: it is
    /// how one observes that a handback is waiting on this close rather than
    /// racing it.
    var hasCloseWaiters: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !closeWaiters.isEmpty
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
        beforeClose?(self)
        Darwin.close(fd)
        noteClosed()
        logger.info("holder reader exited \(self.label, privacy: .public)")
    }
}
