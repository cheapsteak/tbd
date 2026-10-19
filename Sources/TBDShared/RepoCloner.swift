import Darwin
import Foundation
import os

/// How a clone's git talks to the person waiting on it.
public enum CloneMode: Sendable {
    /// The CLI. git inherits the terminal: the person sees git's own progress,
    /// git can ask for a password, and Ctrl-C reaches it.
    case attachedToTerminal
    /// The app. Nobody can answer a prompt, so git gets `GIT_TERMINAL_PROMPT=0`,
    /// an empty stdin and no controlling terminal, and a clone that needs a
    /// login fails fast with git's own error instead of hanging.
    case noPrompt
}

public enum CloneOutcome: Equatable, Sendable {
    case succeeded
    /// When git ran, `lastErrorLines` holds the last five non-empty lines it
    /// wrote to stderr in `.noPrompt`, and is empty in `.attachedToTerminal`,
    /// where git wrote them to the terminal itself. When git never ran — the
    /// destination could not be created, or git could not be started —
    /// `exitCode` is 127 and `lastErrorLines` holds TBD's one-line reason, in
    /// either mode.
    case failed(exitCode: Int32, lastErrorLines: [String])
    case cancelled
    case refusedDestinationExists
}

/// One clone. The app holds it through this protocol so a test can stand in a
/// fake that never spawns git.
public protocol RepoCloning: AnyObject, Sendable {
    func run(onProgress: @escaping @Sendable (String) -> Void) async -> CloneOutcome
    /// Stops the clone. `run` then reports `.cancelled` — unless git had
    /// already finished, in which case the clone is complete and `run` still
    /// reports `.succeeded`.
    func cancel()
}

/// Runs one `git clone --progress <url> <destination>` — a full clone, not
/// shallow and without submodules, because TBD's branch and PR features need
/// the whole history.
///
/// **The destination is claimed before git starts, and the claim is what
/// licenses deleting it.** `run` creates `destination` with `mkdir`, which
/// fails with `EEXIST` if anything at all is already there; that is
/// `.refusedDestinationExists`. A check followed by git's own `mkdir` would
/// not do: whatever appeared between the two — another `tbd repo add` of the
/// same repository — would be deleted as this run's failed clone. git clones
/// into the empty folder this run owns and keeps that folder when it fails or
/// is signalled. After a cancel, `run` removes the folder and whatever git
/// left in it. After any other failure, `run` removes it only if git emptied
/// it: when a checkout or a `post-checkout` hook fails, git exits non-zero but
/// keeps the repository it fetched for the person to inspect, and so does TBD.
/// No other path ever deletes.
///
/// One instance runs one clone; call `run` once.
public final class RepoCloner: RepoCloning {
    public typealias CommandRunner = @Sendable (_ arguments: [String]) async -> (exitCode: Int32, stdout: String)?

    /// The argv that follows `/usr/bin/env`.
    private let arguments: [String]
    private let destination: String
    private let mode: CloneMode
    private let childEnvironment: [String: String]
    private let state = OSAllocatedUnfairLock(initialState: RunState())

    private struct RunState {
        var pid: pid_t?
        var cancelled = false
        /// Set the moment `waitpid` has reaped the child, after which its pid
        /// may belong to someone else and must never be signalled.
        var exited = false
    }

    /// Every clone running in this process, for `terminateAll()`.
    private static let liveClones = OSAllocatedUnfairLock(initialState: [pid_t: CloneMode]())

    public convenience init(url: String, destination: String, mode: CloneMode,
                            environment: [String: String] = ProcessInfo.processInfo.environment) {
        // `--` so a URL that starts with `-` reaches git as a URL, never as an
        // option such as `--upload-pack=`.
        self.init(arguments: ["git", "clone", "--progress", "--", url, destination],
                  destination: destination, mode: mode, environment: environment)
    }

    /// Test seam: argv run in place of `git clone --progress <url> <destination>`
    /// (still via /usr/bin/env, same env, fds and session handling).
    convenience init(command: [String], destination: String, mode: CloneMode,
                     environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(arguments: command, destination: destination, mode: mode, environment: environment)
    }

