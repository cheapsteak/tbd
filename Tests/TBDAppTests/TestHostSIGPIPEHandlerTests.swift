import Darwin
import Foundation
import Testing
import TestProcessDefaults
import TestSupport

/// The test host's SIGPIPE handler (`Tests/TestProcessDefaults/SIGPIPEHandler.c`).
///
/// One write to a pipe or socket whose reader had gone once ended a whole fast
/// pass on CI ("unexpected signal code 13"): every test still to run went
/// unreported, with no summary line and a truncated xUnit file. The handler
/// turns such a write into an `EPIPE` for the code that made it, and counts and
/// logs the catch. These tests pin two consequences: SIGPIPE is caught,
/// neither left at its default nor ignored; and a child still starts with
/// SIGPIPE at its default, because exec resets a caught signal where it would
/// keep an ignored one.
///
/// **No test here raises a live SIGPIPE in the test process.** XNU raises a
/// write's SIGPIPE at the process, not at the writing thread, so the handler
/// runs on whichever thread does not block it and can interrupt another
/// suite's blocked syscall in the middle of its test (measured on CI: a pass
/// wedged for 118 s, 10 s after a deliberate write here). So the
/// write-to-EPIPE conversion is verified by a standalone probe outside the
/// test process, and the child in the second test sends SIGPIPE to itself,
/// never to this process.
///
/// They read SIGPIPE's disposition and never set it: it is process-wide, and
/// every suite in the run shares it. This suite's type name starts with T, so
/// it runs in the app pass that takes everything but `TBDAppTests` A–P;
/// `HostSIGPIPECheckAToPTests` checks the disposition in the other one.
@Suite("Test host SIGPIPE handler")
struct TestHostSIGPIPEHandlerTests {

    /// Read from the kernel, not taken from the handler's own report, so a
    /// constructor that never ran goes red here rather than at the next stray
    /// write. `SA_RESTART` is pinned because it is a choice: XNU delivers a
    /// write's SIGPIPE to any thread that does not block it, and without the
    /// flag a thread blocked in `read`, `accept` or `waitpid` would see `EINTR`.
    @Test("SIGPIPE is caught by the host's handler, neither at its default nor ignored")
    func sigpipeIsCaughtByTheHostHandler() throws {
        var current = sigaction()
        let status = sigaction(SIGPIPE, nil, &current)
        try #require(status == 0, "sigaction could not read SIGPIPE's disposition (errno \(errno))")

        let handler = Self.address(of: current.__sigaction_u.__sa_handler)
        let usesSiginfo = current.sa_flags & SA_SIGINFO != 0
        let restarts = current.sa_flags & SA_RESTART != 0
        #expect(handler != Self.address(of: SIG_DFL), "SIGPIPE is at its default action, so a stray write ends the pass")
        #expect(handler != Self.address(of: SIG_IGN), "SIGPIPE is ignored, which posix_spawn and forkpty children inherit")
        #expect(!usesSiginfo)
        #expect(restarts, "SA_RESTART is not set (flags \(current.sa_flags))")
        #expect(TBDTestHostSIGPIPEHandlerIsCurrent(), "SIGPIPE is caught, but not by SIGPIPEHandler.c's handler")
    }

