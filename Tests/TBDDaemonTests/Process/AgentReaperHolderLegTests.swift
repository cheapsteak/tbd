import Foundation
import Testing

@testable import TBDDaemonLib

/// The decision matrix of `AgentReaper`'s holder-transport leg, and its gate.
///
/// These are the *scripted* cases: every fact the leg consults is dictated by
/// `FakeProcessSignaller`, so a case that is awkward to arrange with real
/// processes (an unreadable start time, a pid whose holder is still running)
/// can be stated in one line. The companion suite
/// `AgentReaperHolderLegLiveTests` proves the same rules against the kernel's
/// own answers about real pids — this one proves the rules are the rules.
@Suite("AgentReaperHolderLeg")
struct AgentReaperHolderLegTests {

    private static let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let holderPID: Int32 = 4242
    private static let childPID: Int32 = 4243
    private static let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// A signaller scripted with a *reapable* orphan: the holder is gone, the
    /// child is alive, its start time sits on the row's `createdAt`, and it
    /// presents a login shell. Each test then breaks exactly one of those.
    private func orphanSignaller() -> FakeProcessSignaller {
        let s = FakeProcessSignaller()
        s.behaviors[Self.holderPID] = .init(aliveInitially: false)
        s.behaviors[Self.childPID] = .init(
            aliveInitially: true, aliveAfterTerminate: false, aliveAfterKill: false)
        s.startTimes[Self.childPID] = Self.createdAt
        s.cmdlines[Self.childPID] = "/bin/zsh -i -l -c claude"
        return s
    }

    private func reaper(
        _ signaller: FakeProcessSignaller,
        records: [HolderChildRecord]
    ) -> AgentReaper {
        AgentReaper(
            tmux: FakeTmuxQuerier(), signaller: signaller,
            graceAttempts: 3, pollInterval: .milliseconds(1),
            holderSessions: { records })
    }

    private static func record(
        holderPID: Int32? = AgentReaperHolderLegTests.holderPID,
        childPID: Int32 = AgentReaperHolderLegTests.childPID,
        createdAt: Date = AgentReaperHolderLegTests.createdAt
    ) -> HolderChildRecord {
        HolderChildRecord(
            terminalID: sessionID, holderPID: holderPID, childPID: childPID, createdAt: createdAt)
    }

    // MARK: - The reapable case

    @Test func aDeadHoldersSurvivingChildIsReaped() async {
        let signaller = orphanSignaller()
        let reaper = reaper(signaller, records: [Self.record()])
        #expect(reaper.decideHolderChild(Self.record()) == .reap)

        await reaper.sweepHolderChildren(enabled: true)
        #expect(signaller.terminated == [Self.childPID])
    }

