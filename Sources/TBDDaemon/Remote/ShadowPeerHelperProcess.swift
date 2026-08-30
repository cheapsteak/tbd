import Darwin
import Foundation
import os
import TBDShared

private let shadowPeerLogger = Logger(subsystem: "com.tbd.daemon", category: "shadowPeer")

// MARK: - Invocation

/// One `TBDPeerHelper` invocation, as a value.
///
/// Separated from the spawning so the argv a shadow gets is a pure function of
/// what the daemon knows about it, assertable without starting a process. The
/// flags mirror `PeerHelperOptions.parse` exactly; the two are a contract
/// between two targets that do not share a type (the helper deliberately links
/// only `TBDShared`), so the argv shape is pinned by a test on each side.
public struct ShadowPeerHelperInvocation: Sendable, Equatable {
    /// The handle the **provider** minted for the remote session this shadow
    /// stands for. Never a socket path, and never persisted past this
    /// connection: a handle means nothing outside the stream that announced it.
    public let handle: String
    /// `<provider>:<worktree display name>`, composed by the daemon.
    public let name: String
    /// The remote session's status, verbatim from its own registry row.
    public let status: String
    /// The peer protocol the link negotiated.
    public let peerProtocol: Int
    /// A directory that exists on **this** machine — the worktree the remote
    /// session was adopted into. A remote path resolves to nothing here, and a
    /// surface that filters on the directory existing would drop the shadow.
    public let cwd: String
    /// Where the shadow binds its socket. Injected so a test never binds into
    /// the `/tmp/cc-socks` every real session on this machine reads.
    public let socketDirectory: URL
    /// The registry directory the record is published in. Injected for the same
    /// reason.
    public let sessionsDirectory: URL
    /// A stable session id across the shadow's whole life, so a status rewrite
    /// does not republish the peer under a fresh identity.
    public let sessionID: String
    /// The agent version, when the far side reported one. Omitted rather than
    /// fabricated — see `ShadowPeerRecord.version`.
    public let version: String?

    public init(
        handle: String, name: String, status: String, peerProtocol: Int, cwd: String,
        socketDirectory: URL, sessionsDirectory: URL, sessionID: String,
        version: String? = nil
    ) {
        self.handle = handle
        self.name = name
        self.status = status
        self.peerProtocol = peerProtocol
        self.cwd = cwd
        self.socketDirectory = socketDirectory
        self.sessionsDirectory = sessionsDirectory
        self.sessionID = sessionID
        self.version = version
    }

    /// The helper's argv, without `argv[0]`.
    ///
    /// **`--handle` leads, because argv is a user-visible surface here.** The
    /// design requires distinctive argv so `ps` reads sanely and no pattern
    /// kill takes out a sibling, and `--handle <handle>` is the discriminator
    /// to match on — never the executable name, which every shadow on the
    /// machine shares.
    public var arguments: [String] {
        var argv = [
            "--handle", handle,
            "--name", name,
            "--status", status,
            "--peer-protocol", String(peerProtocol),
            "--cwd", cwd,
            "--socket-dir", socketDirectory.path,
            "--sessions-dir", sessionsDirectory.path,
            "--session-id", sessionID,
        ]
        if let version {
            argv.append(contentsOf: ["--version", version])
        }
        return argv
    }
}

// MARK: - Seams

/// How a helper's life ended, and therefore **whether its own cleanup ran**.
///
/// The distinction is load-bearing rather than diagnostic. `TBDPeerHelper`
/// unlinks its socket and its record from `defer` blocks, and stdin EOF,
/// `SIGTERM`, `SIGINT` and `SIGHUP` all reach them — the helper's signal
/// handler pokes a self-pipe and shuts down through the same path every other
/// exit takes. `SIGKILL` and a crash reach none of them, so both file artifacts
/// stay on disk after the process is gone.
///
/// The owner needs that answer because it is what decides whether the
/// reclaimer's whitelist row may be retired: a row retired after an unclean
/// exit is the entry that named the two files nothing on the machine can
/// recognise afterwards, and the reconciler is forbidden from finding them by
/// inference.
public enum ShadowPeerHelperTermination: Sendable, Equatable {
    /// The process exited through its own shutdown path, so its socket and
    /// record are already unlinked.
    case clean
    /// The process was `SIGKILL`ed, died on an uncaught signal, or is still
    /// running past every escalation. Its socket and record — if it got as far
    /// as creating them — are still on disk and are the reconciler's to reclaim.
    case unclean
}

