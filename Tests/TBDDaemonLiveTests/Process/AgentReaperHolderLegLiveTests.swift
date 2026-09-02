import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// `AgentReaper`'s holder leg against the kernel's own answers about real pids.
///
/// **Tier 3.** Every process here is real: the orphan it reaps, the stranger it
/// must not touch, the pid it is handed after that pid's process is already
/// gone, and the job that refuses SIGTERM and can only be ended by SIGKILL. The
/// identity check is the whole point of the suite — it exists to make sure the
/// leg can tell one from another using `ps`, not using a fake that was told the
/// answer.
///
/// The escalation tests at the bottom are the other half: `reapVerified`'s
/// SIGTERM → grace → re-decide → SIGKILL sequence, driven through the real
/// `ProductionProcessSignaller` against a real session leader whose disposition
/// for SIGTERM is *ignore*. They exist because every other fixture in this file
/// dies on the first SIGTERM, which leaves the highest-consequence branch of a
/// process-killing guard — the group-widening `kill(-pid, SIGKILL)` — proven
/// only by a dictionary swap in the scripted suite.
///
/// The companion `AgentReaperHolderLegTests` in `TBDDaemonTests` scripts the
/// same matrix through `FakeProcessSignaller`; it can state cases this one
/// cannot arrange (an unreadable start time) and runs in the parallel pass.
/// This suite is `.serialized` and lives in the live target because it spawns
/// processes and waits on real deadlines.
@Suite(.serialized)
struct AgentReaperHolderLegLiveTests {

    // MARK: - Process helpers

