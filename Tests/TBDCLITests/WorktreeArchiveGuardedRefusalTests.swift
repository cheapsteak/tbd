import Foundation
import Testing

@testable import TBDCLI
@testable import TBDShared

/// Tier 1. `tbd worktree archive` names the remedy for a remote lane's guard
/// refusal. The daemon's sentence states the fact alone and marks the
/// refusal `remoteLaneArchiveGuarded`; the CLI appends the `--force` hint for
/// that code and for no other failure, because `--force` gets past nothing
/// else (`docs/specs/2026-08-16-remote-lane-archive-design.md` §"Surfaces").
@Suite("worktree archive: guarded remote-lane refusal")
struct WorktreeArchiveGuardedRefusalTests {

    @Test func aGuardRefusalGainsTheForceHint() {
        let response = RPCResponse(
            error: "Cannot archive acme-remote: its agent is still working.",
            code: RPCErrorCode.remoteLaneArchiveGuarded.rawValue)

        #expect(WorktreeArchive.guardedRefusalMessage(for: response)
            == "Cannot archive acme-remote: its agent is still working. Re-run with --force to retire it anyway.")
    }

    /// A missing capability, remote backends off, the cloud gate: no retry
    /// gets past them, so the hint would point at a flag that only fails
    /// again. The error stays plain.
    @Test func aRefusalWithNoCodeGetsNoHint() {
        let response = RPCResponse(
            error: "Cannot archive acme-remote: provider 'fake' does not declare 'archive'.")

        #expect(WorktreeArchive.guardedRefusalMessage(for: response) == nil)
    }

    @Test func anotherCodeGetsNoHint() {
        for code in [RPCErrorCode.terminalBusy, .startHeld, .profileMissing] {
            let response = RPCResponse(error: "refused", code: code.rawValue)
            #expect(WorktreeArchive.guardedRefusalMessage(for: response) == nil, "\(code)")
        }
    }

    /// The code decides, not the prose: a sentence that happens to mention
    /// the flag is not a guard refusal without the code.
    @Test func theCodeDecidesNotTheProse() {
        let response = RPCResponse(error: "Cannot archive acme-remote. Re-run with --force.")

        #expect(WorktreeArchive.guardedRefusalMessage(for: response) == nil)
    }

    @Test func aSuccessIsNotARefusal() {
        #expect(WorktreeArchive.guardedRefusalMessage(for: .ok()) == nil)
    }
}