/// One running helper, as its owner sees it.
///
/// The manager holds this and nothing about `Process`, so every routing,
/// handle-table and attribution decision in `ShadowPeerManager` is drivable
/// from a fake without spawning anything or binding a socket.
public protocol ShadowPeerHelperHandle: Sendable {
    /// The helper's own real pid. The record it publishes is filed under this,
    /// and a reclaimer recognises the process by it.
    var pid: pid_t { get }
    /// The socket the helper bound — `<socketDirectory>/<pid>.sock`. **Local,
    /// and it stays local**: it is the reply path stamped into an inbound
    /// message's attribution, and it never travels on the wire.
    var socketPath: String { get }
    /// The record the helper published, so a reclaimer's whitelist can name it.
    var recordPath: String { get }
    /// Frames the helper wrote on its stdout — inbound messages from local
    /// sessions addressed to this shadow. Finishes when the helper exits.
    var lines: AsyncStream<String> { get }
    /// Write one control frame to the helper's stdin. Non-blocking: a write
    /// that would block fails the frame rather than parking the caller.
    ///
    /// **All-or-nothing at the stream level.** A frame that reaches the pipe
    /// only in part cannot be un-written, and the bytes on it are the head of a
    /// line the helper will never see terminated — so a short write retires the
    /// stdin channel outright, and every later `send` fails with `stdinGone`
    /// rather than appending a second frame onto a truncated line.
    func send(_ frame: PeerBridgeFrame) async throws
    /// Close stdin and make sure the process is gone before returning. Stdin
    /// EOF is the load-bearing signal — the kernel delivers it even to a
    /// `SIGKILL`ed daemon's children — and the signal escalation behind it is
    /// only for a helper that ignores it.
    ///
    /// **Returns whether the helper cleaned up after itself**, because the
    /// caller cannot tell from the outside and gets the decision wrong in the
    /// unrecoverable direction: a `SIGKILL`ed helper runs no `defer`, so its
    /// socket and record outlive it, and a caller that assumed otherwise would
    /// retire the only whitelist row naming them.
    @discardableResult
    func terminate() async -> ShadowPeerHelperTermination
}

/// Starts one helper.
public protocol ShadowPeerHelperSpawning: Sendable {
    func spawn(_ invocation: ShadowPeerHelperInvocation) async throws -> any ShadowPeerHelperHandle
}

/// Failures starting or driving a helper.
public enum ShadowPeerHelperError: LocalizedError, Equatable, Sendable {
    case executableMissing(path: String)
    case spawnFailed(handle: String, detail: String)
    case stdinGone(handle: String)
    case stdinWouldBlock(handle: String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "TBDPeerHelper is not at \(path); no shadow peer can be published without it"
        case .spawnFailed(let handle, let detail):
            return "could not spawn the shadow peer helper for \(handle): \(detail)"
        case .stdinGone(let handle):
            return "the shadow peer helper for \(handle) is gone; its stdin is closed"
        case .stdinWouldBlock(let handle):
            return "the shadow peer helper for \(handle) is not draining its stdin; frame dropped rather than parking the daemon"
        }
    }
}

// MARK: - Production spawner

/// Spawns real `TBDPeerHelper` processes.
public struct ShadowPeerHelperProcessSpawner: ShadowPeerHelperSpawning {
    /// Where the helper binary lives. Defaults to the daemon's own directory:
    /// SwiftPM builds both into the same `.build/debug`, and `restart.sh`
    /// stages them together, so a sibling lookup is the same resolution
    /// `CLIInstaller.cliPath(forDaemonExecutable:)` already does for `TBDCLI`.
    public let executablePath: String
    /// Grace between stdin EOF and SIGTERM, and between SIGTERM and SIGKILL.
    private let exitGrace: Duration
    private let clock: any Clock<Duration>

    public init(
        executablePath: String = ShadowPeerHelperProcessSpawner.defaultExecutablePath,
        exitGrace: Duration = .milliseconds(500),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.executablePath = executablePath
        self.exitGrace = exitGrace
        self.clock = clock
    }

