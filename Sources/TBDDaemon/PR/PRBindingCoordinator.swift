import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "prBinding")

/// Applies binding policy on top of `PRBindingStore`: a PR must belong to the
/// worktree's own repo, a tombstone is only cleared by an explicit attach, and
/// an unresolvable repo defers rather than rejects.
///
/// The tombstone rule is what makes a user's detach durable. Discovery is
/// continuous — the branch matcher re-runs on every poll, the hook re-fires on
/// every `gh pr create`, and `seedProvenance` reconciles `Worktree.prNumber` on
/// every poll — so a detach that only deleted the row would be undone within
/// seconds. Only an explicit attach may clear one, which is why `seedProvenance`
/// writes with `.manual` yet is barred from reviving.
public actor PRBindingCoordinator {

    public enum BindOutcome: Sendable, Equatable {
        case bound(PRBinding)
        case alreadyBound
        /// The PR belongs to the named `owner/repo`, not the worktree's.
        case rejectedWrongRepo(String)
        /// The worktree's own repo could not be resolved — absence of evidence
        /// is not evidence of mismatch, so nothing is written and the next
        /// attempt retries.
        case deferredUnknownRepo
        /// The user detached this PR; only a manual attach may revive it.
        case tombstoned
        /// The worktree is at `PRBindingStore.maxBindingsPerWorktree` live
        /// bindings with nothing terminal to evict.
        case capFull
    }

    private let store: PRBindingStore
    private let resolveRepo: @Sendable (UUID) async -> (owner: String, name: String, host: String)?

    /// - Parameter resolveRepo: the worktree's own `owner`/`name` and host, or
    ///   nil when they cannot be determined (no remote, git failure, unknown
    ///   worktree). Validation compares `owner`/`name` only: the host is
    ///   carried for the callers that must *compose* a reference, and folding
    ///   it into the wrong-repo check would start rejecting bindings that are
    ///   accepted today, which is a policy change and not this one.
    public init(store: PRBindingStore,
                resolveRepo: @escaping @Sendable (UUID) async -> (owner: String, name: String, host: String)?) {
        self.store = store
        self.resolveRepo = resolveRepo
    }

    public func bind(worktreeID: UUID, parsed: ParsedPRURL,
                     source: PRBindingSource) async -> BindOutcome {
        // Only an explicit attach clears a tombstone — that is the whole
        // tombstone rule, and `.manual` is the source an attach carries.
        await bind(worktreeID: worktreeID, parsed: parsed, source: source,
                   mayReviveTombstone: source == .manual)
    }

    /// Seed the binding a worktree's `Worktree.prNumber` implies — the
    /// provenance of a worktree created from a PR row.
    ///
    /// Without this such a worktree owns a number and no binding, so its PR is
    /// invisible to `tbd pr list`, to the toolbar dropdown and to the status-bar
    /// chips. Fork PRs are the sharpest case: a fork head never appears in the
    /// viewer-authored batch, so branch matching is structurally unable to find
    /// them and the stored number is the only handle that exists.
    ///
    /// The source is `.manual` — naming a PR row at creation is as explicit as
    /// an attach — but seeding is **reconciled on every poll**, and `.manual` is
    /// the one source permitted to clear a tombstone. A plain
    /// `bind(source: .manual)` here would therefore undo a `tbd pr detach`
    /// within seconds. Seeding only ever writes the FIRST row for an identity;
    /// anything already on record, tombstone included, is left exactly as it is.
    public func seedProvenance(worktreeID: UUID, parsed: ParsedPRURL) async -> BindOutcome {
        await bind(worktreeID: worktreeID, parsed: parsed, source: .manual,
                   mayReviveTombstone: false)
    }

    private func bind(worktreeID: UUID, parsed: ParsedPRURL, source: PRBindingSource,
                      mayReviveTombstone: Bool) async -> BindOutcome {
        guard let own = await resolveRepo(worktreeID) else {
            logger.debug("deferring PR #\(parsed.number, privacy: .public): repo unresolved for worktree \(worktreeID.uuidString, privacy: .public)")
            return .deferredUnknownRepo
        }
        let other = "\(parsed.owner)/\(parsed.repo)"
        guard own.owner.lowercased() == parsed.owner.lowercased(),
              own.name.lowercased() == parsed.repo.lowercased() else {
            logger.debug("rejecting PR #\(parsed.number, privacy: .public) for worktree \(worktreeID.uuidString, privacy: .public): PR is in \(other, privacy: .public), worktree is in \(own.owner, privacy: .public)/\(own.name, privacy: .public)")
            return .rejectedWrongRepo(other)
        }

        let candidate = PRBinding(
            worktreeID: worktreeID, host: parsed.host, owner: parsed.owner,
            repo: parsed.repo, number: parsed.number, url: parsed.url, source: source)

        do {
            let existing = try await store.list(worktreeID: worktreeID, includeDetached: true)
                .first { $0.identityKey == candidate.identityKey }
            if let existing {
                guard existing.detached else { return .alreadyBound }
                guard mayReviveTombstone else {
                    logger.debug("refusing to revive detached PR #\(parsed.number, privacy: .public) for worktree \(worktreeID.uuidString, privacy: .public): a \(source.rawValue, privacy: .public) bind is not an explicit attach")
                    return .tombstoned
                }
                try await store.setDetached(worktreeID: worktreeID,
                                            identityKey: candidate.identityKey, detached: false)
                // Re-read so the returned binding reflects the cleared tombstone
                // rather than the detached row we matched on.
                let revived = try await store.list(worktreeID: worktreeID)
                    .first { $0.identityKey == candidate.identityKey }
                logger.debug("revived PR #\(parsed.number, privacy: .public) for worktree \(worktreeID.uuidString, privacy: .public) via manual attach")
                guard let revived else { return .deferredUnknownRepo }
                return .bound(revived)
            }
            guard let stored = try await store.upsert(candidate) else { return .capFull }
            logger.debug("bound PR #\(parsed.number, privacy: .public) to worktree \(worktreeID.uuidString, privacy: .public) via \(source.rawValue, privacy: .public)")
            return .bound(stored)
        } catch {
            logger.warning("failed to bind PR #\(parsed.number, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .deferredUnknownRepo
        }
    }

    /// Undo a branch match the poll's heal just disproved.
    ///
    /// The heal clears the worktree's cached status and persists the clear, but
    /// a binding is re-queried by `(host, owner, repo, number)` and never
    /// re-validated against the worktree's branches or its repo — so without
    /// this the row survives the heal, keeps driving the worktree's icon, and on
    /// merge satisfies `allResolved` and auto-archives a worktree that was
    /// merely tracking someone else's PR.
    ///
    /// **Only `branch` bindings.** A `hook` binding is direct evidence that this
    /// session ran the `gh pr create` that made the PR, and a `manual` binding
    /// is the user's explicit statement; neither is an inference from branch
    /// names, so neither may be undone by one. The removal is a hard delete
    /// rather than a tombstone — see `PRBindingStore.deleteBranchBinding` for
    /// why.
    ///
    /// Returns true when a binding was actually removed.
    @discardableResult
    public func healBranchMatch(worktreeID: UUID, parsed: ParsedPRURL) async -> Bool {
        let key = identityKey(worktreeID: worktreeID, parsed: parsed)
        do {
            let removed = try await store.deleteBranchBinding(worktreeID: worktreeID,
                                                              identityKey: key)
            if removed {
                logger.debug("removed branch-matched PR #\(parsed.number, privacy: .public) from worktree \(worktreeID.uuidString, privacy: .public): a poll heal disproved the attachment")
            }
            return removed
        } catch {
            logger.warning("failed to remove healed PR #\(parsed.number, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Tombstone a binding. Returns false when this worktree has no such PR, or
    /// when it was already detached.
    @discardableResult
    public func detach(worktreeID: UUID, parsed: ParsedPRURL) async throws -> Bool {
        try await store.setDetached(worktreeID: worktreeID,
                                    identityKey: identityKey(worktreeID: worktreeID,
                                                             parsed: parsed),
                                    detached: true)
    }

    private func identityKey(worktreeID: UUID, parsed: ParsedPRURL) -> String {
        PRBinding(worktreeID: worktreeID, host: parsed.host, owner: parsed.owner,
                  repo: parsed.repo, number: parsed.number, url: parsed.url,
                  source: .manual).identityKey
    }
}
