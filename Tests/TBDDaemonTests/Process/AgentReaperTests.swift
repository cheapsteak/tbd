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
