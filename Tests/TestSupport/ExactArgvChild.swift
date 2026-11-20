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
/// and nothing of this process's environment, and inherits this process's
/// open descriptors until it is ended. Start only a program that touches no
/// TBD store; `/bin/sleep` is the one the suites use.
public struct ExactArgvChild: Sendable {
    /// `posix_spawn` refused to start the child. Thrown, so its text is the
    /// failing test's primary line; there is no child to end.
    public struct SpawnFailed: Error, CustomStringConvertible {
        public let path: String
        public let code: Int32
        public var description: String { "posix_spawn of \(path) failed with \(code)" }
    }

    public let pid: pid_t

    /// Starts `path` with `argv` and `environment`, each entry `KEY=value`.
    public init(path: String, argv: [String], environment: [String] = []) throws {
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
        let code = posix_spawn(&pid, path, nil, nil, &arguments, &entries)
        guard code == 0 else { throw SpawnFailed(path: path, code: code) }
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
