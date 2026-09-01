import Darwin
import Foundation
import TBDShared
import os

/// One holder process owns one session's pty master for that session's whole
/// life, and hands `dup`s of it out over a Unix socket.
///
/// The single invariant everything else rests on: **the holder never `read()`s
/// the master.** The only operations it performs on that descriptor are `dup`
/// (hand-over), `ioctl` (size), `write` (input) and `close` (forget). A byte
/// the holder consumed is a byte no reader can ever see again, and there is no
/// way to put it back.
///
/// The holder is deliberately single-threaded. `forkpty` is a `fork`, and a
/// `fork` in a multithreaded process gives the child one thread plus whatever
/// locks the others happened to hold — which is how a child deadlocks inside
/// `malloc` before it ever reaches `execve`. Reaping is therefore a `WNOHANG`
/// `waitpid` inside the same `poll` loop that serves clients, not a thread
/// blocked in `waitpid`: no thread means no window in which one could exist.
/// Writes one line to the holder's stderr, which the spawner redirects to a
/// per-session log file and reads back when a spawn fails.
///
/// `write(2)` rather than `FileHandle`, and a monotonic-free timestamp rather
/// than a formatter, because these lines exist to describe a process that may
/// be in trouble: the fewer subsystems a breadcrumb needs, the more failures it
/// survives. It is also the reason the holder's log is never empty in a healthy
/// run — an empty log is now itself a finding.
func holderTrace(_ message: String) {
    var elapsed = timeval()
    gettimeofday(&elapsed, nil)
    let line = Array(
        String(format: "TBDHolder [%ld.%06d]: %@\n", elapsed.tv_sec, elapsed.tv_usec, message).utf8)
    line.withUnsafeBufferPointer { _ = write(2, $0.baseAddress, $0.count) }
}

final class Holder {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    /// How long a holder whose child has exited keeps its socket bound waiting
    /// for somebody to come and collect the status.
    ///
    /// The trade-off it encodes, in both directions:
    ///
    ///   - **Long enough** that a daemon which was restarting when the job
    ///     finished can come back, connect, and be told what happened. Ten
    ///     seconds comfortably covers a daemon relaunch, which is the case this
    ///     window exists for.
    ///   - **Short enough** that nothing lingers. A holder past this point has
    ///     no job, no reader and nothing left to say; every extra second is a
    ///     process and a bound socket that some reconciler would otherwise have
    ///     to reclaim.
    ///
    /// What is lost when it expires is bounded and honest: the holder unlinks
    /// its rendezvous and goes, so whoever asks later learns the session is
    /// gone but not how it ended — the status reads `exitedStatusUnknown`
    /// rather than a fabricated code. An invented exit code would be
    /// indistinguishable downstream from one the job really returned, which is
    /// strictly worse than admitting the status was never collected.
    static let defaultExitReportTimeout: Duration = .seconds(10)

    private let arguments: HolderArguments
    private let exitReportTimeout: Duration
    private let clock: any Clock<Duration>

    init(
        arguments: HolderArguments,
        exitReportTimeout: Duration = Holder.defaultExitReportTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.arguments = arguments
        self.exitReportTimeout = exitReportTimeout
        self.clock = clock
    }

