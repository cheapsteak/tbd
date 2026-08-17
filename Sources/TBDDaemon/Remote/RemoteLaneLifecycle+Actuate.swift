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
    /// on the provider and so has nothing to defend, which is why all three
    /// guards sit inside the `.invokeVerb` arm rather than ahead of the switch.
    /// `force` overrides all three.
    ///
    /// The stale-snapshot guard belongs with the other two for the same
    /// reason: it exists because `agentState` and `meta.workspace_dirty` are
    /// read out of a mirror a stale inventory makes untrustworthy. The `gone`
    /// path reads neither, so there is nothing for staleness to make wrong —
    /// and gating it would leave a lane on a provider that cannot archive
    /// unretireable for as long as that provider stays unhealthy.
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
                if await manager.hasStaleSnapshot(provider: provider) {
                    return .refused(Self.staleSnapshotRefusal(worktree.name, provider: provider))
                }
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
            // Not gated on staleness: this path calls nothing and consults
            // nothing a stale inventory could make wrong. It is also the only
            // way back for a lane filed under the `gone` exemption, and revive
            // has no `--force` to lift a refusal with.
            return .proceed(.rowOnly)
        case .invokeUnarchive:
            // Same gate as archive's verb path, and there is no `--force` to
            // lift it: `worktree.revive` carries no force flag, and neither
            // does the `remote.unarchive` handler this parallels. The recovery
            // is the provider's next successful poll.
            if await manager.hasStaleSnapshot(provider: provider) {
                return .refused(Self.staleSnapshotRefusal(worktree.name, provider: provider))
            }
            return .proceed(.invokeUnarchive(provider: provider, sessionID: sessionID))
        }
    }

    // MARK: - Acting

    /// Carries out a decided archive. Returns `nil` on success, or the
    /// message to surface when the provider verb failed — in which case the
    /// row is left alone, because a retirement TBD did not perform is not one
    /// it may claim.
    ///
    /// `now` supplies the filing decision's timestamps, which are **compared**,
    /// not displayed — the date seam rather than the clock seam
    /// (`Tests/CLAUDE.md`, "Clock and date seams"). `noteFilingDecision` is
    /// what stops a `list` response composed before this gesture from undoing
    /// it on arrival; skipping it would leave the whole stale-snapshot
    /// watermark dead code.
    ///
    /// **The order of the four writes is load bearing, not incidental.** The
    /// contract mandates that `archive` return the updated Session, so a
    /// conforming provider's response carries `archived: true` — and mirroring
    /// it runs the filing sync. Were that mirror to land before the row is
    /// written, the sync would see a row still `.active` beside a fresh
    /// `archived: true` and file it a second time, on the daemon's own rail,
    /// with a notification claiming the *provider* retired a session the
    /// *user* just retired. So:
    ///
    /// 1. record the filing decision, **before** the verb is invoked, so a
    ///    poll already in flight cannot act on the row while the verb runs;
    /// 2. invoke the verb, holding whatever Session came back;
    /// 3. write the row, and **stamp the watermark again** — a verb takes real
    ///    time, and a poll launched after step 1 but before the row landed
    ///    carries the provider's pre-gesture word while passing a watermark
    ///    that only covers step 1. Without the second stamp the sync would
    ///    reverse the row about (verb duration / poll interval) of the time;
    /// 4. mirror the held response, by which time the sync observes a row
    ///    already in its target state and correctly does nothing.
    func performArchive(
        _ step: ArchiveStep, worktree: Worktree, now: @Sendable () -> Date = { Date() }
    ) async throws -> String? {
        let decidedAt = now()
        let prior = await manager.noteFilingDecision(worktreeID: worktree.id, at: decidedAt)
        var mirrored: (session: RemoteSessionPayload, provider: String)?
        if case .invokeVerb(let provider, let sessionID) = step {
            switch await invokeRetirementVerb(
                "archive", provider: provider, sessionID: sessionID) {
            case .failed(let message):
                await manager.withdrawFilingDecision(
                    worktreeID: worktree.id, restoring: prior, ifStillAt: decidedAt)
                return message
            case .succeeded(let session):
                mirrored = session.map { ($0, provider) }
            }
        }
        do {
            try await db.worktrees.archive(id: worktree.id)
        } catch {
            // The row write is as capable of failing as the verb was, and the
            // watermark recorded for it is as wrong afterwards. Same treatment.
            await manager.withdrawFilingDecision(
                worktreeID: worktree.id, restoring: prior, ifStillAt: decidedAt)
            throw error
        }
        await manager.noteFilingDecision(worktreeID: worktree.id, at: now())
        if let mirrored {
            // A conforming provider's response says `archived: true`, and the
            // sync reading it against a row already `.archived` does nothing.
            // A provider that returns `archived: false` from its own `archive`
            // is contradicting the contract, and the sync will take it at its
            // word and return the row while this RPC reports success. That is
            // the deliberate trade: mirroring the provider's current report is
            // what makes the filing sync authoritative in the first place, and
            // suppressing it for this one row would mean trusting the response
            // exactly as far as it agrees with us.
            await manager.applyUpsert(
                mirrored.session, provider: mirrored.provider, date: now())
        }
        subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(worktreeID: worktree.id)))
        return nil
    }

    /// Carries out a decided revive. Returns `nil` on success, or the message
    /// to surface when the provider verb failed.
    ///
    /// The session's condition — running, exited, or no longer there — is
    /// reported through the mirror: whatever Session object the provider
    /// hands back is upserted, so the lane returns to the active list already
    /// carrying the provider's current word on it rather than the stale
    /// payload it was archived with.
    ///
    /// Same four-step order as `performArchive`, and for the mirror-image
    /// reason: `unarchive` returns `archived: false`, so mirroring it before
    /// the row is written would hand the filing sync an `.archived` row beside
    /// a fresh `archived: false` and earn a second, daemon-rail `.spawn` pair
    /// for a gesture the user made once. The re-stamp after the row write
    /// closes the same window on this side: a poll launched while the verb ran
    /// carries a pre-revive `archived: true` that would otherwise re-file the
    /// row the user just returned.
    func performRevive(
        _ step: ReviveStep, worktree: Worktree, now: @Sendable () -> Date = { Date() }
    ) async throws -> String? {
        let decidedAt = now()
        let prior = await manager.noteFilingDecision(worktreeID: worktree.id, at: decidedAt)
        var mirrored: (session: RemoteSessionPayload, provider: String)?
        if case .invokeUnarchive(let provider, let sessionID) = step {
            switch await invokeRetirementVerb(
                "unarchive", provider: provider, sessionID: sessionID) {
            case .failed(let message):
                await manager.withdrawFilingDecision(
                    worktreeID: worktree.id, restoring: prior, ifStillAt: decidedAt)
                return message
            case .succeeded(let session):
                mirrored = session.map { ($0, provider) }
            }
        }
        do {
            try await db.worktrees.revive(id: worktree.id)
        } catch {
            await manager.withdrawFilingDecision(
                worktreeID: worktree.id, restoring: prior, ifStillAt: decidedAt)
            throw error
        }
        await manager.noteFilingDecision(worktreeID: worktree.id, at: now())
        if let mirrored {
            await manager.applyUpsert(
                mirrored.session, provider: mirrored.provider, date: now())
        }
        subscriptions.broadcast(delta: .worktreeRevived(WorktreeDelta(
            worktreeID: worktree.id, repoID: worktree.repoID,
            name: worktree.name, path: worktree.localPath)))
        return nil
    }

    /// What a retirement verb came back with.
    ///
    /// The Session object travels out rather than being mirrored here, so the
    /// caller can write the row first — see `performArchive`'s ordering note.
    /// A `.succeeded(nil)` is the `not_found` degradation and the row-only
    /// paths: the row may be filed, and there is nothing to mirror.
    private enum VerbOutcome {
        case failed(String)
        case succeeded(RemoteSessionPayload?)
    }

    /// Invokes `archive` or `unarchive` and decodes whatever Session object
    /// comes back. Returns `.succeeded` when the row may now be filed, or the
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
    ) async -> VerbOutcome {
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: provider, verb: [verb, sessionID], stdin: nil, timeout: 30)
        } catch let error as ProviderRunError {
            remoteLaneLogger.error(
                "\(verb, privacy: .public) provider=\(provider, privacy: .public) timed out")
            switch error {
            case .timeout(let timedOutVerb):
                return .failed("provider '\(provider)' timed out running '\(timedOutVerb)'")
            }
        } catch {
            remoteLaneLogger.error(
                "\(verb, privacy: .public) provider=\(provider, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .failed("\(error)")
        }
        if result.failureClass != nil {
            if result.decodedError?.code == "not_found" {
                remoteLaneLogger.debug(
                    "\(verb, privacy: .public) on \(provider, privacy: .public)/\(sessionID, privacy: .public) reported not_found; filing the row alone")
                return .succeeded(nil)
            }
            let message = result.decodedError?.message ?? "\(verb) failed (exit \(result.exitCode))"
            remoteLaneLogger.error(
                "\(verb, privacy: .public) provider=\(provider, privacy: .public) failed: \(message, privacy: .public)")
            return .failed(message)
        }
        return .succeeded(try? result.decoded(RemoteSessionPayload.self))
    }
}
