import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

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
    @Test func tearDownWindowEscalatesSurvivor() async throws {
        let sig = FakeProcessSignaller()
        // panePID in dryRun is "0" → Int32(0). This exercises the escalation path
        // in isolation via the fake signaller's scripted behavior for pid 0 — it
        // does NOT model the production dryRun path (production isAlive(0) returns
        // false via the `guard pid > 0`, so only the fake escalates here).
        sig.behaviors[0] = .init(aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        let lifecycle = try makeLifecycle(signaller: sig)
        _ = await lifecycle.tearDownWindow(server: "tbd-x", windowID: "@1", paneID: "%1")
        #expect(sig.terminated == [0])
        #expect(sig.killed == [0])
    }

    @Test func tearDownWindowNoOpWhenPaneAlreadyDead() async throws {
        let sig = FakeProcessSignaller()
        sig.behaviors[0] = .init(aliveInitially: false)
        let lifecycle = try makeLifecycle(signaller: sig)
        _ = await lifecycle.tearDownWindow(server: "tbd-x", windowID: "@1", paneID: "%1")
        #expect(sig.terminated.isEmpty)
        #expect(sig.killed.isEmpty)
    }
}
