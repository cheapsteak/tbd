import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `ModelProxySpawner` against a **fake** `TBDModelProxy` — a shell script that
/// can be told to publish a port, to exit with one of the statuses the real
/// binary exits with, or to do neither.
///
/// A fake rather than the real binary, for one reason each way: the statuses
/// the spawner branches on are hard to *produce* out of the real proxy without
/// racing something (exit 3 needs a port squatter held for the length of a
/// spawn), and trivial to produce out of `exit 3`. What the fake cannot show is
/// that the real binary still produces them, or that the pid file it writes is
/// the file this spawner parses — so `ModelProxySpawnerLiveTests` spawns the
/// real one and reads what it wrote, and the two halves are only sound
/// together.
@Suite("Model proxy spawner")
struct ModelProxySpawnerTests {

    // MARK: - Publishing a port

    /// The returned port is the one in the pid file, **not** the one asked
    /// for. Those differ on the first spawn of a home, which is the case the
    /// persisted `model_proxy_port` column is filled from (spec, "Port").
    @Test("the published port is read from the pid file, not echoed from the request")
    func thePublishedPortComesFromThePIDFile() async throws {
        let fixture = try SpawnerFixture.make(
            body: """
                printf '%s\\n%s\\n' "$$" "45678" > "$4/proxy/proxy.pid"
                exec sleep 30
                """)
        defer { fixture.tearDown() }

        let result = try await fixture.spawner().spawn(port: 0, home: fixture.home)

        #expect(result.port == 45678)
        #expect(result.pid == fixture.childPID())
    }

    /// A predecessor's pid file must not be read as this spawn's answer.
    ///
    /// It is a real state, not a hypothetical one: a retiring proxy leaves its
    /// pid file in place until it exits, so a spawner that took the first file
    /// it saw would hand back a port a different process owns and route every
    /// new session into a proxy that is draining. The stale file here names
    /// port 1111; a spawner that ignored the pid would return it.
    @Test("a pid file left by another process is not mistaken for this spawn's answer")
    func aStalePIDFileIsIgnored() async throws {
        let fixture = try SpawnerFixture.make(
            body: """
                sleep 0.5
                printf '%s\\n%s\\n' "$$" "45678" > "$4/proxy/proxy.pid"
                exec sleep 30
                """)
        defer { fixture.tearDown() }

        try FileManager.default.createDirectory(
            at: fixture.paths.proxyDir, withIntermediateDirectories: true)
        try "999999\n1111\n".write(
            toFile: fixture.paths.pidPath, atomically: true, encoding: .utf8)

        let result = try await fixture.spawner().spawn(port: 0, home: fixture.home)

        #expect(result.port == 45678, "a stale pid file was read as this spawn's answer")
    }

    // MARK: - What the child was told

    /// The command line and the descriptor, together, because the second is
    /// only meaningful with the first: `--lock-fd 9` naming a descriptor that
    /// did not arrive would make the child take its own lock and the hand-down
    /// a silent no-op.
    @Test("the child is told the port, the home and a lock descriptor that really arrives")
    func theChildGetsItsArgumentsAndTheLock() async throws {
        let fixture = try SpawnerFixture.make(
            body: """
                if [ -e /dev/fd/9 ]; then printf 'open\\n' > "$4/lockfd"; fi
                printf '%s\\n%s\\n' "$$" "$2" > "$4/proxy/proxy.pid"
                exec sleep 30
                """)
        defer { fixture.tearDown() }

        let result = try await fixture.spawner().spawn(port: 51234, home: fixture.home)
        #expect(result.port == 51234)

        let argv = try String(
            contentsOfFile: fixture.home.appendingPathComponent("argv").path, encoding: .utf8)
        let arguments = argv.split(separator: "\n").map(String.init)
        #expect(
            arguments == [
                "--port", "51234", "--home", fixture.home.path, "--lock-fd", "9",
            ], "unexpected command line: \(arguments)")