    /// Runs the holder to completion and returns the process exit code.
    ///
    /// Ordering here is the contract, not a preference:
    ///
    ///   1. `setsid()` first, so a Ctrl-C aimed at whatever spawned us cannot
    ///      reach the holder and strand every session on the machine.
    ///   2. `SIGHUP`/`SIGPIPE` to `SIG_IGN`, so the spawner's death — or a
    ///      `sendmsg` into a peer that just went away — is not ours.
    ///   3. adopt the inherited creation-lock descriptor. We never *take* the
    ///      lock: the spawner already holds it and passed it by number.
    ///   4. bind and listen.
    ///   5. `forkpty`, before any thread could exist.
    ///   6. serve.
    func run() throws -> Int32 {
        // Detaching the session is what makes a holder survive its spawner's
        // terminal. `setsid` fails with EPERM when we are already a process
        // group leader, which is a fine state to be in — it is only worth a
        // debug line, never a failure.
        if setsid() == -1 {
            Self.logger.debug("setsid failed (errno \(errno, privacy: .public)); already a session leader")
        }
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        // The lock arrives as a descriptor number the spawner dup2'd into
        // place. It must be above stdio: `forkpty` dup2s the pty slave onto
        // 0/1/2 in the child, so a lock parked on one of those would be
        // silently overwritten and the lock's whole contract would be a lie.
        guard arguments.lockFD > 2, fcntl(arguments.lockFD, F_GETFD) >= 0 else {
            throw HolderStartupError.invalidLockDescriptor(arguments.lockFD)
        }

        // Two breadcrumbs around the one step whose success the daemon judges
        // by looking at the filesystem. An absent socket plus "binding" means
        // the holder reached `bind` and did not finish; an absent socket with
        // no line at all means it never got this far. The daemon cannot tell
        // those apart from the outside, and they are different bugs.
        holderTrace("binding \(arguments.socketPath)")
        let listenFD = try bindListener(at: arguments.socketPath)
        holderTrace("bound \(arguments.socketPath); forking the job")
        var socketIsBound = true
        defer {
            if socketIsBound {
                close(listenFD)
                unlink(arguments.socketPath)
            }
        }

        let child = try spawnChild(listenFD: listenFD)
        Self.logger.info(
            """
            holder up: session \(self.arguments.sessionID.uuidString, privacy: .public) \
            pid \(child.pid, privacy: .public) tty \(child.ttyName, privacy: .public)
            """)

        let code = serve(listenFD: listenFD, child: child)
        socketIsBound = false
        close(listenFD)
        unlink(arguments.socketPath)
        return code
    }

    // MARK: - Rendezvous

