import Foundation
import TBDShared

struct SidebarGroupReveal: Equatable {
    let generation: UInt64
    let worktreeIDs: Set<UUID>
    let remoteID: UUID?
    let groups: Set<SidebarGroupID>
}

extension SidebarGroupID {
    /// A stable string for persisting an expanded group across launches:
    /// `<kind>|<owner type>|<owner value>`. The provider name comes last and
    /// is split off with a bounded split, so a `|` inside it round-trips.
    var persistenceKey: String {
        let kindName: String
        switch kind {
        case .remote: kindName = "remote"
        case .exited: kindName = "exited"
        case .hibernated: kindName = "hibernated"
        }
        switch owner {
        case .repository(let id): return "\(kindName)|repository|\(id.uuidString)"
        case .provider(let name): return "\(kindName)|provider|\(name)"
        case .scratch: return "\(kindName)|scratch|"
        }
    }

    /// Nil for anything this build does not recognize, so a stale or
    /// hand-edited entry is dropped rather than misread.
    init?(persistenceKey: String) {
        let parts = persistenceKey.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let kind: Kind
        switch parts[0] {
        case "remote": kind = .remote
        case "exited": kind = .exited
        case "hibernated": kind = .hibernated
        default: return nil
        }
        let value = String(parts[2])
        switch parts[1] {
        case "repository":
            guard let id = UUID(uuidString: value) else { return nil }
            self.init(owner: .repository(id), kind: kind)
        case "provider":
            guard !value.isEmpty else { return nil }
            self.init(owner: .provider(value), kind: kind)
        case "scratch":
            guard value.isEmpty, kind == .hibernated else { return nil }
            self.init(owner: .scratch, kind: kind)
        default:
            return nil
        }
    }
}

extension AppState {
    /// UserDefaults key for the Settings → General toggle that files remote,
    /// exited and hibernated worktrees under collapsible sidebar groups.
    /// App-side `UserDefaults` rather than a daemon `config` column because
    /// the behavior is pure sidebar presentation, the same placement as
    /// `enableTranscriptKey`. Off renders the sidebar with every row inline in
    /// its usual place and no group headers. Spec:
    /// `docs/specs/2026-10-06-sidebar-groups-toggle-design.md`.
    ///
    /// Three states: an absent key means nobody has chosen and follows
    /// `sidebarWorkflowGroupsDefault`; the toggle stores an explicit `true`
    /// or `false` only when flipped. Read through
    /// `sidebarWorkflowGroupsEnabled(defaults:)` or an `@AppStorage` whose
    /// default is that constant — never `bool(forKey:)`, which collapses
    /// "unset" into `false`.
    ///
    /// The toggle binds `@AppStorage`, which targets `UserDefaults.standard`,
    /// so the views are the readers: they pass the value into AppState as
    /// `grouped:` rather than AppState re-reading `userDefaults`, which is a
    /// separate suite under `TBD_MOCK` and would disagree with them.
    static let sidebarWorkflowGroupsKey = "sidebarWorkflowGroupsEnabled"

    /// The one shipped default for `sidebarWorkflowGroupsKey`, for the reason
    /// spelled out on `enableTranscriptDefault`. Off: grouping moves rows
    /// users already rely on, so nobody's sidebar rearranges until they ask.
    /// Graduation is a one-line change here, which reaches everyone who never
    /// touched the toggle and preserves every explicit choice.
    static let sidebarWorkflowGroupsDefault = false

    /// UserDefaults key holding the expanded workflow groups, as an array of
    /// `SidebarGroupID.persistenceKey` strings. Prefixed like the other
    /// AppState-owned state keys (`layoutsKey`, `selectionOrderKey`): it is
    /// remembered state, not a Settings preference.
    static let sidebarExpandedGroupsKey = "com.tbd.app.sidebarExpandedGroups"

