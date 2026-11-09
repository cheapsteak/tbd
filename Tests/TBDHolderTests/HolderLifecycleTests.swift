import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDHolder
import TBDKernel

/// Live-process tests for the holder.
///
/// Serialized because each one spawns real processes and a pty, and the point
/// of several of them is a claim about process death — running them alongside
/// each other would make a failure ambiguous about whose child died.
@Suite("Holder lifecycle", .serialized)
struct HolderLifecycleTests {
    private static let rcFreeEnvironment = ["PATH": "/usr/bin:/bin", "TERM": "dumb"]

    /// A job that does nothing but stay alive. It ends on its own after
    /// `TestDeadlines.outlivingChildSeconds`, long enough to outlive the
    /// fixture's bootstrap waits, `waitForSocket` and the test's own wait;
    /// teardown kills it sooner.
    private static func idleJob(marker: String = "") -> HolderLaunchRequest {
        let stayAlive = "sleep \(TestDeadlines.outlivingChildSeconds)"
        return HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", marker.isEmpty ? stayAlive : "printf '\(marker)\\n'; \(stayAlive)"],
            workingDirectory: "/tmp",
            environment: rcFreeEnvironment,
            columns: 100,
            rows: 30)
    }

    // MARK: 1 — it binds and describes

    @Test func holderBindsItsSocketAndDescribesItsChild() async throws {
        let fixture = try await HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        await fixture.waitForSocket()

        let client = try await fixture.connect()
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
    @Test func childSurvivesTheSpawningProcessExiting() async throws {
        let fixture = try await HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        await fixture.waitForSocket()

        #expect(fixture.spawnerExitStatus == 0, "the bootstrap shell should have exited cleanly")

        let client = try await fixture.connect()
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
    @Test func secondConcurrentClientIsRejected() async throws {
        let fixture = try await HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        await fixture.waitForSocket()

        let first = try await fixture.connect()
        defer { first.close() }
        guard case .described(let description) = try first.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        let second = try await fixture.connect()
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
    @Test func handsOverAPTYThatCarriesChildOutput() async throws {
        let fixture = try await HolderFixture.start(launch: Self.idleJob(marker: "HOLDER-OK"))
        defer { fixture.tearDown() }
        await fixture.waitForSocket()

        let client = try await fixture.connect()
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
        await waitUntil("the job's output on the handed-over pty") {
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
    @Test func forgetStopsReportingAndDoesNotResurrectTheChild() async throws {
        let fixture = try await HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        await fixture.waitForSocket()

        let client = try await fixture.connect()
        guard case .described(let description) = try client.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        #expect(try client.request(.forget) == .forgotten)
        client.close()

        await waitUntil("the holder to unlink its socket and exit") {
            !FileManager.default.fileExists(atPath: fixture.socketPath)
                && !processIsAlive(fixture.holderPID)
        }
        #expect(!processIsAlive(fixture.holderPID))
        // Nothing may report the child any more, and nothing may bring a new
        // holder up in its place on its own. `connect` throws at once here and
        // does not wait out its deadline: with the socket gone the attempt
        // fails with ENOENT, which it never retries, and a socket file left
        // behind would be refused by a dead holder, which it never retries
        // either.
        await #expect(throws: TestHolderError.self) {
            _ = try await fixture.connect(receiveTimeout: 1.0)
        }
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
    @Test func theJobDoesNotInheritTheCreationLock() async throws {
        let fixture = try await HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        await fixture.waitForSocket()

        // **The master is taken and held**, which is what keeps the job alive
        // across the kill below — and it is what the daemon holds in production
        // while it reads. A job now really does get `SIGHUP` when the *last*
        // descriptor on its pty closes, which killing the sole holder would
        // otherwise do: it did not used to, because the job inherited the
        // spawning thread's signal mask with SIGHUP among nineteen others
        // blocked, and `Holder.spawnChild` now clears that mask. Arranging the
        // job's survival through a `trap` instead does not work, and looks like
        // it does: bash restores a trapped signal to its startup disposition in
        // any child it forks, so the `sleep` dies and the shell exits with it.
        let childPID: Int32
        var master: Int32 = -1
        do {
            let client = try await fixture.connect()
            defer { client.close() }
            let (response, fds) = try client.requestWithFDs(.handOverPTY)
            guard case .handedOverPTY(let description) = response, let received = fds.first else {
                for descriptor in fds { close(descriptor) }
                Issue.record("expected .handedOverPTY with a descriptor\n\(fixture.diagnostics())")
                return
            }
            for descriptor in fds.dropFirst() { close(descriptor) }
            master = received
            childPID = description.childPID
            fixture.trackChild(childPID)
        }
        defer { close(master) }

        kill(fixture.holderPID, SIGKILL)
        await waitUntil("the holder to die") { !processIsAlive(fixture.holderPID) }
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
    @Test func theJobDoesNotInheritStrayDescriptors() async throws {
        let home = HolderFixture.scratchHome()
        let probe = HolderFixture.strayDescriptorNumber
        // The job has to be alive until it is described, after the fixture's
        // waits and `waitForSocket`: a holder whose job exited unlinks its
        // socket ten seconds later.
        let script = [
            "echo LEAKED >&\(probe) 2>/dev/null",
            "echo RAN > '\(home)/ran.marker'",
            "sleep \(TestDeadlines.outlivingChildSeconds)",
        ].joined(separator: "; ")
        let launch = HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: "/tmp",
            environment: Self.rcFreeEnvironment,
            columns: 80,
            rows: 24)
        let fixture = try await HolderFixture.start(launch: launch, strayDescriptorProbe: true, home: home)
        defer { fixture.tearDown() }
        await fixture.waitForSocket()

        let client = try await fixture.connect()
        defer { client.close() }
        guard case .described(let description) = try client.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        await waitUntil("the job to run past its probe") {
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
    @Test func theJobDoesNotStartWithSIGPIPEIgnored() async throws {
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
        let fixture = try await HolderFixture.start(launch: launch, home: home)
        defer { fixture.tearDown() }
        await fixture.waitForSocket()

        let client = try await fixture.connect()
        defer { client.close() }
        guard case .described(let description) = try client.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        fixture.trackChild(description.childPID)

        await waitUntil("the job to run past its trap") {
            FileManager.default.fileExists(atPath: home + "/ran.marker")
        }
        await waitUntil("the job to take its SIGPIPE trap") {
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
    @Test func reportsTheJobsExitCodeToAConnectedClient() async throws {
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
        let fixture = try await HolderFixture.start(launch: launch, home: home)
        defer { fixture.tearDown() }
        await fixture.waitForSocket()

        let client = try await fixture.connect(receiveTimeout: 15.0)
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
        await waitUntil("the job to finish its read and exit") {
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
        await waitUntil("the holder to unlink its socket and exit") {
            !FileManager.default.fileExists(atPath: fixture.socketPath)
                && !processIsAlive(fixture.holderPID)
        }
    }

    /// A job killed by a signal has no exit code. The holder must say it could
    /// not observe one rather than reporting a number that downstream cannot
    /// tell apart from a real exit.
    @Test func reportsAnUnknownStatusForASignalledJob() async throws {
        let fixture = try await HolderFixture.start(launch: Self.idleJob())
        defer { fixture.tearDown() }
        await fixture.waitForSocket()

        let client = try await fixture.connect(receiveTimeout: 15.0)
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

    // MARK: 11 — the client that arrives after the child is already gone

    /// A job that publishes its own pid, waits to be released, and exits with
    /// `code`.
    ///
    /// It writes nothing to its terminal, which is what makes these tests
    /// possible at all: a job that had written would block in `ttywait` until
    /// somebody drained the master, so it could never reach a reaped state
    /// *before* a client connected. See `drainPTY`. Bounded so a job that
    /// somehow escapes teardown reaps itself.
    private static func jobThatExitsOnCue(home: String, code: Int32) -> HolderLaunchRequest {
        let script = [
            "echo $$ > '\(home)/job.pid'",
            "i=0",
            "while [ ! -e '\(home)/go' ] && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done",
            "exit \(code)",
        ].joined(separator: "; ")
        return HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: "/tmp",
            environment: rcFreeEnvironment,
            columns: 80,
            rows: 24)
    }

    /// Waits for `jobThatExitsOnCue` to publish its pid, and hands the pid to
    /// the fixture so teardown reclaims the job.
    private static func awaitJobPID(home: String, fixture: HolderFixture) async throws -> Int32 {
        let path = home + "/job.pid"
        func published() -> Int32? {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pid > 0
            else { return nil }
            return pid
        }
        let reported = await waitUntil("the job to report its pid\n\(fixture.diagnostics())") {
            published() != nil
        }
        try #require(reported)
        let jobPID = try #require(published())
        fixture.trackChild(jobPID)
        return jobPID
    }

    /// A poll slice longer than every wait in a test, passed as
    /// `--poll-slice-ms`. The job's exit wakes nothing the holder polls, so a
    /// holder given this slice notices the exit only when something else
    /// wakes it, and the test decides what that is.
    private static let pollSliceOutlivingTheTest = Int32(TestDeadlines.outlivingChildSeconds) * 1000

    /// Releases a holder's job only once no holder thread is running or in an
    /// uninterruptible wait, and returns once the job has exited and sat
    /// unreaped for two of the holder's default poll slices.
    ///
    /// The long slice alone does not order the release against the reap. The
    /// holder reaps at the top of every pass of its loop, so a pass that the
    /// test's last request or connect started can still be on its way to
    /// `poll` when the job exits, and then it reaps before the test wakes it.
    /// A holder blocked interruptibly after that request or connect is almost
    /// always parked in `poll`, having already looked at the job, found it
    /// alive, and stopped looking until the test wakes it. It could instead be
    /// blocked in a `send`, an `accept` or a log write, but the next step from
    /// any of those is the non-blocking `waitpid` at the top of the loop. A
    /// job released then is reaped before the test wakes the holder, and the
    /// wait below reports that as `jobReapedBeforeTheTestWokeTheHolder`. The
    /// leftover case fails loudly; it cannot let a broken holder pass.
    ///
    /// The two slices prove the holder is running the long slice: one running
    /// the default would have reaped the job inside them. A job reaped anyway
    /// means the gap never held open, most likely because the holder ignored
    /// `--poll-slice-ms`. That is a broken premise rather than a slow one, so
    /// it fails at once instead of at the deadline.
    private static func releaseJobAndHoldItUnreaped(
        jobPID: Int32, home: String, fixture: HolderFixture
    ) async throws {
        let holderPID = fixture.holderPID
        let parked = await waitUntil(
            """
            the holder to park in poll (thread run states \
            \(threadRunStates(holderPID).map { "\($0)" } ?? "unreadable"))
            \(fixture.diagnostics())
            """
        ) { processIsWaitingInterruptibly(holderPID) }
        try #require(parked)

        FileManager.default.createFile(atPath: home + "/go", contents: nil)
        let unreapedFor = Duration.milliseconds(2 * Int(HolderArguments.defaultPollSliceMilliseconds))
        var firstSeenUnreaped: ContinuousClock.Instant?
        let settled = await waitUntil("job \(jobPID) to exit and stay unreaped\n\(fixture.diagnostics())") {
            // A reaped job ends the wait too, so the guard below reports it
            // at once.
            guard processIsZombie(jobPID) else { return !processIsAlive(jobPID) }
            let since = firstSeenUnreaped ?? ContinuousClock.now
            firstSeenUnreaped = since
            return ContinuousClock.now - since >= unreapedFor
        }
        try #require(settled)
        guard processIsZombie(jobPID) else {
            throw TestHolderError.jobReapedBeforeTheTestWokeTheHolder(
                jobPID: jobPID, diagnostics: fixture.diagnostics())
        }
    }

    /// Reads the busy refusal `probe` must get while another client holds the
    /// holder's one slot. `meaning` says what its absence reveals.
    private static func requireRefusal(
        of probe: TestHolderClient, meaning: String, fixture: HolderFixture
    ) throws {
        let refusal = try probe.receive()
        guard refusal == .rejected(version: HolderProtocolVersion.busySentinel) else {
            throw TestHolderError.unexpectedResponse(
                expected: ".rejected(busy sentinel)", observed: "\(refusal)",
                meaning: meaning, diagnostics: fixture.diagnostics())
        }
    }

    /// Brings up a holder, releases its job, and returns once the holder has
    /// **reaped** it — with no client having ever connected.
    ///
    /// The pid disappearing is precisely "reaped": a zombie still answers
    /// `kill(pid, 0)` until its parent collects it, so `!processIsAlive` cannot
    /// become true until the holder's `waitpid` has run and the exit window is
    /// armed. Everything after this point is the state a daemon finds when it
    /// restarts and comes back for a job that finished while it was away.
    private static func holderWithAnAlreadyExitedChild(
        code: Int32
    ) async throws -> (fixture: HolderFixture, jobPID: Int32) {
        let home = HolderFixture.scratchHome()
        let fixture = try await HolderFixture.start(launch: jobThatExitsOnCue(home: home, code: code), home: home)
        await fixture.waitForSocket()
        let jobPID = try await awaitJobPID(home: home, fixture: fixture)

        FileManager.default.createFile(atPath: home + "/go", contents: nil)
        await waitUntil("the holder to reap its exited job") { !processIsAlive(jobPID) }
        return (fixture, jobPID)
    }

    /// **The primary re-adoption path.** A daemon that was restarting when the
    /// job finished comes back, connects, and asks for the pty.
    ///
    /// The holder used to greet such a client with an unsolicited `.described`
    /// frame at accept time: it landed where this request's answer belonged, so
    /// the hand-over came back with no descriptor, and the collection that
    /// frame recorded then ended the serve loop before the request was ever
    /// read. Every existing hand-over test connects while the child is alive,
    /// which is why it shipped.
    @Test func handsOverThePTYToAClientThatArrivesAfterTheChildExited() async throws {
        let (fixture, jobPID) = try await Self.holderWithAnAlreadyExitedChild(code: 7)
        defer { fixture.tearDown() }

        let client = try await fixture.connect()
        defer { client.close() }
        let (response, fds) = try client.requestWithFDs(.handOverPTY)
        defer { fds.forEach { close($0) } }

        guard case .handedOverPTY(let description) = response else {
            Issue.record("expected .handedOverPTY, got \(response)\n\(fixture.diagnostics())")
            return
        }
        #expect(fds.count == 1, "the master must still ride the hand-over after the child has gone")
        #expect(description.status == .exited(code: 7))
        #expect(description.childPID == jobPID)
    }

    /// The same client, arriving in the gap between the job's exit and the
    /// holder noticing it.
    ///
    /// The exit wakes nothing the holder polls, so it learns of it only at its
    /// next `waitpid`, up to a poll slice later. A client whose connect lands
    /// in that gap wakes the poll and is accepted before the reap. A holder
    /// that pushed at it as though it had been connected when the job exited
    /// would disconnect it with its request unread: the greeting the test
    /// above rules out, reached by timing instead. A job that exits at once
    /// can land a test in the gap, and `theJobDoesNotStartWithSIGPIPEIgnored`
    /// failed with `.sendFailed(32)` whenever it did and the holder's close
    /// beat that test's first write.
    ///
    /// A poll slice longer than the test holds the gap open, so this needs no
    /// luck. The job exits while the holder is parked in `poll` and stays a
    /// zombie, because nothing else reaps it, and this client's connect is
    /// what wakes the holder. A holder that pushes at whatever client it finds
    /// connected when it reaps either answers the hand-over with that bare
    /// `.described` or has hung up before the request is written.
    @Test func handsOverThePTYToAClientThatArrivesBeforeTheExitIsReaped() async throws {
        let home = HolderFixture.scratchHome()
        let fixture = try await HolderFixture.start(
            launch: Self.jobThatExitsOnCue(home: home, code: 5),
            home: home,
            pollSliceMilliseconds: Self.pollSliceOutlivingTheTest)
        defer { fixture.tearDown() }
        await fixture.waitForSocket()
        let jobPID = try await Self.awaitJobPID(home: home, fixture: fixture)
        try await Self.releaseJobAndHoldItUnreaped(jobPID: jobPID, home: home, fixture: fixture)

        let client = try await fixture.connect()
        defer { client.close() }
        let (response, fds) = try client.requestWithFDs(.handOverPTY)
        defer { fds.forEach { close($0) } }
        guard case .handedOverPTY(let description) = response else {
            throw TestHolderError.unexpectedResponse(
                expected: ".handedOverPTY", observed: "\(response)",
                meaning: "the holder pushed the exit at a client it had not answered yet",
                diagnostics: fixture.diagnostics())
        }
        #expect(fds.count == 1, "the master must ride the hand-over")
        #expect(description.status == .exited(code: 5))
        #expect(description.childPID == jobPID)
    }

    /// A client the holder admitted while the job was alive, and has not yet
    /// answered when the holder reaps it.
    ///
    /// Being connected when the exit happened does not make a push safe: the
    /// client has asked nothing yet, so the next frame on its socket belongs
    /// to its first request, and a holder that pushed and wound down would
    /// close before reading it. This is the daemon connecting to a holder
    /// whose job ends a moment later, before its first verb is written.
    ///
    /// A first refused connection proves the client was admitted while the
    /// job was alive: the holder refuses a connection only while it has one,
    /// and accepts in arrival order. The long slice keeps the job unreaped
    /// until a second refused connection wakes the holder, and the pid
    /// disappearing after that proves the reap happened while the client was
    /// connected and silent. The long slice also keeps the exit-report window
    /// out of it: the holder checks that window only before it polls, so the
    /// request is served however long it takes to arrive.
    @Test func handsOverThePTYToAClientThatWasConnectedButUnansweredWhenTheJobExited() async throws {
        let home = HolderFixture.scratchHome()
        let fixture = try await HolderFixture.start(
            launch: Self.jobThatExitsOnCue(home: home, code: 6),
            home: home,
            pollSliceMilliseconds: Self.pollSliceOutlivingTheTest)
        defer { fixture.tearDown() }
        await fixture.waitForSocket()
        let jobPID = try await Self.awaitJobPID(home: home, fixture: fixture)

        let client = try await fixture.connect()
        defer { client.close() }
        let admissionProbe = try await fixture.connect()
        defer { admissionProbe.close() }
        try Self.requireRefusal(
            of: admissionProbe, meaning: "the holder had not admitted the first client", fixture: fixture)

        try await Self.releaseJobAndHoldItUnreaped(jobPID: jobPID, home: home, fixture: fixture)

        let waker = try await fixture.connect()
        defer { waker.close() }
        try Self.requireRefusal(
            of: waker, meaning: "the holder no longer held the first client when it woke", fixture: fixture)
        let reaped = await waitUntil("the holder to reap job \(jobPID)\n\(fixture.diagnostics())") {
            !processIsAlive(jobPID)
        }
        try #require(reaped)

        let (response, fds) = try client.requestWithFDs(.handOverPTY)
        defer { fds.forEach { close($0) } }
        guard case .handedOverPTY(let description) = response else {
            throw TestHolderError.unexpectedResponse(
                expected: ".handedOverPTY", observed: "\(response)",
                meaning: "the holder pushed the exit at a client it had admitted but not answered",
                diagnostics: fixture.diagnostics())
        }
        #expect(fds.count == 1, "the master must ride the hand-over")
        #expect(description.status == .exited(code: 6))
        #expect(description.childPID == jobPID)
    }

    /// A client the holder has answered, whose next request is part-way in
    /// when the holder reaps the job.
    ///
    /// The wire carries no request identifier, so a push landing while a
    /// request is on its way would be read as that request's answer, and the
    /// holder winding down after it would never read the request. The bytes
    /// already buffered say a request is coming; the holder serves it, and
    /// its answer carries the status.
    ///
    /// The long poll slice orders the steps. The job exits while the holder
    /// is parked in `poll` and stays a zombie; the first piece of the frame is
    /// what wakes the holder, which reads it, finds the frame incomplete, and
    /// reaps before polling again. The pid disappearing proves the reap
    /// happened with the partial frame buffered, and only then does the rest
    /// of it go out.
    @Test func handsOverThePTYForARequestPartlyReadWhenTheJobWasReaped() async throws {
        let home = HolderFixture.scratchHome()
        let fixture = try await HolderFixture.start(
            launch: Self.jobThatExitsOnCue(home: home, code: 8),
            home: home,
            pollSliceMilliseconds: Self.pollSliceOutlivingTheTest)
        defer { fixture.tearDown() }
        await fixture.waitForSocket()
        let jobPID = try await Self.awaitJobPID(home: home, fixture: fixture)

        let client = try await fixture.connect()
        defer { client.close() }
        let first = try client.request(.describe)
        guard case .described(let alive) = first else {
            throw TestHolderError.unexpectedResponse(
                expected: ".described", observed: "\(first)",
                meaning: "the holder did not answer the client's first request",
                diagnostics: fixture.diagnostics())
        }
        #expect(alive.status == .alive)

        try await Self.releaseJobAndHoldItUnreaped(jobPID: jobPID, home: home, fixture: fixture)

        let frame = try HolderFraming.frame(HolderRequest.handOverPTY)
        let lengthPrefix = MemoryLayout<UInt32>.size
        try client.sendBytes(frame.prefix(lengthPrefix))
        let reaped = await waitUntil("the holder to reap job \(jobPID)\n\(fixture.diagnostics())") {
            !processIsAlive(jobPID)
        }
        try #require(reaped)
        try client.sendBytes(frame.dropFirst(lengthPrefix))

        let (response, fds) = try client.receiveWithFDs()
        defer { fds.forEach { close($0) } }
        guard case .handedOverPTY(let description) = response else {
            throw TestHolderError.unexpectedResponse(
                expected: ".handedOverPTY", observed: "\(response)",
                meaning: "the holder pushed the exit over a request it had begun to read",
                diagnostics: fixture.diagnostics())
        }
        #expect(fds.count == 1, "the master must ride the hand-over")
        #expect(description.status == .exited(code: 8))
        #expect(description.childPID == jobPID)
    }

    /// The same client, asking the cheaper question. Two claims, and the first
    /// is what the second rests on: the holder says **nothing** to a client
    /// that has asked for nothing, and then answers what it is asked.
    @Test func describesAnAlreadyExitedChildOnlyWhenAsked() async throws {
        let (fixture, jobPID) = try await Self.holderWithAnAlreadyExitedChild(code: 3)
        defer { fixture.tearDown() }

        // The silence probe waits out its whole receive timeout, so it gets a
        // short one. A greeting would be sent at accept time, the instant the
        // holder's poll wakes on the connect, so one that was coming arrives
        // long before 0.3 s. The answer to the real request below gets the
        // ordinary budget back.
        let client = try await fixture.connect(receiveTimeout: 0.3)
        defer { client.close() }
        #expect(
            try client.frameArrivingUnsolicited() == nil,
            "the holder greeted a client that had asked for nothing")
        client.setReceiveTimeout(5.0)

        guard case .described(let description) = try client.request(.describe) else {
            Issue.record("expected .described\n\(fixture.diagnostics())")
            return
        }
        #expect(description.status == .exited(code: 3))
        #expect(description.childPID == jobPID)
    }

    /// `forget` must work on this path too, and it is the request the old
    /// behaviour could never answer: the connection was already torn down.
    @Test func forgetsForAClientThatArrivesAfterTheChildExited() async throws {
        let (fixture, _) = try await Self.holderWithAnAlreadyExitedChild(code: 0)
        defer { fixture.tearDown() }

        let client = try await fixture.connect()
        #expect(try client.request(.forget) == .forgotten)
        client.close()

        await waitUntil("the holder to unlink its socket and exit") {
            !FileManager.default.fileExists(atPath: fixture.socketPath)
                && !processIsAlive(fixture.holderPID)
        }
        #expect(!processIsAlive(fixture.holderPID))
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath))
    }
}
