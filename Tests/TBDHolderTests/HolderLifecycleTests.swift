import Darwin
import Foundation
import Testing
@testable import TBDHolder
@testable import TBDShared

/// Live-process tests for the holder.
///
/// Serialized because each one spawns real processes and a pty, and the point
/// of several of them is a claim about process death — running them alongside
/// each other would make a failure ambiguous about whose child died.
@Suite("Holder lifecycle", .serialized)
struct HolderLifecycleTests {
    private static let rcFreeEnvironment = ["PATH": "/usr/bin:/bin", "TERM": "dumb"]

    /// A job that does nothing but stay alive. Bounded so a fixture that
    /// somehow escapes teardown still reaps itself.
    private static func idleJob(marker: String = "") -> HolderLaunchRequest {
        HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", marker.isEmpty ? "sleep 60" : "printf '\(marker)\\n'; sleep 60"],
            workingDirectory: "/tmp",
            environment: rcFreeEnvironment,
            columns: 100,
            rows: 30)
    }

    // MARK: 1 — it binds and describes

    @Test func holderBindsItsSocketAndDescribesItsChild() throws {
        let fixture = try HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        fixture.waitForSocket()

        let client = try fixture.connect()
        defer { client.close() }
        guard case .described(let description) = try client.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        #expect(description.childPID > 0)
        #expect(description.status == .alive)
        #expect(description.launch.executable == "/bin/sh")
        // The size travels from the launch request into the pty, so a job that
        // asks its terminal how wide it is gets the answer the caller chose.
        #expect(description.launch.columns == 100)
        #expect(description.ttyName.hasPrefix("/dev/tty"))
        #expect(description.owner == HolderOwnerToken(rawValue: "test-installation"))
        #expect(processIsAlive(description.childPID))
    }

    // MARK: 2 — the central claim

    /// The design's whole point: the job outlives the process that spawned the
    /// holder, because the pty master lives in the holder rather than in
    /// whoever asked for the session.
    ///
    /// The fixture always launches through a bootstrap `/bin/sh` that
    /// backgrounds the holder and exits, so by the time any test body runs the
    /// spawner is already gone. This one asserts that instead of assuming it.
    @Test func childSurvivesTheSpawningProcessExiting() throws {
        let fixture = try HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        fixture.waitForSocket()

        #expect(fixture.spawnerExitStatus == 0, "the bootstrap shell should have exited cleanly")

        let client = try fixture.connect()
        defer { client.close() }
        guard case .described(let description) = try client.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        #expect(description.status == .alive)
        #expect(processIsAlive(description.childPID), "the job died with its spawner")
        #expect(processIsAlive(fixture.holderPID), "the holder died with its spawner")
    }

    // MARK: 3 — one client at a time

    /// Two readers on one pty master is silent byte theft: whichever `read`
    /// lands first wins the bytes and the other reader never learns they
    /// existed. So the second connection is accepted, answered with a version
    /// that cannot be mistaken for a real one, and closed.
    @Test func secondConcurrentClientIsRejected() throws {
        let fixture = try HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        fixture.waitForSocket()

        let first = try fixture.connect()
        defer { first.close() }
        guard case .described(let description) = try first.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        let second = try fixture.connect()
        defer { second.close() }
        #expect(try second.receive() == .rejected(version: HolderProtocolVersion.busySentinel))

        // The rejection must not have cost the first client its session.
        guard case .described = try first.request(.describe) else {
            Issue.record("the incumbent client stopped being served after a rejection")
            return
        }
    }

    // MARK: 4 — hand-over

    /// The holder never reads the master, so everything the job has written
    /// since it started is still queued when a reader finally arrives.
    @Test func handsOverAPTYThatCarriesChildOutput() throws {
        let fixture = try HolderFixture.start(launch: Self.idleJob(marker: "HOLDER-OK"))
        defer { fixture.tearDown() }
        fixture.waitForSocket()

        let client = try fixture.connect()
        defer { client.close() }
        let (response, fds) = try client.requestWithFDs(.handOverPTY)
        defer { fds.forEach { close($0) } }

        guard case .handedOverPTY(let description) = response else {
            Issue.record("expected .handedOverPTY, got \(response)\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)
        #expect(fds.count == 1, "exactly one descriptor should ride the hand-over")

        let pty = try #require(fds.first)
        var seen = Data()
        waitUntil("the job's output on the handed-over pty") {
            drainPTY(pty, into: &seen)
            return String(decoding: seen, as: UTF8.self).contains("HOLDER-OK")
        }
        #expect(String(decoding: seen, as: UTF8.self).contains("HOLDER-OK"))
    }

    // MARK: 5 — forget

    /// `forget` is the preemptive close: a session the user killed must not be
    /// resurrectable by anything that reconnects afterwards. The holder answers
    /// once, drops the pty master, unlinks its rendezvous and exits — and the
    /// job it was holding is left for its caller to reap, because holder death
    /// is deliberately not child death.
    @Test func forgetStopsReportingAndDoesNotResurrectTheChild() throws {
        let fixture = try HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        fixture.waitForSocket()

        let client = try fixture.connect()
        guard case .described(let description) = try client.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        #expect(try client.request(.forget) == .forgotten)
        client.close()

        waitUntil("the holder to unlink its socket and exit") {
            !FileManager.default.fileExists(atPath: fixture.socketPath)
                && !processIsAlive(fixture.holderPID)
        }
        #expect(!processIsAlive(fixture.holderPID))
        // Nothing may report the child any more, and nothing may bring a new
        // holder up in its place on its own.
        #expect(throws: TestHolderError.self) { _ = try fixture.connect(receiveTimeout: 1.0) }
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath))
    }

    // MARK: 6 — the lock stays with the holder

    /// **The job must not inherit the creation lock.** `flock` lives on the
    /// open file description, so a job that inherits the descriptor holds the
    /// lock — and keeps holding it after the holder is SIGKILLed. Both halves
    /// of the lock's contract break at once: the kernel stops dropping it when
    /// the holder dies, and every later spawn for this session sees
    /// `.alreadyHeld` forever with no holder alive to explain it.
    ///
    /// The sequencing is what gives the assertion meaning: the holder is killed
    /// while the job is still alive, so if the reacquire succeeds it can only
    /// be because the job never had the lock.
    @Test func theJobDoesNotInheritTheCreationLock() throws {
        let fixture = try HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        fixture.waitForSocket()

        let childPID: Int32
        do {
            let client = try fixture.connect()
            defer { client.close() }
            guard case .described(let description) = try client.request(.describe) else {
                Issue.record("expected .described\n\(fixture.diagnostics())")
                return
            }
            childPID = description.childPID
            fixture.trackChild(childPID)
        }

        kill(fixture.holderPID, SIGKILL)
        waitUntil("the holder to die") { !processIsAlive(fixture.holderPID) }
        // Without a live job this test would pass vacuously — the lock would be
        // free because nothing at all was left holding it.
        try #require(processIsAlive(childPID), "the job must outlive the holder for this to mean anything")

        let reacquired = try HolderLock.acquire(path: fixture.lockPath)
        reacquired.release()
        #expect(reacquired.fileDescriptor >= 0)
    }

    // MARK: 7 — a job gets a terminal and nothing else

    /// The named closes cover the two descriptors the holder knows it holds.
    /// They cannot cover the ones it does not: anything its spawner had open
    /// without `FD_CLOEXEC` arrives unannounced and, without the sweep, ends up
    /// in a job that outlives every process anybody would think to look at.
    ///
    /// Measured, not hypothetical — this repo's build wrapper holds a
    /// machine-global `flock`, and before the sweep a `sleep` job that had
    /// inherited it went on blocking every other worktree's build after its
    /// holder, its test process and its harness were all gone.
    ///
    /// The probe writes THROUGH the descriptor rather than asking whether
    /// something is open at that number: `[ -e /dev/fd/N ]` answers the weaker
    /// question, and the shell's own machinery can transiently park a
    /// descriptor on N. A write can only reach the probe file if the probe file
    /// is still what N refers to. The `ran` marker is the positive control —
    /// without it, an empty probe file would also be what "the job never
    /// started" looks like.
    ///
    /// Nothing here depends on the holder observing or reporting an exit, so
    /// machine load cannot turn the assertion into a timeout.
    @Test func theJobDoesNotInheritStrayDescriptors() throws {
        let home = HolderFixture.scratchHome()
        let probe = HolderFixture.strayDescriptorNumber
        let script = [
            "echo LEAKED >&\(probe) 2>/dev/null",
            "echo RAN > '\(home)/ran.marker'",
            "sleep 120",
        ].joined(separator: "; ")
        let launch = HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: "/tmp",
            environment: Self.rcFreeEnvironment,
            columns: 80,
            rows: 24)
        let fixture = try HolderFixture.start(launch: launch, strayDescriptorProbe: true, home: home)
        defer { fixture.tearDown() }
        fixture.waitForSocket()

        let client = try fixture.connect()
        defer { client.close() }
        guard case .described(let description) = try client.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        waitUntil("the job to run past its probe") {
            FileManager.default.fileExists(atPath: home + "/ran.marker")
        }
        let leaked = (try? String(contentsOfFile: home + "/stray.probe", encoding: .utf8)) ?? ""
        #expect(
            leaked.isEmpty,
            "a descriptor the holder never asked for reached the job through fd \(probe)")
    }

    // MARK: 8 — the job's signal dispositions are its own

    /// **The job must not start with SIGPIPE ignored.** The holder ignores
    /// SIGHUP and SIGPIPE so its spawner's death is not its own, but `SIG_IGN`
    /// is inherited across fork AND exec — so without an explicit reset between
    /// the two, every job would run with SIGPIPE ignored and `yes | head` would
    /// spin forever instead of terminating.
    ///
    /// The probe is the shell's own rule that a signal ignored on entry cannot
    /// be trapped or reset. A job whose SIGPIPE was reset to `SIG_DFL` installs
    /// the trap, takes the signal it sends itself, and writes the marker; a job
    /// that inherited `SIG_IGN` could not install the trap, never sees the
    /// signal, and leaves the marker absent. The `ran` marker is the positive
    /// control, so "no marker" cannot be satisfied by a job that never started.
    @Test func theJobDoesNotStartWithSIGPIPEIgnored() throws {
        let home = HolderFixture.scratchHome()
        let script = [
            "trap 'echo TRAPPED > \"\(home)/sigpipe.marker\"; exit 42' PIPE",
            "echo RAN > '\(home)/ran.marker'",
            "kill -PIPE $$",
            "sleep 120",
        ].joined(separator: "; ")
        let launch = HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: "/tmp",
            environment: Self.rcFreeEnvironment,
            columns: 80,
            rows: 24)
        let fixture = try HolderFixture.start(launch: launch, home: home)
        defer { fixture.tearDown() }
        fixture.waitForSocket()

        let client = try fixture.connect()
        defer { client.close() }
        guard case .described(let description) = try client.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        waitUntil("the job to run past its trap") {
            FileManager.default.fileExists(atPath: home + "/ran.marker")
        }
        waitUntil("the job to take its SIGPIPE trap") {
            FileManager.default.fileExists(atPath: home + "/sigpipe.marker")
        }
        #expect(
            FileManager.default.fileExists(atPath: home + "/sigpipe.marker"),
            "the job could not install a SIGPIPE trap, so SIGPIPE was still ignored at exec")
    }

    // MARK: 9 — reporting the exit

    /// The holder exits when its job does, but only after telling a connected
    /// client what happened. The exit is triggered from here — through the
    /// handed-over pty, so the client is connected the whole time and the report
    /// cannot race a fresh connection. Driving it through the master also makes
    /// this the one test that proves *input* survives the hand-over; test 4
    /// only proves output does.
    ///
    /// **The reader has to keep draining while it waits.** The job is the pty's
    /// session leader, so its exit blocks in `ttywait` until the tty's output
    /// queue is empty, and the four bytes of canonical echo for `"go\n"` are
    /// enough to wedge it forever — the holder must never drain them itself.
    /// See `drainPTY`.
    @Test func reportsTheJobsExitCodeToAConnectedClient() throws {
        // Every path this job touches lives under the fixture's own scratch
        // root. A fixed `/tmp/…` name is shared by every concurrent run of this
        // suite on the machine — several worktrees test here at once — so one
        // run could satisfy or clobber another's marker.
        let home = HolderFixture.scratchHome()
        let launch = HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", "read line; echo DONE > '\(home)/read.marker'; exit 7"],
            workingDirectory: "/tmp",
            environment: Self.rcFreeEnvironment,
            columns: 80,
            rows: 24)
        let fixture = try HolderFixture.start(launch: launch, home: home)
        defer { fixture.tearDown() }
        fixture.waitForSocket()

        let client = try fixture.connect(receiveTimeout: 15.0)
        defer { client.close() }
        let (response, fds) = try client.requestWithFDs(.handOverPTY)
        defer { fds.forEach { close($0) } }
        guard case .handedOverPTY(let description) = response else {
            Issue.record("expected .handedOverPTY, got \(response)\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        // `forkpty` leaves the line discipline canonical, so a newline is what
        // completes the job's `read`.
        let pty = try #require(fds.first)
        let line = Array("go\n".utf8)
        #expect(write(pty, line, line.count) == line.count)
        var echoed = Data()
        waitUntil("the job to finish its read and exit") {
            drainPTY(pty, into: &echoed)
            return !processIsAlive(description.childPID)
        }
        // The positive control: without it, a job that never received the line
        // and was killed by teardown would look the same as one that ran.
        #expect(
            FileManager.default.fileExists(atPath: home + "/read.marker"),
            "the job never completed its read, so nothing written to the master reached it")

        let final = try client.awaitTerminalStatus()
        #expect(final.status == .exited(code: 7))
        #expect(final.childPID == description.childPID)

        // Having reported, the holder is done: it unlinks its rendezvous and
        // goes, rather than sitting on a socket nothing can use.
        waitUntil("the holder to unlink its socket and exit") {
            !FileManager.default.fileExists(atPath: fixture.socketPath)
                && !processIsAlive(fixture.holderPID)
        }
    }

    /// A job killed by a signal has no exit code. The holder must say it could
    /// not observe one rather than reporting a number that downstream cannot
    /// tell apart from a real exit.
    @Test func reportsAnUnknownStatusForASignalledJob() throws {
        let fixture = try HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        fixture.waitForSocket()

        let client = try fixture.connect(receiveTimeout: 15.0)
        defer { client.close() }
        guard case .described(let description) = try client.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        kill(description.childPID, SIGKILL)
        let final = try client.awaitTerminalStatus()
        #expect(final.status == .exitedStatusUnknown)
    }
}