    private func bindListener(at path: String) throws -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw HolderStartupError.socketDirectoryUnavailable(path: directory, errno: errno)
        }

        guard path.utf8.count < HolderRendezvous.sunPathLimit else {
            throw HolderStartupError.socketPathTooLong(path: path, limit: HolderRendezvous.sunPathLimit)
        }

        // Unlinking a socket path is only ever safe for the process that holds
        // the creation lock for it, and we do — the spawner took it and handed
        // us the descriptor. `bind` refuses an existing path, and the corpse of
        // a SIGKILLed holder looks exactly like a live one from the filesystem.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HolderStartupError.cannotBind(path: path, errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { chars in
                    _ = strlcpy(chars, source, sunPathSize)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) { addressPtr in
            addressPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let saved = errno
            close(fd)
            throw HolderStartupError.cannotBind(path: path, errno: saved)
        }
        guard listen(fd, 8) == 0 else {
            let saved = errno
            close(fd)
            unlink(path)
            throw HolderStartupError.cannotListen(path: path, errno: saved)
        }
        return fd
    }

    // MARK: - The job

    /// `ptyFD` is the pty **master**. Declarations spell it `ptyFD` for the
    /// same reason the wire verbs are `handOverPTY`/`handedOverPTY`: SwiftLint's
    /// `inclusive_language` rule refuses the POSIX word in a declaration, and a
    /// suppression on the central noun of this design is worse than a name
    /// whose doc comment says exactly which end of the pty it is. Prose keeps
    /// saying "pty master", because that is what `forkpty` calls it.
    private struct SpawnedChild {
        var pid: pid_t
        var ptyFD: Int32
        var ttyName: String
    }

    private func spawnChild(listenFD: Int32) throws -> SpawnedChild {
        let launch = arguments.launch

        // EVERY allocation happens here, before the fork. Between `forkpty`
        // and `execve` only async-signal-safe calls are legal, and `strdup`,
        // `malloc` and every Swift string operation are not.
        let executablePath = strdup(launch.executable)
        let workingDirectory = strdup(launch.workingDirectory)
        let argv = Self.makeCArray([launch.executable] + launch.arguments)
        // Sorted purely so a holder's environment is reproducible in a log or
        // a crash report; the child cannot observe the order.
        let envp = Self.makeCArray(launch.environment.map { "\($0.key)=\($0.value)" }.sorted())
        let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Self.ttyNameCapacity)
        nameBuffer.initialize(repeating: 0, count: Self.ttyNameCapacity)
        defer {
            free(executablePath)
            free(workingDirectory)
            Self.freeCArray(argv)
            Self.freeCArray(envp)
            nameBuffer.deallocate()
        }

        // Passed to `forkpty` AND re-applied below. `forkpty` sizes the pty
        // before the child exists, which closes the window where a job reads
        // 0x0 and lays itself out for a zero-column terminal; the explicit
        // `ioctl` is what the rest of the system uses to resize, so going
        // through it once here keeps one code path for "the size is now this".
        var size = winsize(
            ws_row: launch.rows, ws_col: launch.columns, ws_xpixel: 0, ws_ypixel: 0)
        var primaryFD: Int32 = -1
        // Read into locals BEFORE the fork, for the same reason the C strings
        // are built here: a Swift `static let` is a lazy global behind
        // `swift_once`, and touching one for the first time in a forked child
        // can deadlock on a lock another thread held at fork time.
        let lockFD = arguments.lockFD
        let chdirFailure = Self.chdirFailureExitCode
        let execFailure = Self.execFailureExitCode
        let descriptorCeiling = Self.descriptorCeiling()

        let pid = forkpty(&primaryFD, nameBuffer, nil, &size)
        if pid == 0 {
            // ---- CHILD. Async-signal-safe calls only, and no `defer`: the
            // `_exit`s below deliberately skip Swift cleanup.

            // `SIG_IGN` is inherited across fork AND exec, so without this the
            // job would start life with SIGPIPE ignored — `yes | head` spins
            // instead of dying, and nothing hangs up on a lost terminal.
            // `signal(2)` is async-signal-safe, so it is legal in this window.
            signal(SIGHUP, SIG_DFL)
            signal(SIGPIPE, SIG_DFL)

            // **A job gets a terminal and nothing else.** Everything above
            // stdio is closed, and two of those descriptors are the reason the
            // sweep exists rather than a pair of named closes:
            //
            //   - `lockFD`, the creation lock. `flock` lives on the open file
            //     description, so a job that inherits the descriptor holds the
            //     lock — and keeps holding it after the holder is SIGKILLed.
            //     Both halves of the lock's contract break at once: the kernel
            //     no longer drops it when the holder dies, and a respawn sees
            //     `.alreadyHeld` forever with no holder alive to explain it.
            //   - `listenFD`, the rendezvous socket, which a job would
            //     otherwise keep alive past the holder's exit.
            //
            // Naming only those two is not enough, because the holder does not
            // know what its spawner leaked into it: anything the spawner had
            // open without `FD_CLOEXEC` arrives here unannounced and would then
            // outlive the whole chain in a job nobody associates with it. That
            // is not hypothetical — this repo's own build wrapper holds a
            // machine-global `flock`, and a `sleep` job that inherited it went
            // on blocking every other worktree's build after its holder, its
            // test process and its harness were all gone.
            //
            // `close(2)` is async-signal-safe, and the ceiling was read before
            // the fork because `getrlimit` is not.
            close(lockFD)
            close(listenFD)
            var descriptor: Int32 = 3
            while descriptor < descriptorCeiling {
                close(descriptor)
                descriptor += 1
            }

            if chdir(workingDirectory) != 0 { _exit(chdirFailure) }
            execve(executablePath, argv, envp)
            _exit(execFailure)
        }
        guard pid > 0 else { throw HolderStartupError.forkFailed(errno: errno) }

        var applied = size
        if ioctl(primaryFD, TIOCSWINSZ, &applied) != 0 {
            Self.logger.error("TIOCSWINSZ failed (errno \(errno, privacy: .public))")
        }
        return SpawnedChild(pid: pid, ptyFD: primaryFD, ttyName: String(cString: nameBuffer))
    }

    // MARK: - Serving

    // swiftlint:disable:next function_body_length - one poll loop; splitting it
    // would scatter the state machine across helpers that each need all of it.
    private func serve(listenFD: Int32, child: SpawnedChild) -> Int32 {
        var ptyFD = child.ptyFD
        var status: HolderChildStatus = .alive
        var clientFD: Int32 = -1
        var inbox = Data()
        var forgotten = false
        /// The terminal status has actually **reached** a client — either
        /// pushed at one that was already connected when the child exited, or
        /// carried back as the answer to that client's own request. It is what
        /// ends the holder's life, so it is set only after a successful send: a
        /// send that failed collected nothing, and the window must stay open
        /// for whoever connects next.
        var exitCollected = false
        var window = ExitReportWindow(limit: exitReportTimeout, clock: clock)

        func describe() -> HolderChildDescription {
            HolderChildDescription(
                childPID: child.pid,
                ttyName: child.ttyName,
                status: status,
                launch: arguments.launch,
                owner: arguments.owner)
        }

        func dropClient() {
            if clientFD >= 0 { close(clientFD) }
            clientFD = -1
            inbox = Data()
        }

        /// Push the terminal status at a client that was **already connected**
        /// when the child exited. There is no separate "exited" verb on the
        /// wire: the description already carries the status, and an unsolicited
        /// `.described` frame is what a reader blocked on the pty needs to see
        /// to stop waiting.
        ///
        /// It is called from the reaping branch alone, and that restriction is
        /// the whole contract: **the holder never speaks first to a client that
        /// arrives after the child is gone.** Greeting one at accept time put a
        /// frame nobody asked for where that client's first response belongs —
        /// its `handOverPTY` came back as a bare `.described` with no
        /// descriptor — and the collection that frame recorded then tore the
        /// connection down before the request was ever read. That is exactly
        /// the shape of a daemon reconnecting after a restart to collect a
        /// finished job's status, so it silently broke the primary
        /// re-adoption path. Such a client is served instead; see the request
        /// loop below.
        func pushExitToConnectedClient() {
            guard status != .alive, clientFD >= 0, !exitCollected else { return }
            guard let frame = try? HolderFraming.frame(.described(describe())) else { return }
            do {
                try FDChannel.sendData(frame, over: clientFD)
                exitCollected = true
            } catch {
                Self.logger.error(
                    "could not report exit to the connected client: \(error.localizedDescription, privacy: .public)")
                dropClient()
            }
        }

        /// Records that an answer we just sent carried the terminal status, so
        /// the loop can wind the holder down. A response about a live child
        /// collects nothing and leaves the holder serving.
        func noteAnswerCarriedTheStatus() {
            if status != .alive { exitCollected = true }
        }

        while true {
            if case .alive = status {
                var raw: Int32 = 0
                let reaped = waitpid(child.pid, &raw, WNOHANG)
                if reaped == child.pid {
                    status = Self.status(fromWaitpidStatus: raw)
                    window.arm()
                    Self.logger.info(
                        "child \(child.pid, privacy: .public) exited: \(String(describing: status), privacy: .public)")
                    pushExitToConnectedClient()
                } else if reaped < 0 && errno != EINTR {
                    // We can no longer observe the child at all. Say exactly
                    // that — a fabricated exit code would be indistinguishable
                    // from a real one to everything downstream.
                    status = .exitedStatusUnknown
                    window.arm()
                    Self.logger.error("waitpid failed (errno \(errno, privacy: .public))")
                    pushExitToConnectedClient()
                }
            }

            if forgotten { break }
            // Once the status has reached somebody the holder has nothing left
            // to do, and the armed window bounds the wait for anyone at all.
            // Both halves must read `exitCollected` as "a client has actually
            // been answered": a flag set by an unsolicited greeting would break
            // here before that client's own request was ever read.
            if window.isArmed && (exitCollected || window.isExpired) { break }

            var watched = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)]
            if clientFD >= 0 {
                watched.append(pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0))
            }
            var ready: Int32 = 0
            // The window only charges while it is armed, so the ordinary
            // serving loop runs untimed and a holder whose child has exited
            // starts burning its grace period from that moment.
            window.charging {
                ready = poll(&watched, nfds_t(watched.count), Self.pollSliceMilliseconds)
            }
            if ready < 0 && errno != EINTR {
                Self.logger.error("poll failed (errno \(errno, privacy: .public))")
            }
            guard ready > 0 else { continue }

            if clientFD >= 0, watched.count > 1, watched[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                switch readRequests(from: clientFD, into: &inbox) {
                case .closed:
                    dropClient()
                case .requests(let requests):
                    for request in requests {
                        switch request {
                        case .describe:
                            if send(.described(describe()), to: clientFD) {
                                noteAnswerCarriedTheStatus()
                            } else {
                                dropClient()
                            }
                        case .handOverPTY:
                            // A forgotten holder has no master left to hand
                            // over; it answers with the description instead of
                            // pretending the transfer happened.
                            //
                            // A holder whose child has **exited** still hands
                            // the master over, deliberately. The holder never
                            // read it, so everything the job wrote and nobody
                            // collected is still queued there and dies with the
                            // holder — and the description riding the same
                            // frame carries the terminal status, so no reader
                            // can mistake the child for alive. Answering
                            // `.described` instead would be a coherent reply
                            // too, but it would throw those bytes away.
                            let delivered = ptyFD >= 0
                                ? handOver(ptyFD, description: describe(), to: clientFD)
                                : send(.described(describe()), to: clientFD)
                            if delivered {
                                noteAnswerCarriedTheStatus()
                            } else {
                                dropClient()
                            }
                        case .forget:
                            _ = send(.forgotten, to: clientFD)
                            if ptyFD >= 0 { close(ptyFD) }
                            ptyFD = -1
                            forgotten = true
                            Self.logger.info(
                                "forgot session \(self.arguments.sessionID.uuidString, privacy: .public)")
                        }
                        if forgotten || clientFD < 0 { break }
                    }
                }
            }

            if watched[0].revents & Int16(POLLIN) != 0 {
                let incoming = accept(listenFD, nil, nil)
                if incoming >= 0 {
                    if clientFD >= 0 {
                        // Two readers on one pty master is silent byte theft:
                        // whichever `read` lands first wins the bytes and the
                        // other reader never learns they existed. So a second
                        // client is answered — with a version that can never
                        // be mistaken for a real one — and disconnected.
                        _ = send(.rejected(version: HolderProtocolVersion.busySentinel), to: incoming)
                        close(incoming)
                    } else {
                        // Nothing is sent here, even when the child is already
                        // gone. This client has asked nothing yet, and the next
                        // frame down this socket belongs to its first request.
                        clientFD = incoming
                    }
                }
            }

            if forgotten { break }
        }

        dropClient()
        if ptyFD >= 0 { close(ptyFD) }
        return 0
    }

    private enum ReadOutcome {
        case closed
        case requests([HolderRequest])
    }

    private func readRequests(from fd: Int32, into inbox: inout Data) -> ReadOutcome {
        var buffer = [UInt8](repeating: 0, count: Self.readChunkSize)
        let count = read(fd, &buffer, buffer.count)
        if count == 0 { return .closed }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { return .requests([]) }
            return .closed
        }
        inbox.append(contentsOf: buffer[0..<count])
        do {
            return .requests(try HolderFraming.drainRequests(from: &inbox))
        } catch {
            Self.logger.error(
                "unparseable request frame, dropping the client: \(error.localizedDescription, privacy: .public)")
            return .closed
        }
    }

    /// Returns `false` when the client is gone, so call sites can read as
    /// `send(…) || dropClient()`.
    @discardableResult
    private func send(_ response: HolderResponse, to fd: Int32) -> Bool {
        do {
            try FDChannel.sendData(try HolderFraming.frame(response), over: fd)
            return true
        } catch {
            Self.logger.error("send failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func handOver(_ ptyFD: Int32, description: HolderChildDescription, to fd: Int32) -> Bool {
        // A `dup`, never the original: the caller closes what it receives, and
        // the holder's own reference to the pty master has to outlive every
        // reader that ever attaches.
        let duplicate = dup(ptyFD)
        guard duplicate >= 0 else {
            Self.logger.error("dup of the pty master failed (errno \(errno, privacy: .public))")
            return send(.described(description), to: fd)
        }
        defer { close(duplicate) }
        do {
            let frame = try HolderFraming.frame(.handedOverPTY(description))
            try FDChannel.sendFDMinimal(duplicate, over: fd, payload: frame)
            return true
        } catch {
            Self.logger.error("hand-over failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Small helpers

    /// `<sys/wait.h>`'s `WIFEXITED`/`WEXITSTATUS` are function-like macros,
    /// which Swift does not import — this is their definition, spelled out.
    static func status(fromWaitpidStatus raw: Int32) -> HolderChildStatus {
        let terminatingSignal = raw & 0x7f
        guard terminatingSignal == 0 else {
            // Killed by a signal: there IS no exit code, so do not invent one.
            return .exitedStatusUnknown
        }
        return .exited(code: (raw >> 8) & 0xff)
    }

    /// One past the highest descriptor the child sweeps closed.
    ///
    /// Read in the parent because `getrlimit` is not async-signal-safe. Clamped
    /// because `RLIMIT_NOFILE` can be `RLIM_INFINITY`, and floored at 3 so a
    /// pathological limit cannot make the sweep touch stdio.
    private static func descriptorCeiling() -> Int32 {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return descriptorSweepCap }
        // The `<` also catches `RLIM_INFINITY`, whose Swift name the SDK does
        // not export ("macro unavailable: structure not supported") — it is
        // 2^63-1, so an unlimited soft limit clamps like any oversized one.
        let soft = limits.rlim_cur
        guard soft < rlim_t(descriptorSweepCap) else { return descriptorSweepCap }
        return max(3, Int32(soft))
    }

    /// 64Ki close() syscalls is a fraction of a millisecond, and no sane soft
    /// limit reaches it — this only bounds the pathological case.
    private static let descriptorSweepCap: Int32 = 65_536
    private static let ttyNameCapacity = 1024
    private static let readChunkSize = 4096
    private static let pollSliceMilliseconds: Int32 = 50
    private static let chdirFailureExitCode: Int32 = 126
    private static let execFailureExitCode: Int32 = 127

    private static func makeCArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, value) in strings.enumerated() {
            buffer[index] = strdup(value)
        }
        buffer[strings.count] = nil
        return buffer
    }

    private static func freeCArray(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var index = 0
        while let entry = array[index] {
            free(entry)
            index += 1
        }
        array.deallocate()
    }
}

// MARK: - Invocation

/// The parsed command line.
///
/// The lock arrives as a **descriptor number**, not a path. The spawner has
/// already taken the lock and `dup2`d it into the child; the holder adopts
/// that descriptor and holds it for life. A holder that only knew the path
/// could not name the inherited descriptor, and therefore could not keep it
/// out of the job — which is the one thing about the lock that must not
/// happen. The holder never calls `HolderLock.acquire` itself.
struct HolderArguments: Equatable {
    var sessionID: UUID
    var socketPath: String
    var lockFD: Int32
    var launch: HolderLaunchRequest
    /// Which TBD installation spawned us. Echoed in every description so
    /// reclamation can tell one of ours from a healthy stranger's. Optional on
    /// the command line so a holder launched by hand for diagnosis still runs.
    var owner: HolderOwnerToken

    static let usage = """
        usage: TBDHolder --session <uuid> --socket <path> --lock-fd <n> \
        --launch <base64-json> [--owner <token>]
        """

    /// `arguments` excludes argv[0].
    ///
    /// Unrecognised `--flags` are collected and ignored rather than refused, on
    /// purpose: a long-lived session keeps running the holder binary it was
    /// born with, so a newer daemon will one day pass a flag an older holder
    /// has never heard of. Refusing would turn "this holder predates the flag"
    /// into "this session cannot start". A bare word with no leading `--` is
    /// still an error, because that is a quoting mistake rather than a version
    /// skew.
    static func parse(_ arguments: [String]) throws -> HolderArguments {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else {
                throw HolderStartupError.unknownArgument(flag)
            }
            guard index + 1 < arguments.count else {
                throw HolderStartupError.missingValue(flag)
            }
            values[String(flag.dropFirst(2))] = arguments[index + 1]
            index += 2
        }

        func required(_ name: String) throws -> String {
            guard let value = values[name], !value.isEmpty else {
                throw HolderStartupError.missingArgument(name)
            }
            return value
        }

        let sessionText = try required("session")
        guard let sessionID = UUID(uuidString: sessionText) else {
            throw HolderStartupError.invalidSessionID(sessionText)
        }
        let lockText = try required("lock-fd")
        guard let lockFD = Int32(lockText) else {
            throw HolderStartupError.invalidLockDescriptorArgument(lockText)
        }
        let launchText = try required("launch")
        guard let launchData = Data(base64Encoded: launchText),
              let launch = try? JSONDecoder().decode(HolderLaunchRequest.self, from: launchData) else {
            throw HolderStartupError.invalidLaunchPayload
        }

        return HolderArguments(
            sessionID: sessionID,
            socketPath: try required("socket"),
            lockFD: lockFD,
            launch: launch,
            owner: HolderOwnerToken(rawValue: values["owner"] ?? ""))
    }
}

