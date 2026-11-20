import Foundation

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

    /// The selection is a filter input only while some repo is filtered.
    func invalidateSidebarRegistryFilterForSelection() {
        guard !sidebarRegistryRemoteHiddenRepoIDs.isEmpty else { return }
        sidebarRegistryFilterCache.removeAll()
        sidebarParentRemoteGroupsCache.removeAll()
    }
}
