import Darwin
import Foundation
import SwiftTerm
import os

/// The daemon's drain loop and headless emulator for one holder-backed session.
///
/// **Draining is a liveness requirement, not a convenience.** The job is its
/// pty's session leader, and XNU's `proc_exit` calls `ttywait` on the
/// controlling terminal before revoking it: a job that exits with anything at
/// all still queued on the terminal stops half-exited in `P_WEXIT`, and the
/// holder's `waitpid` correctly reports nothing, because nothing has happened
/// yet. A few bytes of ordinary echo are enough. So whoever holds the master
/// **must read it unconditionally** — not lazily, not only while somebody wants
/// a screen, not only while a session is idle. A reader that stops reading is
/// not falling behind; it is holding jobs open.
///
/// Two consequences shape everything below. The drain loop never exits on a
/// transient error, and it is never gated on anyone wanting the output: the
/// emulator is where the bytes go, but emptying the queue is why the loop runs.
///
/// An `actor` for the ordinary reason — its callers are async and the state
/// machine (`idle → draining → stopped`) must not be raced — but note what is
/// *not* actor-isolated: `Terminal` is not `Sendable`, so the emulator and the
/// descriptor live in two lock-guarded boxes shared with the drain thread. The
/// actor holds the state machine; the boxes hold everything the thread touches.
actor HolderReader {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    /// Lines of detached history the emulator keeps behind the viewport.
    ///
    /// Named rather than inherited: SwiftTerm's default is 500 lines, which is
    /// an accident of its own defaults, not a decision about how much of an
    /// unattended agent's session a daemon should be able to show. Each line
    /// costs a `BufferLine` of `cols` cells, so this is memory per live
    /// session — generous enough to answer "what did it print before it went
    /// quiet", bounded enough that a thousand-session fleet is not a leak.
    static let scrollbackLines = 5_000

    /// How long `stop()` waits for the drain thread to acknowledge the wake and
    /// close the descriptor. Bounded because a `stop` that never returns is
    /// worse than one that gives up and says so.
    static let defaultStopTimeout: Duration = .seconds(5)
    /// The granularity of that wait. Small: the thread is woken by a self-pipe
    /// write, so it is already on its way out.
    static let stopPollInterval: Duration = .milliseconds(5)

    enum Error: LocalizedError, Equatable {
        /// The reader has been stopped; its descriptor is gone or going.
        case stopped
        /// The self-pipe `start()` needs could not be created, so there would be
        /// no way to wake a blocked `poll` — and a drain thread that cannot be
        /// woken cannot be stopped without closing an fd under it.
        case cannotCreateWakePipe(errno: Int32)
        case writeFailed(errno: Int32)
        /// The child never made room for the rest of the write inside the
        /// budget. Carries what is left so a caller can decide, rather than
        /// pretending a partial write succeeded.
        case writeTimedOut(unwritten: Int)

        var errorDescription: String? {
            switch self {
            case .stopped:
                return "the holder reader has been stopped"
            case .cannotCreateWakePipe(let code):
                return "could not create the drain loop's wake pipe: "
                    + "\(String(cString: strerror(code))) (errno \(code))"
            case .writeFailed(let code):
                return "could not write to the session's pty: "
                    + "\(String(cString: strerror(code))) (errno \(code))"
            case .writeTimedOut(let unwritten):
                return "the session's pty did not accept \(unwritten) more bytes within the budget"
            }
        }
    }

    private enum State {
        case idle
        case draining
        case stopped
    }

    let sessionID: UUID
    private let descriptor: PTYDescriptor
    private let emulator: HolderEmulator
    private let stopTimeout: Duration
    private let clock: any Clock<Duration>

    private var state: State = .idle
    /// The write end of the self-pipe that wakes a blocked `poll`. Held by the
    /// actor, written by `stop()`; the read end belongs to the drain thread.
    private var wakeWriteFD: Int32 = -1
    private var drain: DrainLoop?

    /// - Parameter ptyFD: a `dup` of the session's pty master, handed over by
    ///   the holder. The reader owns it from here: it closes it on the drain
    ///   thread when the loop ends, and nowhere else. The parameter is spelled
    ///   `ptyFD` rather than the POSIX word because SwiftLint's
    ///   `inclusive_language` rule refuses that word in a *declaration*; prose
    ///   throughout still says "pty master", which is what `forkpty` calls it.
    init(
        sessionID: UUID,
        ptyFD: Int32,
        columns: Int,
        rows: Int,
        scrollbackLines: Int = HolderReader.scrollbackLines,
        stopTimeout: Duration = HolderReader.defaultStopTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.sessionID = sessionID
        self.stopTimeout = stopTimeout
        self.clock = clock
        let descriptor = PTYDescriptor(fd: ptyFD)
        self.descriptor = descriptor
        // The emulator's replies go straight back down the same descriptor.
        // A device-status or cursor-position report that never reaches the
        // child is a hang in that child, not a cosmetic loss — the program
        // asked the terminal a question and is waiting for the answer.
        self.emulator = HolderEmulator(
            columns: columns,
            rows: rows,
            scrollback: scrollbackLines,
            reply: { [descriptor] bytes in descriptor.replyBestEffort(bytes) })
    }

    deinit {
        // Every stored property is read into a local first: a `deinit` may
        // touch isolated state only until something copies `self`, and a log
        // interpolation counts as a copy.
        let finalState = state
        let wake = wakeWriteFD
        let identifier = sessionID.uuidString
        let pty = descriptor

        // A reader dropped without `stop()` leaks its drain thread, because the
        // thread's only exit is the wake pipe and nothing is left to write it.
        // The descriptor is not closed here: the thread may be inside a read on
        // it, and closing an fd under a live reader is the use-after-close race
        // this whole design exists to avoid. Only the never-started case is
        // safe to clean up.
        if wake >= 0 { Darwin.close(wake) }
        switch finalState {
        case .idle:
            pty.close()
        case .draining:
            Self.logger.error(
                """
                holder reader for session \(identifier, privacy: .public) was deallocated while \
                still draining; its thread and pty descriptor are leaked
                """)
        case .stopped:
            break
        }
    }

    /// Whether the drain loop is running. Test-facing, and the honest answer:
    /// it reads the thread's own flag rather than the actor's intent.
    var isDraining: Bool {
        guard let drain else { return false }
        return !drain.isFinished
    }

    // MARK: - Lifecycle

    /// Starts draining. Idempotent; a stopped reader stays stopped.
    func start() throws {
        switch state {
        case .draining: return
        case .stopped: throw Error.stopped
        case .idle: break
        }

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            throw Error.cannotCreateWakePipe(errno: errno)
        }
        wakeWriteFD = pipeFDs[1]

        let loop = DrainLoop(
            sessionID: sessionID,
            descriptor: descriptor,
            emulator: emulator,
            wakeReadFD: pipeFDs[0])
        drain = loop
        state = .draining

        let thread = Thread { loop.run() }
        thread.name = "tbd-holder-drain"
        // Bigger than the 512 KB Foundation hands a bare Thread: the drain
        // buffer alone is 64 KB of stack-adjacent scratch and the parser
        // recurses on escape sequences.
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Stops draining and closes the descriptor — **on the drain thread**.
    ///
    /// The ordering is the whole point. Closing the fd here, from the actor,
    /// while the thread sits in `read` or `poll` on it, is a use-after-close the
    /// moment the kernel hands that number to something else: the thread would
    /// then be watching an unrelated descriptor. So `stop` writes a byte to the
    /// self-pipe the loop also polls, and the thread — which alone knows it has
    /// left the descriptor — closes it. This call then waits, bounded on the
    /// injected clock, for that to have happened.
    func stop() async {
        guard state == .draining else {
            // A reader that never started has no thread to hand the close to,
            // and nothing can be mid-read on the descriptor, so this is the one
            // place the actor may close it itself. Stopping such a reader must
            // still release the pty: it is a `dup` the holder handed over, and
            // leaking it keeps a reference to that terminal alive for the life
            // of the daemon.
            if state == .idle { descriptor.close() }
            state = .stopped
            return
        }
        state = .stopped

        if wakeWriteFD >= 0 {
            var byte: UInt8 = 1
            // One byte, and the result is deliberately ignored: a full pipe
            // means a wake is already queued, which is exactly the outcome
            // wanted. SIGPIPE cannot arrive — the read end is closed only by
            // the thread on its way out, after which the wait below ends.
            _ = Darwin.write(wakeWriteFD, &byte, 1)
            Darwin.close(wakeWriteFD)
            wakeWriteFD = -1
        }

        await awaitDrainExit()
    }

    /// Polls for the drain thread to finish, accumulating elapsed time from the
    /// interval rather than measuring against a deadline: `any Clock<Duration>`
    /// pins `Duration` but not `Instant`, so instant arithmetic does not
    /// typecheck through the existential — and "how much waiting has been
    /// spent" is what a fake clock can drive. Same idiom as `HolderSpawner`.
    private func awaitDrainExit() async {
        guard let drain else { return }
        var waited: Duration = .zero
        while !drain.isFinished, waited < stopTimeout {
            try? await clock.sleep(for: Self.stopPollInterval)
            waited += Self.stopPollInterval
        }
        if !drain.isFinished {
            Self.logger.error(
                """
                drain thread for session \(self.sessionID.uuidString, privacy: .public) did not \
                stop within the budget; its pty descriptor stays open
                """)
        }
    }

    // MARK: - The session's screen

    /// The viewport as text, one line per row, trailing blank rows dropped.
    func renderScreen() -> String {
        emulator.renderScreen()
    }

    /// The tail of the scrollback plus the viewport, at most `maxLines` lines.
    func renderScreenWithScrollback(maxLines: Int) -> String {
        emulator.renderScreenWithScrollback(maxLines: maxLines)
    }

    // MARK: - Input and size

    /// Writes input to the child. Bounded: a child that has stopped reading its
    /// terminal must fail the write rather than park the caller forever.
    func write(_ data: Data) throws {
        guard state != .stopped else { throw Error.stopped }
        try descriptor.write(data)
    }

    /// Resizes both halves of the illusion: the emulator's grid, so rendering
    /// matches, and the pty itself, so the child gets `SIGWINCH` and can lay
    /// itself out. Doing only the first leaves a child drawing at the old size
    /// into a differently-shaped grid.
    func resize(columns: Int, rows: Int) {
        let cols = max(1, columns)
        let lines = max(1, rows)
        emulator.resize(columns: cols, rows: lines)
        descriptor.setWindowSize(columns: cols, rows: lines)
    }
}