/// What a holder that died before it ever served anything exits with.
///
/// The split is the point. A spawner reading a holder's exit code has exactly
/// one decision to make — could retrying ever help? — and a single code for
/// every startup failure answers it wrongly half the time: it reads a full
/// disk or a rendezvous directory that momentarily did not exist as a mistake
/// in its own command line, and gives up on a session that a second attempt
/// would have started.
enum HolderExitCode {
    /// The invocation was wrong: a missing or malformed flag, a lock
    /// descriptor the spawner never placed, a socket path that cannot fit in
    /// `sun_path`. The same command line will fail the same way forever, so
    /// the spawner must fix its arguments or give up. Retrying is pointless.
    static let badInvocation: Int32 = 2
    /// The machine refused: no rendezvous directory, a socket that would not
    /// bind or listen, a `forkpty` that failed. Nothing about the invocation
    /// is wrong, so a later attempt on a healthier machine can succeed.
    static let environmentFailure: Int32 = 3
    /// Something that is neither — an error `run()` did not classify.
    static let unexpected: Int32 = 1
}

enum HolderStartupError: LocalizedError, Equatable {
    case unknownArgument(String)
    case missingValue(String)
    case missingArgument(String)
    case invalidSessionID(String)
    case invalidLaunchPayload
    case invalidLockDescriptorArgument(String)
    case invalidLockDescriptor(Int32)
    case socketPathTooLong(path: String, limit: Int)
    case socketDirectoryUnavailable(path: String, errno: Int32)
    case cannotBind(path: String, errno: Int32)
    case cannotListen(path: String, errno: Int32)
    case forkFailed(errno: Int32)

