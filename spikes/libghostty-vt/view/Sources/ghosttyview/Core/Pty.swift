// Adapted from tkzmux c961533 Sources/TkzTerminalCore/Pty.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// Pty — fork/exec a shell on a pty (via TkzPtyShim) and pump it from a dedicated IO queue.
// M1.2.
import Darwin
import Dispatch
import Foundation
import Synchronization
import TkzPtyShim

/// Terminal geometry: cells plus the pixel size of one cell (0 = unknown, which is what a
/// terminal reports before the renderer has measured the font).
public struct TerminalSize: Equatable, Sendable {
    public var rows: UInt16
    public var cols: UInt16
    public var cellWidthPx: UInt16
    public var cellHeightPx: UInt16

    public init(rows: UInt16, cols: UInt16, cellWidthPx: UInt16 = 0, cellHeightPx: UInt16 = 0) {
        self.rows = rows
        self.cols = cols
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
    }

    /// Total pixel width reported to the child through `TIOCSWINSZ` (0 when the cell size is unknown).
    public var pixelWidth: UInt16 { cols &* cellWidthPx }
    /// Total pixel height reported to the child through `TIOCSWINSZ`.
    public var pixelHeight: UInt16 { rows &* cellHeightPx }
}

/// What to launch on the pty.
public struct PtySpawn: Sendable {
    /// Absolute path handed to `execve`.
    public var executablePath: String
    /// Full argv including argv[0] (which may differ from `executablePath`, e.g. `-zsh` for a login shell).
    public var argv: [String]
    /// The complete environment of the child; nothing is inherited implicitly.
    public var environment: [String: String]
    /// Working directory, or nil to keep the parent's. A cwd that no longer exists is ignored by the
    /// child (it execs from the inherited directory) rather than failing the spawn.
    public var cwd: String?
    public var size: TerminalSize

    public init(
        executablePath: String,
        argv: [String],
        environment: [String: String],
        cwd: String? = nil,
        size: TerminalSize
    ) {
        self.executablePath = executablePath
        self.argv = argv
        self.environment = environment
        self.cwd = cwd
        self.size = size
    }

    /// The environment as `KEY=VALUE` strings, sorted so spawns are reproducible.
    public var environmentStrings: [String] {
        environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
    }
}

public enum PtyError: Error, Equatable, Sendable {
    /// `tkz_pty_spawn` failed; `code` is an errno (ENOENT for a missing binary, EACCES, …).
    case spawnFailed(code: Int32)
    case resizeFailed(code: Int32)
    case writeFailed(code: Int32)
    /// The pty has already hung up / been closed.
    case closed
}

/// How the child process ended.
public struct PtyExit: Equatable, Sendable {
    /// The raw `waitpid` status.
    public let rawStatus: Int32
    /// Exit code when the child exited normally, else nil.
    public let exitCode: Int32?
    /// Signal number when the child was killed by a signal, else nil.
    public let signal: Int32?

    init(rawStatus: Int32) {
        self.rawStatus = rawStatus
        let low = rawStatus & 0x7F
        if low == 0 {
            self.exitCode = (rawStatus >> 8) & 0xFF
            self.signal = nil
        } else if low == 0x7F {
            self.exitCode = nil
            self.signal = nil  // stopped, not exited; never reported as an exit
        } else {
            self.exitCode = nil
            self.signal = low
        }
    }
}

/// The process group in the foreground of the pty, plus what we can learn about its leader.
/// This is how the status bar knows whether the shell is idle or running something, without any
/// shell integration.
public struct ForegroundProcess: Equatable, Sendable {
    public let pgid: pid_t
    public let executablePath: String?
    public let currentDirectory: String?
}

/// A pty master plus the child attached to it.
///
/// All IO happens on `ioQueue` (a serial queue owned by the caller): the read source, the write
/// source and the exit source are all scheduled there, so `onData` and `onExit` are delivered
/// serialized on that queue and `write(_:)` may only be called from it.
public final class Pty: Sendable {
    /// pid of the child (also its process group id and session id — it is a session leader).
    public let pid: pid_t
    public let ioQueue: DispatchQueue

    private let masterFD: Int32
    private let onData: @Sendable (Data) -> Void
    private let onExit: @Sendable (PtyExit) -> Void
    private let state: Mutex<State>

    private struct State {
        var readSource: (any DispatchSourceRead)?
        var writeSource: (any DispatchSourceWrite)?
        var procSource: (any DispatchSourceProcess)?
        var exitPoll: (any DispatchSourceTimer)?
        var pendingWrites: [UInt8] = []
        var size: TerminalSize
        var sawEOF = false
        var reaped = false
        var exitDelivered = false
        var fdClosed = false
        var shuttingDown = false
        var didQueuePendingWrite = false
    }