// MARK: - The drain loop

/// The body of the dedicated reader thread.
///
/// A `Thread` rather than a `DispatchSource` on a shared queue, deliberately: a
/// feed is a full escape-sequence parse of up to a bufferful, and a session
/// flooding its terminal would otherwise occupy a concurrent-queue worker for
/// as long as it kept flooding. One thread per holder-backed session costs a
/// stack; a stalled queue costs unrelated daemon work.
private final class DrainLoop: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    /// Sized to take a whole tty output queue in one read on any plausible
    /// setting, so a flooding job costs one syscall per burst rather than one
    /// per kilobyte.
    private static let readBufferSize = 64 * 1024
    /// The poll slice. Finite rather than infinite so a loop that somehow
    /// missed a wake still notices its descriptor is gone, and so a poll that
    /// fails for a reason nobody predicted degrades into polling rather than
    /// into spinning.
    private static let pollSliceMilliseconds: Int32 = 250

    private let sessionID: UUID
    private let descriptor: PTYDescriptor
    private let emulator: HolderEmulator
    private let wakeReadFD: Int32
    private let stateLock = NSLock()
    private var finished = false

    init(sessionID: UUID, descriptor: PTYDescriptor, emulator: HolderEmulator, wakeReadFD: Int32) {
        self.sessionID = sessionID
        self.descriptor = descriptor
        self.emulator = emulator
        self.wakeReadFD = wakeReadFD
    }

    var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finished
    }

    func run() {
        defer {
            // The descriptor is closed here and nowhere else: this thread is
            // the only one that can know it has left the fd alone.
            descriptor.close()
            Darwin.close(wakeReadFD)
            stateLock.lock()
            finished = true
            stateLock.unlock()
        }

        // Stable for the loop's life: nothing else closes this descriptor, so
        // the number cannot be reused under the poll set.
        let ptyFD = descriptor.rawDescriptor
        var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)
        var ptyCanYieldBytes = ptyFD >= 0
        var consecutivePollFailures = 0

        while true {
            var watched = [pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0)]
            if ptyCanYieldBytes {
                watched.append(pollfd(fd: ptyFD, events: Int16(POLLIN), revents: 0))
            }

            let ready = poll(&watched, nfds_t(watched.count), Self.pollSliceMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                // **Never a reason to stop draining.** A poll that fails leaves
                // the queue exactly as full as it was, and a job blocked in
                // `ttywait` behind it. So the loop reads anyway — the read is
                // non-blocking and answers the same question poll was asked —
                // and slows itself down only enough not to spin.
                consecutivePollFailures += 1
                if consecutivePollFailures == 1 {
                    Self.logger.error(
                        """
                        poll failed while draining session \
                        \(self.sessionID.uuidString, privacy: .public) \
                        (errno \(errno, privacy: .public)); continuing to drain
                        """)
                }
                if ptyCanYieldBytes {
                    ptyCanYieldBytes = drainEverythingReadable(into: &buffer)
                }
                usleep(20_000)
                continue
            }
            consecutivePollFailures = 0

            // Checked before the pty: a stop must win a tie, or a session
            // flooding its terminal could keep the loop fed forever.
            if watched[0].revents != 0 { return }
            guard ready > 0, ptyCanYieldBytes, watched.count > 1, watched[1].revents != 0 else {
                continue
            }
            ptyCanYieldBytes = drainEverythingReadable(into: &buffer)
        }
    }

    /// Reads until the descriptor would block, feeding everything to the
    /// emulator. Returns whether the descriptor can still yield bytes.
    ///
    /// The inner loop matters: one `poll` wake means *at least* one read is
    /// ready, and a loop that took one bufferful per wake would fall behind a
    /// job writing faster than the scheduler round-trips.
    private func drainEverythingReadable(into buffer: inout [UInt8]) -> Bool {
        while true {
            switch descriptor.read(into: &buffer) {
            case .bytes(let count):
                // Never logged, at any level: these are session contents.
                emulator.feed(buffer[0..<count])
            case .wouldBlock, .interrupted:
                return true
            case .childGone:
                // `0` or `EIO` on a pty master means the last slave closed —
                // the ordinary end of a session, not an error. The loop stays
                // alive on the wake pipe so `stop()` still owns the close.
                Self.logger.debug(
                    """
                    pty for session \(self.sessionID.uuidString, privacy: .public) reached end of \
                    file; the job's terminal has no slave left
                    """)
                return false
            case .failed(let code):
                // Unrecoverable rather than transient: EAGAIN and EINTR are
                // handled above, so what is left is a descriptor that will
                // never yield anything again. Continuing to read it would spin.
                Self.logger.error(
                    """
                    read failed on the pty for session \
                    \(self.sessionID.uuidString, privacy: .public) \
                    (errno \(code, privacy: .public)); stopped draining it
                    """)
                return false
            case .closed:
                return false
            }
        }
    }
}

