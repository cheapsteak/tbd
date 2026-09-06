import Darwin
import Foundation
import SwiftTerm
// Scoped, not a whole-module import: `TBDShared.Terminal` is the DB row model
// and `SwiftTerm.Terminal` is the emulator, and this file is full of the
// second. Naming the two types it needs keeps every bare `Terminal` here
// meaning the emulator.
import struct TBDShared.TerminalModeReading
import struct TBDShared.TerminalScreen
import TBDTerminalSerialization
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
        /// The drain thread did not leave the descriptor within the budget, so
        /// nothing may touch it: reading a descriptor another thread might
        /// still be reading is the byte theft this whole design prevents. The
        /// reader keeps draining rather than handing anything over.
        case drainDidNotQuiesce
        /// The pty master could not be duplicated for a viewer.
        case cannotDuplicate(errno: Int32)

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
            case .drainDidNotQuiesce:
                return "the drain thread did not leave the session's pty within the budget, so "
                    + "nothing else may read it"
            case .cannotDuplicate(let code):
                return "could not duplicate the session's pty for a viewer: "
                    + "\(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }

    private enum State {
        case idle
        case draining
        /// The drain thread has left the descriptor and exited, but the
        /// descriptor is still open and still this reader's to close. Reached
        /// only through `suspendDraining()`, and left through
        /// `resumeDraining()` or `stop()`.
        ///
        /// **This state holds jobs open.** Nothing is reading the pty, so a job
        /// that exits while the reader is suspended stops half-exited in
        /// `ttywait` until somebody drains again. It is entered only to hand
        /// the descriptor to a viewer that will read it instead, and every path
        /// out of it is either that hand-over completing or the drain resuming.
        case suspended
        case stopped
    }

    let sessionID: UUID
    private let descriptor: PTYDescriptor
    private let emulator: HolderEmulator
    private let stopTimeout: Duration
    private let clock: any Clock<Duration>
    /// Handed to the drain loop when it starts; see `init`.
    private let onEndOfOutput: (@Sendable () -> Void)?

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
    /// - Parameter readFault: a test seam. Production passes nothing; see
    ///   `HolderReadFault` for why the branch it reaches has no other way in.
    /// - Parameter onEndOfOutput: announced once, on the drain thread, when the
    ///   session's output is exhausted — see `hasReachedEndOfOutput`. It must
    ///   not block, and must not stop this reader inline; the registry's
    ///   reclaimer hops onto the actor instead.
    /// - Parameter monotonicNow: reads the monotonic clock, for the two
    ///   instants the emulator stamps — its adoption and its last consumed
    ///   byte — whose difference is a screen's `age`. It sits *before* `clock`
    ///   so `clock` stays the last parameter, per the repo's clock-seam rule,
    ///   and it is a separate seam because `any Clock<Duration>` pins
    ///   `Duration` and not `Instant`: it can express a delay but cannot do the
    ///   instant arithmetic an age is. `ContinuousClock.Instant` can, which is
    ///   what lets a test hand back `base + .minutes(41)` and assert an exact
    ///   age rather than a tolerance window.
    init(
        sessionID: UUID,
        ptyFD: Int32,
        columns: Int,
        rows: Int,
        scrollbackLines: Int = HolderReader.scrollbackLines,
        stopTimeout: Duration = HolderReader.defaultStopTimeout,
        readFault: HolderReadFault? = nil,
        onEndOfOutput: (@Sendable () -> Void)? = nil,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.sessionID = sessionID
        self.stopTimeout = stopTimeout
        self.clock = clock
        self.onEndOfOutput = onEndOfOutput
        let descriptor = PTYDescriptor(fd: ptyFD, readFault: readFault)
        self.descriptor = descriptor
        // The emulator's replies go straight back down the same descriptor.
        // A device-status or cursor-position report that never reaches the
        // child is a hang in that child, not a cosmetic loss — the program
        // asked the terminal a question and is waiting for the answer.
        self.emulator = HolderEmulator(
            columns: columns,
            rows: rows,
            scrollback: scrollbackLines,
            monotonicNow: monotonicNow,
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
        case .idle, .suspended:
            // Both are states in which no thread can be inside a read: an idle
            // reader never started one, and a suspended reader's thread has
            // provably finished. So the descriptor is this actor's to close.
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

    /// Whether the drain has reached the end of this session's output — end of
    /// file on the pty master, or a read failure no waiting can undo.
    ///
    /// **It is the only safe moment to let go of a session's output**, and that
    /// is what it is for. The drain reads until the descriptor would block
    /// before it can ever see end of file, so once this is true nothing the job
    /// wrote is still queued anywhere; before it is true, whatever is queued is
    /// still owed to somebody. `HolderRegistry` releases a finished session's
    /// reader on exactly this edge.
    ///
    /// Reads the drain thread's own flag rather than the actor's intent, for
    /// the same reason `isDraining` does.
    var hasReachedEndOfOutput: Bool {
        drain?.hasReachedEndOfOutput ?? false
    }

    /// The emulator's grid, in columns and rows.
    ///
    /// Test-facing, and the honest instrument for adoption geometry: a
    /// re-adopted session whose grid does not match its pty is a job painting
    /// into a differently-shaped screen, and nothing else in the daemon can see
    /// the difference.
    var gridSize: (columns: Int, rows: Int) {
        emulator.size
    }

    /// The window size this session's own pty reports, or nil when the ioctl
    /// cannot answer.
    ///
    /// Test-facing, and the honest instrument for "did anybody issue
    /// `TIOCSWINSZ`": the emulator's grid cannot answer it, because a resize
    /// that reshaped the grid and skipped the tty looks identical from there.
    var ptyWindowSize: (columns: Int, rows: Int)? {
        HolderReader.windowSize(ptyFD: descriptor.rawDescriptor)
    }

    /// The window size the pty itself reports, or nil when the ioctl fails or
    /// answers a degenerate size.
    ///
    /// **The pty is the authority on its own geometry.** A launch request
    /// records the size a session was *asked* for once, and nothing updates it
    /// afterwards; `TIOCSWINSZ` — which every resize goes through — moves the
    /// terminal itself. So anything reconstructing a session's screen asks the
    /// descriptor, not the request that opened it.
    ///
    /// The parameter is spelled `ptyFD` for the reason given on `init`.
    static func windowSize(ptyFD: Int32) -> (columns: Int, rows: Int)? {
        guard ptyFD >= 0 else { return nil }
        var size = winsize(ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(ptyFD, TIOCGWINSZ, &size) == 0 else { return nil }
        // A zero in either axis is not a size a grid can be built at, and a
        // terminal that has never been sized reports one. Answering nil sends
        // the caller to its fallback rather than to `max(1, 0)`.
        guard size.ws_col > 0, size.ws_row > 0 else { return nil }
        return (Int(size.ws_col), Int(size.ws_row))
    }

    // MARK: - Lifecycle

    /// Starts draining. Idempotent; a stopped reader stays stopped, and a
    /// suspended one resumes.
    func start() throws {
        switch state {
        case .draining: return
        case .stopped: throw Error.stopped
        case .idle, .suspended: break
        }
        try startDrainThread()
    }

    /// Puts a suspended reader back on its descriptor.
    ///
    /// The other half of `suspendDraining()`, and the only path out of the
    /// suspended state that keeps the session drainable. **Every caller that
    /// suspends owes this or a `stop()`**: a reader left suspended reads
    /// nothing, and a job that exits with unread output cannot finish exiting.
    func resumeDraining() throws {
        guard state == .suspended else { return }
        try startDrainThread()
    }

    /// Mints a wake pipe, builds a drain loop and puts a thread on it.
    ///
    /// Shared by `start()` and `resumeDraining()` because a resume is a genuine
    /// restart: the wake pipe is consumed by the wake that ended the previous
    /// loop, and the loop itself has exited. What is *not* rebuilt is the
    /// descriptor or the emulator — the session's screen and its pty survive
    /// the pause, which is the whole point of pausing rather than stopping.
    private func startDrainThread() throws {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            throw Error.cannotCreateWakePipe(errno: errno)
        }
        wakeWriteFD = pipeFDs[1]

        let loop = DrainLoop(
            sessionID: sessionID,
            descriptor: descriptor,
            emulator: emulator,
            wakeReadFD: pipeFDs[0],
            onEndOfOutput: onEndOfOutput)
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
            // and a suspended one's thread has provably finished, so neither
            // can be mid-read on the descriptor: this is the one place the
            // actor may close it itself. Stopping such a reader must still
            // release the pty: it is a `dup` the holder handed over, and
            // leaking it keeps a reference to that terminal alive for the life
            // of the daemon.
            if state == .idle || state == .suspended { descriptor.close() }
            state = .stopped
            return
        }
        state = .stopped
        wakeDrainThread(closingDescriptor: true)
        await awaitDrainExit()
    }

    /// Wakes the drain thread off the descriptor and tells it whether to close
    /// the descriptor on its way out.
    ///
    /// Closing the write end is itself a wake — the thread's `poll` reports
    /// `POLLHUP` on the read end — so a byte that lands in a full pipe costs
    /// nothing and a wake can never be missed.
    private func wakeDrainThread(closingDescriptor: Bool) {
        drain?.requestExit(closingDescriptor: closingDescriptor)
        guard wakeWriteFD >= 0 else { return }
        var byte: UInt8 = 1
        // One byte, and the result is deliberately ignored: a full pipe means a
        // wake is already queued, which is exactly the outcome wanted. SIGPIPE
        // cannot arrive — the read end is closed only by the thread on its way
        // out, after which the wait below ends.
        _ = Darwin.write(wakeWriteFD, &byte, 1)
        Darwin.close(wakeWriteFD)
        wakeWriteFD = -1
    }

    /// Quiesces the drain and hands back a `dup` of the session's pty master.
    ///
    /// **This is the hand-over edge, and its order is the whole of it.** The
    /// drain thread is woken off the descriptor and waited for; everything
    /// still readable is then read on *this* thread and fed to the emulator, so
    /// no byte is stranded in a buffer nobody will ever look at again; and only
    /// then is the descriptor duplicated. A caller that snapshots the screen
    /// after this call therefore sees every byte the session had produced up to
    /// the moment it stopped reading, and everything after that moment is still
    /// queued on the tty for whoever reads next. Nothing falls between the two.
    ///
    /// The descriptor is deliberately **not** closed: this reader still owns it
    /// and can be put back on it with `resumeDraining()`. The returned `dup` is
    /// the caller's, and the caller closes it.
    ///
    /// Idempotent — a second call on a suspended reader drains whatever has
    /// arrived since and hands back another `dup`.
    ///
    /// **It leaves the session unread.** That is the fail-closed direction (at
    /// most one reader, ever) and it is not free: see `State.suspended`.
    func suspendDraining() async throws -> Int32 {
        guard state != .stopped else { throw Error.stopped }
        if state == .draining {
            wakeDrainThread(closingDescriptor: false)
            await awaitDrainExit()
            guard drain?.isFinished ?? true else {
                // The thread is still in there somewhere, so nothing may read
                // this descriptor and nothing may be handed a `dup` of it: two
                // readers on one pty is the one unrecoverable outcome. The
                // hand-over is refused and the reader is left exactly as it is.
                //
                // Deliberately NOT restarted here, however much a "put it back"
                // reads like the safe half of a rollback. The loop that is
                // still running owns the descriptor; starting a second one
                // beside it would BE the double read this refusal exists to
                // prevent. It exits on its own — the wake pipe's write end is
                // closed, which its `poll` reports as a hang-up — and `stop()`
                // still works afterwards, because the exit request it makes is
                // read on the way out.
                Self.logger.error(
                    """
                    the drain thread for session \(self.sessionID.uuidString, privacy: .public) did \
                    not leave the pty within the budget, so the session was not handed over
                    """)
                throw Error.drainDidNotQuiesce
            }
            state = .suspended
        }
        drainRemainder()
        let duplicate = descriptor.duplicate()
        guard duplicate >= 0 else {
            let code = errno
            // Nothing was handed over, so nobody else can be on this pty and
            // resuming is unambiguously safe — the one failure on this path
            // where that is true.
            try? resumeDraining()
            throw Error.cannotDuplicate(errno: code)
        }
        return duplicate
    }

    /// Reads everything the descriptor will yield right now into the emulator.
    ///
    /// Only ever called with the drain thread provably gone, so this is the
    /// single reader for its duration. Bounded rather than "until it would
    /// block": a job flooding its terminal could otherwise feed this loop for
    /// as long as it kept writing, with the actor parked. Stopping early costs
    /// nothing — the bytes stay queued for whoever reads next, which is exactly
    /// where every byte written after this call already is.
    private func drainRemainder() {
        var buffer = [UInt8](repeating: 0, count: Self.quiesceBufferSize)
        for _ in 0..<Self.quiesceMaxReads {
            guard case .bytes(let count) = descriptor.read(into: &buffer) else { return }
            emulator.feed(buffer[0..<count])
        }
    }

    /// The read buffer the quiesce uses, matching the drain loop's own.
    private static let quiesceBufferSize = 64 * 1024
    /// How many bufferfuls the quiesce will take before it stops trying. Four
    /// megabytes is far past any plausible tty queue and finite against a job
    /// that never stops writing.
    private static let quiesceMaxReads = 64

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

    /// The typed screen `terminal.output` answers with: the tail of the
    /// scrollback plus the viewport at most `maxLines` long, plus the facts a
    /// string cannot carry — where the viewport starts, where the cursor is,
    /// what modes the child is in, which store answered, and how stale that
    /// store is.
    ///
    /// The one whole-buffer walk. A second one existed while `terminal.output`
    /// was migrating and produced the same lines with none of the facts; it is
    /// gone, because two walks over one buffer are two chances for a
    /// projection fix to land in only one of them.
    ///
    /// **`source` is read from this reader's own drain state**, which is the
    /// only place it can be read honestly. A reader that is draining is on the
    /// pty and its emulator is live, so it answers `.daemon`. A reader in any
    /// other state — suspended for an attach, idle, stopped — is holding a
    /// screen it is no longer updating, and a consumer told `.daemon` about it
    /// would apply a live-screen policy to a frozen one. `.viewer` never comes
    /// from here: it is the app's answer to a pull, on a path this reader is
    /// not part of.
    ///
    /// Throws only what `TerminalScreen`'s construction refuses. That is a
    /// projection bug rather than a session state, and the handler above turns
    /// it into an error naming the offending line rather than an empty screen.
    func screen(maxLines: Int) throws -> TerminalScreen {
        try emulator.screen(maxLines: maxLines, source: currentSource)
    }

    /// The child's modes, their provenance and their age, with no line walk.
    ///
    /// What the send path's oracle asks. A whole screen would be the same
    /// answer at the price of walking the retained scrollback on every message
    /// composed.
    func modeReading() -> TerminalModeReading {
        emulator.modeReading(source: currentSource)
    }

    /// Whether this reader's emulator is live or frozen — see `screen`.
    ///
    /// Three states answer `.staleDaemon`, but **only one of them is reachable
    /// in production**, and that is what makes the answer mean what the type
    /// says it does. `HolderRegistry` publishes a reader into its `.adopted`
    /// slot only after `start()` has returned, and `reader(for:)` reads no
    /// other slot — so no caller can reach an `.idle` reader — while a stopped
    /// reader has been through `.releasing` and been dropped from the slot, so
    /// no caller can reach one of those either. What a consumer can reach is a
    /// reader suspended for an attach, which is exactly the case `staleDaemon`
    /// describes: a viewer holds the pty, and this emulator has been frozen
    /// since it did.
    ///
    /// A test harness *can* hold an `.idle` reader, and one answers
    /// `staleDaemon` there. That is not a special case to be excused: an idle
    /// reader's emulator is by definition not being fed, so a screen taken from
    /// it is a frozen one and saying so is the truthful answer.
    private var currentSource: TerminalScreen.Source {
        state == .draining ? .daemon : .staleDaemon
    }

    /// The session's whole screen — modes, scrollback, viewport, cursor — as a
    /// byte stream that reconstructs it in a fresh terminal.
    ///
    /// What an attaching viewer is sent so it paints the session as it already
    /// is, rather than a blank grid waiting for the program to print something
    /// next. Only bytes leave: the emulator's `Terminal` never does, because it
    /// is not `Sendable` and its lock is what makes the drain thread and this
    /// call safe to run at once.
    ///
    /// Meaningful at any time, and only *complete* when the drain is quiesced —
    /// which is why `suspendDraining()` runs first on the attach path.
    func snapshotPreamble(maxScrollbackLines: Int = HolderReader.scrollbackLines) -> Data {
        emulator.snapshotPreamble(maxScrollbackLines: maxScrollbackLines)
    }

    /// Feeds a departing viewer's handback preamble into this session's screen
    /// model — `snapshotPreamble` run backwards.
    ///
    /// **It does not reset the emulator first, and does not need to.** The
    /// preamble opens with `TerminalSnapshotWriter.resetPrelude`, whose whole
    /// purpose is to supersede whatever state the receiving terminal was
    /// already in: it leaves the alt screen, resets the scroll region and every
    /// mode the capture carries, and erases the display *and the scrollback*
    /// (`ESC[3J`, which SwiftTerm implements as a trim of every line above the
    /// viewport). A separate reset would only be a second way to say that, and
    /// there is no way to say it that the writer does not already own.
    ///
    /// **Must be called with nothing else feeding this emulator**, which on the
    /// handback path means before `resumeDraining()` or before the first
    /// `start()`. The emulator's lock makes a concurrent feed safe but not
    /// *ordered*, and a live byte parsed ahead of the prelude would be erased
    /// by it — output the viewer never saw and the daemon then throws away.
    /// A stopped reader ignores the feed: its screen has no further readers.
    func ingest(preamble: Data) {
        guard state != .stopped, !preamble.isEmpty else { return }
        emulator.feed([UInt8](preamble)[...])
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
    ///
    /// **Only for a session the daemon still owns.** While a viewer holds this
    /// pty the viewer owns `TIOCSWINSZ` and drives it on its own descriptor;
    /// `resizeGrid` is the half that is still the daemon's then.
    func resize(columns: Int, rows: Int) {
        let (cols, lines) = Self.clamped(columns: columns, rows: rows)
        emulator.resize(columns: cols, rows: lines)
        descriptor.setWindowSize(columns: cols, rows: lines)
    }

    /// Reshapes the emulator's grid and leaves the tty alone.
    ///
    /// The half of a resize that stays the daemon's while a viewer owns the
    /// pty. It is not an optimisation: the emulator is what a re-adoption or a
    /// `terminal.output` renders, so a grid left at the size the viewer arrived
    /// at wraps every later line at the wrong width. The other half is not
    /// skipped — the viewer has already made it, on its own descriptor, which
    /// is why issuing it here as well would signal the child twice for one
    /// resize.
    func resizeGrid(columns: Int, rows: Int) {
        let (cols, lines) = Self.clamped(columns: columns, rows: rows)
        emulator.resize(columns: cols, rows: lines)
    }

    /// A grid has to have at least one of each. SwiftTerm emits transient zero
    /// sizes mid-layout and a caller may pass one straight through.
    private static func clamped(columns: Int, rows: Int) -> (columns: Int, rows: Int) {
        (max(1, columns), max(1, rows))
    }

    /// Forces a repaint from programs that redraw on `SIGWINCH`, by changing the
    /// tty size and changing it back.
    ///
    /// Applied at every reader-handoff edge — attach, detach, app death, daemon
    /// re-adoption — which is a deliberate divergence from iTerm2, whose jiggle
    /// fires on orphan adoption but not ordinary reattach and is suppressed when
    /// the requested geometry already matches. A same-geometry reattach there
    /// issues no ioctl and heals nothing.
    ///
    /// Scope, measured rather than assumed: a full-screen program repaints its
    /// viewport exactly, a plain shell repaints essentially nothing, and no
    /// program repaints its scrollback. **This heals screen state; it cannot
    /// recover history.** The snapshot preamble covers what this cannot.
    ///
    /// Only the tty changes size. The emulator's grid is deliberately left
    /// alone: resizing it too would reflow its contents and reflow them back for
    /// nothing, and the repaint would arrive at a size the grid was never at.
    /// `resize(columns:rows:)` drives both because a real resize must; this
    /// drives one because a jiggle must not.
    func jiggle() async {
        guard state != .stopped else { return }
        let size = gridSize
        descriptor.setWindowSize(columns: size.columns + 1, rows: size.rows)
        // Let the child be scheduled so it handles the first `SIGWINCH` before
        // the second arrives. Signals do not queue: two `TIOCSWINSZ` calls in
        // the same instant can be observed as a single coalesced size change,
        // and a program that sees only the final, unchanged size repaints
        // nothing. The gap is why this is `async` at all.
        try? await clock.sleep(for: Self.jiggleGap)
        // Re-read rather than restoring the size captured above: `resize` may
        // have run during the suspension, and restoring a stale size would put
        // the tty back to a geometry the emulator has already left.
        let restored = gridSize
        descriptor.setWindowSize(columns: restored.columns, rows: restored.rows)
    }

    /// How long the tty stays one column wider. Long enough that the child is
    /// scheduled between the two signals on a loaded machine, short enough that
    /// nothing perceives a handoff as slow.
    private static let jiggleGap: Duration = .milliseconds(10)
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

    /// The first pause after a read failed with an unclassified errno, doubling
    /// per consecutive failure up to the ceiling.
    private static let readBackoffBaseMilliseconds: Int32 = 10
    /// The slowest the loop will retry a failing descriptor. Four attempts a
    /// second costs nothing and keeps the promise that the queue will be
    /// emptied the moment the descriptor can be read again.
    private static let readBackoffCeilingMilliseconds: Int32 = 250
    /// The streak length at which a failure stops being plausibly transient and
    /// earns a second, louder log line. It changes what is *said*, never what is
    /// done: the loop keeps retrying past it.
    private static let implausibleReadFailureStreak = 8

    /// What one pass of `drainEverythingReadable` decided about the descriptor.
    private enum DrainOutcome {
        /// The descriptor was emptied and may yield again.
        case readable
        /// The descriptor will never yield anything again — end of file, or an
        /// errno that no amount of waiting can change.
        case exhausted
        /// A read failed with an errno that is *not* classified as permanent.
        /// The descriptor stays in the loop's care and is retried after a pause.
        case retryable(errno: Int32)
    }

    private let sessionID: UUID
    private let descriptor: PTYDescriptor
    private let emulator: HolderEmulator
    private let wakeReadFD: Int32
    /// Announced once, the first time the descriptor is classified as
    /// exhausted. Called **on the drain thread**, so it must not block: the
    /// thread's next job is to keep answering the wake pipe, and a reclaimer
    /// that stopped this reader from inside the callback would be waiting on
    /// the very thread it is running on.
    private let onEndOfOutput: (@Sendable () -> Void)?
    private let stateLock = NSLock()
    private var finished = false
    private var endOfOutput = false
    /// Whether this loop closes the descriptor when it leaves.
    ///
    /// Set by the actor immediately before it writes the wake byte, and read
    /// only on the way out. `true` is the default and the ordinary case — a
    /// stop hands the close to this thread precisely because it is the only one
    /// that knows it has left the fd. `false` is a **pause**: the actor keeps
    /// the descriptor to hand a `dup` of it to a viewer, and closing it here
    /// would revoke the very thing being handed over.
    private var closeDescriptorOnExit = true

    init(
        sessionID: UUID,
        descriptor: PTYDescriptor,
        emulator: HolderEmulator,
        wakeReadFD: Int32,
        onEndOfOutput: (@Sendable () -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.descriptor = descriptor
        self.emulator = emulator
        self.wakeReadFD = wakeReadFD
        self.onEndOfOutput = onEndOfOutput
    }

    var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finished
    }

    var hasReachedEndOfOutput: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return endOfOutput
    }

    /// Says what this loop should do with the descriptor when it leaves.
    /// Called before the wake that ends it; see `closeDescriptorOnExit`.
    func requestExit(closingDescriptor: Bool) {
        stateLock.lock()
        closeDescriptorOnExit = closingDescriptor
        stateLock.unlock()
    }

    /// Records the exhausted edge and announces it exactly once.
    ///
    /// Once, because the announcement is a *transition* — a second one for the
    /// same reader would ask a reclaimer to reclaim what it has already
    /// reclaimed, and the reader whose slot it names may by then be a different
    /// one.
    private func noteEndOfOutput() {
        stateLock.lock()
        let firstTime = !endOfOutput
        endOfOutput = true
        stateLock.unlock()
        guard firstTime else { return }
        onEndOfOutput?()
    }

    func run() {
        defer {
            // The descriptor is closed here and nowhere else *while a thread
            // could be inside it*: this thread is the only one that can know it
            // has left the fd alone. A pause is the exception, and only because
            // it is the same fact read the other way round — `finished` below
            // is what tells the actor this thread is out, after which the actor
            // may touch the descriptor itself.
            stateLock.lock()
            let closesDescriptor = closeDescriptorOnExit
            stateLock.unlock()
            if closesDescriptor { descriptor.close() }
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
        var consecutiveReadFailures = 0
        // While positive, the loop is pausing before it retries a descriptor
        // whose last read failed. The pause is spent in `poll` on the wake pipe
        // alone rather than in a sleep, so `stop()` is answered immediately and
        // the pty is simply not looked at for that long.
        var readBackoffMilliseconds: Int32 = 0

        while true {
            let backingOff = readBackoffMilliseconds > 0
            let watchingPTY = ptyCanYieldBytes && !backingOff
            var watched = [pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0)]
            if watchingPTY {
                watched.append(pollfd(fd: ptyFD, events: Int16(POLLIN), revents: 0))
            }

            let slice = backingOff ? readBackoffMilliseconds : Self.pollSliceMilliseconds
            let ready = poll(&watched, nfds_t(watched.count), slice)
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
                    apply(
                        drainEverythingReadable(into: &buffer),
                        canYield: &ptyCanYieldBytes,
                        failures: &consecutiveReadFailures,
                        backoff: &readBackoffMilliseconds)
                }
                usleep(20_000)
                continue
            }
            consecutivePollFailures = 0

            // Checked before the pty: a stop must win a tie, or a session
            // flooding its terminal could keep the loop fed forever.
            if watched[0].revents != 0 { return }

            if backingOff {
                // The pause is over — the descriptor was deliberately not in
                // the poll set, so nothing here says whether it is readable.
                // Ask it directly; that is what the pause was for.
                readBackoffMilliseconds = 0
                if ptyCanYieldBytes {
                    apply(
                        drainEverythingReadable(into: &buffer),
                        canYield: &ptyCanYieldBytes,
                        failures: &consecutiveReadFailures,
                        backoff: &readBackoffMilliseconds)
                }
                continue
            }

            guard ready > 0, watchingPTY, watched.count > 1, watched[1].revents != 0 else {
                continue
            }
            apply(
                drainEverythingReadable(into: &buffer),
                canYield: &ptyCanYieldBytes,
                failures: &consecutiveReadFailures,
                backoff: &readBackoffMilliseconds)
        }
    }

    /// Folds one drain pass into the loop's state.
    ///
    /// The `.retryable` arm is the whole point of the enum. Draining is a
    /// liveness requirement — a job cannot finish exiting while its output sits
    /// unread — so a failure the loop cannot *prove* is permanent must never
    /// end the loop's interest in the descriptor. It backs off instead, and
    /// keeps backing off at a floor of four attempts a second for as long as
    /// the session lives.
    private func apply(
        _ outcome: DrainOutcome,
        canYield: inout Bool,
        failures: inout Int,
        backoff: inout Int32
    ) {
        switch outcome {
        case .readable:
            failures = 0
            backoff = 0
        case .exhausted:
            canYield = false
            failures = 0
            backoff = 0
            // Announced only from here, which is the one place the loop knows
            // the descriptor was read until it would block and then said it was
            // done. Everything the job wrote has reached the emulator; nothing
            // more ever will.
            noteEndOfOutput()
        case .retryable(let code):
            failures += 1
            backoff = Self.backoffMilliseconds(forAttempt: failures)
            if failures == 1 {
                Self.logger.error(
                    """
                    read failed on the pty for session \
                    \(self.sessionID.uuidString, privacy: .public) \
                    (errno \(code, privacy: .public)); retrying — this errno is not one the \
                    drain loop treats as permanent
                    """)
            } else if failures == Self.implausibleReadFailureStreak {
                // Copied out: an os_log interpolation is an escaping
                // autoclosure and cannot capture an `inout` parameter.
                let streak = failures
                Self.logger.error(
                    """
                    read on the pty for session \(self.sessionID.uuidString, privacy: .public) \
                    has failed \(streak, privacy: .public) times running \
                    (errno \(code, privacy: .public)); still retrying at the floor cadence, so \
                    the job stays drainable if the descriptor recovers
                    """)
            }
        }
    }

    /// Doubling backoff, capped. Attempt 1 pauses 10 ms; by attempt 6 the pause
    /// has reached the 250 ms floor cadence and stays there.
    private static func backoffMilliseconds(forAttempt attempt: Int) -> Int32 {
        let doublings = Int32(min(max(attempt - 1, 0), 16))
        let scaled = readBackoffBaseMilliseconds << doublings
        return min(scaled, readBackoffCeilingMilliseconds)
    }

    /// The errnos a read on a pty master can report that no amount of waiting
    /// will change.
    ///
    /// Deliberately a short, explicit list rather than a catch-all. `EBADF`
    /// means the number is not an open descriptor and `ENXIO` means the device
    /// behind it is gone; neither can become readable again. Everything else —
    /// `ENOMEM` under memory pressure being the obvious case — is retried,
    /// because assuming an unclassified errno is permanent is exactly how a
    /// drain loop abandons a live job and wedges it in `ttywait`.
    private static func isPermanentReadFailure(_ code: Int32) -> Bool {
        code == EBADF || code == ENXIO
    }

    /// Reads until the descriptor would block, feeding everything to the
    /// emulator, and says what the caller should do with the descriptor next.
    ///
    /// The inner loop matters: one `poll` wake means *at least* one read is
    /// ready, and a loop that took one bufferful per wake would fall behind a
    /// job writing faster than the scheduler round-trips.
    private func drainEverythingReadable(into buffer: inout [UInt8]) -> DrainOutcome {
        while true {
            switch descriptor.read(into: &buffer) {
            case .bytes(let count):
                // Never logged, at any level: these are session contents.
                emulator.feed(buffer[0..<count])
            case .wouldBlock, .interrupted:
                return .readable
            case .childGone:
                // `0` or `EIO` on a pty master means the last slave closed —
                // the ordinary end of a session, not an error. The loop stays
                // alive on the wake pipe so `stop()` still owns the close.
                Self.logger.debug(
                    """
                    pty for session \(self.sessionID.uuidString, privacy: .public) reached end of \
                    file; the job's terminal has no slave left
                    """)
                return .exhausted
            case .failed(let code):
                // EAGAIN, EINTR and EIO are classified above, so what arrives
                // here is an errno nobody has ruled on. Only the explicitly
                // permanent ones end the drain; the rest are handed back for a
                // paced retry, because a descriptor that fails once is not
                // evidence of a job that has stopped producing output — and a
                // job whose output goes unread cannot finish exiting.
                guard Self.isPermanentReadFailure(code) else {
                    return .retryable(errno: code)
                }
                Self.logger.error(
                    """
                    read failed on the pty for session \
                    \(self.sessionID.uuidString, privacy: .public) \
                    (errno \(code, privacy: .public)); that descriptor can never be read again, \
                    so draining it stopped
                    """)
                return .exhausted
            case .closed:
                return .exhausted
            }
        }
    }
}