    static func sidebarWorkflowGroupsEnabled(defaults: UserDefaults = .standard) -> Bool {
        sidebarWorkflowGroupsEnabled(stored: defaults.object(forKey: sidebarWorkflowGroupsKey) as? Bool)
    }

    /// The three-state decision with the shipped default injected, so a test
    /// can prove `nil` follows the default while an explicit choice holds
    /// against either value of it.
    static func sidebarWorkflowGroupsEnabled(
        stored: Bool?,
        shippedDefault: Bool = sidebarWorkflowGroupsDefault
    ) -> Bool {
        stored ?? shippedDefault
    }

    static func restoredSidebarGroups(defaults: UserDefaults) -> Set<SidebarGroupID> {
        let keys = defaults.stringArray(forKey: sidebarExpandedGroupsKey) ?? []
        return Set(keys.compactMap(SidebarGroupID.init(persistenceKey:)))
    }

    /// Writes only when the stored array differs, so restoring at launch —
    /// which goes through the observed setter — never writes, and an absent
    /// key is not created for an empty set.
    func persistExpandedSidebarGroups() {
        let keys = expandedSidebarGroups.map(\.persistenceKey).sorted()
        guard keys != (userDefaults.stringArray(forKey: Self.sidebarExpandedGroupsKey) ?? []) else { return }
        userDefaults.set(keys, forKey: Self.sidebarExpandedGroupsKey)
    }

    /// Drops remembered groups whose repository the daemon no longer reports.
    /// Called only with an authoritative repo list, so a transient empty
    /// state never forgets anything.
    func pruneExpandedSidebarGroups(repoIDs: Set<UUID>) {
        let kept = expandedSidebarGroups.filter {
            guard case .repository(let id) = $0.owner else { return true }
            return repoIDs.contains(id)
        }
        if kept != expandedSidebarGroups { expandedSidebarGroups = kept }
    }

    /// Drops remembered groups whose provider is no longer registered. Called
    /// only after a successful roster fetch, never on a refused or failed one.
    func pruneExpandedSidebarGroups(providerNames: Set<String>) {
        let kept = expandedSidebarGroups.filter {
            guard case .provider(let name) = $0.owner else { return true }
            return providerNames.contains(name)
        }
        if kept != expandedSidebarGroups { expandedSidebarGroups = kept }
    }

    /// A repository's active and creating top-level rows, local and remote
    /// alike, in their stored order: the ungrouped section's inline rows.
    func sidebarTopLevelWorktrees(repoID: UUID) -> [Worktree] {
        Self.topLevelWorktrees(worktrees[repoID] ?? [])
    }

