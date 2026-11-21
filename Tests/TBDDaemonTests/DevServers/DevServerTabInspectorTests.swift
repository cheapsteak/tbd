import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

@Suite("Dev server tab inspection")
struct DevServerTabInspectorTests {
    /// A server tab still on tmux reads unknown, so a start refuses rather
    /// than open a second tab beside a command that may still run there.
    @Test func aTmuxTabIsUnknown() async {
        var terminal = Terminal(worktreeID: UUID(), tmuxWindowID: "@3", tmuxPaneID: "%3", transport: .tmux)
        terminal.serverName = "web"
        #expect(await holderInspector().status(of: terminal, tmuxServer: "tbd-acme")
            == .unknown(reason: ProductionDevServerTabInspector.tmuxTabReason))
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
            holderRegistry: registry, signaller: ProductionProcessSignaller())
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
            holderRegistry: registry, signaller: ProductionProcessSignaller())
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
