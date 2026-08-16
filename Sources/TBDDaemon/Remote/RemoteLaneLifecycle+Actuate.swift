import Foundation
import TBDShared
import os

private let remoteLaneLogger = Logger(subsystem: "com.tbd.daemon", category: "remoteLane")

/// Carrying a remote lane's archive or revive out, once
/// `RemoteLaneLifecycle`'s pure decisions have said what to do
/// (`docs/specs/2026-08-16-remote-lane-archive-design.md` §"Archive",
/// §"Revive", §"The record").
///
/// The split between deciding and acting is the record's shape, not a style
/// preference. **A refusal happens above the actuation row** — nothing was
/// attempted, and the record may claim solely acts that were attempted — so
/// callers ask for a decision first, return the refusal if that is what comes
/// back, and only then write their row and call the `perform` half. The `gone`
/// path does write a row: no provider call was made, but the row genuinely
/// changed status, and that is the act the record names.
///
/// Nothing here reaches `beginArchiveWorktree`, `completeArchiveWorktree`,
/// tmux teardown, scrollback capture, or directory removal. A remote lane's
/// files are on another machine; there is nothing local to tear down.
extension RemoteLaneLifecycle {

    // MARK: - Decisions, with the guards applied

    /// A remote archive, decided: either refused above the record, or a step
    /// to carry out below it.
    enum ArchiveDecision: Equatable {
        case refused(String)
        case proceed(ArchiveStep)
    }

    /// The act itself, once the capability routing and the guards have both
    /// passed.
    enum ArchiveStep: Equatable {
        /// Call `archive <id>`, then mark the row archived.
        case invokeVerb(provider: String, sessionID: String)
        /// Mark the row archived and call nothing — the `gone` exemption.
        case rowOnly
    }

    /// A remote revive, decided. Same shape and the same reason as
    /// `ArchiveDecision`.
    enum ReviveDecision: Equatable {
        case refused(String)
        case proceed(ReviveStep)
    }

    enum ReviveStep: Equatable {
        case invokeUnarchive(provider: String, sessionID: String)
        case rowOnly
    }

    /// Routes an archive of `worktree`, applying the verb path's two guards.
    ///
    /// The capability routing is `archivePlan`'s, unchanged — this only adds
    /// the guards, and only on the verb path. The `gone` path touches nothing
    /// on the provider and so has nothing to defend, which is why the guards
    /// sit inside the `.invokeVerb` arm rather than ahead of the switch.
    /// `force` overrides both.
    func archiveDecision(for worktree: Worktree, force: Bool) async throws -> ArchiveDecision {
        guard case .remote(let provider, let sessionID) = worktree.location else {
            return .refused("Cannot archive \(worktree.name) through the remote path: it is a local worktree.")
        }
        let row = try await db.remoteSessions.row(provider: provider, sessionID: sessionID)
        let payload = row?.decodedPayload
        let capabilities = await manager.declaredCapabilities(provider: provider)
        switch Self.archivePlan(capabilities: capabilities, isGone: row?.gone ?? false) {
        case .refused(let message):
            return .refused("Cannot archive \(worktree.name): \(message)")
        case .rowOnlyGone:
            return .proceed(.rowOnly)
        case .invokeVerb:
            if !force {
                if payload?.agentState == .working {
                    return .refused(Self.workingGuardRefusal(worktree.name))
                }
                if Self.metaReportsDirtyWorkspace(payload?.meta) {
                    return .refused(Self.dirtyWorkspaceGuardRefusal(worktree.name))
                }
            }
            return .proceed(.invokeVerb(provider: provider, sessionID: sessionID))
        }
    }

    /// Routes a revive of `worktree`.
    ///
    /// `providerReportsArchived` is what the provider reports **right now**,
    /// read from the mirror's current payload — not how the row came to be
    /// archived, so no provenance has to be persisted. An absent `archived`
    /// reads as `false` here (`isArchived`, the contract's display reading):
    /// a provider that made no claim is not one asserting a retirement this
    /// flip would fight with.
    func reviveDecision(for worktree: Worktree) async throws -> ReviveDecision {
        guard case .remote(let provider, let sessionID) = worktree.location else {
            return .refused("Cannot revive \(worktree.name) through the remote path: it is a local worktree.")
        }
        let row = try await db.remoteSessions.row(provider: provider, sessionID: sessionID)
        let capabilities = await manager.declaredCapabilities(provider: provider)
        switch Self.revivePlan(
            capabilities: capabilities,
            providerReportsArchived: row?.decodedPayload?.isArchived ?? false
        ) {
        case .refusedNoUnarchive(let message):
            return .refused("Cannot revive \(worktree.name): \(message)")
        case .rowOnly:
            return .proceed(.rowOnly)
        case .invokeUnarchive:
            return .proceed(.invokeUnarchive(provider: provider, sessionID: sessionID))
        }
    }