    /// `TBDPeerHelper` next to the running daemon binary, resolved through
    /// argv[0] with symlinks followed — the same resolution the daemon already
    /// uses to find `TBDCLI`.
    public static let defaultExecutablePath: String = {
        let daemon: URL
        if let argv0 = CommandLine.arguments.first, !argv0.isEmpty {
            let base = argv0.hasPrefix("/")
                ? URL(fileURLWithPath: argv0)
                : URL(fileURLWithPath: argv0,
                      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            daemon = base.resolvingSymlinksInPath().standardizedFileURL
        } else {
            daemon = URL(fileURLWithPath: "TBDDaemon")
        }
        return daemon.deletingLastPathComponent()
            .appendingPathComponent("TBDPeerHelper").path
    }()

    public func spawn(
        _ invocation: ShadowPeerHelperInvocation
    ) async throws -> any ShadowPeerHelperHandle {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ShadowPeerHelperError.executableMissing(path: executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = invocation.arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        let reader = ShadowPeerLineReader(continuation: continuation)
        let readHandle = stdoutPipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            if !reader.readAvailable(from: handle) {
                handle.readabilityHandler = nil
                reader.finish(handle: handle)
            }
        }

        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            reader.finish(handle: readHandle)
            throw ShadowPeerHelperError.spawnFailed(
                handle: invocation.handle, detail: String(describing: error))
        }

        return ShadowPeerHelperProcess(
            handle: invocation.handle,
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdoutHandle: readHandle,
            reader: reader,
            lines: lines,
            socketPath: invocation.socketDirectory
                .appendingPathComponent("\(process.processIdentifier).sock").path,
            recordPath: invocation.sessionsDirectory
                .appendingPathComponent("\(process.processIdentifier).json").path,
            exitGrace: exitGrace,
            clock: clock)
    }
}

/// One live `TBDPeerHelper`.
final class ShadowPeerHelperProcess: ShadowPeerHelperHandle, @unchecked Sendable {
    let pid: pid_t
    let socketPath: String
    let recordPath: String
    let lines: AsyncStream<String>

    private let handleName: String
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let reader: ShadowPeerLineReader
    private let exitGrace: Duration
    private let clock: any Clock<Duration>

    /// Everything `send` and `terminate` race each other over. Scoped locking
    /// rather than a bare `NSLock`: both callers are `async`, where
    /// `lock()`/`unlock()` are unavailable, and `withLock` releases on the
    /// throwing path in `send` for free.
    private struct StdinState {
        var closed = false
    }
    private let stdinState = OSAllocatedUnfairLock(initialState: StdinState())

    init(
        handle: String, process: Process, stdin: FileHandle, stdoutHandle: FileHandle,
        reader: ShadowPeerLineReader, lines: AsyncStream<String>,
        socketPath: String, recordPath: String,
        exitGrace: Duration, clock: any Clock<Duration>
    ) {
        self.handleName = handle
        self.process = process
        self.stdinHandle = stdin
        self.stdoutHandle = stdoutHandle
        self.reader = reader
        self.lines = lines
        self.pid = process.processIdentifier
        self.socketPath = socketPath
        self.recordPath = recordPath
        self.exitGrace = exitGrace
        self.clock = clock
        // Non-blocking from here on: `EAGAIN` means the helper has stopped
        // draining — a frame to drop, never a reason to park the daemon's
        // whole shadow-peer actor on a wedged child. A message frame can carry
        // a body far larger than the pipe buffer, so the write may also stop
        // part-way through one; `send` treats that as fatal to the stream for
        // the reason spelled out there.
        let fd = stdin.fileDescriptor  // the parameter, not Darwin's `stdin` global
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    func send(_ frame: PeerBridgeFrame) async throws {
        let line = try PeerBridgeFrameCodec.encodeLine(frame)
        try stdinState.withLock { state in
            guard !state.closed else {
                throw ShadowPeerHelperError.stdinGone(handle: self.handleName)
            }
            let data = Data(line.utf8)
            var offset = 0
            do {
                try data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    while offset < raw.count {
                        let written = Darwin.write(
                            self.stdinHandle.fileDescriptor, base.advanced(by: offset),
                            raw.count - offset)
                        if written > 0 {
                            offset += written
                            continue
                        }
                        if written < 0 && errno == EINTR { continue }
                        if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                            throw ShadowPeerHelperError.stdinWouldBlock(handle: self.handleName)
                        }
                        throw ShadowPeerHelperError.stdinGone(handle: self.handleName)
                    }
                }
            } catch {
                // **A partly-written frame poisons the stream, so the pipe is
                // dead rather than merely busy.** The fd is `O_NONBLOCK`, and a
                // non-blocking pipe accepts a *prefix* of a large write when its
                // buffer fills mid-frame — a message body may be up to
                // `PeerBridgeFrameCodec.maxFrameBytes`, so this is reachable
                // rather than theoretical. What is already on the pipe is then
                // the head of an NDJSON line that will never get its newline,
                // and a later `send` would append a whole frame directly onto
                // it: the helper reads one merged line and every frame after it
                // is misaligned. There is no way to take those bytes back, so
                // `closed` latches here and every subsequent `send` fails fast
                // with `stdinGone` instead of splicing onto a truncated line.
                if offset > 0 { state.closed = true }
                throw error
            }
        }
    }

    @discardableResult
    func terminate() async -> ShadowPeerHelperTermination {
        // The state transition is guarded; the `close()` deliberately is not —
        // no I/O while holding the lock.
        let needsClose = stdinState.withLock { state -> Bool in
            let alreadyClosed = state.closed
            state.closed = true
            return !alreadyClosed
        }
        if needsClose {
            try? stdinHandle.close()
        }

        // Stdin EOF is the mechanism; the escalation below is the backstop for
        // a helper wedged somewhere it cannot notice. `SIGTERM` is still clean:
        // the helper's handler pokes a self-pipe and its poll loop shuts down
        // through the same `defer`s stdin EOF reaches.
        if process.isRunning {
            try? await clock.sleep(for: exitGrace)
        }
        if process.isRunning {
            shadowPeerLogger.debug("""
                shadow peer helper \(self.handleName, privacy: .public) outlived its stdin \
                close; sending SIGTERM
                """)
            kill(pid, SIGTERM)
            try? await clock.sleep(for: exitGrace)
        }
        var forced = false
        if process.isRunning {
            shadowPeerLogger.error("""
                shadow peer helper \(self.handleName, privacy: .public) ignored SIGTERM; \
                escalating to SIGKILL. Its record and socket are now the reconciler's to \
                reclaim
                """)
            kill(pid, SIGKILL)
            forced = true
            // Waited out so `terminationReason` is readable and the answer
            // describes a process that is really gone. `SIGKILL` is delivered
            // synchronously but the exit is not observable until the kernel has
            // reaped the child.
            try? await clock.sleep(for: exitGrace)
        }
        stdoutHandle.readabilityHandler = nil
        reader.finish(handle: stdoutHandle)
        return outcome(forced: forced)
    }

    /// **Unclean unless the exit is provably clean.** Every ambiguity resolves
    /// to `.unclean`, and the asymmetry is deliberate: an unclean answer costs
    /// one extra sweep over a row whose artifacts are already gone, while a
    /// wrongly-clean answer retires the row that names two files nothing can
    /// recognise afterwards.
    private func outcome(forced: Bool) -> ShadowPeerHelperTermination {
        guard !process.isRunning else { return .unclean }
        guard !forced else { return .unclean }
        // Covers the crash as well as our own escalation: a helper that died on
        // `SIGSEGV` ran no `defer` either.
        return process.terminationReason == .uncaughtSignal ? .unclean : .clean
    }
}