    /// A job that declines SIGTERM — the shape the acceptance harness measured,
    /// where the job ignores the hangup and outlives its holder at `ppid=1` —
    /// is escalated to SIGKILL, and only it.
    @Test func aChildThatDeclinesSIGTERMIsEscalated() async {
        let signaller = orphanSignaller()
        signaller.behaviors[Self.childPID] = .init(
            aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        let reaper = reaper(signaller, records: [Self.record()])

        await reaper.sweepHolderChildren(enabled: true)
        #expect(signaller.terminated == [Self.childPID])
        #expect(signaller.killed == [Self.childPID])
    }

    // MARK: - Both branches of the gate

    @Test func theLegSignalsNothingWhenTheFlagIsOff() async {
        let signaller = orphanSignaller()
        let reaper = reaper(signaller, records: [Self.record()])

        await reaper.sweepHolderChildren(enabled: false)
        #expect(signaller.terminated.isEmpty)
        #expect(signaller.killed.isEmpty)
    }

    /// The gate must be the only thing separating the two runs: same reaper,
    /// same scripted process table, opposite verdicts.
    @Test func theSameOrphanIsReapedOnlyWithTheFlagOn() async {
        let off = orphanSignaller()
        await reaper(off, records: [Self.record()]).sweepHolderChildren(enabled: false)
        #expect(off.terminated.isEmpty)

        let on = orphanSignaller()
        await reaper(on, records: [Self.record()]).sweepHolderChildren(enabled: true)
        #expect(on.terminated == [Self.childPID])
    }

    /// The flag gates the enumeration too, not just the kill: a disabled leg
    /// must not pay for a `ps` per holder row on every sweep.
    @Test func theFlagOffSkipsEnumerationEntirely() async {
        let signaller = orphanSignaller()
        let enumerated = Enumerated()
        let reaper = AgentReaper(
            tmux: FakeTmuxQuerier(), signaller: signaller,
            graceAttempts: 3, pollInterval: .milliseconds(1),
            holderSessions: {
                enumerated.hit()
                return [Self.record()]
            })

        await reaper.sweepHolderChildren(enabled: false)
        #expect(enumerated.count == 0)
        await reaper.sweepHolderChildren(enabled: true)
        #expect(enumerated.count == 1)
    }

    // MARK: - Every reason the leg keeps

    @Test func aLiveHolderMeansALiveSession() async {
        let signaller = orphanSignaller()
        signaller.behaviors[Self.holderPID] = .init(aliveInitially: true)
        let reaper = reaper(signaller, records: [Self.record()])
        #expect(reaper.decideHolderChild(Self.record()) == .keep(reason: "holder-alive"))

        await reaper.sweepHolderChildren(enabled: true)
        #expect(signaller.terminated.isEmpty)
    }

    /// A row still being established has no holder pid yet, and a session being
    /// born must never be reclaimed as an orphan.
    @Test func anUnrecordedHolderKeeps() {
        let reaper = reaper(orphanSignaller(), records: [])
        #expect(
            reaper.decideHolderChild(Self.record(holderPID: nil))
                == .keep(reason: "holder-unrecorded"))
    }

    /// The pid sentinels that would signal the daemon's own process group.
    /// `HolderRegistry` guards the same two numbers in the same words.
    @Test func pidZeroAndPidOneAreNeverSignalled() async {
        for pid: Int32 in [0, 1] {
            let signaller = orphanSignaller()
            let record = Self.record(childPID: pid)
            let reaper = reaper(signaller, records: [record])
            #expect(reaper.decideHolderChild(record) == .keep(reason: "invalid-child-pid"))
            await reaper.sweepHolderChildren(enabled: true)
            #expect(signaller.terminated.isEmpty)
            #expect(signaller.killed.isEmpty)
        }
    }

    @Test func aRecordedPidWhoseProcessIsGoneIsNotSignalled() async {
        let signaller = orphanSignaller()
        signaller.behaviors[Self.childPID] = .init(aliveInitially: false)
        let reaper = reaper(signaller, records: [Self.record()])
        #expect(reaper.decideHolderChild(Self.record()) == .keep(reason: "child-gone"))

        await reaper.sweepHolderChildren(enabled: true)
        #expect(signaller.terminated.isEmpty)
        #expect(signaller.killed.isEmpty)
    }

    /// The anti-pid-reuse gate. The pid is alive and presents a plausible
    /// executable; only its start time says it is somebody else's process.
    @Test func aStartTimeFarFromTheRowIsAStranger() async {
        let signaller = orphanSignaller()
        signaller.startTimes[Self.childPID] = Self.createdAt.addingTimeInterval(3600)
        let reaper = reaper(signaller, records: [Self.record()])
        #expect(reaper.decideHolderChild(Self.record()) == .keep(reason: "start-time-mismatch"))

        await reaper.sweepHolderChildren(enabled: true)
        #expect(signaller.terminated.isEmpty)
    }

