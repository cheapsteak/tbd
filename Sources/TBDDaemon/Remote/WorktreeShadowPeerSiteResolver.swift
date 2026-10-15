import Foundation
import TBDShared

/// The production `ShadowPeerSiteResolving`: the join from a provider's own
/// session id to the worktree row TBD adopted that session into.
///
/// **An index probe on an identity both sides already hold, not a search.** The
/// `peer` line carries the provider's session id, which is exactly what TBD
/// stored as that row's `providerSessionID` when it adopted the session, so the
/// lookup is `findRemote(provider:sessionID:)` against
/// `idx_worktree_provider_session`. Nothing the provider asserts on the line
/// composes the answer: not the handle, which means nothing outside one
/// connection, and not the name, which is the far side's claim rather than the
/// name TBD's own rule specifies.
///
/// **The `cwd` is the repository's own directory, and it is chosen rather than
/// inherited.** A shadow's `cwd` MUST name a directory that exists on *this*
/// machine — a remote path resolves to nothing here, and a surface filtering on
/// the directory existing would drop the row. A remote worktree row cannot
/// supply one: its `localPath` is the synthetic `remote://` URI
/// `WorktreeLocation.storagePath` mints to satisfy a `NOT NULL UNIQUE` column,
/// and there are no files behind it. The repository the row is registered
/// under is the nearest local thing that is genuinely *about* that session, it
/// exists on disk, and it is a directory TBD already owns. It is verified
/// before use rather than assumed, because a repo whose checkout was moved or
/// deleted would otherwise publish a shadow pointing at nothing.
///
/// **Every failure is nil, and nil means "publish nothing".** A session with no
/// row, a row with no repository (a scratch space), and a repository whose
/// directory is gone all leave TBD without one half of a site, and it may
/// invent neither half: a made-up display name is an identity peers would go on
/// to address, and a made-up `cwd` is a directory that does not exist. The
/// manager counts such a handle as unmirrored and surfaces it, which is the
/// path that already exists there.
///
/// **A repository whose `tbd.toml` does not switch peer messaging on gets no
/// shadow**, and says so as `.switchedOff` rather than as an unsited nil — and
/// so does every case where TBD cannot confirm the switch is on: a failed
/// read, a repo row that is gone, a checkout that is gone. The difference
/// matters to the manager: both withdraw a published shadow on its recheck,
/// but only `.switchedOff` holds the peer back to republish when the switch
/// turns on again; consent to share that cannot be confirmed is treated as
/// absent.
///
/// Design: `docs/specs/2026-08-29-remote-peer-messaging-design.md`
/// §§ "Addressing and naming", "The per-repository switch".
public struct WorktreeShadowPeerSiteResolver: ShadowPeerSiteResolving {
    /// One resolver per provider: `providerSessionID` is unique only within a
    /// provider, and a resolver that searched across providers could site a
    /// shadow into another provider's lane.
    private let provider: String
    private let worktrees: WorktreeStore
    private let repos: RepoStore
    /// Whether a path is a directory that exists here. Injected so a test needs
    /// no real checkout, and so the check is visibly part of the contract
    /// rather than an incidental `FileManager` call.
    private let directoryExists: @Sendable (String) -> Bool
    /// Whether the repository has peer messaging switched on. Required rather
    /// than defaulted, so no caller can build a resolver that forgets the
    /// switch.
    private let peerMessagingOn: @Sendable (Repo) -> Bool

    public init(
        provider: String,
        worktrees: WorktreeStore,
        repos: RepoStore,
        peerMessagingOn: @escaping @Sendable (Repo) -> Bool,
        directoryExists: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    ) {
        self.provider = provider
        self.worktrees = worktrees
        self.repos = repos
        self.directoryExists = directoryExists
        self.peerMessagingOn = peerMessagingOn
    }

    public func site(forProviderSessionID sessionID: String) async -> ShadowPeerSite? {
        guard case .sited(let site) = await resolution(forProviderSessionID: sessionID)
        else { return nil }
        return site
    }

    public func resolution(
        forProviderSessionID sessionID: String
    ) async -> ShadowPeerSiteResolution {
        // The switch fails closed. Once TBD cannot rule out that the session
        // sits in a switched-off repository — the row read failed, the repo row
        // is gone, its checkout is gone so its `tbd.toml` cannot be read — the
        // answer is `.switchedOff`, which holds a new peer back and withdraws a
        // published one. Only "TBD adopted no row for this session" and "the
        // row belongs to no repository" are `.unsited`: neither can be a shadow
        // anyone consented to.
        let found: Worktree?
        do {
            found = try await worktrees.findRemote(provider: provider, sessionID: sessionID)
        } catch {
            return .switchedOff
        }
        guard let worktree = found else { return .unsited }
        guard let repoID = worktree.repoID else { return .unsited }
        let repo: Repo?
        do {
            repo = try await repos.get(id: repoID)
        } catch {
            return .switchedOff
        }
        guard let repo, directoryExists(repo.path), peerMessagingOn(repo) else {
            return .switchedOff
        }
        return .sited(ShadowPeerSite(worktreeDisplayName: worktree.displayName, path: repo.path))
    }
}