    private init(arguments: [String], destination: String, mode: CloneMode,
                 environment: [String: String]) {
        self.arguments = arguments
        self.destination = destination
        self.mode = mode
        self.childEnvironment = Self.environment(for: mode, inheriting: environment)
    }

    // MARK: - Environment

    /// `base` with `PATH` augmented by `ExecutableSearchPath` — the app can start
    /// with launchd's bare `PATH`, which would miss a Homebrew git — and, for
    /// `.noPrompt`, `GIT_TERMINAL_PROMPT=0`.
    public static func environment(for mode: CloneMode, inheriting base: [String: String]) -> [String: String] {
        var environment = withSearchPath(base)
        if mode == .noPrompt {
            environment["GIT_TERMINAL_PROMPT"] = "0"
        }
        return environment
    }

    private static func withSearchPath(_ base: [String: String]) -> [String: String] {
        var environment = base
        let home = base["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ExecutableSearchPath.augmented(base["PATH"], homeDirectory: home)
        return environment
    }

    // MARK: - GitHub short form

    /// `/usr/bin/env <arguments>` with the augmented `PATH`, returning the exit
    /// status and stdout; nil when the process cannot be launched at all.
    public static let defaultCommandRunner: CommandRunner = { arguments in
        await withCheckedContinuation { (continuation: CheckedContinuation<(exitCode: Int32, stdout: String)?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.environment = RepoCloner.withSearchPath(ProcessInfo.processInfo.environment)
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            let reader = output.fileHandleForReading
            process.terminationHandler = { finished in
                // Read after exit: the one caller reads a one-word setting, far
                // below a pipe's buffer, so the child never blocks on a reader.
                let data = reader.readDataToEndOfFile()
                continuation.resume(returning: (exitCode: finished.terminationStatus,
                                               stdout: String(bytes: data, encoding: .utf8) ?? ""))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// The clone URL for GitHub's `owner/repo`, chosen the way `gh repo clone`
    /// chooses: SSH when `gh config get git_protocol -h github.com` says `ssh`,
    /// HTTPS for any other answer, an error, or no `gh` at all.
    public static func githubCloneURL(owner: String, repo: String,
                                      run: CommandRunner = defaultCommandRunner) async -> String {
        let reply = await run(["gh", "config", "get", "git_protocol", "-h", "github.com"])
        if let reply, reply.exitCode == 0,
           reply.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ssh" {
            return "git@github.com:\(owner)/\(repo).git"
        }
        return "https://github.com/\(owner)/\(repo).git"
    }

    // MARK: - Running

    public func run(onProgress: @escaping @Sendable (String) -> Void) async -> CloneOutcome {
        if state.withLock({ $0.cancelled }) {
            return .cancelled
        }
        switch claimDestination() {
        case .claimed:
            break
        case .exists:
            return .refusedDestinationExists
        case .failed(let reason):
            return .failed(exitCode: 127, lastErrorLines: [reason])
        }
        // From here on, `destination` is the empty folder this run created —
        // the fact that lets `clone` remove it after a failure or a cancel.
        return await withTaskCancellationHandler {
            await self.clone(onProgress: onProgress)
        } onCancel: {
            self.cancel()
        }
    }

    /// Sends SIGTERM: to the clone's whole process group in `.noPrompt` (git and
    /// the transport helpers it started), to git alone in
    /// `.attachedToTerminal`, whose group is the terminal's. git stops on
    /// SIGTERM, and `run` removes the folder with whatever git kept in it and
    /// reports `.cancelled`. A clone that had already finished is complete, is
    /// kept, and still reports `.succeeded`.
    public func cancel() {
        let mode = self.mode
        state.withLock { run in
            run.cancelled = true
            if let pid = run.pid, !run.exited {
                Self.signalTerminate(pid: pid, mode: mode)
            }
        }
    }

    /// SIGTERM to every running clone, as `cancel()` would send it. For
    /// `applicationWillTerminate`, so git can empty its partial clones before
    /// the app is gone. It is not a cancel: a `run` that gets to return, which
    /// a quitting process may not reach, reports `.failed` and removes its
    /// folder only if git emptied it.
    public static func terminateAll() {
        liveClones.withLock { clones in
            for (pid, mode) in clones {
                Self.signalTerminate(pid: pid, mode: mode)
            }
        }
    }

    private static func signalTerminate(pid: pid_t, mode: CloneMode) {
        switch mode {
        case .noPrompt:
            // The child leads its own process group (POSIX_SPAWN_SETSID).
            _ = kill(-pid, SIGTERM)
        case .attachedToTerminal:
            _ = kill(pid, SIGTERM)
        }
    }

    private enum DestinationClaim {
        case claimed
        case exists
        case failed(reason: String)
    }

    /// Creates `destination` (and any missing parents). `mkdir` is atomic and
    /// fails with `EEXIST` for anything already there — a folder, a file, a
    /// dangling symlink — so at most one run can claim a path.
    private func claimDestination() -> DestinationClaim {
        let parent = (destination as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            // A failure here surfaces as mkdir's own error just below.
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        if mkdir(destination, 0o777) == 0 {
            return .claimed
        }
        let code = errno
        if code == EEXIST {
            return .exists
        }
        return .failed(reason: "Could not create \(destination): \(String(cString: strerror(code)))")
    }

    /// Only reached once `run` has claimed `destination`.
    private func clone(onProgress: @escaping @Sendable (String) -> Void) async -> CloneOutcome {
        let child: SpawnedChild
        switch spawn() {
        case .success(let spawned):
            child = spawned
        case .failure(let failure):
            // git never ran, so the folder is still the empty one `run` made.
            _ = rmdir(destination)
            return .failed(exitCode: 127, lastErrorLines: [failure.message])
        }
        register(child.pid)

        let waitStatus: Int32?
        let lastLines: [String]
        if let pipes = child.progress {
            async let lines = Self.readProgress(pipes, onProgress: onProgress)
            waitStatus = await waitForExit(child.pid, exitedWrite: pipes.exitedWrite)
            lastLines = await lines
        } else {
            waitStatus = await waitForExit(child.pid, exitedWrite: nil)
            lastLines = []
        }

        let cancelled = state.withLock { $0.cancelled }
        let outcome = Self.outcome(waitStatus: waitStatus, cancelled: cancelled, lastLines: lastLines)
        // An unknowable status (git reaped elsewhere) may hide a finished
        // clone, so only a known outcome deletes.
        guard waitStatus != nil else { return outcome }
        switch outcome {
        case .cancelled:
            // The person asked to stop, so even a repository git kept goes.
            try? FileManager.default.removeItem(atPath: destination)
        case .failed:
            // A failed fetch leaves the folder empty. A failed checkout or
            // `post-checkout` hook leaves a repository git kept on purpose, and
            // `rmdir` refuses it with ENOTEMPTY — honouring git's decision
            // without reading its text.
            _ = rmdir(destination)
        case .succeeded, .refusedDestinationExists:
            break
        }
        return outcome
    }

    /// Decodes a `waitpid` status by hand, since Swift cannot import the
    /// `WIFEXITED` family of macros. A signal reads as the shell's `128 + n`.
    ///
    /// A clone that exited 0 succeeded even if a cancel arrived meanwhile: git
    /// had finished, and the folder is a complete clone. A cancel that landed
    /// kills git, which then never exits 0.
    private static func outcome(waitStatus: Int32?, cancelled: Bool, lastLines: [String]) -> CloneOutcome {
        guard let waitStatus else {
            // Not reaped by us (ECHILD): the status is unknowable.
            return cancelled ? .cancelled : .failed(exitCode: -1, lastErrorLines: lastLines)
        }
        let signalNumber = waitStatus & 0x7f
        let exitCode = signalNumber == 0 ? (waitStatus >> 8) & 0xff : 128 + signalNumber
        if exitCode == 0 {
            return .succeeded
        }
        if cancelled {
            return .cancelled
        }
        return .failed(exitCode: exitCode, lastErrorLines: lastLines)
    }

    private func register(_ pid: pid_t) {
        let mode = self.mode
        state.withLock { run in
            run.pid = pid
            Self.liveClones.withLock { $0[pid] = mode }
            // A cancel that arrived while git was being spawned had no pid to
            // signal; deliver it now.
            if run.cancelled {
                Self.signalTerminate(pid: pid, mode: mode)
            }
        }
    }

    private func markExited(_ pid: pid_t) {
        state.withLock { run in
            run.exited = true
            Self.liveClones.withLock { $0[pid] = nil }
        }
    }

    /// Blocks a dedicated thread in `waitpid` — never a cooperative-pool or
    /// libdispatch thread, which a clone could hold for many minutes — then
    /// closes `exitedWrite` to tell the progress reader git is gone.
    private func waitForExit(_ pid: pid_t, exitedWrite: Int32?) async -> Int32? {
        await withCheckedContinuation { continuation in
            let thread = Thread { [self] in
                var status: Int32 = 0
                var reaped = false
                while true {
                    if waitpid(pid, &status, 0) == pid {
                        reaped = true
                        break
                    }
                    if errno != EINTR {
                        break
                    }
                }
                self.markExited(pid)
                if let exitedWrite {
                    close(exitedWrite)
                }
                continuation.resume(returning: reaped ? status : nil)
            }
            thread.name = "com.tbd.repo-clone.wait"
            thread.start()
        }
    }

    // MARK: - Progress

    /// Reads git's stderr on a dedicated thread, handing each line to
    /// `onProgress`, and returns the last few.
    private static func readProgress(_ pipes: ProgressPipes,
                                     onProgress: @escaping @Sendable (String) -> Void) async -> [String] {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                var lines = ProgressLines(onLine: onProgress)
                RepoCloner.pump(pipes.stderrRead, exited: pipes.exitedRead, into: &lines)
                lines.finish()
                close(pipes.stderrRead)
                close(pipes.exitedRead)
                continuation.resume(returning: lines.last)
            }
            thread.name = "com.tbd.repo-clone.progress"
            thread.start()
        }
    }

    /// Reads `fd` until end of file, or until `exited` becomes readable —
    /// whichever comes first — and then takes whatever is already buffered.
    ///
    /// **It never waits for end of file once git has exited.** Any process git
    /// starts can inherit its stderr and outlive it, and end of file comes only
    /// when the last copy of the write end closes. Everything git itself wrote
    /// is in the pipe by the time it has been reaped, so the final drain loses
    /// nothing of git's.
    private static func pump(_ fd: Int32, exited: Int32, into lines: inout ProgressLines) {
        var watched = [
            pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
            pollfd(fd: exited, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            watched[0].revents = 0
            watched[1].revents = 0
            if poll(&watched, nfds_t(watched.count), -1) < 0 {
                if errno == EINTR {
                    continue
                }
                // Never a reason to stop reading: git blocks once the pipe is
                // full and would then never exit. Fall back to blocking reads.
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                _ = drain(fd, into: &lines)
                return
            }
            if watched[0].revents != 0, drain(fd, into: &lines) {
                return
            }
            if watched[1].revents != 0 {
                _ = drain(fd, into: &lines)
                return
            }
        }
    }

    /// Reads what `fd` has buffered. True at end of file, or on a read error,
    /// which ends the stream all the same; false once the pipe is empty.
    private static func drain(_ fd: Int32, into lines: inout ProgressLines) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                lines.consume(buffer[0..<count])
            } else if count == 0 {
                return true
            } else if errno == EINTR {
                continue
            } else {
                return errno != EAGAIN
            }
        }
    }

    // MARK: - Spawning

    private struct SpawnedChild {
        let pid: pid_t
        /// `.noPrompt` only.
        let progress: ProgressPipes?
    }

    private struct SpawnFailure: LocalizedError {
        let call: String
        let code: Int32

        var message: String {
            "Could not start git: \(call) failed: \(String(cString: strerror(code)))"
        }

        var errorDescription: String? { message }
    }

    /// The parent's side of one `.noPrompt` clone: git's stderr, and a pipe
    /// whose write end the waiter closes once git is reaped. All four are
    /// close-on-exec, so no other child this process starts inherits them —
    /// an inherited stderr write end would hold off end of file.
    private struct ProgressPipes: Sendable {
        let stderrRead: Int32
        let stderrWrite: Int32
        let exitedRead: Int32
        let exitedWrite: Int32

        static func make() -> Result<ProgressPipes, SpawnFailure> {
            guard let output = makePipe() else {
                return .failure(SpawnFailure(call: "pipe", code: errno))
            }
            guard let exited = makePipe() else {
                let code = errno
                close(output.read)
                close(output.write)
                return .failure(SpawnFailure(call: "pipe", code: code))
            }
            // Non-blocking so the final drain after git exits stops at an
            // empty pipe instead of waiting on a write end git's children hold.
            _ = fcntl(output.read, F_SETFL, fcntl(output.read, F_GETFL) | O_NONBLOCK)
            return .success(ProgressPipes(stderrRead: output.read, stderrWrite: output.write,
                                          exitedRead: exited.read, exitedWrite: exited.write))
        }

        /// After a failed spawn, everything `make` opened except `stderrWrite`,
        /// which `spawn` closes on both paths.
        func closeAfterFailedSpawn() {
            close(stderrRead)
            close(exitedRead)
            close(exitedWrite)
        }

        private static func makePipe() -> (read: Int32, write: Int32)? {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else { return nil }
            for descriptor in descriptors {
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            }
            return (descriptors[0], descriptors[1])
        }
    }

    private func spawn() -> Result<SpawnedChild, SpawnFailure> {
        var pipes: ProgressPipes?
        if mode == .noPrompt {
            switch ProgressPipes.make() {
            case .success(let made):
                pipes = made
            case .failure(let failure):
                return .failure(failure)
            }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // **A signal mask survives `execve`.** This runs on a Swift-concurrency
        // worker thread, and those block SIGTERM and SIGINT among many others
        // (measured in `HolderSpawner`). Inherited, that mask would leave git
        // deaf to cancel, to `terminateAll()` and to Ctrl-C. Dispositions are
        // reset for the same reason: a `SIG_IGN` here would survive the exec.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)

        // CLOEXEC_DEFAULT: git gets 0, 1 and 2 and nothing else of ours, in
        // both modes — only descriptors named by a file action survive.
        var flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        if let pipes {
            // The dup2 comes before the opens: should the pipe's write end
            // itself be 0 or 1, it reaches 2 before /dev/null replaces it.
            posix_spawn_file_actions_adddup2(&actions, pipes.stderrWrite, 2)
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            // SETSID: no controlling terminal, so nothing can prompt, and its
            // own process group, so a cancel reaches the transport helpers too.
            flags |= POSIX_SPAWN_SETSID
        } else {
            // Attached: git keeps the caller's terminal on 0, 1 and 2. One the
            // caller has closed stays closed, because inheriting a closed
            // descriptor fails the whole spawn with EBADF.
            for descriptor: Int32 in 0...2 where fcntl(descriptor, F_GETFD) != -1 {
                posix_spawn_file_actions_addinherit_np(&actions, descriptor)
            }
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))

        var argv: [UnsafeMutablePointer<CChar>?] = (["env"] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = childEnvironment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for entry in argv { free(entry) }
            for entry in envp { free(entry) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/usr/bin/env", &actions, &attributes, &argv, &envp)
        // The parent's copy of the write end goes on both paths: while it is
        // open, the reader could never see end of file.
        if let pipes {
            close(pipes.stderrWrite)
        }
        guard status == 0 else {
            pipes?.closeAfterFailedSpawn()
            return .failure(SpawnFailure(call: "posix_spawn", code: status))
        }
        return .success(SpawnedChild(pid: pid, progress: pipes))
    }
}

/// Splits git's stderr into lines: on `\n`, and on the `\r` that ends each
/// in-place progress update. Pieces are trimmed and empty ones dropped.
private struct ProgressLines {
    private static let kept = 5

    private let onLine: @Sendable (String) -> Void
    private var pending: [UInt8] = []
    private(set) var last: [String] = []

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    mutating func consume(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                emitPending()
            } else {
                pending.append(byte)
            }
        }
    }

    /// Emits a final line that had no terminator.
    mutating func finish() {
        emitPending()
    }

    private mutating func emitPending() {
        // Lossy on purpose: a line with one bad byte (a path in a legacy
        // encoding) is still worth showing, where a failable decode drops it.
        // swiftlint:disable:next optional_data_string_conversion
        let line = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        pending.removeAll(keepingCapacity: true)
        guard !line.isEmpty else { return }
        last.append(line)
        if last.count > Self.kept {
            last.removeFirst(last.count - Self.kept)
        }
        onLine(line)
    }
}
