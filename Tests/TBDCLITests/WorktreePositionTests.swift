import Foundation
import Testing

@testable import TBDCLI

@Suite("WorktreePosition → WorktreeCreateParams field mapping")
struct WorktreePositionTests {
    private static let callerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    // MARK: - --position=child (default)

    @Test func childPassesCallerToDaemon() {
        let fields = WorktreePosition.child.rpcFields(callerEnvID: Self.callerID)
        #expect(fields.callerWorktreeID == Self.callerID)
        #expect(fields.siblingOfWorktreeID == nil)
        #expect(fields.suppressAutoParent == nil)
    }

    @Test func childWithNoCallerProducesAllNilFields() {
        // Without TBD_WORKTREE_ID, child has no anchor and degrades to a
        // top-level create (same fallback as the old un-flagged default).
        let fields = WorktreePosition.child.rpcFields(callerEnvID: nil)
        #expect(fields.callerWorktreeID == nil)
        #expect(fields.siblingOfWorktreeID == nil)
        #expect(fields.suppressAutoParent == nil)
    }

    // MARK: - --position=sibling

    @Test func siblingPassesCallerInSiblingSlot() {
        let fields = WorktreePosition.sibling.rpcFields(callerEnvID: Self.callerID)
        #expect(fields.siblingOfWorktreeID == Self.callerID)
        #expect(fields.callerWorktreeID == nil)
        #expect(fields.suppressAutoParent == nil)
    }

    @Test func siblingWithNoCallerProducesAllNilFields() {
        // Without TBD_WORKTREE_ID, there is no peer to anchor on; falls back
        // to top-level (same as the old --sibling flag behavior).
        let fields = WorktreePosition.sibling.rpcFields(callerEnvID: nil)
        #expect(fields.siblingOfWorktreeID == nil)
        #expect(fields.callerWorktreeID == nil)
        #expect(fields.suppressAutoParent == nil)
    }

    // MARK: - --position=root

    @Test func rootSetsSuppressAutoParent() {
        let fields = WorktreePosition.root.rpcFields(callerEnvID: Self.callerID)
        #expect(fields.suppressAutoParent == true)
        #expect(fields.callerWorktreeID == nil)
        #expect(fields.siblingOfWorktreeID == nil)
    }

    @Test func rootIgnoresCaller() {
        // Should be identical whether or not TBD_WORKTREE_ID is set.
        let withCaller = WorktreePosition.root.rpcFields(callerEnvID: Self.callerID)
        let withoutCaller = WorktreePosition.root.rpcFields(callerEnvID: nil)
        #expect(withCaller == withoutCaller)
    }

    // MARK: - Argument parsing

    @Test func parsesValidValues() {
        #expect(WorktreePosition(argument: "child") == .child)
        #expect(WorktreePosition(argument: "sibling") == .sibling)
        #expect(WorktreePosition(argument: "root") == .root)
    }

    @Test func rejectsUnknownValue() {
        #expect(WorktreePosition(argument: "parent") == nil)
        #expect(WorktreePosition(argument: "") == nil)
    }

    // MARK: - unmetIntentWarning

    @Test func childWithCallerHasNoWarning() {
        #expect(WorktreePosition.child.unmetIntentWarning(callerEnvID: Self.callerID) == nil)
    }

    @Test func childWithoutCallerHasNoWarning() {
        // Degrading to top-level is the documented graceful fallback for child.
        #expect(WorktreePosition.child.unmetIntentWarning(callerEnvID: nil) == nil)
    }

    @Test func siblingWithCallerHasNoWarning() {
        #expect(WorktreePosition.sibling.unmetIntentWarning(callerEnvID: Self.callerID) == nil)
    }

    @Test func siblingWithoutCallerWarns() {
        // The whole point of the warning: sibling intent silently degrades to
        // a top-level worktree when there's no caller to anchor on.
        let warning = WorktreePosition.sibling.unmetIntentWarning(callerEnvID: nil)
        #expect(warning != nil)
        // Keep the message greppable on substring, not exact wording.
        #expect(warning?.contains("sibling") == true)
        #expect(warning?.contains("TBD_WORKTREE_ID") == true)
        #expect(warning?.contains("not a valid UUID") == true)
    }

    @Test func rootWithCallerHasNoWarning() {
        #expect(WorktreePosition.root.unmetIntentWarning(callerEnvID: Self.callerID) == nil)
    }

    @Test func rootWithoutCallerHasNoWarning() {
        // Top-level is exactly what root requested; nothing to warn about.
        #expect(WorktreePosition.root.unmetIntentWarning(callerEnvID: nil) == nil)
    }
}