// MARK: - The descriptor

/// Owns the handed-over pty master and serializes every operation on it.
///
/// The lock is not about throughput — the descriptor is non-blocking, so no
/// operation under it waits on the child — it is about the fd *number*. Reads
/// happen on the drain thread, writes arrive from the actor, and the close
/// happens exactly once; funnelling all three through one lock and one `fd`
/// field is what makes "closed" a state a writer can observe instead of a race
/// it can lose.
private final class PTYDescriptor: @unchecked Sendable {
    enum ReadOutcome {
        case bytes(Int)
        case wouldBlock
        case interrupted
        /// End of file, or `EIO`: on a pty master, the last slave has closed.
        case childGone
        case failed(errno: Int32)
        case closed
    }

    /// How long a `write` may wait for a child that is not currently reading
    /// its terminal. Short: the caller is an actor, and a paste that cannot
    /// land must be reported rather than absorbed into an unbounded wait.
    private static let writeBudgetMilliseconds: Int32 = 250
    /// The same budget for the emulator's own replies, which are written from
    /// inside a feed and must not hold the terminal lock for long.
    private static let replyBudgetMilliseconds: Int32 = 50

    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
        // Non-blocking from the outset, for both directions. Reads are
        // poll-guarded anyway; what this really buys is that no `write` — not
        // the actor's, and above all not a terminal reply issued from inside a
        // feed — can park a thread on a child that has stopped reading.
        //
        // The flag lives on the open file description, which this descriptor
        // shares with the holder's own copy. That is harmless precisely because
        // of the holder's central invariant: it never reads the master.
        if fd >= 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
    }

    /// The raw number, for a poll set. Valid only while the owner has not
    /// closed it — which, by construction, only the drain thread does.
    var rawDescriptor: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fd
    }

    func read(into buffer: inout [UInt8]) -> ReadOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return .closed }
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if count > 0 { return .bytes(count) }
        if count == 0 { return .childGone }
        switch errno {
        case EAGAIN: return .wouldBlock
        case EINTR: return .interrupted
        case EIO: return .childGone
        default: return .failed(errno: errno)
        }
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            try writeAll(raw, budgetMilliseconds: Self.writeBudgetMilliseconds)
        }
    }

    /// A terminal reply, written best-effort.
    ///
    /// Best-effort because the alternative is worse: this runs inside a feed,
    /// under the terminal lock, and there is no caller to hand an error to. A
    /// reply that cannot land within a small budget is dropped and logged —
    /// never the bytes, only the fact.
    func replyBestEffort(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        do {
            try bytes.withUnsafeBufferPointer { pointer in
                try writeAll(UnsafeRawBufferPointer(pointer), budgetMilliseconds: Self.replyBudgetMilliseconds)
            }
        } catch {
            Logger(subsystem: "com.tbd.daemon", category: "holder").error(
                "could not deliver a terminal reply to the child: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer, budgetMilliseconds: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw HolderReader.Error.stopped }

        var offset = 0
        var remainingBudget = budgetMilliseconds
        while offset < bytes.count {
            let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            guard written < 0, errno == EAGAIN else {
                throw HolderReader.Error.writeFailed(errno: errno)
            }
            guard remainingBudget > 0 else {
                throw HolderReader.Error.writeTimedOut(unwritten: bytes.count - offset)
            }
            let slice = min(remainingBudget, 20)
            var watched = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&watched, 1, slice)
            if ready < 0, errno != EINTR {
                throw HolderReader.Error.writeFailed(errno: errno)
            }
            remainingBudget -= slice
        }
    }

    func setWindowSize(columns: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: 0,
            ws_ypixel: 0)
        if ioctl(fd, TIOCSWINSZ, &size) != 0 {
            Logger(subsystem: "com.tbd.daemon", category: "holder").error(
                "TIOCSWINSZ failed (errno \(errno, privacy: .public))")
        }
    }

    /// Closes the descriptor once. Every later operation observes "closed"
    /// rather than acting on a number the kernel may have handed to somebody
    /// else in the meantime.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}

