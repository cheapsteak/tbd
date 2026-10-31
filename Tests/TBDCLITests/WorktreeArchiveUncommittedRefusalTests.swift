import Foundation
import Testing

@testable import TBDCLI
@testable import TBDShared

/// Tier 1. `tbd worktree archive` names the remedy for a local worktree's
/// uncommitted-changes refusal. The daemon guards every archive, refuses a
/// worktree whose folder holds uncommitted changes or whose `git status`
/// cannot be read, states the fact alone and marks the refusal
/// `worktreeArchiveUncommitted`; the CLI runs no check of its own and appends
/// the `--force` hint for that code. One test per branch of
/// `WorktreeArchive.guardedRefusalMessage(for:)`.
@Suite("worktree archive: uncommitted-changes refusal")
struct WorktreeArchiveUncommittedRefusalTests {

    /// The daemon's sentence, verbatim, gains the flag that gets past it.
    @Test func anUncommittedRefusalGainsTheForceHint() {
        let sentence = """
            acme-wt has 1 uncommitted change(s) that archiving would delete:
              ?? notes.md
            Commit or remove them first.
            """
        let response = RPCResponse(
            error: sentence, code: RPCErrorCode.worktreeArchiveUncommitted.rawValue)

        #expect(WorktreeArchive.guardedRefusalMessage(for: response)
            == sentence + " Pass --force to archive anyway.")
    }

    /// An unreadable status refuses under the same code, so it gets the same
    /// hint.
    @Test func anUnverifiableRefusalGainsTheForceHint() {
        let sentence = "Could not check /tmp/acme-wt for uncommitted changes "
            + "(git status exited 128: fatal: not a git repository). Archiving deletes the directory."
        let response = RPCResponse(
            error: sentence, code: RPCErrorCode.worktreeArchiveUncommitted.rawValue)

        #expect(WorktreeArchive.guardedRefusalMessage(for: response)
            == sentence + " Pass --force to archive anyway.")
    }

    /// The remote lane's code keeps its own hint, which retires a lane rather
    /// than archiving a folder.
    @Test func theRemoteCodeKeepsTheRemoteHint() {
        let response = RPCResponse(
            error: "Cannot archive acme-remote: its agent is still working.",
            code: RPCErrorCode.remoteLaneArchiveGuarded.rawValue)

        #expect(WorktreeArchive.guardedRefusalMessage(for: response)
            == "Cannot archive acme-remote: its agent is still working. Re-run with --force to retire it anyway.")
    }

    @Test func aSuccessGetsNoHint() {
        #expect(WorktreeArchive.guardedRefusalMessage(for: .ok()) == nil)
    }

    /// `--force` gets past nothing else, so every other code keeps its plain
    /// error.
    @Test func anotherCodeGetsNoHint() {
        for code in [RPCErrorCode.terminalBusy, .startHeld, .profileMissing] {
            let response = RPCResponse(error: "refused", code: code.rawValue)
            #expect(WorktreeArchive.guardedRefusalMessage(for: response) == nil, "\(code)")
        }
    }

    /// The code decides, not the prose: a sentence about uncommitted changes
    /// carries no hint without the code.
    @Test func aRefusalWithNoCodeGetsNoHint() {
        let response = RPCResponse(
            error: "acme-wt has 1 uncommitted change(s) that archiving would delete.")

        #expect(WorktreeArchive.guardedRefusalMessage(for: response) == nil)
    }
}
