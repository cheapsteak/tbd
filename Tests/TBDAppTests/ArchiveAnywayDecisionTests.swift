import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// Tier 1. A remote lane's archive that a guard refused is offered back as
/// Archive anyway (`docs/specs/2026-08-16-remote-lane-archive-design.md`
/// §"Surfaces"), a local worktree's archive refused over uncommitted changes
/// is offered back as Archive and Delete Changes, and nothing else is offered
/// at all. Tests the pure classifier and copy behind
/// `archiveWorktree(id:force:discardUncommittedChanges:)` without a live
/// `DaemonClient` or a modal, one test per branch.
@MainActor
@Suite("Archive anyway decision")
struct ArchiveAnywayDecisionTests {

    /// Accepting Archive anyway resends with `force` and nothing else.
    @Test func archiveAnywayRetriesForced() throws {
        let flags = try #require(AppState.archiveRetryFlags(after: .offerArchiveAnyway, force: false))
        #expect(flags.force == true)
        #expect(flags.discardUncommittedChanges == false)
    }

    /// Accepting the discard offer never sends `force`, so the archive hook
    /// still runs.
    @Test func discardOfferRetriesWithoutForce() throws {
        let flags = try #require(AppState.archiveRetryFlags(after: .offerDiscardUncommitted, force: false))
        #expect(flags.force == false)
        #expect(flags.discardUncommittedChanges == true)
    }

    /// A plain failure offers nothing to resend.
    @Test func plainFailureHasNoRetry() {
        #expect(AppState.archiveRetryFlags(after: .plainFailure, force: false) == nil)
    }

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

    // MARK: - Uncommitted changes in a local worktree

    /// The uncommitted-changes code on a call that carried neither flag:
    /// offer to resend it with `discardUncommittedChanges`.
    @Test func uncommittedCodeOnAPlainArchiveOffersToDiscard() {
        let surface = AppState.archiveFailureSurface(
            forErrorCode: RPCErrorCode.worktreeArchiveUncommitted.rawValue,
            alreadyForced: false, alreadyDiscardingUncommitted: false)
        #expect(surface == .offerDiscardUncommitted)
    }

    /// A call already discarding the changes cannot meet that guard again, so
    /// the offer can never loop.
    @Test func uncommittedCodeOnADiscardingArchiveIsAPlainFailure() {
        let surface = AppState.archiveFailureSurface(
            forErrorCode: RPCErrorCode.worktreeArchiveUncommitted.rawValue,
            alreadyForced: false, alreadyDiscardingUncommitted: true)
        #expect(surface == .plainFailure)
    }

    /// `force` lifts the guard as well, so a forced call carrying the code is
    /// a plain failure too.
    @Test func uncommittedCodeOnAForcedArchiveIsAPlainFailure() {
        let surface = AppState.archiveFailureSurface(
            forErrorCode: RPCErrorCode.worktreeArchiveUncommitted.rawValue,
            alreadyForced: true, alreadyDiscardingUncommitted: false)
        #expect(surface == .plainFailure)
    }

    /// Discarding uncommitted changes is not a remote lane's flag: its guard
    /// code still offers Archive anyway, exactly as without it.
    @Test func remoteGuardCodeIsUnchangedByTheDiscardFlag() {
        let surface = AppState.archiveFailureSurface(
            forErrorCode: RPCErrorCode.remoteLaneArchiveGuarded.rawValue,
            alreadyForced: false, alreadyDiscardingUncommitted: true)
        #expect(surface == .offerArchiveAnyway)
    }

    /// The daemon's sentence is the alert's message, verbatim, the
    /// informative text says the loss is permanent, and the button names the
    /// act.
    @Test func discardPromptCopyCarriesTheRefusalSentence() {
        let refusal = """
            acme-wt has 1 uncommitted change(s) that archiving would delete:
              ?? notes.md
            Commit or remove them first.
            """
        let (message, informative, confirm) = AppState.discardUncommittedPrompt(refusal: refusal)
        #expect(message == refusal)
        #expect(informative.contains("deletes this worktree's folder"))
        #expect(informative.contains("committed on its branch"))
        #expect(informative.contains("lost for good"))
        #expect(confirm == "Archive and Delete Changes")
    }
}
