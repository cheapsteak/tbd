import ArgumentParser
import Foundation
import Testing

@testable import TBDCLI

@Suite("WorktreeReparent argument parsing")
struct WorktreeReparentTests {
    @Test func requiresParentOrRoot() {
        // `.parse` invokes validate() internally; missing --parent / --root
        // surfaces as a CommandError wrapping our ValidationError.
        #expect(throws: (any Error).self) {
            _ = try WorktreeReparent.parse(["my-worktree"])
        }
    }

    @Test func rejectsBothParentAndRoot() {
        #expect(throws: (any Error).self) {
            _ = try WorktreeReparent.parse(["my-worktree", "--parent", "orchestrator", "--root"])
        }
    }

    @Test func acceptsParentAlone() throws {
        let cmd = try WorktreeReparent.parse(["my-worktree", "--parent", "orchestrator"])
        #expect(cmd.parent == "orchestrator")
        #expect(cmd.root == false)
    }

    @Test func acceptsRootAlone() throws {
        let cmd = try WorktreeReparent.parse(["my-worktree", "--root"])
        #expect(cmd.root == true)
        #expect(cmd.parent == nil)
    }

    @Test func parsesOptionalIndex() throws {
        let cmd = try WorktreeReparent.parse(["my-worktree", "--root", "--index", "2"])
        #expect(cmd.index == 2)
    }
}
