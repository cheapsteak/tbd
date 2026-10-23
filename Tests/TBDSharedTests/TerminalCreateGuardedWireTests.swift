import Foundation
import Testing
@testable import TBDShared

@Suite("Guarded Codex terminal create wire")
struct TerminalCreateGuardedWireTests {
    @Test("explicit home selects an RPC an older daemon cannot mistake for terminal.create")
    func distinctMethod() throws {
        let worktreeID = UUID()
        let ordinary = TerminalCreateParams(worktreeID: worktreeID, type: .codex)
        let guarded = TerminalCreateParams(
            worktreeID: worktreeID, type: .codex, codexHome: "/synthetic/codex-home")

        #expect(ordinary.rpcMethod == RPCMethod.terminalCreate)
        #expect(guarded.rpcMethod == RPCMethod.terminalCreateGuardedCodex)
        #expect(guarded.rpcMethod != ordinary.rpcMethod)
        let payload = try JSONEncoder().encode(guarded)
        #expect(try JSONDecoder().decode(TerminalCreateParams.self, from: payload).codexHome
                == "/synthetic/codex-home")
    }
}
