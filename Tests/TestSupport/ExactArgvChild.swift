import Darwin

/// A child process started with exactly the argv and environment a test
/// gives, `argv[0]` included, for tests that read what the kernel recorded
/// about a real process: its `KERN_PROCARGS2` buffer, or its entry in the
/// process table.
///
/// End it in a `defer` straight after starting it, so it is killed and reaped
/// however the test leaves:
///
/// ```swift
/// let child = try ExactArgvChild(path: "/bin/sleep", argv: ["", "30"])
/// defer { child.end() }
/// ```
///
/// `path` must be absolute. `posix_spawn` runs it as given, with no `PATH`
/// search, and the kernel records it as given, so repeated slashes lengthen
/// the recorded path without changing what runs. The child gets `environment`
/// and nothing of this process's environment, and it starts with no open
/// descriptors at all, stdio included (`POSIX_SPAWN_CLOEXEC_DEFAULT`): every
/// suite shares this test process, so an inherited descriptor could be
/// another suite's lock or pipe, held open until the child is ended. Start
/// only a program that needs no stdio and touches no TBD store; `/bin/sleep`
/// is the one the suites use.
///
/// `startSuspended` starts the child stopped before its first instruction
/// (`POSIX_SPAWN_START_SUSPENDED`). The kernel has already executed it, so its
/// process-table entry, its command name and its `KERN_PROCARGS2` buffer are
/// all in place, but it never runs. That lets a test give a program an argv
/// it would refuse: a suspended `/bin/sleep` keeps whatever argv it was given
/// for as long as the test needs, where a running one would exit on it at
/// once. `end()` kills and reaps a suspended child the same way.
public struct ExactArgvChild: Sendable {
    /// A call that starts the child failed. Thrown, so its text is the
    /// failing test's primary line; there is no child to end.
    public struct SpawnFailed: Error, CustomStringConvertible {
        public let call: String
        public let path: String
        public let code: Int32
        public var description: String { "\(call) for \(path) failed with \(code)" }
    }

    public let pid: pid_t

    /// Starts `path` with `argv` and `environment`, each entry `KEY=value`,
    /// suspended when `startSuspended` is true.
    public init(
        path: String, argv: [String], environment: [String] = [], startSuspended: Bool = false
    ) throws {
        var pid: pid_t = 0
        // `posix_spawn` copies both lists before it returns, so they need to
        // live only until then.
        var arguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        arguments.append(nil)
        var entries: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) }
        entries.append(nil)
        defer {
            for argument in arguments { free(argument) }
            for entry in entries { free(entry) }
        }

        var attributes: posix_spawnattr_t?
        let initialized = posix_spawnattr_init(&attributes)
        guard initialized == 0 else {
            throw SpawnFailed(call: "posix_spawnattr_init", path: path, code: initialized)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT
        if startSuspended { flags |= POSIX_SPAWN_START_SUSPENDED }
        let flagged = posix_spawnattr_setflags(&attributes, Int16(flags))
        guard flagged == 0 else {
            throw SpawnFailed(call: "posix_spawnattr_setflags", path: path, code: flagged)
        }

        let code = posix_spawn(&pid, path, nil, &attributes, &arguments, &entries)
        guard code == 0 else { throw SpawnFailed(call: "posix_spawn", path: path, code: code) }
        self.pid = pid
    }

    /// Kills the child and reaps it. The `waitpid` blocks, but only until the
    /// `SIGKILL` lands, so it needs no deadline.
    public func end() {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
    }
}
