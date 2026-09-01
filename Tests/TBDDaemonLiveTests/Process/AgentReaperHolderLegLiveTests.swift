import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// `AgentReaper`'s holder leg against the kernel's own answers about real pids.
///
/// **Tier 3.** Every process here is real: the orphan it reaps, the stranger it
/// must not touch, and the pid it is handed after that pid's process is already
/// gone. The identity check is the whole point of the suite — it exists to make
/// sure the leg can tell one from another using `ps`, not using a fake that was
/// told the answer.
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

/// The real signaller, with the signals it sends written down.
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
    private var terminatedPIDs: [Int32] = []
    private var killedPIDs: [Int32] = []

    var terminated: [Int32] { lock.withLock { terminatedPIDs } }
    var killed: [Int32] { lock.withLock { killedPIDs } }

    func isAlive(_ pid: Int32) -> Bool { real.isAlive(pid) }
    func children(ofServerPID serverPID: Int32) -> [Int32] { real.children(ofServerPID: serverPID) }
    func commandLine(_ pid: Int32) -> String? { real.commandLine(pid) }
    func stat(_ pid: Int32) -> String? { real.stat(pid) }
    func startTime(_ pid: Int32) -> Date? { real.startTime(pid) }

    func terminate(_ pid: Int32) {
        lock.withLock { terminatedPIDs.append(pid) }
        real.terminate(pid)
    }

    func forceKill(_ pid: Int32) {
        lock.withLock { killedPIDs.append(pid) }
        real.forceKill(pid)
    }

    func terminateProcessOnly(_ pid: Int32) {
        lock.withLock { terminatedPIDs.append(pid) }
        real.terminateProcessOnly(pid)
    }

    func forceKillProcessOnly(_ pid: Int32) {
        lock.withLock { killedPIDs.append(pid) }
        real.forceKillProcessOnly(pid)
    }
}

/// The holder leg never asks tmux anything; this makes that structural rather
/// than incidental.
private struct NoTmuxQuerier: TmuxProcessQuerying {
    func serverPID(server: String) async -> Int32? { nil }
    func livePanePIDs(server: String) async -> Set<Int32> { [] }
}
