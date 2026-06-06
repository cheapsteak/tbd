import Testing
import Foundation
@testable import TBDShared

@Suite("TerminalFocusParams")
struct TerminalFocusParamsTests {
    @Test func methodNameIsStable() {
        #expect(RPCMethod.terminalFocus == "terminal.focus")
    }

    @Test func roundTripsThroughJSON() throws {
        let id = UUID()
        let params = TerminalFocusParams(terminalID: id, message: "look here", activate: true)
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(TerminalFocusParams.self, from: data)
        #expect(decoded.terminalID == id)
        #expect(decoded.message == "look here")
        #expect(decoded.activate == true)
    }

    @Test func defaultsActivateFalseAndMessageNil() {
        let params = TerminalFocusParams(terminalID: UUID())
        #expect(params.activate == false)
        #expect(params.message == nil)
    }
}
