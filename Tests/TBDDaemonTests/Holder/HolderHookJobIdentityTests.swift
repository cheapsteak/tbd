import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `HolderRegistry.abandonVerifiedJob` — the hook-tab teardown's decision about
/// whether the pid it wrote down may still be signalled.
///
/// Every fact the decision rests on is dictated by `FakeProcessSignaller`,
/// because the case that matters cannot be arranged with real processes: the
/// point of the check is what it does when the kernel has handed the recorded
/// number to somebody else, and a test cannot make the kernel reissue a pid on
/// demand. Scripting the process table is the only way to state that at all.
///
/// The rendezvous socket never exists in any of these: the `forget` is
/// best-effort and its failure to connect is not what is under test. What is
/// under test is which pids get signalled, so `forceKill` is the observable
/// throughout — never `terminate`, since this path escalates straight to
/// `SIGKILL` exactly as `killJob` does.
@Suite("Holder hook-tab job identity")
struct HolderHookJobIdentityTests {

    private static let childPID: Int32 = 8801
    /// The row's recorded `holderChildStartedAt`, and the anchor every verdict
    /// below is measured against.
    private static let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    /// A registry whose process table the caller scripts, and whose rendezvous
    /// paths resolve to a short scratch root so the socket derivation can never
    /// be what fails (`sun_path` is 104 bytes).
    private static func registry(
        signaller: FakeProcessSignaller, home: String
    ) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: [
                "TBD_HOME": home,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/sh",
            ],
            listTerminals: { [] },
            spawner: nil,
            signaller: signaller)
    }

    private static func scratchHome() throws -> String {
        let home = fencedScratchRoot(prefix: "tbdhji")
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return home
    }

    /// A signaller scripted with a job that IS ours: alive, started when the
    /// row says it started, presenting the login shell the holder forks. Each
    /// test below breaks exactly one of those.
    private static func ourJob() -> FakeProcessSignaller {
        let signaller = FakeProcessSignaller()
        signaller.behaviors[childPID] = .init(
            aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        signaller.startTimes[childPID] = anchor
        signaller.cmdlines[childPID] = "/bin/zsh -i -l -c hook"
        return signaller
    }

    // MARK: - The case the check exists for

    /// A pid the kernel reissued between the job's exit and the teardown is not
    /// signalled, and the teardown says so.
    ///
    /// This is the whole finding: on the setup auto-close path the hook has
    /// usually finished — which is *why* the tab is closing — so the recorded
    /// pid is free for the kernel to hand out again, and the stranger holding
    /// it looks like an ordinary shell. Only the start time separates them.
    @Test("a recycled pid is never signalled")
    func aRecycledPIDIsLeftAlone() async throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let signaller = Self.ourJob()
        // An hour past the anchor: a different process, wearing a shell's
        // command line so nothing but the start time can refuse it.
        signaller.startTimes[Self.childPID] = Self.anchor.addingTimeInterval(3600)
        signaller.cmdlines[Self.childPID] = "zsh -c make"

        let left = await Self.registry(signaller: signaller, home: home)
            .abandonVerifiedJob(
                terminalID: UUID(), holderPID: nil, childPID: Self.childPID,
                childStartedAt: Self.anchor)

        #expect(signaller.killed.isEmpty, "a recycled pid was killed")
        #expect(signaller.terminated.isEmpty)
        let reported = try #require(left, "a refused kill was not reported")
        #expect(reported.contains("startTimeMismatch"), "the report did not name the verdict: \(reported)")
        #expect(reported.contains("\(Self.childPID)"))
    }

    /// The job that really is ours is still reclaimed — otherwise the check
    /// above would be indistinguishable from never killing anything.
    @Test("a job that verifies is force-killed")
    func aVerifiedJobIsKilled() async throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let signaller = Self.ourJob()

        let left = await Self.registry(signaller: signaller, home: home)
            .abandonVerifiedJob(
                terminalID: UUID(), holderPID: nil, childPID: Self.childPID,
                childStartedAt: Self.anchor)

        #expect(signaller.killed == [Self.childPID])
        #expect(left == nil)
    }

    // MARK: - The answers that are not failures

    /// The ordinary auto-close case: the hook finished, the job exited, and
    /// nothing holds the number. Nothing is signalled and nothing is reported —
    /// a teardown that found its job already gone did its whole job.
    @Test("a job that has already exited is neither signalled nor reported")
    func anExitedJobIsNotReported() async throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let signaller = Self.ourJob()
        signaller.behaviors[Self.childPID] = .init(aliveInitially: false)

        let left = await Self.registry(signaller: signaller, home: home)
            .abandonVerifiedJob(
                terminalID: UUID(), holderPID: nil, childPID: Self.childPID,
                childStartedAt: Self.anchor)

        #expect(signaller.killed.isEmpty)
        #expect(left == nil)
    }

    /// A corpse is read as gone rather than as a stranger. `ps` prints a
    /// zombie's command in parentheses, so the executable gate would refuse it
    /// — naming the wrong reason for the right decision — which is why the
    /// zombie is asked about first.
    @Test("a zombie is read as gone, not as a foreign executable")
    func aZombieIsReadAsGone() async throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let signaller = Self.ourJob()
        signaller.stats[Self.childPID] = "Z+"
        signaller.cmdlines[Self.childPID] = "(zsh)"

        let left = await Self.registry(signaller: signaller, home: home)
            .abandonVerifiedJob(
                terminalID: UUID(), holderPID: nil, childPID: Self.childPID,
                childStartedAt: Self.anchor)

        #expect(signaller.killed.isEmpty)
        #expect(left == nil, "a corpse was reported as a job left running: \(left ?? "")")
    }

    // MARK: - The other ways an identity fails to hold

    /// A stranger that started inside the window is still refused, because the
    /// executable is one no holder job could present.
    @Test("a foreign executable at the recorded pid is left alone")
    func aForeignExecutableIsLeftAlone() async throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let signaller = Self.ourJob()
        signaller.cmdlines[Self.childPID] = "htop"

        let left = await Self.registry(signaller: signaller, home: home)
            .abandonVerifiedJob(
                terminalID: UUID(), holderPID: nil, childPID: Self.childPID,
                childStartedAt: Self.anchor)

        #expect(signaller.killed.isEmpty, "a stranger's process was killed")
        let reported = try #require(left)
        #expect(reported.contains("foreignExecutable"), "unexpected report: \(reported)")
    }

    /// No anchor, no signal. A row that never recorded a start time cannot be
    /// used to tell its own job from a stranger, and "we are not certain" is
    /// spelled keep on this path exactly as it is on the reaper's.
    @Test("a spawn with no recorded start time is left alone and reported")
    func aMissingAnchorRefusesTheKill() async throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let signaller = Self.ourJob()

        let left = await Self.registry(signaller: signaller, home: home)
            .abandonVerifiedJob(
                terminalID: UUID(), holderPID: nil, childPID: Self.childPID,
                childStartedAt: nil)

        #expect(signaller.killed.isEmpty)
        let reported = try #require(left)
        #expect(reported.contains("start time"), "unexpected report: \(reported)")
    }

    /// The sentinel a row that never recorded a child pid decodes to is refused
    /// before any identity question is asked: `kill(0, …)` reaches the daemon's
    /// own process group.
    @Test("a missing child pid is reported and nothing is signalled")
    func aMissingChildPIDIsReported() async throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let signaller = Self.ourJob()

        let left = await Self.registry(signaller: signaller, home: home)
            .abandonVerifiedJob(
                terminalID: UUID(), holderPID: nil, childPID: nil,
                childStartedAt: Self.anchor)

        #expect(signaller.killed.isEmpty)
        let reported = try #require(left)
        #expect(reported.contains("no child pid"), "unexpected report: \(reported)")
    }
}