        let lockFD = try? String(
            contentsOfFile: fixture.home.appendingPathComponent("lockfd").path, encoding: .utf8)
        #expect(lockFD?.contains("open") == true, "descriptor 9 did not reach the child")
    }

    // MARK: - Exit statuses

    /// The three statuses a supervisor branches on, each mapped to the error
    /// that says what to do about it. `bindFailed` carries the port that was
    /// *requested*, because that is the one the caller probes and may re-mint.
    @Test(
        "the proxy's named exit statuses map onto the spawner's errors",
        arguments: [
            (3, ModelProxySpawner.Error.bindFailed(port: 51234)),
            (4, ModelProxySpawner.Error.lockHeld),
            (5, ModelProxySpawner.Error.homeUnusable),
            (2, ModelProxySpawner.Error.childExited(status: 2)),
        ])
    func exitStatusesMapToErrors(status: Int, expected: ModelProxySpawner.Error) async throws {
        let fixture = try SpawnerFixture.make(body: "exit \(status)")
        defer { fixture.tearDown() }

        await #expect(throws: expected) {
            _ = try await fixture.spawner().spawn(port: 51234, home: fixture.home)
        }
    }

    /// A crashed proxy is not a bind failure. `SIGQUIT` is signal 3 and
    /// `bindFailed` is status 3, so a spawner that read a raw `waitpid` status
    /// would send its caller probing a port nothing ever took.
    @Test("a signalled child is a negative status, never a named one")
    func aSignalledChildIsNotABindFailure() {
        #expect(ModelProxySpawner.exitStatus(fromWaitpidStatus: 3) == -3)
        #expect(ModelProxySpawner.exitStatus(fromWaitpidStatus: 9) == -9)
        #expect(ModelProxySpawner.exitStatus(fromWaitpidStatus: 3 << 8) == 3)
        #expect(
            ModelProxySpawner.classify(exitStatus: -3, requestedPort: 51234)
                == .childExited(status: -3))
        #expect(
            ModelProxySpawner.classify(exitStatus: 3, requestedPort: 51234)
                == .bindFailed(port: 51234))
    }

    // MARK: - The lock

    /// A held lock refuses the spawn and **starts nothing**. The marker is the
    /// assertion that matters: the lock exists so a second daemon backs off
    /// without touching the rendezvous, and a spawner that spawned first and
    /// let the child discover the contention would have already written a log
    /// file and raced the pid file.
    @Test("a lock held by a live proxy refuses the spawn before anything is started")
    func aHeldLockStartsNothing() async throws {
        let fixture = try SpawnerFixture.make(
            body: """
                printf 'ran\\n' > "$4/ran"
                exec sleep 30
                """)
        defer { fixture.tearDown() }

        try FileManager.default.createDirectory(
            at: fixture.paths.proxyDir, withIntermediateDirectories: true)
        let held = try HolderLock.acquire(path: fixture.paths.lockPath)
        defer { held.release() }

        await #expect(throws: ModelProxySpawner.Error.lockHeld) {
            _ = try await fixture.spawner().spawn(port: 51234, home: fixture.home)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.home.appendingPathComponent("ran").path),
            "a proxy was spawned while another held the lock")
    }

    /// The lock the spawner took is the child's afterwards, and the daemon's
    /// own copy is gone: a second spawn attempt against a live proxy must be
    /// refused by the *child's* lock, not by a descriptor the daemon forgot to
    /// drop.
    @Test("the daemon drops its own copy of the lock, leaving the child holding it")
    func theChildEndsUpHoldingTheLockAlone() async throws {
        let fixture = try SpawnerFixture.make(
            body: """
                printf '%s\\n%s\\n' "$$" "$2" > "$4/proxy/proxy.pid"
                exec sleep 30
                """)
        defer { fixture.tearDown() }

        _ = try await fixture.spawner().spawn(port: 51234, home: fixture.home)

        // Still held — by the child, which inherited it and is still running.
        #expect(throws: HolderLock.Error.alreadyHeld(path: fixture.paths.lockPath)) {
            _ = try HolderLock.acquire(path: fixture.paths.lockPath)
        }

        // And released the moment the child dies, which is only true if the
        // daemon's copy really went away: the kernel drops an `flock` when the
        // last descriptor on that open file description closes.
        let child = try #require(fixture.childPID())
        kill(child, SIGKILL)
        var ignored: Int32 = 0
        _ = waitpid(child, &ignored, 0)
        let reacquired = try HolderLock.acquire(path: fixture.paths.lockPath)
        reacquired.release()
    }

    // MARK: - The budget

    /// A proxy that never publishes a port is killed rather than left holding
    /// the lock.
    ///
    /// Nothing can be orphaned by that kill — a proxy has no children, and no
    /// session can be routed to a port nobody was ever told — while leaving it
    /// alive would block every later spawn for this home for as long as it
    /// ran.
    ///
    /// The budget here is a real three seconds rather than a faked ten, and
    /// that is deliberate: the claim is about a child that *started* and never
    /// announced itself, so the budget has to outlast an `execve`. An
    /// `ImmediateClock` would spend all ten seconds of credit in a few
    /// milliseconds and kill a process that had not reached its first line —
    /// the assertion would then pass without ever exercising the case.
    @Test("a proxy that never publishes a port is killed and reported as a timeout")
    func aSilentProxyIsKilled() async throws {
        let fixture = try SpawnerFixture.make(body: "exec sleep 30")
        defer { fixture.tearDown() }

        await #expect(throws: ModelProxySpawner.Error.bindTimeout) {
            _ = try await fixture.spawner(bindTimeout: .seconds(3)).spawn(
                port: 51234, home: fixture.home)
        }

        // Non-vacuity: the fake really ran, so what was killed was a live
        // child rather than a spawn that never happened.
        let child = try #require(
            fixture.childPID(), "the fake proxy never started, so nothing was killed")
        #expect(
            kill(child, 0) != 0,
            "pid \(child) survived a spawn that timed out, still holding the lock")
    }

    // MARK: - The home

    /// A home that cannot hold a `proxy/` directory fails before any process
    /// exists — and as `homeUnusable` rather than as a bind failure, because
    /// respawning changes nothing until somebody fixes the filesystem.
    @Test("a home that cannot be created fails without spawning anything")
    func anUnusableHomeNeverSpawns() async throws {
        // `$0` is the script itself, so the marker lands beside it rather than
        // under a home this test has deliberately made unusable.
        let fixture = try SpawnerFixture.make(
            body: """
                printf 'ran\\n' > "$(dirname "$0")/ran"
                exit 0
                """)
        defer { fixture.tearDown() }

        // A regular file where the home should be: `proxy/` cannot be created
        // under it at any point in the future.
        let blocked = fixture.root.appendingPathComponent("blocked-home")
        try "not a directory".write(to: blocked, atomically: true, encoding: .utf8)

        await #expect(throws: ModelProxySpawner.Error.homeUnusable) {
            _ = try await fixture.spawner().spawn(port: 51234, home: blocked)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("ran").path),
            "a proxy was spawned against a home that cannot hold its directory")
    }

    // MARK: - The pid file's format

    /// The pid file is `"<pid>\n<port>\n"`, and this spawner parses it out of
    /// a *different module* than the one that writes it (`ProxyPIDFile` lives
    /// in the proxy's executable target, which no library can import). The
    /// literal is pinned here and end-to-end in the live suite, so a change to
    /// either spelling reddens rather than silently stopping every adoption.
    @Test("the pid file is parsed as pid then port, and only when it names us")
    func thePIDFileIsParsedStrictly() throws {
        let root = fencedScratchRoot(prefix: "tbdmp")
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = "\(root)/proxy.pid"

        try "4321\n51234\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(ModelProxySpawner.publishedPort(path: path, pid: 4321) == 51234)
        #expect(ModelProxySpawner.publishedPort(path: path, pid: 4322) == nil)

        // Half-written, or written by something that is not a proxy.
        try "4321\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(ModelProxySpawner.publishedPort(path: path, pid: 4321) == nil)
        try "hello\nworld\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(ModelProxySpawner.publishedPort(path: path, pid: 4321) == nil)

        try FileManager.default.removeItem(atPath: path)
        #expect(ModelProxySpawner.publishedPort(path: path, pid: 4321) == nil)
    }

    // MARK: - Finding the binary

    /// A sibling of the daemon and nothing else — never `PATH`, for
    /// `HolderSpawner.locateSiblingExecutable`'s reason: a binary of the same
    /// name found somewhere else would own this home's sessions.
    @Test("the proxy binary is located beside the daemon, or not at all")
    func theSiblingBinaryIsLocated() throws {
        let root = fencedScratchRoot(prefix: "tbdmp")
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let daemon = URL(fileURLWithPath: "\(root)/TBDDaemon")
        try "#!/bin/sh\nexit 0\n".write(to: daemon, atomically: true, encoding: .utf8)
        #expect(ModelProxySpawner.locateSiblingExecutable(of: daemon) == nil)

        let proxy = URL(fileURLWithPath: "\(root)/TBDModelProxy")
        try "#!/bin/sh\nexit 0\n".write(to: proxy, atomically: true, encoding: .utf8)
        // Present but not executable is still "no binary to spawn".
        #expect(ModelProxySpawner.locateSiblingExecutable(of: daemon) == nil)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: proxy.path)
        // Compared through `resolvingSymlinksInPath` on both sides: the
        // locator resolves the daemon's path before taking its directory, and
        // on macOS a scratch root under `/tmp` is a symlink to `/private/tmp`.
        #expect(
            ModelProxySpawner.locateSiblingExecutable(of: daemon)?.path
                == proxy.resolvingSymlinksInPath().path)
        #expect(ModelProxySpawner.locateSiblingExecutable(of: nil) == nil)
    }
}