    /// The process exit code this failure ends the holder with.
    ///
    /// Switched exhaustively with no `default`, so a new case cannot be added
    /// without deciding which side of the retry question it falls on.
    var exitCode: Int32 {
        switch self {
        case .unknownArgument, .missingValue, .missingArgument, .invalidSessionID,
             .invalidLaunchPayload, .invalidLockDescriptorArgument, .invalidLockDescriptor,
             .socketPathTooLong:
            return HolderExitCode.badInvocation
        case .socketDirectoryUnavailable, .cannotBind, .cannotListen, .forkFailed:
            return HolderExitCode.environmentFailure
        }
    }

    var errorDescription: String? {
        switch self {
        case .unknownArgument(let argument):
            return "unexpected argument \"\(argument)\"\n\(HolderArguments.usage)"
        case .missingValue(let flag):
            return "\(flag) needs a value\n\(HolderArguments.usage)"
        case .missingArgument(let name):
            return "--\(name) is required\n\(HolderArguments.usage)"
        case .invalidSessionID(let text):
            return "--session must be a UUID, got \"\(text)\""
        case .invalidLaunchPayload:
            return "--launch must be base64-encoded JSON for a HolderLaunchRequest"
        case .invalidLockDescriptorArgument(let text):
            return "--lock-fd must be a descriptor number, got \"\(text)\""
        case .invalidLockDescriptor(let fd):
            return "--lock-fd \(fd) is not an open descriptor above stdio; the "
                + "spawner must dup2 the held creation lock into place"
        case .socketPathTooLong(let path, let limit):
            return "holder socket path is \(path.utf8.count) bytes, over the "
                + "\(limit)-byte sun_path limit: \(path)"
        case .socketDirectoryUnavailable(let path, let errno):
            return "could not create the holder rendezvous directory \(path): "
                + "\(String(cString: strerror(errno))) (errno \(errno))"
        case .cannotBind(let path, let errno):
            return "could not bind the holder socket at \(path): "
                + "\(String(cString: strerror(errno))) (errno \(errno))"
        case .cannotListen(let path, let errno):
            return "could not listen on the holder socket at \(path): "
                + "\(String(cString: strerror(errno))) (errno \(errno))"
        case .forkFailed(let errno):
            return "forkpty failed: \(String(cString: strerror(errno))) (errno \(errno))"
        }
    }
}

// MARK: - The bounded wait for somebody to collect the exit status

/// The holder's one delay, and therefore the one thing that takes the clock.
///
/// It is duration-shaped rather than deadline-shaped on purpose: `any
/// Clock<Duration>` pins `Duration` but not `Instant`, so instant arithmetic
/// does not typecheck through the existential — and a limit expressed as
/// "how much time has been spent" is what a fake clock can drive.
struct ExitReportWindow {
    private let limit: Duration
    private let clock: any Clock<Duration>
    private var elapsed: Duration = .zero
    private(set) var isArmed = false

    init(limit: Duration, clock: any Clock<Duration>) {
        self.limit = limit
        self.clock = clock
    }

    var isExpired: Bool { isArmed && elapsed >= limit }

    /// Starts the clock. Before this the window never expires, so an ordinary
    /// holder serving a live child is untimed.
    mutating func arm() { isArmed = true }

    /// Runs `work`, charging its wall time against the limit once armed.
    mutating func charging(_ work: () -> Void) {
        let slice = clock.measure(work)
        if isArmed { elapsed += slice }
    }
}
