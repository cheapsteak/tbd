import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// Tier 1. A remote lane's archive that a guard refused is offered back as
/// Archive anyway, and nothing else is
/// (`docs/specs/2026-08-16-remote-lane-archive-design.md` §"Surfaces"). Tests
/// the pure classifier and copy behind `archiveWorktree(id:force:)` without a
/// live `DaemonClient` or a modal, one test per branch.
@MainActor
@Suite("Archive anyway decision")
struct ArchiveAnywayDecisionTests {

    /// The guard code on an unforced archive: offer to send it again with
    /// `force`.
    @Test func guardCodeOnAnUnforcedArchiveOffersArchiveAnyway() {
        let surface = AppState.archiveFailureSurface(
            forErrorCode: RPCErrorCode.remoteLaneArchiveGuarded.rawValue, alreadyForced: false)
        #expect(surface == .offerArchiveAnyway)
    }

    /// The same code on a call that was already forced gets the plain alert,
    /// so the offer can never loop.
    @Test func guardCodeOnAForcedArchiveIsAPlainFailure() {
        let surface = AppState.archiveFailureSurface(
            forErrorCode: RPCErrorCode.remoteLaneArchiveGuarded.rawValue, alreadyForced: true)
        #expect(surface == .plainFailure)
    }

    /// No code — a missing capability, remote backends off, the cloud gate, a
    /// local archive's failure — is a refusal no retry gets past.
    @Test func noCodeIsAPlainFailure() {
        #expect(AppState.archiveFailureSurface(forErrorCode: nil, alreadyForced: false) == .plainFailure)
    }

    /// A different code has its own remedy, or none; force is not it.
    @Test func anotherCodeIsAPlainFailure() {
        let surface = AppState.archiveFailureSurface(
            forErrorCode: RPCErrorCode.profileMissing.rawValue, alreadyForced: false)
        #expect(surface == .plainFailure)
    }

    /// The daemon's sentence is the alert's message, verbatim and without the
    /// transport's "RPC error:" prefix, and the buttons name the act.
    @Test func promptCopyCarriesTheRefusalSentence() {
        let refusal = "Cannot archive acme-remote: its agent is still working."
        let (message, informative, confirm) = AppState.archiveAnywayPrompt(refusal: refusal)
        #expect(message == refusal)
        #expect(informative.contains("all three safety checks"))
        #expect(informative.contains("working agent"))
        #expect(informative.contains("uncommitted work"))
        #expect(informative.contains("stale inventory"))
        #expect(confirm == "Archive anyway")
    }
}