    // MARK: - Acting

    /// Carries out a decided archive. Returns `nil` on success, or the
    /// message to surface when the provider verb failed — in which case the
    /// row is left alone, because a retirement TBD did not perform is not one
    /// it may claim.
    ///
    /// `date` is the filing decision's timestamp and is **compared**, not
    /// displayed: `noteFilingDecision` is what stops a `list` response
    /// composed before this moment from undoing it on arrival. Skipping that
    /// call would leave the whole stale-snapshot watermark dead code.
    func performArchive(
        _ step: ArchiveStep, worktree: Worktree, date: Date = Date()
    ) async throws -> String? {
        if case .invokeVerb(let provider, let sessionID) = step {
            if let failure = await invokeRetirementVerb(
                "archive", provider: provider, sessionID: sessionID) {
                return failure
            }
        }
        try await db.worktrees.archive(id: worktree.id)
        await manager.noteFilingDecision(worktreeID: worktree.id, at: date)
        subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(worktreeID: worktree.id)))
        return nil
    }

    /// Carries out a decided revive. Returns `nil` on success, or the message
    /// to surface when the provider verb failed.
    ///
    /// The session's condition — running, exited, or no longer there — is
    /// reported through the mirror: whatever Session object the provider
    /// hands back is upserted before the row flips, so the lane returns to
    /// the active list already carrying the provider's current word on it
    /// rather than the stale payload it was archived with.
    func performRevive(
        _ step: ReviveStep, worktree: Worktree, date: Date = Date()
    ) async throws -> String? {
        if case .invokeUnarchive(let provider, let sessionID) = step {
            if let failure = await invokeRetirementVerb(
                "unarchive", provider: provider, sessionID: sessionID) {
                return failure
            }
        }
        try await db.worktrees.revive(id: worktree.id)
        await manager.noteFilingDecision(worktreeID: worktree.id, at: date)
        subscriptions.broadcast(delta: .worktreeRevived(WorktreeDelta(
            worktreeID: worktree.id, repoID: worktree.repoID,
            name: worktree.name, path: worktree.localPath)))
        return nil
    }

    /// Invokes `archive` or `unarchive` and mirrors whatever Session object
    /// comes back. Returns `nil` when the row may now be filed, or the
    /// message to surface otherwise.
    ///
    /// **`not_found` degrades to a row-only filing rather than an error, in
    /// both directions.** A provider that no longer knows this session cannot
    /// retire or restore it, and there is no live session left to
    /// misdescribe — the same reasoning the `gone` exemption rests on. Were
    /// it an error instead, a `gone` lane whose provider happens to declare
    /// `archive` would take the verb path, fail, and become unretirable,
    /// while an identical lane on a provider declaring nothing would file
    /// cleanly. Both verbs are idempotent per contract, so the attempt costs
    /// a round trip and never a wrong outcome.
    ///
    /// This is deliberately **not** a place `stop` can be reached from. The
    /// contract names ending compute and retiring a record as separate acts,
    /// and no path in TBD substitutes one for the other.
    private func invokeRetirementVerb(
        _ verb: String, provider: String, sessionID: String
    ) async -> String? {
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: provider, verb: [verb, sessionID], stdin: nil, timeout: 30)
        } catch let error as ProviderRunError {
            remoteLaneLogger.error(
                "\(verb, privacy: .public) provider=\(provider, privacy: .public) timed out")
            switch error {
            case .timeout(let timedOutVerb):
                return "provider '\(provider)' timed out running '\(timedOutVerb)'"
            }
        } catch {
            remoteLaneLogger.error(
                "\(verb, privacy: .public) provider=\(provider, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return "\(error)"
        }
        if result.failureClass != nil {
            if result.decodedError?.code == "not_found" {
                remoteLaneLogger.debug(
                    "\(verb, privacy: .public) on \(provider, privacy: .public)/\(sessionID, privacy: .public) reported not_found; filing the row alone")
                return nil
            }
            let message = result.decodedError?.message ?? "\(verb) failed (exit \(result.exitCode))"
            remoteLaneLogger.error(
                "\(verb, privacy: .public) provider=\(provider, privacy: .public) failed: \(message, privacy: .public)")
            return message
        }
        if let session = try? result.decoded(RemoteSessionPayload.self) {
            await manager.applyUpsert(session, provider: provider)
        }
        return nil
    }
}
