import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Dev server tab inspection")
struct DevServerTabInspectorTests {
    @Test func aLivePaneParsesAsRunning() {
        #expect(TmuxManager.parsePaneExitState("%3|0||1234\n%4|0||99", paneID: "%3") == .running(pid: 1234))
    }

    /// tmux keeps a dead pane's `pane_pid`, and a respawn changes it: the
    /// pid tells one run of a respawned server tab from the next.
    @Test func aDeadPaneCarriesItsStatusAndPID() {
        #expect(TmuxManager.parsePaneExitState("%4|0||99\n%3|1|127|1234", paneID: "%3")
            == .dead(status: 127, pid: 1234))
        #expect(TmuxManager.parsePaneExitState("%3|1|1|", paneID: "%3") == .dead(status: 1, pid: nil))
    }

    @Test func aMissingPaneIsGone() {
        #expect(TmuxManager.parsePaneExitState("%4|0||99", paneID: "%3") == .gone)
        #expect(TmuxManager.parsePaneExitState("", paneID: "%3") == .gone)
    }

    /// Only tmux's own "not there" answer makes a tab gone; a timeout or an
    /// unrecognised failure is ignorance, and must never read as stopped.
    @Test func aFailedQueryIsGoneOnlyWhenTmuxSaysThePaneIsAbsent() {
        let absentPane = TmuxError.commandFailed(command: "tmux list-panes", status: 1, output: "can't find pane: %3")
        let noServer = TmuxError.commandFailed(
            command: "tmux list-panes", status: 1, output: "no server running on /tmp/tmux-501/tbd-x")
        #expect(TmuxManager.paneExitState(forFailure: absentPane) == .gone)
        #expect(TmuxManager.paneExitState(forFailure: noServer) == .gone)
        let timedOut = TmuxError.timedOut(command: "tmux list-panes", timeout: .seconds(15))
        let unrecognised = TmuxError.commandFailed(command: "tmux list-panes", status: 1, output: "lost server")
        let noBinary = TmuxError.commandFailed(
            command: "tmux list-panes", status: 127, output: "tmux executable is unavailable")
        for error in [timedOut, unrecognised, noBinary] {
            guard case .unknown = TmuxManager.paneExitState(forFailure: error) else {
                Issue.record("\(error) did not read as unknown")
                continue
            }
        }
    }

    @Test func dryRunReadsAPaneAsGone() async {
        #expect(await TmuxManager(dryRun: true).paneExitState(server: "tbd-x", paneID: "%3") == .gone)
    }

    @Test func theQueryNamesThePane() {
        #expect(TmuxManager.paneExitStateQuery(server: "tbd-x", paneID: "%3")
            == ["-L", "tbd-x", "list-panes", "-t", "%3", "-F",
                "#{pane_id}|#{pane_dead}|#{pane_dead_status}|#{pane_pid}"])
    }

    @Test func aHolderExitCodeComesFromTheRegistry() async {
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-devtab-\(UUID().uuidString)"],
            listTerminals: { [] }, spawner: nil)
        var terminal = Terminal(worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder,
                                childPID: 999_999)
        terminal.serverName = "web"
        await registry.recordStatusForTesting(.exited(code: 3), for: terminal.id)
        let inspector = ProductionDevServerTabInspector(
            tmux: TmuxManager(dryRun: true), holderRegistry: registry, signaller: ProductionProcessSignaller())
        #expect(await inspector.status(of: terminal, tmuxServer: "unused") == .exited(code: 3))
    }
    private func holderRegistry() -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-devtab-\(UUID().uuidString)"],
            listTerminals: { [] }, spawner: nil)
    }

    private func holderInspector(_ registry: HolderRegistry? = nil) -> ProductionDevServerTabInspector {
        let registry = registry ?? holderRegistry()
        return ProductionDevServerTabInspector(
            tmux: TmuxManager(dryRun: true), holderRegistry: registry, signaller: ProductionProcessSignaller())
    }

    /// A live holder child with no recorded start time and no adopted
    /// session cannot be tied to the tab. It reads running — never anchored
    /// to the row's creation time, which a stop would then silently skip.
    @Test func aLiveHolderChildWithNoRecordedStartIsUnverifiable() async {
        var terminal = Terminal(worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder,
                                childPID: getpid())
        terminal.serverName = "web"
        #expect(await holderInspector().status(of: terminal, tmuxServer: "unused")
            == .runningUnverifiable(pid: getpid()))
    }

    @Test func aLiveHolderChildIsAnchoredByItsRecordedStart() async throws {
        let started = try #require(DevServerProcessProbe.kernelInfo(pid: getpid())).startTime
        var terminal = Terminal(worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder,
                                childPID: getpid(), holderChildStartedAt: started)
        terminal.serverName = "web"
        #expect(await holderInspector().status(of: terminal, tmuxServer: "unused")
            == .running(pid: getpid(), expectedStart: started))
    }

    /// The recorded child pid is alive but started far from the recorded
    /// time: a reused pid, so the server's command has ended.
    @Test func aHolderChildPidReusedByAnotherProcessReadsExited() async throws {
        let actual = try #require(DevServerProcessProbe.kernelInfo(pid: getpid())).startTime
        var terminal = Terminal(worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder,
                                childPID: getpid(), holderChildStartedAt: actual.addingTimeInterval(-86_400))
        terminal.serverName = "web"
        #expect(await holderInspector().status(of: terminal, tmuxServer: "unused") == .exited(code: nil))
    }

    /// The registry's adopted child carries no start time of its own, so a
    /// live adopted pid the row recorded none for is anchored only by its
    /// liveness, which a reused pid also has. It reads running but is never
    /// signalled: a stop, gesture or archive, refuses it.
    @Test func anAdoptedHolderChildWithNoRecordedStartIsUnverifiable() async {
        let registry = holderRegistry()
        var terminal = Terminal(worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder,
                                childPID: getpid())
        terminal.serverName = "web"
        await registry.recordAdoptedProcessForTesting(
            .init(holderPID: nil, childPID: getpid()), for: terminal.id)
        #expect(await holderInspector(registry).status(of: terminal, tmuxServer: "unused")
            == .runningUnverifiable(pid: getpid()))
    }

    /// The same adopted child with the row's recorded start time is anchored
    /// by it, and reads running with that anchor.
    @Test func anAdoptedHolderChildIsAnchoredByItsRecordedStart() async throws {
        let registry = holderRegistry()
        let started = try #require(DevServerProcessProbe.kernelInfo(pid: getpid())).startTime
        var terminal = Terminal(worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder,
                                childPID: getpid(), holderChildStartedAt: started)
        terminal.serverName = "web"
        await registry.recordAdoptedProcessForTesting(
            .init(holderPID: nil, childPID: getpid()), for: terminal.id)
        #expect(await holderInspector(registry).status(of: terminal, tmuxServer: "unused")
            == .running(pid: getpid(), expectedStart: started))
    }
}