    /// A job that survives a hangup — the shape the acceptance harness measured
    /// outliving its teardown at `ppid=1` while its default-disposition sibling
    /// died. Spawned through `zsh -c` with no `-l`/`-i`, so it sources nothing
    /// from the developer's shell configuration.
    private static func spawnHangupProofShell() throws -> Process {
        try spawn("/bin/zsh", ["-c", #"trap "" HUP; while :; do sleep 0.2; done"#])
    }

    /// A live process that is emphatically not a holder's job: `cat` blocking
    /// on a pipe nobody writes to. Its argv[0] basename is neither a login
    /// shell nor an agent binary, which is exactly the fact under test.
    private static func spawnForeignExecutable() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cat")
        // An unwritten pipe, so `cat` blocks in `read` instead of seeing EOF on
        // an inherited stdin and exiting immediately.
        p.standardInput = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    private static func spawn(_ path: String, _ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// A pid whose process has already exited and been collected — the "gone"
    /// case, obtained by running something that exits immediately and waiting
    /// for it. Darwin allocates pids sequentially, so the number is not about
    /// to be handed to somebody else mid-test.
    private static func spentPID() throws -> Int32 {
        let p = try spawn("/usr/bin/true", [])
        p.waitUntilExit()
        return p.processIdentifier
    }

    /// True while the kernel still knows this pid. Deliberately `kill(pid, 0)`,
    /// the same call the reaper's own liveness check makes.
    private static func pidExists(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func waitForPIDToVanish(
        _ pid: Int32, within seconds: Double = 10
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !pidExists(pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !pidExists(pid)
    }

    private static func killAndReap(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    // MARK: - A job that only SIGKILL can end

    /// A live job whose disposition for SIGTERM (and SIGHUP) is **ignore**, in
    /// its own session, with a descendant sharing its process group.
    ///
    /// This is the fixture the escalation branch needs and no other test in the
    /// file has: `spawnHangupProofShell` traps only SIGHUP, so it dies on the
    /// reaper's first `terminate` and never reaches SIGKILL.
    ///
    /// Two details are load-bearing rather than decorative:
    ///
    /// - **`trap '' TERM` is the ignore form, and ignore is what survives.** A
    ///   disposition of *ignore* is inherited across both `fork` and `execve`;
    ///   a disposition of *handled* (`trap 'handler' TERM`) is reset to the
    ///   default in any child, so a handler-based fixture is SIGTERM-proof only
    ///   in the shell that installed it and races itself under load.
    /// - **`POSIX_SPAWN_SETSID` reproduces the holder's `setsid`.** The
    ///   group-widening in `ProductionProcessSignaller.signal` is conditional on
    ///   `getpgid(pid) == pid`; without the new session the job inherits the
    ///   test runner's process group, `signal` degrades to pid-exact, and the
    ///   group test would fail for a reason that has nothing to do with the
    ///   reaper. The tests assert the leadership rather than assume it.
    private struct SIGTERMProofJob {
        let jobPID: pid_t
        let grandchildPID: pid_t
        let scratch: URL

        /// Best-effort, and pid-exact plus group — never a pattern kill.
        func tearDown() {
            kill(grandchildPID, SIGKILL)
            kill(-jobPID, SIGKILL)
            kill(jobPID, SIGKILL)
            var status: Int32 = 0
            // SIGKILL cannot be blocked, so this is bounded; it returns
            // immediately with ECHILD if the test already reaped the job.
            _ = waitpid(jobPID, &status, 0)
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    private struct FixtureSpawnFailure: Error { let code: Int32 }

    /// Spawns the job above and waits, bounded, for it to publish its
    /// descendant's pid.
    private static func spawnSIGTERMProofJob() async throws -> SIGTERMProofJob {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-reaper-esc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let pidFile = scratch.appendingPathComponent("grandchild.pid")

        // The descendant re-opens /dev/null on 0/1/2 for itself as well as
        // inheriting it, because the measured hazard was a job that could not be
        // killed by a write error on a vanished pty. Nothing here has a pty at
        // all, and the test asserts the three fds afterwards.
        // Both loops are **counted**, not `while :`. A process this test spawns
        // and cannot reach again — the test host killed mid-run, which happens
        // on a shared machine — would otherwise spin forever with no reconciler
        // that can see it. 1500 × 0.2 s is ~5 minutes: two orders of magnitude
        // past what the assertions need, and self-limiting regardless.
        let script = #"""
            trap '' TERM HUP INT
            { trap '' TERM HUP INT; exec 0</dev/null 1>/dev/null 2>/dev/null
              for _ in {1..1500}; do sleep 0.2; done } &
            echo $! > '@PIDFILE@'
            for _ in {1..1500}; do sleep 0.2; done
            """#.replacingOccurrences(of: "@PIDFILE@", with: pidFile.path)

        // No `-l`/`-i`, and a two-entry environment, so the fixture sources
        // nothing from the developer's shell configuration.
        let jobPID = try spawnSessionLeader(
            "/bin/zsh", ["-c", script], env: ["PATH=/usr/bin:/bin", "HOME=\(scratch.path)"])

        guard let grandchildPID = await readPID(from: pidFile) else {
            var status: Int32 = 0
            kill(-jobPID, SIGKILL)
            kill(jobPID, SIGKILL)
            _ = waitpid(jobPID, &status, 0)
            try? FileManager.default.removeItem(at: scratch)
            throw FixtureSpawnFailure(code: ETIMEDOUT)
        }
        return SIGTERMProofJob(jobPID: jobPID, grandchildPID: grandchildPID, scratch: scratch)
    }

    private static func readPID(from file: URL, within seconds: Double = 15) async -> pid_t? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// `posix_spawn` with `POSIX_SPAWN_SETSID` and `/dev/null` on 0/1/2.
    /// Foundation's `Process` cannot express the new session, and a probe
    /// confirmed its children inherit the runner's process group instead.
    ///
    /// **`SETSIGMASK` and `SETSIGDEF` are what make the fixture honest.** This
    /// spawn runs on a Swift-concurrency worker thread, and `HolderSpawner`
    /// measured those threads running with SIGHUP, SIGINT, SIGQUIT and SIGTERM
    /// (among nineteen others) blocked — a mask is inherited and survives
    /// `execve`, and so is a `SIG_IGN` disposition. Without these two flags the
    /// job would decline SIGTERM because the *test host's* mask said so, the
    /// escalation tests would go green on a mechanism the production path
    /// resets away, and `trap '' TERM` would be decoration. Starting from an
    /// empty mask and default dispositions leaves the trap as the only reason
    /// this job survives a SIGTERM — which is the fact the tests assert.
    private static func spawnSessionLeader(
        _ path: String, _ args: [String], env: [String]
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw FixtureSpawnFailure(code: errno)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        var attrs: posix_spawnattr_t?
        guard posix_spawnattr_init(&attrs) == 0 else { throw FixtureSpawnFailure(code: errno) }
        defer { posix_spawnattr_destroy(&attrs) }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attrs, &emptyMask)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attrs, &everySignal)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        guard posix_spawnattr_setflags(&attrs, Int16(flags)) == 0 else {
            throw FixtureSpawnFailure(code: errno)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) }
        envp.append(nil)
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fileActions, &attrs, &argv, &envp)
        guard rc == 0 else { throw FixtureSpawnFailure(code: rc) }
        return pid
    }

    /// Reaps the fixture job while waiting for it, so a zombie cannot be read as
    /// "still alive" — `kill(pid, 0)` answers 0 for a process this test has not
    /// yet collected, and every other liveness helper here goes through it.
    private static func waitForOwnChildToExit(
        _ pid: pid_t, within seconds: Double = 15
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var status: Int32 = 0
        while Date() < deadline {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { return true }
            if reaped == -1 && errno == ECHILD { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// True while the pid names a process that is actually **running**.
    ///
    /// Deliberately not `kill(pid, 0)`, which the rest of the suite can use
    /// safely and these tests cannot: the fixture job is this process's own
    /// child, so between its death and the test's `waitpid` it is a zombie —
    /// and a zombie answers `kill(pid, 0)` with success. A premise assertion
    /// built on that would read "it survived SIGTERM" off a process that
    /// SIGTERM had just killed, which is precisely the false green these tests
    /// exist to rule out. `ps -o stat=` prints `Z` for the zombie and nothing
    /// at all once it is collected.
    private static func isRunning(_ pid: Int32) -> Bool {
        guard let stat = ProductionProcessSignaller().stat(pid), !stat.isEmpty else { return false }
        return !stat.hasPrefix("Z")
    }

    /// True when the pid keeps running for the whole (bounded) interval.
    private static func staysRunning(_ pid: Int32, for seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isRunning(pid) { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return isRunning(pid)
    }

    private static func waitForProcessToStop(
        _ pid: Int32, within seconds: Double = 15
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isRunning(pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isRunning(pid)
    }

    /// fd number → open file name, from `lsof -Fn`. Used to prove the fixture's
    /// stdio really is `/dev/null`.
    private static func openFiles(ofPID pid: Int32) -> [String: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-p", String(pid), "-a", "-d", "0,1,2", "-Fn"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var result: [String: String] = [:]
        var fd: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            switch line.first {
            case "f": fd = String(line.dropFirst())
            case "n": if let fd { result[fd] = String(line.dropFirst()) }
            default: break
            }
        }
        return result
    }

    // MARK: - Subject

    private func reaper(
        _ signaller: RecordingProcessSignaller, records: [HolderChildRecord]
    ) -> AgentReaper {
        AgentReaper(
            tmux: NoTmuxQuerier(), signaller: signaller,
            // Bounded so a job that declines SIGTERM reaches SIGKILL inside the
            // test's own deadline rather than the production 3 seconds.
            graceAttempts: 20, pollInterval: .milliseconds(50),
            holderSessions: { records })
    }

    private func record(
        holderPID: Int32, childPID: Int32, createdAt: Date = Date()
    ) -> HolderChildRecord {
        HolderChildRecord(
            terminalID: UUID(), holderPID: holderPID, childPID: childPID, createdAt: createdAt)
    }

    // MARK: - The reap

    /// The case the leg exists for: a holder that died while the daemon was
    /// down, and a job that ignored the resulting hangup and reparented to
    /// launchd. `WorktreeLifecycle+Reconcile` skips holder rows and the tmux
    /// sweep enumerates children of tmux server pids, so nothing but this leg
    /// can see it.
    @Test func aGenuineOrphanIsReaped() async throws {
        let deadHolder = try Self.spentPID()
        let child = try Self.spawnHangupProofShell()
        defer { Self.killAndReap(child) }
        let childPID = child.processIdentifier
        #expect(Self.pidExists(childPID), "the orphan must be running before the sweep")

        let signaller = RecordingProcessSignaller()
        await reaper(signaller, records: [record(holderPID: deadHolder, childPID: childPID)])
            .sweepHolderChildren(enabled: true)

        #expect(
            await Self.waitForPIDToVanish(childPID),
            "pid \(childPID) survived the holder leg's sweep")
        #expect(signaller.terminated.contains(childPID))
    }

    // MARK: - The identity check earning its keep

    /// A pid that now belongs to a different executable is left alone. This is
    /// pid reuse as the reaper actually meets it: the number is live, the row
    /// says it was ours, and the only thing standing between the sweep and a
    /// stranger's process is the identity check.
    @Test func aPidBelongingToADifferentExecutableIsLeftAlone() async throws {
        let deadHolder = try Self.spentPID()
        let stranger = try Self.spawnForeignExecutable()
        defer { Self.killAndReap(stranger) }
        let strangerPID = stranger.processIdentifier

        let signaller = RecordingProcessSignaller()
        let subject = reaper(
            signaller, records: [record(holderPID: deadHolder, childPID: strangerPID)])
        #expect(
            subject.decideHolderChild(record(holderPID: deadHolder, childPID: strangerPID))
                == .keep(reason: "foreign-executable"))

        await subject.sweepHolderChildren(enabled: true)

        #expect(signaller.terminated.isEmpty, "a stranger's pid must never be signalled")
        #expect(signaller.killed.isEmpty)
        #expect(Self.pidExists(strangerPID), "pid \(strangerPID) was killed and should not have been")
        #expect(stranger.isRunning)
    }

    /// The other half of pid reuse, and the more dangerous one: the pid now
    /// belongs to a process that *would* pass the executable test — a shell —
    /// and only its start time says it is not ours. A row whose session was
    /// created hours ago cannot own a process that started a moment ago.
    @Test func aPidWhoseProcessStartedLongAfterTheRowIsLeftAlone() async throws {
        let deadHolder = try Self.spentPID()
        let stranger = try Self.spawnHangupProofShell()
        defer { Self.killAndReap(stranger) }
        let strangerPID = stranger.processIdentifier

        let ancientRow = record(
            holderPID: deadHolder, childPID: strangerPID,
            createdAt: Date().addingTimeInterval(-4 * 3600))
        let signaller = RecordingProcessSignaller()
        let subject = reaper(signaller, records: [ancientRow])
        #expect(subject.decideHolderChild(ancientRow) == .keep(reason: "start-time-mismatch"))

        await subject.sweepHolderChildren(enabled: true)

        #expect(signaller.terminated.isEmpty)
        #expect(Self.pidExists(strangerPID), "pid \(strangerPID) was killed and should not have been")
        #expect(stranger.isRunning)
    }

    /// A recorded pid whose process is gone is not signalled at all. The
    /// recorded number is not a licence to kill on the strength of the row.
    @Test func aRecordedPidWhoseProcessIsGoneIsNotSignalled() async throws {
        let deadHolder = try Self.spentPID()
        let spent = try Self.spentPID()
        #expect(!Self.pidExists(spent), "the fixture pid must really be gone")

        // A live bystander, so the assertion is not merely "nothing happened to
        // a pid nothing could happen to": if the leg were to signal blindly, it
        // would be signalling a number the kernel may hand out next.
        let bystander = try Self.spawnHangupProofShell()
        defer { Self.killAndReap(bystander) }

        let signaller = RecordingProcessSignaller()
        let subject = reaper(signaller, records: [record(holderPID: deadHolder, childPID: spent)])
        #expect(
            subject.decideHolderChild(record(holderPID: deadHolder, childPID: spent))
                == .keep(reason: "child-gone"))

        await subject.sweepHolderChildren(enabled: true)

        #expect(signaller.terminated.isEmpty, "no signal may be sent to a pid naming nothing")
        #expect(signaller.killed.isEmpty)
        #expect(Self.pidExists(bystander.processIdentifier))
    }

    /// A live holder means a live session, whatever its job looks like.
    @Test func aLiveHoldersChildIsLeftAlone() async throws {
        let holder = try Self.spawnHangupProofShell()
        defer { Self.killAndReap(holder) }
        let child = try Self.spawnHangupProofShell()
        defer { Self.killAndReap(child) }

        let signaller = RecordingProcessSignaller()
        await reaper(
            signaller,
            records: [
                record(holderPID: holder.processIdentifier, childPID: child.processIdentifier)
            ]
        ).sweepHolderChildren(enabled: true)

        #expect(signaller.terminated.isEmpty)
        #expect(Self.pidExists(child.processIdentifier))
        #expect(child.isRunning)
    }

    // MARK: - Both branches of the gate, against a real process

    @Test func theFlagOffLeavesARealOrphanRunning() async throws {
        let deadHolder = try Self.spentPID()
        let child = try Self.spawnHangupProofShell()
        defer { Self.killAndReap(child) }
        let childPID = child.processIdentifier

        let signaller = RecordingProcessSignaller()
        let records = [record(holderPID: deadHolder, childPID: childPID)]

        await reaper(signaller, records: records).sweepHolderChildren(enabled: false)
        #expect(signaller.terminated.isEmpty)
        #expect(Self.pidExists(childPID), "the flag is off; pid \(childPID) must still be running")

        // Same orphan, same reaper shape, flag on: now it goes.
        await reaper(signaller, records: records).sweepHolderChildren(enabled: true)
        #expect(await Self.waitForPIDToVanish(childPID))
    }

    // MARK: - SIGTERM → SIGKILL escalation, against a job that refuses SIGTERM

    /// The escalation itself. Every other fixture in this file dies on the
    /// reaper's first `terminate`, so without this the SIGKILL branch of
    /// `reapVerified` is reached by no live test at all.
    @Test func aJobThatIgnoresSIGTERMIsEscalatedToSIGKILL() async throws {
        let fixture = try await Self.spawnSIGTERMProofJob()
        defer { fixture.tearDown() }
        let job = fixture.jobPID

        // The premise, proven through the very door the reaper uses: a real
        // SIGTERM from `ProductionProcessSignaller` leaves this job running.
        // Without it the test would also pass against a process that simply
        // died of SIGTERM — which is the thing it exists to rule out.
        #expect(getpgid(job) == job, "the fixture must lead its own process group")
        ProductionProcessSignaller().terminate(job)
        #expect(
            await Self.staysRunning(job, for: 0.5),
            "pid \(job) died of SIGTERM, so the escalation branch was never reached")

        let deadHolder = try Self.spentPID()
        let signaller = RecordingProcessSignaller()
        await reaper(signaller, records: [record(holderPID: deadHolder, childPID: job)])
            .sweepHolderChildren(enabled: true)

        #expect(signaller.terminated.contains(job))
        #expect(
            signaller.killed.contains(job),
            "the job declined SIGTERM, so the sweep had to escalate to SIGKILL")
        #expect(
            await Self.waitForOwnChildToExit(job),
            "pid \(job) outlived the sweep; nothing but SIGKILL can end it")
    }

    /// The group-widening half, live. `ProductionProcessSignaller.signal` sends
    /// `kill(-pid, SIGKILL)` when the pid leads its own group, and that widening
    /// — justified in `c12c0386` by a measured real-process hazard — is the only
    /// thing that reclaims a descendant the orphaned job left running.
    @Test func theSIGKILLEscalationWidensToTheJobsProcessGroup() async throws {
        let fixture = try await Self.spawnSIGTERMProofJob()
        defer { fixture.tearDown() }
        let job = fixture.jobPID
        let grandchild = fixture.grandchildPID

        // Premise 1 — the descendant really is in the job's group, so reclaiming
        // it can only be the widening and not a side effect of the job's death.
        #expect(getpgid(job) == job, "the fixture must lead its own process group")
        #expect(
            getpgid(grandchild) == job,
            "pid \(grandchild) must share the job's process group for the widening to reach it")
        // Premise 2 — its stdio is /dev/null, so a death here can never be
        // explained by EIO on a vanished pty. That is the shape the original
        // hazard was measured in.
        #expect(
            Self.openFiles(ofPID: grandchild)
                == ["0": "/dev/null", "1": "/dev/null", "2": "/dev/null"])
        // Premise 3 — a real SIGTERM through the production door, which already
        // widens to the group, leaves both of them running.
        ProductionProcessSignaller().terminate(job)
        #expect(
            await Self.staysRunning(grandchild, for: 0.5),
            "pid \(grandchild) died of the group SIGTERM; SIGKILL would prove nothing")
        #expect(Self.isRunning(job), "pid \(job) died of SIGTERM; SIGKILL would prove nothing")

        let deadHolder = try Self.spentPID()
        let signaller = RecordingProcessSignaller()
        await reaper(signaller, records: [record(holderPID: deadHolder, childPID: job)])
            .sweepHolderChildren(enabled: true)

        #expect(signaller.killed.contains(job))
        #expect(await Self.waitForOwnChildToExit(job))
        #expect(
            await Self.waitForProcessToStop(grandchild),
            """
            pid \(grandchild) survived the sweep: the SIGKILL landed on pid \(job) alone \
            instead of on its process group, which is exactly the leak this leg exists to \
            collect
            """)
    }

    /// The re-decision that makes escalating by a recorded pid safe, run against
    /// real kernel state rather than a scripted dictionary swap.
    ///
    /// Asserted as ordering, not as a call count: every fact
    /// `decideHolderChild` consults must be consulted *again* after the SIGTERM
    /// and before the SIGKILL. A shortcut that escalated on the first decision
    /// would leave that window empty.
    @Test func theSIGKILLEscalationReRunsTheIdentityDecision() async throws {
        let fixture = try await Self.spawnSIGTERMProofJob()
        defer { fixture.tearDown() }
        let job = fixture.jobPID

        #expect(getpgid(job) == job, "the fixture must lead its own process group")
        ProductionProcessSignaller().terminate(job)
        #expect(
            await Self.staysRunning(job, for: 0.5),
            "pid \(job) died of SIGTERM, so no re-decision could have happened")

        let deadHolder = try Self.spentPID()
        let signaller = RecordingProcessSignaller()
        await reaper(signaller, records: [record(holderPID: deadHolder, childPID: job)])
            .sweepHolderChildren(enabled: true)
        #expect(await Self.waitForOwnChildToExit(job))

        let events = signaller.events
        let sentTerm = try #require(
            events.firstIndex(of: .terminate(job)), "no SIGTERM reached pid \(job)")
        // Either kill door counts here: which one the escalation takes is
        // `theSIGKILLEscalationWidensToTheJobsProcessGroup`'s question, and this
        // test should not go red for its answer.
        let sentKill = try #require(
            events.firstIndex(where: { $0 == .forceKill(job) || $0 == .forceKillProcessOnly(job) }),
            "no SIGKILL reached pid \(job)")
        #expect(sentTerm < sentKill)
        let betweenTheSignals = events[(sentTerm + 1)..<sentKill]
        #expect(
            betweenTheSignals.contains(.isAlive(deadHolder)),
            "the holder-liveness gate did not re-run before the SIGKILL")
        #expect(
            betweenTheSignals.contains(.isAlive(job)),
            "the child-liveness gate did not re-run before the SIGKILL")
        #expect(
            betweenTheSignals.contains(.startTime(job)),
            "the start-time gate did not re-run before the SIGKILL")
        #expect(
            betweenTheSignals.contains(.commandLine(job)),
            "the executable gate did not re-run before the SIGKILL")
    }

    // MARK: - The `ps` reader itself

    /// `ProductionProcessSignaller.startTime` reads a real pid, and the value
    /// is the anti-pid-reuse fact the whole leg rests on. A parser that
    /// silently returned nil would turn every reap into a keep — a leg that
    /// looks healthy and reclaims nothing.
    @Test func productionStartTimeReadsARealPID() throws {
        let child = try Self.spawnHangupProofShell()
        defer { Self.killAndReap(child) }

        let signaller = ProductionProcessSignaller()
        let started = try #require(
            signaller.startTime(child.processIdentifier),
            "ps -o lstart= must parse for a live pid")
        #expect(
            abs(started.timeIntervalSinceNow) < 60,
            "a process spawned moments ago reported \(started)")
        #expect(signaller.startTime(0) == nil)
    }

    /// The day-of-month is space-padded, so the field carries a double space for
    /// the first nine days of every month. Pinned because the failure mode is
    /// seasonal: parsing works for three weeks and then stops.
    @Test func lstartParsesBothDayPaddings() throws {
        let padded = try #require(ProductionProcessSignaller.parseLstart("Tue Sep  1 14:02:47 2026"))
        let unpadded = try #require(
            ProductionProcessSignaller.parseLstart("Mon Sep 21 14:02:47 2026"))
        #expect(unpadded > padded)
        #expect(ProductionProcessSignaller.parseLstart("") == nil)
        #expect(ProductionProcessSignaller.parseLstart("not a date") == nil)
    }
}

/// One call the reaper made through the signaller, in order.
///
/// Ordering is what distinguishes "the escalation re-proved identity" from "the
/// escalation happened", and neither a set of signalled pids nor a call count
/// can express it: the question is whether the identity reads fall *between* the
/// SIGTERM and the SIGKILL.
private enum SignallerCall: Equatable {
    case isAlive(Int32)
    case startTime(Int32)
    case commandLine(Int32)
    case terminate(Int32)
    case forceKill(Int32)
    case terminateProcessOnly(Int32)
    case forceKillProcessOnly(Int32)
}

/// The real signaller, with every call it is asked to make written down.
///
/// Reads (`isAlive`, `startTime`, `commandLine`) go to `ps` and `kill(pid, 0)`
/// untouched — those are what the suite is testing. The writes are delegated to
/// the production implementation too, so the guarded `kill` in
/// `ProductionProcessSignaller.signal` is the code actually running; the
/// recording exists so a test can assert that *nothing* was signalled, which no
/// amount of looking at a surviving process can prove on its own.
private final class RecordingProcessSignaller: ProcessSignaller, @unchecked Sendable {
    private let real = ProductionProcessSignaller()
    private let lock = NSLock()
    private var calls: [SignallerCall] = []

    var events: [SignallerCall] { lock.withLock { calls } }

    var terminated: [Int32] {
        events.compactMap { call -> Int32? in
            switch call {
            case .terminate(let pid), .terminateProcessOnly(let pid): return pid
            default: return nil
            }
        }
    }

    var killed: [Int32] {
        events.compactMap { call -> Int32? in
            switch call {
            case .forceKill(let pid), .forceKillProcessOnly(let pid): return pid
            default: return nil
            }
        }
    }

    private func record(_ call: SignallerCall) { lock.withLock { calls.append(call) } }

    func isAlive(_ pid: Int32) -> Bool {
        record(.isAlive(pid))
        return real.isAlive(pid)
    }

    func children(ofServerPID serverPID: Int32) -> [Int32] { real.children(ofServerPID: serverPID) }

    func commandLine(_ pid: Int32) -> String? {
        record(.commandLine(pid))
        return real.commandLine(pid)
    }

    func stat(_ pid: Int32) -> String? { real.stat(pid) }

    func startTime(_ pid: Int32) -> Date? {
        record(.startTime(pid))
        return real.startTime(pid)
    }

    func terminate(_ pid: Int32) {
        record(.terminate(pid))
        real.terminate(pid)
    }

    func forceKill(_ pid: Int32) {
        record(.forceKill(pid))
        real.forceKill(pid)
    }

    func terminateProcessOnly(_ pid: Int32) {
        record(.terminateProcessOnly(pid))
        real.terminateProcessOnly(pid)
    }

    func forceKillProcessOnly(_ pid: Int32) {
        record(.forceKillProcessOnly(pid))
        real.forceKillProcessOnly(pid)
    }
}

/// The holder leg never asks tmux anything; this makes that structural rather
/// than incidental.
private struct NoTmuxQuerier: TmuxProcessQuerying {
    func serverPID(server: String) async -> Int32? { nil }
    func livePanePIDs(server: String) async -> Set<Int32> { [] }
}
