import Testing
import Foundation
@testable import TBDShared

@Suite("TerminalFocusParams")
struct TerminalFocusParamsTests {
    @Test func methodNameIsStable() {
        #expect(RPCMethod.terminalFocus == "terminal.focus")
    }
}
