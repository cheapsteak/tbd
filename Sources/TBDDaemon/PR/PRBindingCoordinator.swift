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
    private let isGitLabHost: @Sendable (UUID, String) async -> Bool?

    /// - Parameter resolveRepo: the worktree's own `owner`/`name` and host, or
    ///   nil when they cannot be determined (no remote, git failure, unknown
    ///   worktree). Validation always compares `owner`/`name`, and compares the
    ///   host under the rule `hostAgreement` states — the host also rides along
    ///   for the callers that must *compose* a reference.
    /// - Parameter isGitLabHost: whether the worktree's own host is one the
    ///   user has configured `glab` for, or nil when the question could not be
    ///   put at all (no directory on this machine to ask in). Only the
    ///   `github.com` exemption in `hostAgreement` consults it, so a worktree
    ///   whose host already matches the URL's never pays for the answer.
    public init(store: PRBindingStore,
                resolveRepo: @escaping @Sendable (UUID) async -> (owner: String, name: String, host: String)?,
                isGitLabHost: @escaping @Sendable (UUID, String) async -> Bool?) {
        self.store = store
        self.resolveRepo = resolveRepo
        self.isGitLabHost = isGitLabHost
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
        switch await hostAgreement(worktreeID: worktreeID, own: own.host, parsed: parsed.host) {
        case .agree:
            break
        case .disagree:
            // The owner and name are identical here, so naming them alone would
            // read as nonsense — the host is the whole disagreement.
            let elsewhere = "\(parsed.host)/\(other)"
            logger.debug("rejecting PR #\(parsed.number, privacy: .public) for worktree \(worktreeID.uuidString, privacy: .public): PR is on \(elsewhere, privacy: .public), worktree is on \(own.host, privacy: .public)")
            return .rejectedWrongRepo(elsewhere)
        case .undetermined:
            logger.debug("deferring PR #\(parsed.number, privacy: .public) for worktree \(worktreeID.uuidString, privacy: .public): the forge of \(own.host, privacy: .public) could not be determined")
            return .deferredUnknownRepo
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

    /// The host `PRBindingExtractor`'s GitHub pattern hard-codes. Because that
    /// pattern is host-locked, a parsed `github.com` is the pattern's own
    /// constant rather than something read off the URL's forge — which is what
    /// `hostAgreement` leans on. When enterprise support lands and that pattern
    /// starts *capturing* a host, this constant and the exemption it drives go
    /// with it.
    private static let patternAssumedGitHubHost = "github.com"

    /// Whether a request's host may name the same repo the worktree checks out,
    /// or whether nothing could answer.
    private enum HostAgreement {
        case agree
        case disagree
        /// The worktree's forge could not be established, and the answer would
        /// have decided the `github.com` exemption.
        case undetermined
    }

    /// Whether a request's host may name the same repo the worktree checks out.
    ///
    /// Two identically named projects on two different forges are two different
    /// projects. `PRBinding.identityKey` and the `worktree_pull_request` unique
    /// index both key on the host; the wrong-repo guard is the one place that
    /// does not, and comparing `owner`/`name` alone lets a GitLab merge request
    /// for `acme/proj` bind to a `github.com/acme/proj` worktree. A false bind
    /// is the expensive direction — when that foreign request merges,
    /// `allResolved` can auto-archive a worktree that never had anything to do
    /// with it, while a missed bind costs one `tbd pr attach`.
    ///
    /// So hosts agree when they are the same host (case-insensitively;
    /// hostnames are), and when either side has no host at all.
    ///
    /// **The `github.com` exemption, and where it stops.** A parsed
    /// `github.com` is a constant `PRBindingExtractor`'s host-locked GitHub
    /// pattern supplies rather than a host it read off the URL, so on its own it
    /// is not evidence about where the request lives. Rejecting on it would
    /// refuse bindings that work today — a `github.com` URL attached to a GitHub
    /// Enterprise or self-hosted-mirror checkout with the same `owner/name`, the
    /// same-org/same-name-across-hosts collision `RemoteRepoMatching` documents
    /// as deliberately tolerated. Such a worktree therefore still binds.
    ///
    /// A worktree whose own host speaks **GitLab** does not. Its merge requests
    /// live on that host, so a `github.com` pull request sharing an `owner/name`
    /// with it is a different project by construction — and binding it would
    /// poll a stranger's PR through `gh` and let that stranger's merge
    /// auto-archive this worktree. That is the cross-forge collision this guard
    /// exists to close, and it is the whole of what the exemption gives up.
    ///
    /// **The forge is asked, never read off the hostname.** "Not github.com"
    /// describes GitHub Enterprise, Bitbucket, Gitea and Codeberg as readily as
    /// a self-managed GitLab, so a host-keyed classifier would refuse all four
    /// of those fleets a binding they should get. The answer comes from the same
    /// seam the rest of the daemon uses — the hosts the user configured `glab`
    /// for, a declaration rather than an inference.
    ///
    /// **An undetermined forge defers rather than binds.** Nothing has answered
    /// there, and the two ways to be wrong are not symmetric: binding invents a
    /// row that can auto-archive a worktree on someone else's merge, while
    /// deferring writes nothing and the next poll or attach asks again. The
    /// caller turns it into `.deferredUnknownRepo`, the same outcome an
    /// unresolvable repo already gets. Like an absent host it is belt-and-braces
    /// rather than a live case: the forge is unaskable only for a worktree with
    /// no directory on this machine, and such a worktree cannot resolve its own
    /// repo either, so `bind` has already deferred before reaching here.
    ///
    /// An absent host on either side is treated as unknown, not as a mismatch —
    /// the same reason an unresolvable repo defers instead of rejecting. Absent
    /// is unreachable from the shipping call paths (the extractor always names a
    /// host, and a bare-number attach composes the worktree's own), so it too is
    /// belt-and-braces; `owner`/`name` still have to match either way.
    ///
    /// Hosts themselves are compared as strings, and no forge classification
    /// derived from a URL's shape (`Forge.forURL`) enters this guard: that
    /// answers what a request is, not whether two hosts are one host, and a
    /// validation gate needs the hosts.
    private func hostAgreement(worktreeID: UUID, own: String, parsed: String) async -> HostAgreement {
        let own = own.lowercased()
        let parsed = parsed.lowercased()
        guard !own.isEmpty, !parsed.isEmpty else { return .agree }
        if parsed == own { return .agree }
        // Every other disagreement is a disagreement; only the pattern's own
        // constant earns a second question, and only that question spawns work.
        guard parsed == Self.patternAssumedGitHubHost else { return .disagree }
        guard let ownIsGitLab = await isGitLabHost(worktreeID, own) else { return .undetermined }
        return ownIsGitLab ? .disagree : .agree
    }

    private func identityKey(worktreeID: UUID, parsed: ParsedPRURL) -> String {
        PRBinding(worktreeID: worktreeID, host: parsed.host, owner: parsed.owner,
                  repo: parsed.repo, number: parsed.number, url: parsed.url,
                  source: .manual).identityKey
    }
}
