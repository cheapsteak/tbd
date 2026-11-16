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

@Suite struct AgentReaperAgentBinaryTests {
    @Test func recognizesAgentBinariesByArgvZero() {
        #expect(AgentReaper.isAgentBinary("codex"))                                // bare codex
        #expect(AgentReaper.isAgentBinary("/Users/x/.local/bin/codex --resume ABC")) // codex by path
        #expect(AgentReaper.isAgentBinary("claude --resume ABC"))                  // claude agent binary
        #expect(!AgentReaper.isAgentBinary("node script.js"))                      // non-agent process
        #expect(!AgentReaper.isAgentBinary("/opt/homebrew/bin/make"))              // non-agent binary
        #expect(!AgentReaper.isAgentBinary("node /Users/x/claude/script.js"))      // agent name in a later arg
        #expect(!AgentReaper.isAgentBinary(""))
    }
}

@Suite struct AgentReaperEscalationTests {
    private func reaper(_ sig: FakeProcessSignaller) -> AgentReaper {
        AgentReaper(signaller: sig, graceAttempts: 2, pollInterval: .milliseconds(1))
    }

    @Test func reapSendsSigtermThenSigkillWhenProcessSurvives() async {
        let sig = FakeProcessSignaller()
        sig.behaviors[7] = .init(aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        await reaper(sig).reap(7)
        #expect(sig.terminated == [7])
        #expect(sig.killed == [7])
    }

    @Test func reapStopsAtSigtermWhenProcessDies() async {
        let sig = FakeProcessSignaller()
        sig.behaviors[8] = .init(aliveInitially: true, aliveAfterTerminate: false, aliveAfterKill: false)
        await reaper(sig).reap(8)
        #expect(sig.terminated == [8])
        #expect(sig.killed.isEmpty)            // died on SIGTERM — no SIGKILL
    }

    @Test func escalateAfterHangupDoesNothingWhenAlreadyDead() async {
        let sig = FakeProcessSignaller()
        sig.behaviors[9] = .init(aliveInitially: false)
        await reaper(sig).escalateAfterHangup(9)
        #expect(sig.terminated.isEmpty)
        #expect(sig.killed.isEmpty)
    }

    @Test func escalateAfterHangupReapsSurvivor() async {
        let sig = FakeProcessSignaller()
        sig.behaviors[10] = .init(aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        await reaper(sig).escalateAfterHangup(10)
        #expect(sig.terminated == [10])
        #expect(sig.killed == [10])
    }
}