    private static let readChunk = 64 * 1024
    private static let maxChunksPerWakeup = 4

    /// Spawn `spawn` on a new pty and start pumping it.
    ///
    /// The callbacks are supplied up front (not set afterwards) so that no output can arrive before
    /// there is somewhere to put it. Both run on `ioQueue`.
    public init(
        spawn: PtySpawn,
        ioQueue: DispatchQueue,
        onData: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (PtyExit) -> Void
    ) throws {
        var result = tkz_pty_spawn_result(master_fd: -1, pid: -1)
        let code = Pty.withCArrays(argv: spawn.argv, envp: spawn.environmentStrings) { argv, envp in
            spawn.executablePath.withCString { path -> Int32 in
                func run(_ cwd: UnsafePointer<CChar>?) -> Int32 {
                    var opts = tkz_pty_spawn_options(
                        path: path,
                        argv: argv,
                        envp: envp,
                        cwd: cwd,
                        rows: spawn.size.rows,
                        cols: spawn.size.cols,
                        cell_width_px: spawn.size.cellWidthPx,
                        cell_height_px: spawn.size.cellHeightPx
                    )
                    return tkz_pty_spawn(&opts, &result)
                }
                if let cwd = spawn.cwd {
                    return cwd.withCString { run($0) }
                }
                return run(nil)
            }
        }
        guard code == 0 else { throw PtyError.spawnFailed(code: code) }

        self.pid = result.pid
        self.masterFD = result.master_fd
        self.ioQueue = ioQueue
        self.onData = onData
        self.onExit = onExit
        self.state = Mutex(State(size: spawn.size))

        start()
    }