    /// Active and creating parentless rows sorted by `sortOrder`: the one
    /// definition of a section's top level, shared by the row list, the
    /// grouped partition and drag reorder's index snapshot, so a plain index
    /// move always lands on the rows the user sees.
    nonisolated static func topLevelWorktrees(_ rows: [Worktree]) -> [Worktree] {
        rows.filter { ($0.status == .active || $0.status == .creating) && $0.parentWorktreeID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The repository section's rows under the current grouping setting.
    /// `matchedSessions` is the view's memoized
    /// `RepoSectionView.matchedRemoteSessions`, evaluated only when ungrouped.
    func sidebarRepositoryLayout(
        repoID: UUID, grouped: Bool,
        matchedSessions: @autoclosure () -> [RemoteSessionInfo]
    ) -> SidebarSectionLayout {
        .repository(
            grouped: grouped, topLevel: sidebarTopLevelWorktrees(repoID: repoID),
            matchedSessions: matchedSessions(),
            remoteGroups: sidebarRemoteGroups(repoID: repoID),
            hibernation: sidebarHibernation(repoID: repoID))
    }

    /// A provider's unmatched sessions under the current grouping setting.
    func sidebarProviderLayout(provider: String, grouped: Bool) -> SidebarSectionLayout {
        .provider(
            grouped: grouped,
            sessions: RemoteSectionView.sessions(
                in: remoteSessions, forProvider: provider,
                knownRepoIDs: RemoteSectionView.knownRepoIDs(repos: repos, repoFilter: repoFilter)),
            remoteGroups: sidebarRemoteGroups(provider: provider))
    }

    /// The Scratch section's rows under the current grouping setting.
    func sidebarScratchLayout(grouped: Bool) -> SidebarSectionLayout {
        .scratch(grouped: grouped, rows: scratchWorktrees, hibernation: sidebarScratchHibernation)
    }

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
        return SidebarRemoteGroups(
            roots: Self.topLevelWorktrees(rows),
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

    /// A cached presentation partition; tracked inputs are read even on a hit
    /// so wake/park and tree changes remain observable to the mounted sidebar.
    func sidebarHibernation(repoID: UUID) -> SidebarHibernationPartition {
        _ = worktrees
        _ = terminals
        let owner = SidebarGroupID.Owner.repository(repoID)
        if let cached = sidebarHibernationCache[owner] { return cached }
        let roots = Self.topLevelWorktrees(worktrees[repoID] ?? []).filter(\.location.isLocal)
        let partition = SidebarHibernation.partition(roots: roots, terminals: terminals, children: children(of:))
        sidebarHibernationCache[owner] = partition
        return partition
    }

    var sidebarScratchHibernation: SidebarHibernationPartition {
        _ = scratchWorktrees
        _ = worktrees
        _ = terminals
        if let cached = sidebarHibernationCache[.scratch] { return cached }
        let partition = SidebarHibernation.partition(
            roots: scratchWorktrees, terminals: terminals, allowsDescendants: false, children: children(of:))
        sidebarHibernationCache[.scratch] = partition
        return partition
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
            if !sidebarHibernation(repoID: repo.id).hibernatedWorktreeIDs.isDisjoint(with: worktreeIDs) {
                groups.insert(.init(owner: .repository(repo.id), kind: .hibernated))
            }
        }
        for provider in remoteProviders {
            groups.formUnion(sidebarRemoteGroups(provider: provider.config.name).revealGroups(
                owner: .provider(provider.config.name), worktreeIDs: worktreeIDs, remoteID: remoteID))
        }
        if !sidebarScratchHibernation.hibernatedWorktreeIDs.isDisjoint(with: worktreeIDs) {
            groups.insert(.init(owner: .scratch, kind: .hibernated))
        }
        return SidebarGroupReveal(generation: sidebarSelectionGeneration,
                                  worktreeIDs: worktreeIDs, remoteID: remoteID, groups: groups)
    }

    /// Membership changes reveal transient groups without overriding a collapsed
    /// repository. Navigation may expand the owning section; a missing previous
    /// value explicitly requests that behavior for initial mounting and scrolls.
    /// A no-op when `grouped` is false (workflow groups off): there is no
    /// group to open, and the ungrouped sidebar never expanded a section on
    /// selection. `grouped` is the caller's `@AppStorage` read of
    /// `sidebarWorkflowGroupsKey`, so the gate and the rendered sidebar
    /// always agree.
    func revealSidebarGroups(_ reveal: SidebarGroupReveal, previous: SidebarGroupReveal? = nil, grouped: Bool) {
        guard grouped else { return }
        expandedSidebarGroups.formUnion(reveal.groups)
        if let previous,
           previous.generation == reveal.generation,
           previous.worktreeIDs == reveal.worktreeIDs,
           previous.remoteID == reveal.remoteID { return }
        for group in reveal.groups {
            if group.owner == .scratch {
                userDefaults.set(true, forKey: Self.scratchSectionExpandedKey)
            }
            guard case .repository(let id) = group.owner,
                  let index = repos.firstIndex(where: { $0.id == id }), !repos[index].expanded else { continue }
            repos[index].expanded = true
            Task { try? await daemonClient.setRepoExpanded(id: id, expanded: true) }
        }
    }
}
