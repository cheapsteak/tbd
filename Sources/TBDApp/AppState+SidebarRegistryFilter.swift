import Foundation
import TBDShared

/// Storage for the per-repo "hide registry remote sessions" sidebar filter.
/// Spec: docs/specs/2026-11-19-sidebar-remote-session-filter-design.md.
extension AppState {
    static let sidebarRegistryRemoteHiddenRepoIDsKey = "sidebarRegistryRemoteHiddenRepoIDs"

    /// Absent and empty both mean no repo is filtered; unreadable entries are dropped.
    static func restoredSidebarRegistryRemoteHiddenRepoIDs(defaults: UserDefaults) -> Set<UUID> {
        let strings = defaults.stringArray(forKey: sidebarRegistryRemoteHiddenRepoIDsKey) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    /// Writes the sorted uuidStrings only when they differ from what is stored,
    /// so restoring at launch never writes (same shape as `persistExpandedSidebarGroups`).
    func persistSidebarRegistryRemoteHiddenRepoIDs() {
        let strings = sidebarRegistryRemoteHiddenRepoIDs.map(\.uuidString).sorted()
        let key = Self.sidebarRegistryRemoteHiddenRepoIDsKey
        guard strings != (userDefaults.stringArray(forKey: key) ?? []) else { return }
        userDefaults.set(strings, forKey: key)
    }

    func isSidebarRegistryRemoteFilterOn(repoID: UUID) -> Bool {
        sidebarRegistryRemoteHiddenRepoIDs.contains(repoID)
    }

    func toggleSidebarRegistryRemoteFilter(repoID: UUID) {
        if sidebarRegistryRemoteHiddenRepoIDs.contains(repoID) {
            sidebarRegistryRemoteHiddenRepoIDs.remove(repoID)
        } else {
            sidebarRegistryRemoteHiddenRepoIDs.insert(repoID)
        }
    }

    /// Called only with an authoritative repo list.
    func pruneSidebarRegistryRemoteHiddenRepoIDs(repoIDs: Set<UUID>) {
        let kept = sidebarRegistryRemoteHiddenRepoIDs.intersection(repoIDs)
        if kept != sidebarRegistryRemoteHiddenRepoIDs { sidebarRegistryRemoteHiddenRepoIDs = kept }
    }

    /// The selection is an input only to what a filtered repo's section
    /// shows: that repo's filter (`sidebarRegistryRemoteFilter(repoID:)`)
    /// and the remote partition of each parent in its section
    /// (`sidebarRemoteGroups(parentID:)`). Every other entry survives a
    /// selection change.
    ///
    /// A parent's section is the repo of its top-level ancestor, read from
    /// the cached snapshot as `sidebarRemoteGroups(parentID:)` reads it.
    /// Every change that drops the snapshot drops the parent partitions too,
    /// so a cached partition was computed over the cached snapshot; without
    /// one, every partition is cleared.
    func invalidateSidebarRegistryFilterForSelection() {
        let filtered = sidebarRegistryRemoteHiddenRepoIDs
        guard !filtered.isEmpty else { return }
        for repoID in filtered { sidebarRegistryFilterCache[repoID] = nil }
        guard let snapshot = sidebarRemoteSnapshotCache else {
            sidebarParentRemoteGroupsCache.removeAll()
            return
        }
        sidebarParentRemoteGroupsCache = sidebarParentRemoteGroupsCache.filter { entry in
            guard let repoID = snapshot.ancestorPath(to: entry.key)?.first?.repoID else { return true }
            return !filtered.contains(repoID)
        }
    }
}