    deinit {
        // Safe to drop at any time: cancel the sources (the read source's cancel handler closes the
        // master fd), hang the child up and reap it on a detached queue so no zombie is left.
        let leftovers: (read: (any DispatchSourceRead)?, write: (any DispatchSourceWrite)?,
                        proc: (any DispatchSourceProcess)?, poll: (any DispatchSourceTimer)?,
                        reaped: Bool) = state.withLock { s in
            s.shuttingDown = true
            defer {
                s.readSource = nil
                s.writeSource = nil
                s.procSource = nil
                s.exitPoll = nil
            }
            return (s.readSource, s.writeSource, s.procSource, s.exitPoll, s.reaped)
        }
        // Order matters: deregister the write source before the read source's cancel handler
        // closes the fd. `start()` always installs a read source, so that handler is the *only*
        // place the master is ever closed — closing it here as well could hit a recycled fd number.
        leftovers.write?.cancel()
        leftovers.read?.cancel()
        leftovers.proc?.cancel()
        leftovers.poll?.cancel()

        if !leftovers.reaped {
            let pid = self.pid
            kill(pid, SIGHUP)
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
    }

    // MARK: - Lifecycle

    private func start() {
        let fd = masterFD
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        read.setEventHandler { [weak self] in self?.drain(bounded: true) }
        read.setCancelHandler { [weak self] in
            // The fd is closed exactly once, from here, so nothing can still be watching it.
            let shouldClose: Bool = self?.state.withLock { s in
                if s.fdClosed { return false }
                s.fdClosed = true
                return true
            } ?? true
            if shouldClose { close(fd) }
        }

        let proc = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        proc.setEventHandler { [weak self] in self?.reapIfNeeded() }

        state.withLock { s in
            s.readSource = read
            s.procSource = proc
        }
        read.resume()
        proc.resume()

        // The child can die between fork() and this resume(); kqueue NOTE_EXIT never fires for a
        // process that is already gone, so poll once here. `reapIfNeeded` is idempotent.
        ioQueue.async { [weak self] in self?.reapIfNeeded() }
    }

    // MARK: - Reading

    /// Drain the master. `bounded` limits one wakeup to 4 × 64 KiB so a chatty child cannot starve
    /// the rest of the queue; the final drain after exit is unbounded (the fd is non-blocking, so it
    /// always terminates on EAGAIN/EOF).
    private func drain(bounded: Bool) {
        var buffer = [UInt8](repeating: 0, count: Pty.readChunk)
        var chunks = 0
        while true {
            if bounded && chunks >= Pty.maxChunksPerWakeup { return }
            if state.withLock({ $0.fdClosed || $0.sawEOF }) { return }
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(masterFD, raw.baseAddress, Pty.readChunk)
            }
            if n > 0 {
                chunks += 1
                onData(Data(buffer[0..<n]))
                continue
            }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK { return }
                // EIO on a pty master means the last slave went away: that is EOF.
            }
            handleEOF()
            return
        }
    }

    /// EOF on the master (0 bytes or EIO) = the child let go of the tty. Stop reading and make sure
    /// the exit is noticed even if the process source never fired.
    private func handleEOF() {
        let (readSource, writeSource, alreadyEOF) = state.withLock {
            s -> ((any DispatchSourceRead)?, (any DispatchSourceWrite)?, Bool) in
            if s.sawEOF { return (nil, nil, true) }
            s.sawEOF = true
            let r = s.readSource
            let w = s.writeSource
            s.readSource = nil
            s.writeSource = nil
            s.pendingWrites = []
            return (r, w, false)
        }
        if alreadyEOF { return }
        // The write source must be deregistered before the read source's cancel handler closes the fd.
        writeSource?.cancel()
        readSource?.cancel()
        reapIfNeeded()
        startExitPollIfNeeded()
    }

    // MARK: - Exit

    /// Idempotent `waitpid(WNOHANG)`; delivers `onExit` once, after a last drain of the master.
    private func reapIfNeeded() {
        let shouldWait: Bool = state.withLock { s in !s.reaped && !s.shuttingDown }
        guard shouldWait else { return }

        var status: Int32 = 0
        var rc = waitpid(pid, &status, WNOHANG)
        while rc < 0 && errno == EINTR { rc = waitpid(pid, &status, WNOHANG) }
        if rc == 0 { return }  // still running
        if rc < 0 {
            guard errno == ECHILD else { return }
            status = 0  // already reaped elsewhere; report a clean exit
        }

        let proceed: (any DispatchSourceProcess)?
        let poll: (any DispatchSourceTimer)?
        let deliver: Bool = state.withLock { s in
            if s.reaped { return false }
            s.reaped = true
            return true
        }
        (proceed, poll) = state.withLock { s in
            let p = s.procSource
            let t = s.exitPoll
            s.procSource = nil
            s.exitPoll = nil
            return (p, t)
        }
        proceed?.cancel()
        poll?.cancel()
        guard deliver else { return }

        finishExit(status: status, attempt: 0)
    }

    /// Output written just before exit can still be in flight in the pty when the exit notification
    /// arrives, so drain until the master reports EOF — bounded (~100 ms) so a slave held open by
    /// some other process can never stall the exit event.
    private func finishExit(status: Int32, attempt: Int) {
        drain(bounded: false)
        let sawEOF = state.withLock { $0.sawEOF || $0.fdClosed }
        if !sawEOF && attempt < 20 {
            ioQueue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                self?.finishExit(status: status, attempt: attempt + 1)
            }
            return
        }

        let shouldDeliver: Bool = state.withLock { s in
            if s.exitDelivered || s.shuttingDown { return false }
            s.exitDelivered = true
            return true
        }
        if shouldDeliver { onExit(PtyExit(rawStatus: status)) }
    }

    /// Fallback for the (undetectable from the API) case where the process source never fires:
    /// once the pty has hung up, poll `waitpid` until the child is reaped. Costs nothing while the
    /// session is alive.
    private func startExitPollIfNeeded() {
        let timer: (any DispatchSourceTimer)? = state.withLock { s in
            if s.reaped || s.exitPoll != nil || s.shuttingDown { return nil }
            let t = DispatchSource.makeTimerSource(queue: ioQueue)
            s.exitPoll = t
            return t
        }
        guard let timer else { return }
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(25), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.reapIfNeeded() }
        timer.resume()
    }

    // MARK: - Writing

    /// Queue bytes for the child. **Call only from `ioQueue`.**
    /// A short write (`EAGAIN`) parks the remainder in a pending buffer that a write source drains.
    public func write(_ data: Data) throws {
        if data.isEmpty { return }
        if state.withLock({ $0.fdClosed || $0.sawEOF }) { throw PtyError.closed }

        let hadPending = state.withLock { !$0.pendingWrites.isEmpty }
        if hadPending {
            state.withLock {
                $0.pendingWrites.append(contentsOf: data)
                $0.didQueuePendingWrite = true
            }
            enableWriteSource()
            return
        }
        let remainder = try writeDirect([UInt8](data))
        if !remainder.isEmpty {
            state.withLock {
                $0.pendingWrites.append(contentsOf: remainder)
                $0.didQueuePendingWrite = true
            }
            enableWriteSource()
        }
    }

    /// Returns whatever could not be written yet.
    private func writeDirect(_ bytes: [UInt8]) throws -> ArraySlice<UInt8> {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(masterFD, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if n > 0 {
                offset += n
                continue
            }
            let err = errno
            if err == EINTR { continue }
            if err == EAGAIN || err == EWOULDBLOCK { return bytes[offset...] }
            throw PtyError.writeFailed(code: err)
        }
        return bytes[bytes.count...]
    }

    private func enableWriteSource() {
        let source: (any DispatchSourceWrite)? = state.withLock { s in
            if s.writeSource != nil || s.fdClosed || s.shuttingDown { return nil }
            let w = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: ioQueue)
            s.writeSource = w
            return w
        }
        guard let source else { return }
        source.setEventHandler { [weak self] in self?.flushPending() }
        source.resume()
    }

    private func flushPending() {
        let pending = state.withLock { s -> [UInt8] in
            let p = s.pendingWrites
            s.pendingWrites = []
            return p
        }
        guard !pending.isEmpty else {
            disableWriteSource()
            return
        }
        let remainder = (try? writeDirect(pending)) ?? pending[pending.count...]
        if remainder.isEmpty {
            disableWriteSource()
        } else {
            state.withLock { $0.pendingWrites.insert(contentsOf: remainder, at: 0) }
        }
    }

    private func disableWriteSource() {
        let source: (any DispatchSourceWrite)? = state.withLock { s in
            let w = s.writeSource
            s.writeSource = nil
            return w
        }
        source?.cancel()
    }

    // MARK: - Control

    /// Push a new size to the child (`TIOCSWINSZ` → the child sees `SIGWINCH`).
    public func resize(_ size: TerminalSize) throws {
        state.withLock { $0.size = size }
        let code = tkz_pty_set_size(masterFD, size.rows, size.cols, size.pixelWidth, size.pixelHeight)
        if code != 0 { throw PtyError.resizeFailed(code: code) }
    }

    public var size: TerminalSize { state.withLock { $0.size } }

    /// The foreground process group of the pty and, when it can be read, its leader's path and cwd.
    /// While the shell sits at its prompt this is the shell itself; while a command runs it is that
    /// command's job — which is exactly the job-control invariant.
    public func foregroundProcess() -> ForegroundProcess? {
        if state.withLock({ $0.fdClosed }) { return nil }
        let pgid = tkz_pty_foreground_pgid(masterFD)
        guard pgid > 0 else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLen = pathBuffer.withUnsafeMutableBufferPointer {
            tkz_proc_path(pgid, $0.baseAddress!, UInt32($0.count))
        }
        var cwdBuffer = [CChar](repeating: 0, count: 4096)
        let cwdLen = cwdBuffer.withUnsafeMutableBufferPointer {
            tkz_proc_cwd(pgid, $0.baseAddress!, UInt32($0.count))
        }
        return ForegroundProcess(
            pgid: pgid,
            executablePath: Pty.string(pathBuffer, length: pathLen),
            currentDirectory: Pty.string(cwdBuffer, length: cwdLen)
        )
    }

    /// Signal the child's process group (it is a session leader, so pgid == pid). SIGHUP is what a
    /// terminal sends when its window goes away; the shell then hangs up its own jobs.
    @discardableResult
    public func terminate(signal: Int32 = SIGHUP) -> Bool {
        if state.withLock({ $0.reaped }) { return false }
        if killpg(pid, signal) == 0 { return true }
        return kill(pid, signal) == 0
    }

    /// True once a write had to be parked in the pending buffer (i.e. the `EAGAIN` path ran).
    /// Only interesting to tests.
    var didQueuePendingWrite: Bool { state.withLock { $0.didQueuePendingWrite } }

    /// True once the child has been reaped.
    public var hasExited: Bool { state.withLock { $0.reaped } }

    // MARK: - C string plumbing

    /// A NUL-free prefix of `buffer` as a String; nil when the shim reported nothing.
    private static func string(_ buffer: [CChar], length: Int32) -> String? {
        guard length > 0, Int(length) <= buffer.count else { return nil }
        return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func withCArrays<R>(
        argv: [String],
        envp: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>, UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        func dup(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
            strings.map { strdup($0) } + [nil]
        }
        let cArgv = dup(argv)
        let cEnvp = dup(envp)
        defer {
            for p in cArgv where p != nil { free(p) }
            for p in cEnvp where p != nil { free(p) }
        }
        return cArgv.withUnsafeBufferPointer { a in
            cEnvp.withUnsafeBufferPointer { e in
                body(a.baseAddress!, e.baseAddress!)
            }
        }
    }
}
