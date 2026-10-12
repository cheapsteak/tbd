import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Dev server tab inspection")
struct DevServerTabInspectorTests {
    @Test func aLivePaneParsesAsRunning() {
        #expect(TmuxManager.parsePaneExitState("%3|0||1234\n%4|0||99", paneID: "%3") == .running(pid: 1234))
    }

    @Test func aDeadPaneCarriesItsStatus() {
        #expect(TmuxManager.parsePaneExitState("%4|0||99\n%3|1|127|1234", paneID: "%3") == .dead(status: 127))
    }

    @Test func aMissingPaneIsGone() {
        #expect(TmuxManager.parsePaneExitState("%4|0||99", paneID: "%3") == .gone)
        #expect(TmuxManager.parsePaneExitState("", paneID: "%3") == .gone)
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
    private func holderInspector() -> ProductionDevServerTabInspector {
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-devtab-\(UUID().uuidString)"],
            listTerminals: { [] }, spawner: nil)
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

    @Test func aLiveHolderChildIsAnchoredByItsRecordedStart() async {
        let started = Date(timeIntervalSince1970: 1_760_190_000)
        var terminal = Terminal(worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder,
                                childPID: getpid(), holderChildStartedAt: started)
        terminal.serverName = "web"
        #expect(await holderInspector().status(of: terminal, tmuxServer: "unused")
            == .running(pid: getpid(), expectedStart: started))
    }
}
