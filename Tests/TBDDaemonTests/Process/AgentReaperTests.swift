import Testing
import Foundation
@testable import TBDDaemonLib

@Suite struct ProcessSignallerTests {
    @Test func isAliveTrueForSelf() {
        let s = ProductionProcessSignaller()
        #expect(s.isAlive(getpid()) == true)
    }

    @Test func isAliveFalseForUnusedPID() {
        let s = ProductionProcessSignaller()
        // PID 0 and negative are rejected; a very high pid is almost certainly free.
        #expect(s.isAlive(0) == false)
        #expect(s.isAlive(2_000_000_000) == false)
    }

    @Test func commandLineContainsPSForSelf() {
        let s = ProductionProcessSignaller()
        let cmd = s.commandLine(getpid())
        #expect(cmd != nil)
    }
}

@Suite struct AgentReaperDetectionTests {
    private func reaper(_ tmux: FakeTmuxQuerier, _ sig: FakeProcessSignaller) -> AgentReaper {
        AgentReaper(tmux: tmux, signaller: sig, graceAttempts: 2, pollInterval: .milliseconds(1))
    }

    @Test func orphansAreChildrenMinusLivePanes() async {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        tmux.serverPIDs["tbd-x"] = 1000
        sig.childrenByServer[1000] = [11, 22, 33]
        tmux.panePIDs["tbd-x"] = [22]               // only 22 has a live pane
        let orphans = await reaper(tmux, sig).findStructuralOrphans(server: "tbd-x")
        #expect(Set(orphans) == [11, 33])
    }

    @Test func livePaneIsNeverAnOrphan() async {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        tmux.serverPIDs["tbd-x"] = 1000
        sig.childrenByServer[1000] = [42]
        tmux.panePIDs["tbd-x"] = [42]
        let orphans = await reaper(tmux, sig).findStructuralOrphans(server: "tbd-x")
        #expect(orphans.isEmpty)
    }

    @Test func noServerPIDYieldsNoOrphans() async {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        let orphans = await reaper(tmux, sig).findStructuralOrphans(server: "gone")
        #expect(orphans.isEmpty)
    }

    @Test func fingerprintMatchesTBDArgvOnly() {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        sig.cmdlines[11] = "claude --settings /Users/x/tbd/runtime/claude-overlay.json"
        sig.cmdlines[12] = "claude --plugin-dir /Users/x/Library/Application Support/TBD/plugin"
        sig.cmdlines[13] = "claude --resume ABC"           // a user's own claude
        let r = reaper(tmux, sig)
        #expect(r.isTBDOwned(11) == true)
        #expect(r.isTBDOwned(12) == true)
        #expect(r.isTBDOwned(13) == false)
    }
}
