import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct WorktreeLifecycleReaperTests {
    /// Builds a WorktreeLifecycle with a dryRun tmux (panePID → "0",
    /// killWindow no-ops), an in-memory DB, tiny reaper grace knobs, and the
    /// injected process signaller.
    private func makeLifecycle(signaller: FakeProcessSignaller) throws -> WorktreeLifecycle {
        let db = try TBDDatabase(inMemory: true)
        return WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(),
            processSignaller: signaller,
            reaperGraceAttempts: 2,
            reaperPollInterval: .milliseconds(1)
        )
    }

    /// A wedged pane process that survives kill-window's SIGHUP gets escalated.
    @Test func killWindowAndReapEscalatesSurvivor() async throws {
        let sig = FakeProcessSignaller()
        // panePID in dryRun is "0" → Int32(0). This exercises the escalation path
        // in isolation via the fake signaller's scripted behavior for pid 0 — it
        // does NOT model the production dryRun path (production isAlive(0) returns
        // false via the `guard pid > 0`, so only the fake escalates here).
        sig.behaviors[0] = .init(aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        let lifecycle = try makeLifecycle(signaller: sig)
        await lifecycle.killWindowAndReap(server: "tbd-x", windowID: "@1", paneID: "%1")
        #expect(sig.terminated == [0])
        #expect(sig.killed == [0])
    }

    @Test func killWindowAndReapNoOpWhenPaneAlreadyDead() async throws {
        let sig = FakeProcessSignaller()
        sig.behaviors[0] = .init(aliveInitially: false)
        let lifecycle = try makeLifecycle(signaller: sig)
        await lifecycle.killWindowAndReap(server: "tbd-x", windowID: "@1", paneID: "%1")
        #expect(sig.terminated.isEmpty)
        #expect(sig.killed.isEmpty)
    }

    @Test func reapServerChildrenRunsForOwnedChildren() async {
        // Unit-level guard on the reaper method reconcile now calls before kill-server.
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        tmux.serverPIDs = ["tbd-x": 500]
        sig.childrenByServer = [500: [77]]
        sig.cmdlines = [77: "claude --plugin-dir /x/TBD/plugin"]
        sig.behaviors = [77: .init(aliveAfterTerminate: false)]
        let reaper = AgentReaper(tmux: tmux, signaller: sig, graceAttempts: 1, pollInterval: .milliseconds(1))
        await reaper.reapServerChildren(server: "tbd-x")
        #expect(sig.terminated == [77])
    }
}