// MARK: - Line reading

/// Turns a helper's stdout into an ordered stream of complete lines.
///
/// The `readabilityHandler` shape rather than `FileHandle.bytes.lines`, for the
/// hazard `ProviderEventsSupervisor.PipeLineReader` documents: on Darwin,
/// closing an fd out from under a thread parked in `read(2)` does not wake that
/// thread, and the fd *number* is then free for another consumer in this
/// process to claim. A readability handler only ever reads when bytes or EOF
/// are already waiting, so no thread is ever parked at close time.
final class ShadowPeerLineReader: @unchecked Sendable {
    /// The frame cap, which is also the point past which an un-newlined buffer
    /// can never become a frame this build would accept. Discarded whole rather
    /// than grown without bound.
    private static let maxPendingBytes = PeerBridgeFrameCodec.maxFrameBytes

    private let lock = NSLock()
    private let continuation: AsyncStream<String>.Continuation
    private var pending = Data()
    private var finished = false
    private var loggedOverflow = false

    init(continuation: AsyncStream<String>.Continuation) {
        self.continuation = continuation
    }

    /// Returns false at EOF or after `finish`, so the caller detaches itself.
    func readAvailable(from handle: FileHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return false }
        emitLinesLocked(from: chunk)
        return true
    }

    /// Drains what is already buffered without blocking, closes the read end,
    /// and finishes the stream. Idempotent.
    func finish(handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                emitLinesLocked(from: Data(chunk.prefix(count)))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
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
            // Failable rather than lossy: message content passes byte-verbatim,
            // so a line that is not UTF-8 is dropped rather than re-encoded
            // with replacement characters into something nobody wrote.
            if let line = String(data: lineData, encoding: .utf8) {
                continuation.yield(line)
            }
        }
        pending = Data(pending)
        if pending.count > Self.maxPendingBytes {
            if !loggedOverflow {
                loggedOverflow = true
                shadowPeerLogger.error("""
                    a shadow peer helper buffered \(self.pending.count, privacy: .public) bytes \
                    with no newline (cap \(Self.maxPendingBytes, privacy: .public)); discarding
                    """)
            }
            pending.removeAll()
        }
    }
}
