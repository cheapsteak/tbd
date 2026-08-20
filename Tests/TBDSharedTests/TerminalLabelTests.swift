import Foundation
import Testing
@testable import TBDShared

/// `TerminalLabel` names identities the daemon assigns, and consumers on both
/// sides of the socket read a row's label as a claim about how it was spawned.
/// `userSupplied` is the boundary that keeps caller text from making that claim.
@Suite("TerminalLabel")
struct TerminalLabelTests {

    @Test("Every reserved identity is refused as a caller-supplied label")
    func reservedLabelsAreRefused() {
        for reserved in TerminalLabel.reserved {
            #expect(
                TerminalLabel.userSupplied(reserved) == nil,
                "\(reserved) is a daemon-assigned identity and must not survive as a caller label")
        }
        // Named individually too, so deleting a value from `reserved` fails
        // here rather than shrinking the loop above into a vacuous pass.
        #expect(TerminalLabel.userSupplied(TerminalLabel.preSession) == nil)
        #expect(TerminalLabel.userSupplied(TerminalLabel.setup) == nil)
        #expect(TerminalLabel.userSupplied(TerminalLabel.shell) == nil)
        #expect(TerminalLabel.userSupplied(TerminalLabel.claudeCode) == nil)
        #expect(TerminalLabel.userSupplied(TerminalLabel.codex) == nil)
        #expect(TerminalLabel.userSupplied(TerminalLabel.login) == nil)
    }

    @Test("An ordinary command passes through unchanged")
    func ordinaryLabelsPassThrough() {
        #expect(TerminalLabel.userSupplied("vim") == "vim")
        #expect(TerminalLabel.userSupplied("npm run dev") == "npm run dev")
        // Nothing here is a claim on an identity, so nothing is dropped: the
        // match is exact, and these are all different strings from the values
        // every consumer compares against.
        #expect(TerminalLabel.userSupplied("codex") == "codex")
        #expect(TerminalLabel.userSupplied("Pre-Session") == "Pre-Session")
        #expect(TerminalLabel.userSupplied("pre-session-check") == "pre-session-check")
    }

    @Test("No label supplied stays no label")
    func nilPassesThrough() {
        #expect(TerminalLabel.userSupplied(nil) == nil)
    }
}