// MARK: - Fixture

/// A scratch home and a fake `TBDModelProxy` that runs `body`.
///
/// The script writes its own pid and its argv before anything else, which is
/// what lets a test kill a child it never learned the pid of and assert on the
/// command line the spawner composed. `$4` is the `--home` value: the argument
/// order is `--port <n> --home <path> --lock-fd <n>`.
struct SpawnerFixture {
    let root: URL
    let home: URL
    let executable: URL
    let paths: ProxyHomePaths

    static func make(body: String) throws -> SpawnerFixture {
        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdmp"))
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("TBDModelProxy")
        let script = """
            #!/bin/sh
            printf '%s\\n' "$$" > "$4/child.pid"
            printf '%s\\n' "$@" > "$4/argv"
            \(body)
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        return SpawnerFixture(
            root: root, home: home, executable: executable, paths: ProxyHomePaths(home: home))
    }

    /// An rc-free environment with no `TBD_HOME`: a passing run must not be
    /// the accident of the developer's own config, and the spawner is supposed
    /// to be telling the child its home on the command line.
    func spawner(bindTimeout: Duration = .seconds(10)) -> ModelProxySpawner {
        ModelProxySpawner(
            executableURL: executable,
            bindTimeout: bindTimeout,
            bindPollInterval: .milliseconds(20),
            environment: ["PATH": "/usr/bin:/bin"])
    }

    /// The pid the fake wrote for itself, or nil if it never ran.
    func childPID() -> pid_t? {
        guard
            let text = try? String(
                contentsOfFile: home.appendingPathComponent("child.pid").path, encoding: .utf8)
        else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Kills whatever the fake left running and reaps it, so a suite that
    /// spawns `sleep 30` eleven times does not leave eleven of them behind for
    /// the rest of the test run.
    func tearDown() {
        if let child = childPID() {
            kill(child, SIGKILL)
            var ignored: Int32 = 0
            _ = waitpid(child, &ignored, 0)
        }
        try? FileManager.default.removeItem(at: root)
    }
}