    /// Symmetric around `createdAt`, because the holder is spawned just before
    /// the row today and the design's creation ordering puts it just after.
    @Test func theStartTimeWindowIsSymmetric() {
        let signaller = orphanSignaller()
        let reaper = reaper(signaller, records: [])
        for offset in [-299.0, -1.0, 1.0, 299.0] {
            signaller.startTimes[Self.childPID] = Self.createdAt.addingTimeInterval(offset)
            #expect(reaper.decideHolderChild(Self.record()) == .reap, "offset \(offset)")
        }
        for offset in [-301.0, 301.0] {
            signaller.startTimes[Self.childPID] = Self.createdAt.addingTimeInterval(offset)
            #expect(
                reaper.decideHolderChild(Self.record()) == .keep(reason: "start-time-mismatch"),
                "offset \(offset)")
        }
    }

    /// An unreadable identity is an uncertain identity, and uncertainty keeps.
    @Test func anUnreadableStartTimeKeeps() async {
        let signaller = orphanSignaller()
        signaller.startTimes.removeValue(forKey: Self.childPID)
        let reaper = reaper(signaller, records: [Self.record()])
        #expect(reaper.decideHolderChild(Self.record()) == .keep(reason: "start-time-unreadable"))

        await reaper.sweepHolderChildren(enabled: true)
        #expect(signaller.terminated.isEmpty)
    }

    @Test func anUnreadableCommandLineKeeps() async {
        let signaller = orphanSignaller()
        signaller.cmdlines.removeValue(forKey: Self.childPID)
        let reaper = reaper(signaller, records: [Self.record()])
        #expect(reaper.decideHolderChild(Self.record()) == .keep(reason: "command-unreadable"))

        await reaper.sweepHolderChildren(enabled: true)
        #expect(signaller.terminated.isEmpty)
    }

    /// `ps` prints nothing for a pid that vanished mid-decision, and the
    /// production reader trims that to `""`. It is the unreadable case, not a
    /// stranger's executable — the decision is the same either way, but only
    /// one of the two reasons is true, and the reason is what a soak reads.
    @Test func anEmptyCommandLineIsUnreadableRatherThanForeign() async {
        let signaller = orphanSignaller()
        signaller.cmdlines[Self.childPID] = ""
        let reaper = reaper(signaller, records: [Self.record()])
        #expect(reaper.decideHolderChild(Self.record()) == .keep(reason: "command-unreadable"))

        await reaper.sweepHolderChildren(enabled: true)
        #expect(signaller.terminated.isEmpty)
    }

    @Test func aForeignExecutableKeeps() async {
        let signaller = orphanSignaller()
        signaller.cmdlines[Self.childPID] = "/usr/bin/vim README.md"
        let reaper = reaper(signaller, records: [Self.record()])
        #expect(reaper.decideHolderChild(Self.record()) == .keep(reason: "foreign-executable"))

        await reaper.sweepHolderChildren(enabled: true)
        #expect(signaller.terminated.isEmpty)
    }

    // MARK: - The executable membership test

    @Test func loginShellsAndAgentBinariesAreHolderChildren() {
        for cmd in [
            "/bin/zsh -i -l -c claude",
            "/bin/bash --login -c codex",
            "/opt/homebrew/bin/fish -l -c ls",
            "claude --dangerously-skip-permissions",
            "/Users/x/.local/bin/codex",
        ] {
            #expect(AgentReaper.isHolderChildExecutable(cmd), "\(cmd) should be accepted")
        }
    }

    @Test func strangersAreNotHolderChildren() {
        for cmd in [
            "/usr/bin/vim README.md",
            "/usr/bin/python3 script.py",
            "node server.js",
            "/Users/x/bin/claude-helper",
            "",
        ] {
            #expect(!AgentReaper.isHolderChildExecutable(cmd), "\(cmd) should be rejected")
        }
    }

    // MARK: - The escalation re-check

    /// A pid freed by the SIGTERM and handed to something else inside the grace
    /// window must not take the SIGKILL. The scripted process stays "alive"
    /// after the terminate but its identity changes underneath — exactly what a
    /// reused pid looks like from here.
    @Test func aPidReusedInsideTheGraceWindowIsNotEscalated() async {
        let signaller = orphanSignaller()
        signaller.behaviors[Self.childPID] = .init(
            aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        let reaper = AgentReaper(
            tmux: FakeTmuxQuerier(), signaller: signaller,
            graceAttempts: 2, pollInterval: .milliseconds(1),
            holderSessions: { [Self.record()] })

        // The reuse happens the moment the SIGTERM lands.
        signaller.onTerminate = { _ in
            signaller.cmdlines[Self.childPID] = "/usr/bin/vim README.md"
        }

        await reaper.sweepHolderChildren(enabled: true)
        #expect(signaller.terminated == [Self.childPID])
        #expect(
            signaller.killed.isEmpty,
            "the escalation must re-prove identity before SIGKILL, and this pid no longer verifies")
    }
}

/// Counts calls from a `@Sendable` closure without an actor hop.
private final class Enumerated: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func hit() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
