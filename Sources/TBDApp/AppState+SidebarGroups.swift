import Foundation
import TBDShared

struct SidebarGroupReveal: Equatable {
    let generation: UInt64
    let worktreeIDs: Set<UUID>
    let remoteID: UUID?
    let groups: Set<SidebarGroupID>
}

extension AppState {
    /// One indexed fleet snapshot shared by every section and reveal pass.
    /// Read tracked inputs even on a cache hit, preserving Observation dependencies.
    var sidebarRemoteSnapshot: SidebarRemoteGroups.Snapshot {
        let rows = worktrees, sessions = remoteSessions, providers = remoteProviders
        if let cached = sidebarRemoteSnapshotCache { return cached }
        let snapshot = SidebarRemoteGroups.Snapshot(
            worktrees: rows.values.flatMap { $0 }, sessions: sessions, providers: providers)
        sidebarRemoteSnapshotCache = snapshot
        return snapshot
    }

    func toggleSidebarGroup(_ id: SidebarGroupID) {
        if expandedSidebarGroups.contains(id) {
            expandedSidebarGroups.remove(id)
        } else {
            expandedSidebarGroups.insert(id)
        }
    }

    func sidebarRemoteGroups(repoID: UUID) -> SidebarRemoteGroups {
        let snapshot = sidebarRemoteSnapshot
        let rows = worktrees[repoID] ?? []
        let roots = rows.filter {
            ($0.status == .active || $0.status == .creating) && $0.parentWorktreeID == nil
        }.sorted { $0.sortOrder < $1.sortOrder }
        return SidebarRemoteGroups(
            roots: roots,
            remainder: RepoSectionView.matchedRemoteSessions(
                snapshot.sessionsByRepo[repoID] ?? [], repoID: repoID, worktrees: rows),
            snapshot: snapshot, unread: unreadByRemoteSession, worktreeUnread: unreadByWorktree)
    }

    func sidebarRemoteGroups(provider: String) -> SidebarRemoteGroups {
        let snapshot = sidebarRemoteSnapshot
        let known = RemoteSectionView.knownRepoIDs(repos: repos, repoFilter: repoFilter)
        return SidebarRemoteGroups(
            roots: [],
            remainder: RemoteSectionView.sessions(
                in: snapshot.sessionsByProvider[provider] ?? [], forProvider: provider, knownRepoIDs: known),
            snapshot: snapshot,
            unread: unreadByRemoteSession)
    }

    var sidebarSelectionReveal: SidebarGroupReveal {
        sidebarGroupReveal(worktreeIDs: selectedWorktreeIDs, selection: selectedRemoteSession)
    }

    func sidebarGroupReveal(worktreeIDs: Set<UUID>, selection: RemoteSessionSelection?) -> SidebarGroupReveal {
        let remoteID = selection.map { RemoteSessionIdentity.uuid(provider: $0.provider, sessionID: $0.sessionID) }
        var groups: Set<SidebarGroupID> = []
        for repo in repos where repoFilter == nil || repoFilter == repo.id {
            groups.formUnion(sidebarRemoteGroups(repoID: repo.id).revealGroups(
                owner: .repository(repo.id), worktreeIDs: worktreeIDs, remoteID: remoteID))
        }
        for provider in remoteProviders {
            groups.formUnion(sidebarRemoteGroups(provider: provider.config.name).revealGroups(
                owner: .provider(provider.config.name), worktreeIDs: worktreeIDs, remoteID: remoteID))
        }
        return SidebarGroupReveal(generation: sidebarSelectionGeneration,
                                  worktreeIDs: worktreeIDs, remoteID: remoteID, groups: groups)
    }

    /// Membership changes reveal transient groups without overriding a collapsed
    /// repository. Navigation may expand the owning section; a missing previous
    /// value explicitly requests that behavior for initial mounting and scrolls.
    func revealSidebarGroups(_ reveal: SidebarGroupReveal, previous: SidebarGroupReveal? = nil) {
        expandedSidebarGroups.formUnion(reveal.groups)
        if let previous,
           previous.generation == reveal.generation,
           previous.worktreeIDs == reveal.worktreeIDs,
           previous.remoteID == reveal.remoteID { return }
        for group in reveal.groups {
            guard case .repository(let id) = group.owner,
                  let index = repos.firstIndex(where: { $0.id == id }), !repos[index].expanded else { continue }
            repos[index].expanded = true
            Task { try? await daemonClient.setRepoExpanded(id: id, expanded: true) }
        }
    }
}