// MARK: - The descriptor

/// A test seam that substitutes a synthetic errno for one `read` on the pty.
///
/// It exists because the branch it reaches cannot otherwise be entered. The
/// drain loop's retry path fires on errnos like `ENOMEM` — a machine under
/// genuine memory pressure — which a test cannot provoke on demand and must not
/// try to. Production never constructs one: every real call site takes the
/// defaulted `nil`, so the check costs an optional test per read and nothing
/// else.
struct HolderReadFault: Sendable {
    /// Consulted immediately before each `read`. Return an errno to report in
    /// place of issuing the syscall, or `nil` to let the real read happen. The
    /// returned errno runs through the same classification as a real one, so a
    /// fault can exercise any outcome the descriptor can produce.
    let nextErrno: @Sendable () -> Int32?

    init(nextErrno: @escaping @Sendable () -> Int32?) {
        self.nextErrno = nextErrno
    }
}

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
        /// An errno this type does not rule on. Whether it ends the drain is the
        /// drain loop's decision, not the descriptor's — see
        /// `DrainLoop.isPermanentReadFailure`.
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
    private let readFault: HolderReadFault?

    init(fd: Int32, readFault: HolderReadFault? = nil) {
        self.fd = fd
        self.readFault = readFault
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

    /// A close-on-exec copy of the pty master for somebody else to read, or -1
    /// with `errno` set. Taken under the lock so it cannot race the close: a
    /// duplicate of a number the kernel has already handed to something else is
    /// how a viewer ends up reading an unrelated descriptor.
    ///
    /// `F_DUPFD_CLOEXEC`, never `dup(2)`: `dup` deliberately clears
    /// `FD_CLOEXEC` on the copy whatever the original carries, and this copy
    /// sits in the daemon's table from here until the vend hands it to the app.
    /// The daemon spawns children throughout that window — git, tmux, usage and
    /// PR-status probes, peer supervisors, nearly all through
    /// `Foundation.Process`, which closes nothing that lacks the flag — and one
    /// that inherited a copy would hold the session open for as long as it
    /// lives, well past the attach it borrowed the pty for.
    func duplicate() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else {
            errno = EBADF
            return -1
        }
        return fcntl(fd, F_DUPFD_CLOEXEC, 0)
    }

    func read(into buffer: inout [UInt8]) -> ReadOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return .closed }
        // The injected errno takes the same classification path a real one
        // does, so a fault cannot accidentally test a shape production never
        // produces.
        if let injected = readFault?.nextErrno() { return Self.classify(errno: injected) }
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if count > 0 { return .bytes(count) }
        if count == 0 { return .childGone }
        return Self.classify(errno: errno)
    }

    private static func classify(errno code: Int32) -> ReadOutcome {
        switch code {
        case EAGAIN: return .wouldBlock
        case EINTR: return .interrupted
        case EIO: return .childGone
        default: return .failed(errno: code)
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
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    /// When this emulator started existing — the floor for a screen's age.
    ///
    /// A store that has never consumed a byte reports its own age rather than
    /// no age at all, so a fresh, silent session reads as exactly as old as it
    /// is instead of as instantly current.
    private let adoptedAt: ContinuousClock.Instant
    /// When this emulator last took in bytes that came from outside the daemon.
    ///
    /// Under `terminalLock` like everything else here, and stamped in `feed`
    /// only — which is the whole definition, because it is what decides the
    /// answer for each of the three things that reach `feed` and the one that
    /// does not:
    ///
    /// - **The drain loop's reads** and **the quiesce remainder** stamp it.
    ///   They are the child's own output; this is the measurement's subject.
    /// - **A handback preamble** (`ingest(preamble:)`) stamps it, deliberately.
    ///   A returning viewer hands back the screen as it stood a moment ago, so
    ///   the emulator's view really is fresh again, and reporting it as an hour
    ///   old would make a take-back look like a session nobody had watched.
    /// - **`snapshotPreamble`'s `DECRQM` probes** do not, because they feed the
    ///   `Terminal` directly rather than through this method. The daemon asking
    ///   its own emulator a question must never make a stale screen look fresh.
    ///   Keep it that way — routing a probe through `feed` would make every
    ///   read reset the age it was taken to measure.
    ///
    /// `screen` asks nothing at all: it reads the delegate's `DECTCEM` flag.
    private var lastByteAt: ContinuousClock.Instant?

    init(
        columns: Int, rows: Int, scrollback: Int,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant,
        reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void
    ) {
        let delegate = ReplyForwardingDelegate(reply: reply)
        self.delegate = delegate
        self.monotonicNow = monotonicNow
        self.adoptedAt = monotonicNow()
        self.terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(
                cols: max(1, columns),
                rows: max(1, rows),
                scrollback: max(0, scrollback)))
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        terminal.terminalLock.withLock {
            lastByteAt = monotonicNow()
            terminal.feed(buffer: bytes)
        }
    }

    func renderScreen() -> String {
        terminal.terminalLock.withLock {
            var lines: [String] = []
            lines.reserveCapacity(terminal.rows)
            for row in 0..<terminal.rows {
                lines.append(terminal.getLine(row: row).map(Self.rowText) ?? "")
            }
            return Self.joined(lines)
        }
    }

    /// The typed screen, taken as **one observation** under a single
    /// `terminalLock` hold.
    ///
    /// The lock is what makes lines, cursor, modes and size one fact rather
    /// than four. Taken separately, a drain-thread feed between two of them
    /// would produce a screen that never existed — modes from after a mode
    /// change beside lines from before it, which is exactly the pairing the
    /// input path must not compose against.
    ///
    /// The line walk enumerates from `totalLinesTrimmed`, the absolute index of
    /// the oldest line still held, until `getScrollInvariantLine` returns nil —
    /// because there is no public line count and `Buffer.lines` is internal.
    /// It is the only whole-buffer walk in this type: the string-returning twin
    /// that answered `terminal.output` before the screen contract is gone, so a
    /// change to the projection cannot land in one walk and miss the other.
    ///
    /// **Nothing here feeds the terminal**, which is why the cursor's
    /// visibility is read from a flag the delegate keeps rather than probed
    /// with a `DECRQM` 25 query. `Terminal.cursorHidden` is not public, but
    /// SwiftTerm calls `showCursor`/`hideCursor` on its delegate every time the
    /// child sets or resets `DECTCEM`, so the fact arrives without asking.
    ///
    /// A probe here would be fed into a live parser: this method runs on every
    /// `terminal.output`, including against a reader whose drain thread is
    /// mid-stream, and SwiftTerm's parser carries its state across `feed` calls
    /// while an `ESC` in any state aborts whatever sequence is pending. A read
    /// whose last chunk ended mid-sequence — routine when a TUI repaint exceeds
    /// the pty buffer — would therefore truncate the child's sequence, print
    /// its remainder into the screen model as literal text, and swallow the
    /// reply to a query the child was in the middle of asking. `snapshotPreamble`
    /// still probes, once per attach; its own doc argues that case.
    ///
    /// It does not touch `lastByteAt` either — a daemon reading its own
    /// emulator must not make a stale screen look fresh.
    func screen(maxLines: Int, source: TerminalScreen.Source) throws -> TerminalScreen {
        try terminal.terminalLock.withLock {
            var enumerated: [String] = []
            var row = terminal.buffer.totalLinesTrimmed
            while let line = terminal.getScrollInvariantLine(row: row) {
                enumerated.append(Self.rowText(line))
                row += 1
            }
            let enumeratedCount = enumerated.count

            var lines = enumerated
            if maxLines <= 0 {
                lines = []
            } else if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            let droppedFromFront = enumeratedCount - lines.count
            while let last = lines.last, last.isEmpty { lines.removeLast() }

            // SwiftTerm's line list is always `yBase + rows` long, so the
            // viewport is its tail — but `yBase` is not public, so the index of
            // the viewport's first row is derived from the length instead. The
            // tail cut then shifts it, which is why `droppedFromFront` comes
            // off it: the result is an index into `lines`, not into the buffer.
            // It can land outside `lines` in both directions, which the type's
            // own documentation states and callers must bounds check.
            let viewportStart = enumeratedCount - terminal.rows - droppedFromFront

            let cursor = TerminalScreen.Cursor(
                row: terminal.buffer.y,
                column: terminal.buffer.x,
                visible: delegate.cursorVisible)

            return try TerminalScreen(
                lines: lines,
                viewportStart: viewportStart,
                cursor: cursor,
                size: TerminalScreen.Size(columns: terminal.cols, rows: terminal.rows),
                modes: currentModes(),
                source: source,
                ageMilliseconds: ageMilliseconds())
        }
    }

    /// The modes, their provenance and their age, without the line walk.
    func modeReading(source: TerminalScreen.Source) -> TerminalModeReading {
        terminal.terminalLock.withLock {
            TerminalModeReading(
                modes: currentModes(), source: source, ageMilliseconds: ageMilliseconds())
        }
    }

    /// The three child modes, all readable from public properties.
    ///
    /// `TerminalModeCapture` reads these same three the same way, and its
    /// comment records why 1049 in particular must come from the property:
    /// `cmdDecRqm`'s switch does not carry it, so a `DECRQM` query answers
    /// "unknown". Caller holds `terminalLock`.
    private func currentModes() -> TerminalScreen.ChildModes {
        TerminalScreen.ChildModes(
            bracketedPaste: terminal.bracketedPasteMode,
            applicationCursor: terminal.applicationCursor,
            alternateScreen: terminal.isCurrentBufferAlternate)
    }

    /// How long ago this emulator last consumed a byte, in milliseconds, never
    /// negative. Caller holds `terminalLock`.
    ///
    /// Clamped at zero rather than trusted: the clock is injected, and a seam
    /// that ever moved backwards would otherwise produce an age the screen type
    /// refuses — turning a test double's mistake into a failed machine read.
    private func ageMilliseconds() -> Int {
        let since = lastByteAt ?? adoptedAt
        let elapsed = since.duration(to: monotonicNow())
        let milliseconds =
            elapsed.components.seconds * 1_000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        return Int(max(0, milliseconds))
    }

    /// Serializes the whole terminal — modes, scrollback, viewport, cursor —
    /// into bytes that reconstruct it elsewhere.
    ///
    /// Everything happens inside one `terminalLock`, and only `Data` comes out.
    /// That is not tidiness: `TerminalSnapshotWriter` reads the buffer, *feeds*
    /// the terminal (the alt-screen toggle, and a DECRQM query per mode it
    /// cannot read from a public property) and feeds it again to put the alt
    /// screen back, so a drain-thread feed interleaved with any of that would
    /// garble both. It also means the lock is held across the whole walk, which
    /// is the longest this lock is ever held — bounded by the retained
    /// scrollback, and paid once per attach.
    ///
    /// **The replies those queries provoke must not reach the child.** They are
    /// answers to questions nobody asked: a program reading its stdin would
    /// receive `\u{1b}[?7;1$y` as if somebody had typed it. So the delegate is
    /// switched from forwarding to collecting for the duration, which is also
    /// how `DelegateModeReader` reads the answers at all. This is the
    /// daemon-side twin of the app's quiet ingest, in the opposite direction.
    ///
    /// Those queries feed the `Terminal` directly rather than through `feed`,
    /// so they do not stamp `lastByteAt` — an attach must not make a session
    /// that has been silent for an hour report an age of zero.
    func snapshotPreamble(maxScrollbackLines: Int) -> Data {
        terminal.terminalLock.withLock {
            let reader = DelegateModeReader(terminal: terminal, delegate: delegate)
            delegate.beginCollectingReplies()
            defer { delegate.endCollectingReplies() }
            return TerminalSnapshotWriter.snapshot(
                of: terminal, reply: reader, maxScrollbackLines: maxScrollbackLines)
        }
    }

    func resize(columns: Int, rows: Int) {
        terminal.terminalLock.withLock {
            terminal.resize(cols: columns, rows: rows)
        }
    }

    /// The grid's dimensions, read under the same lock as everything else here.
    var size: (columns: Int, rows: Int) {
        terminal.terminalLock.withLock { (terminal.cols, terminal.rows) }
    }

    /// One row of the grid as text, the way a reader of `terminal.output`
    /// needs it: **a cell nobody ever wrote projects as a space, never as
    /// `U+0000`.**
    ///
    /// A never-written or erased cell holds `CharData.Null`, whose code is 0,
    /// and `translateToString`'s default path renders that literally. The
    /// result looks right and is not: a TUI paints differentially, positioning
    /// the cursor past the cells it is leaving alone rather than overwriting
    /// them with blanks, so the skipped cells become invisible NULs scattered
    /// through the line — and which cells get skipped changes with every
    /// repaint, so the holes appear to move. Every consumer of this string
    /// matches on text (fleet supervision, the pending-input rail, the login
    /// driver), and a NUL is a missing character nothing displays. `tmux
    /// capture-pane`, which this replaces for machine reads, returns spaces;
    /// so does the app-side serializer in `TerminalCellWalk`.
    ///
    /// `skipNullCellsFollowingWide` is the other half and not optional: the
    /// trailing cell of a two-column glyph carries code 0 as well, and padding
    /// *it* to a space would put a stray blank after every CJK character and
    /// every emoji. Trimming is unaffected — `trimRight` is computed from
    /// `getTrimmedLength()` before the projection runs, so a row nobody wrote
    /// still renders empty rather than as a row of spaces.
    ///
    /// **`U+0000` is not the only cell a screen line may not hold.** SwiftTerm's
    /// printable-run inserter takes every byte from `0x20` through `0x7f`
    /// without consulting a width, so a `printf '\x7f'` leaves a `DEL` in a cell
    /// — legal for a child to emit, and refused by `TerminalScreen`'s
    /// whitelist. Mapping only the NUL would therefore let one such byte break
    /// *every* later read of that session until the line left the scrollback: a
    /// session-wide outage caused by the session's own output.
    ///
    /// `DEL` is the only one reachable today — a C1 control is dropped before
    /// insertion, because non-ASCII goes through a width table and nothing of
    /// width zero is inserted. The projection is written against
    /// `TerminalScreen.isDisallowed` anyway, rather than against the list of
    /// scalars currently known to get through: the render and the whitelist
    /// cannot disagree if they read the same predicate, and a width table that
    /// changes its mind cannot reopen the outage. `U+FFFD` rather than a space
    /// for these, because unlike a never-written cell something *was* written
    /// and a reader should see that something is there.
    private static func rowText(_ line: BufferLine) -> String {
        line.translateToString(
            trimRight: true,
            skipNullCellsFollowingWide: true,
            characterProvider: { cell in
                let character = cell.getCharacter()
                if character == Character(Unicode.Scalar(0)) { return " " }
                guard character.unicodeScalars.contains(where: TerminalScreen.isDisallowed) else {
                    return character
                }
                return "\u{FFFD}"
            })
    }

    /// Trailing blank lines are dropped — a screen is 24 rows whether or not
    /// the job filled them, and rendering 20 empty ones helps nobody.
    private static func joined(_ lines: [String]) -> String {
        var lines = lines
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// The emulator's delegate: the terminal's outbound wire, plus the one piece of
/// its state that is not readable from a public property.
///
/// `send` is the required hook — bytes the terminal itself wants to send back:
/// device-status replies, cursor-position reports, the answers to `DECRQM`.
/// `TerminalDelegate` declares 31 methods and a public extension defaults 30 of
/// them; `send` is the one that has no default, and routing it anywhere but the
/// child would turn every terminal query into a hang.
///
/// `showCursor`/`hideCursor` are overridden from that default set, because
/// being *told* about `DECTCEM` is the only way to know the cursor's visibility
/// without asking the terminal — and asking is what `HolderEmulator.screen`
/// must never do.
private final class ReplyForwardingDelegate: TerminalDelegate {
    private let reply: @Sendable (ArraySlice<UInt8>) -> Void
    /// While true, replies are kept here instead of being written to the pty.
    ///
    /// Raised only for the duration of a snapshot, and only from a caller
    /// already holding `terminalLock` — which is also the lock every `send`
    /// arrives under, since the terminal calls its delegate from inside a parse.
    /// So the flag needs no lock of its own; the terminal's is doing the work.
    private var collecting = false
    private var collected: [UInt8] = []

    /// Whether the child's cursor is currently visible — `DECTCEM`, mode 25.
    ///
    /// `Terminal.cursorHidden` is not public, and the emulator must not ask for
    /// it: a `DECRQM` probe fed into a parser that is mid-sequence aborts the
    /// child's sequence (see `HolderEmulator.screen`). So the fact is taken
    /// where SwiftTerm volunteers it instead — `showCursor`/`hideCursor` are
    /// called on the delegate whenever the child sets or resets the mode.
    /// Starts `true`, the mode's own default: a terminal shows its cursor until
    /// a program hides it.
    ///
    /// Like `collecting`, this needs no lock of its own. The terminal calls its
    /// delegate from inside a parse, which always runs under `terminalLock`,
    /// and `HolderEmulator.screen` reads the flag under that same lock.
    ///
    /// **One residual, and it is `DECSTR`.** A soft reset (`CSI ! p`,
    /// `Terminal.cmdSoftReset`) clears `cursorHidden` by assignment, with no
    /// delegate call, so a soft reset arriving while the cursor is hidden
    /// leaves this reading hidden while the terminal is showing. `RIS` (`ESC
    /// c`) does **not** have this problem, though its `setup(isReset:)` clears
    /// the same field: `resetToInitialState` saves `cursorHidden` around the
    /// call and restores it afterwards, so a full reset leaves the flag exactly
    /// as it found it and this reading stays true.
    ///
    /// The `DECSTR` residual self-corrects on the child's next
    /// *hide-then-show* pair, not on a bare `DECSET 25`: `Terminal.showCursor`
    /// returns early when `cursorHidden` is already false, so the call the flag
    /// needs never happens until something has set it true again. A TUI hides
    /// its cursor for a repaint and shows it afterwards, so in practice that is
    /// the next repaint — but a child that soft-resets and only ever shows
    /// reads hidden until it does hide once.
    private(set) var cursorVisible = true

    init(reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void) {
        self.reply = reply
    }

    func showCursor(source: Terminal) {
        cursorVisible = true
    }

    func hideCursor(source: Terminal) {
        cursorVisible = false
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard collecting else {
            reply(data)
            return
        }
        collected.append(contentsOf: data)
    }

    func beginCollectingReplies() {
        collecting = true
        collected.removeAll(keepingCapacity: true)
    }

    func endCollectingReplies() {
        collecting = false
        collected.removeAll(keepingCapacity: false)
    }

    /// Drops whatever has been collected and hands back what arrives next.
    /// Used to read one query's answer without the previous one's bytes in it.
    ///
    /// Bytes that are not valid UTF-8 are no answer at all rather than a
    /// mangled one: every reply this reads is a `CSI` sequence of digits and
    /// punctuation, so anything undecodable is not the reply that was asked
    /// for, and an empty string is what the caller reads as "the terminal did
    /// not answer".
    func takeCollected(after query: (Terminal) -> Void, from terminal: Terminal) -> String {
        collected.removeAll(keepingCapacity: true)
        query(terminal)
        return String(bytes: collected, encoding: .utf8) ?? ""
    }
}

/// Reads a terminal's mode state by asking the terminal itself.
///
/// `TerminalModeCapture` needs `DECRQM` answers for every mode SwiftTerm keeps
/// private, and the only way to get one is to feed the query and catch what the
/// terminal tries to send back. That is what makes this a *collecting* delegate
/// rather than a suppressing one: the same switch that keeps the answers away
/// from the child is what makes them readable here.
///
/// The caller must hold `terminal.terminalLock` — the lock every parse, and so
/// every `send`, arrives under — and must have put the delegate in collecting
/// mode with `beginCollectingReplies`, or the answers go to the child and this
/// reads nothing. `HolderEmulator.snapshotPreamble` is the only construction
/// site, and it does both. Deliberately only that one: a probe is safe there
/// because it runs once per attach, and unsafe on the per-`terminal.output`
/// path, where it would abort a sequence the child is mid-way through sending.
private struct DelegateModeReader: ModeReplyReader {
    let terminal: Terminal
    let delegate: ReplyForwardingDelegate

    func requestMode(_ mode: Int, decPrivate: Bool) -> Int? {
        let prefix = decPrivate ? "?" : ""
        let reply = delegate.takeCollected(
            after: { $0.feed(text: "\u{1b}[\(prefix)\(mode)$p") }, from: terminal)
        // `CSI ? Pd ; Ps $y`, where `Ps` is 1 set, 2 reset, 4 permanently reset
        // and 0 unknown. Located rather than matched whole, because a terminal
        // may answer a query the caller did not ask for on the same wire — but
        // anchored on the CSI introducer, so that "mode 7" cannot be found
        // inside the answer for mode 1007.
        guard let head = reply.range(of: "\u{1b}[\(prefix)\(mode);"),
              let tail = reply[head.upperBound...].range(of: "$y")
        else { return nil }
        return Int(reply[head.upperBound..<tail.lowerBound])
    }
}
