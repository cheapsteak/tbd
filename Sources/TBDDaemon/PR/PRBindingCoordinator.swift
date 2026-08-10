import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "prBinding")

/// Applies binding policy on top of `PRBindingStore`: a PR must belong to the
/// worktree's own repo, a tombstone is only cleared by an explicit attach, and
/// an unresolvable repo defers rather than rejects.
///
/// The tombstone rule is what makes a user's detach durable. Discovery is
/// continuous — the branch matcher re-runs on every poll and the hook re-fires
/// on every `gh pr create` — so a detach that only deleted the row would be
/// undone within seconds. Only `.manual` may clear one.
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
    private let resolveRepo: @Sendable (UUID) async -> (owner: String, name: String)?

    /// - Parameter resolveRepo: the worktree's own GitHub `owner`/`name`, or nil
    ///   when it cannot be determined (no remote, git failure, unknown worktree).
    public init(store: PRBindingStore,
                resolveRepo: @escaping @Sendable (UUID) async -> (owner: String, name: String)?) {
        self.store = store
        self.resolveRepo = resolveRepo
    }

    public func bind(worktreeID: UUID, parsed: ParsedPRURL,
                     source: PRBindingSource) async -> BindOutcome {
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
                guard source == .manual else {
                    logger.debug("refusing to revive detached PR #\(parsed.number, privacy: .public) for worktree \(worktreeID.uuidString, privacy: .public) from \(source.rawValue, privacy: .public)")
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

    /// Tombstone a binding. Returns false when this worktree has no such PR.
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