    /// Why the host catches SIGPIPE instead of ignoring it. exec resets a
    /// caught signal to its default action and keeps an ignored one ignored, so
    /// with the handler a child the test process starts itself, through
    /// `posix_spawn` or `forkpty`, gets SIGPIPE at its default: what ends the
    /// `yes` in a `yes | head` that a test's shell runs.
    ///
    /// The child is a shell that sends itself SIGPIPE. At the default action
    /// that ends it by signal 13; had it inherited `SIG_IGN` it would carry on
    /// and exit 3. It is started with a bare `posix_spawn`, without
    /// `POSIX_SPAWN_SETSIGDEF`, so exec's own rule alone decides its
    /// disposition. Foundation's `Process` would not do: it resets every signal
    /// to its default itself (measured: its child died of SIGPIPE under a
    /// parent that ignored SIGPIPE), so it cannot tell a handler from `SIG_IGN`.
    @Test("a child spawned from the test host starts with SIGPIPE at its default action")
    func aSpawnedChildStartsWithSIGPIPEAtItsDefault() async throws {
        let pid = try Self.spawnShell("kill -PIPE $$; exit 3")
        var waitStatus: Int32 = 0
        var collected = false
        var reapedElsewhere = false
        defer {
            // Never leave the child unreaped, whatever the wait decided. A
            // SIGKILLed child exits at once, so the blocking reap is brief.
            if !collected {
                kill(pid, SIGKILL)
                _ = waitpid(pid, &waitStatus, 0)
            }
        }

        let budget = TestDeadlines.saturatedPass
        let outcome = await pollUntilTrue(timeout: budget, pollInterval: .milliseconds(20)) {
            let result = waitpid(pid, &waitStatus, WNOHANG)
            if result == pid {
                collected = true
            } else if result == -1 && errno == ECHILD {
                collected = true
                reapedElsewhere = true
            }
            return collected
        }
        switch outcome {
        case .satisfied:
            break
        case .cancelled:
            return
        case .timedOut:
            Issue.record(BoundedWaitTimeout(
                what: "the probe shell (pid \(pid)) to exit after sending itself SIGPIPE",
                observed: "still running; it is SIGKILLed and reaped now", deadline: budget))
            return
        }
        try #require(!reapedElsewhere, "something else in the process reaped the probe shell, so its exit is unknown")

        let signalNumber = waitStatus & 0x7f
        let observed = signalNumber == 0 ? "exited \((waitStatus >> 8) & 0xff)" : "died of signal \(signalNumber)"
        #expect(
            signalNumber == SIGPIPE,
            "the probe shell \(observed); exit 3 means it started with SIGPIPE ignored")
    }

    // MARK: - Helpers

    /// A handler's address, so dispositions compare as numbers: Swift cannot
    /// compare C function pointers. `SIG_DFL` is 0 and `SIG_IGN` is 1.
    private static func address(of handler: sig_t?) -> Int {
        unsafeBitCast(handler, to: Int.self)
    }

    /// Starts `/bin/sh -c script` with a bare `posix_spawn`: no
    /// `POSIX_SPAWN_SETSIGDEF`, so the child's SIGPIPE disposition is whatever
    /// exec makes of this process's. The mask is emptied, because a Swift
    /// concurrency thread's mask also survives exec and the probe must not
    /// depend on which thread spawned it. `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps
    /// every other suite's descriptors out of the child, which gets `/dev/null`
    /// on 0, 1 and 2 and an environment of `PATH` alone.
    private static func spawnShell(_ script: String) throws -> pid_t {
        // Every `posix_spawn*` call returns its error code instead of setting
        // `errno`, and each one is checked: a probe that ran without
        // SETSIGMASK or CLOEXEC_DEFAULT, or without its `/dev/null`s, would
        // measure something else and still look like an answer.
        func check(_ call: String, _ code: Int32) throws {
            guard code == 0 else { throw SpawnFailed(call: call, code: code) }
        }

        var actions: posix_spawn_file_actions_t?
        try check("posix_spawn_file_actions_init", posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        let standardStreams: [(descriptor: Int32, flags: Int32)] = [(0, O_RDONLY), (1, O_WRONLY), (2, O_WRONLY)]
        for stream in standardStreams {
            try check(
                "posix_spawn_file_actions_addopen(\(stream.descriptor))",
                posix_spawn_file_actions_addopen(&actions, stream.descriptor, "/dev/null", stream.flags, 0))
        }

        var attributes: posix_spawnattr_t?
        try check("posix_spawnattr_init", posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        try check("posix_spawnattr_setsigmask", posix_spawnattr_setsigmask(&attributes, &emptyMask))
        // Deliberately no POSIX_SPAWN_SETSIGDEF: it would reset SIGPIPE in the
        // child whatever this process's disposition, and prove nothing.
        try check(
            "posix_spawnattr_setflags",
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)))

        let words: [String] = ["/bin/sh", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer {
            for entry in argv { free(entry) }
            for entry in envp { free(entry) }
        }

        var pid: pid_t = 0
        try check("posix_spawn", posix_spawn(&pid, "/bin/sh", &actions, &attributes, &argv, &envp))
        return pid
    }

    private struct SpawnFailed: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call) failed: \(String(cString: strerror(code)))" }
    }
}