// MARK: - The emulator

/// The headless terminal, and the lock discipline it demands.
///
/// `Terminal` is not `Sendable`, carries no `@MainActor`, and does not lock
/// itself: it publishes `terminalLock` and expects every feed and every read of
/// its state to hold it. The drain thread and a rendering caller are genuinely
/// concurrent, so this box exists to make that impossible to get wrong — no
/// path reaches the `Terminal` except through a method here, and every method
/// here takes the lock. Getting it wrong garbles output rather than crashing,
/// which is why it must be structural instead of remembered.
private final class HolderEmulator: @unchecked Sendable {
    private let terminal: Terminal
    /// Held strongly: `Terminal.tdel` is `weak`, so a delegate nobody else
    /// retains is deallocated and the child's terminal queries go unanswered.
    private let delegate: ReplyForwardingDelegate

    init(columns: Int, rows: Int, scrollback: Int, reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void) {
        let delegate = ReplyForwardingDelegate(reply: reply)
        self.delegate = delegate
        self.terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(
                cols: max(1, columns),
                rows: max(1, rows),
                scrollback: max(0, scrollback)))
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        terminal.terminalLock.withLock {
            terminal.feed(buffer: bytes)
        }
    }

    func renderScreen() -> String {
        terminal.terminalLock.withLock {
            var lines: [String] = []
            lines.reserveCapacity(terminal.rows)
            for row in 0..<terminal.rows {
                lines.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
            }
            return Self.joined(lines)
        }
    }

    /// The tail of the whole buffer — scrollback and viewport together.
    ///
    /// Enumeration starts at `totalLinesTrimmed`, the absolute index of the
    /// oldest line still held, and runs until `getScrollInvariantLine` returns
    /// nil: there is no public line count, and `Buffer.lines` is internal.
    func renderScreenWithScrollback(maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        return terminal.terminalLock.withLock {
            var lines: [String] = []
            var row = terminal.buffer.totalLinesTrimmed
            while let line = terminal.getScrollInvariantLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
                row += 1
            }
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            return Self.joined(lines)
        }
    }

    func resize(columns: Int, rows: Int) {
        terminal.terminalLock.withLock {
            terminal.resize(cols: columns, rows: rows)
        }
    }

    /// Trailing blank lines are dropped — a screen is 24 rows whether or not
    /// the job filled them, and rendering 20 empty ones helps nobody.
    private static func joined(_ lines: [String]) -> String {
        var lines = lines
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// The emulator's only required delegate hook: bytes the terminal itself wants
/// to send back — device-status replies, cursor-position reports, the answers
/// to `DECRQM`. `TerminalDelegate` declares 31 methods and a public extension
/// defaults 30 of them; this is the one that has no default, and routing it
/// anywhere but the child would turn every terminal query into a hang.
private final class ReplyForwardingDelegate: TerminalDelegate {
    private let reply: @Sendable (ArraySlice<UInt8>) -> Void

    init(reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void) {
        self.reply = reply
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        reply(data)
    }
}
