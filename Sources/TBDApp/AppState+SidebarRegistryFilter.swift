import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "sidebar-registry-filter")

/// A `repo.setRegistryRemoteHidden` this app has applied locally and not yet
/// retired: the latest toggle of one repo.
///
/// It stays in `AppState.pendingRegistryFilterToggles` while its call is in
/// flight, and after the call succeeds until a repo fetch sent after that
/// success has been applied. Until then every fetched list carries its value,
/// so a fetch that read the daemon before the commit cannot flip the button
/// back. A failed call removes it and puts back what the daemon holds.
struct PendingRegistryFilterToggle {
    /// Tells this toggle from a later one of the same repo.
    let token: UInt64
    /// The value the toggle set.
    let hidden: Bool
    /// What a failure puts back, as the app knows the daemon holds it:
    /// whether the repo was in the mirror and its `registryRemoteHidden`
    /// before the first click of the run of toggles this one ends, or the
    /// value of the last of them whose call succeeded.
    var committedMirror: Bool
    var committedValue: Bool?
    /// The number the next repo fetch would get when the call succeeded. A
    /// fetch numbered at or above it was sent after the commit and so reads
    /// it. nil while the call is in flight.
    var fence: UInt64?
    /// The task that sends the call. The next toggle of the repo waits for
    /// it, so the daemon applies a repo's toggles in click order.
    let send: Task<Void, Never>
}

/// Where the one-time copy of the old `UserDefaults` set stands.
enum RegistryFilterLegacyCopy: Equatable {
    /// Not run yet, or the last run had a failure: the next successful repo
    /// refresh runs it.
    case pending
    /// A run is awaiting its calls.
    case running
    /// The key is gone: it was absent, or every call succeeded. It never runs
    /// again in this process.
    case done
}

/// The per-repo "hide registry remote sessions" sidebar filter.
///
/// The setting lives on the daemon's repo row (`Repo.registryRemoteHidden`),
/// which the phone sets too. `sidebarRegistryRemoteHiddenRepoIDs` mirrors the
/// repos whose value is `true`, set from the repo list after each fetch and
/// by a toggle at once.
/// Specs: docs/specs/2026-11-19-sidebar-remote-session-filter-design.md and
/// docs/specs/2026-11-22-phone-remote-session-filter-design.md.
extension AppState {
    /// The `UserDefaults` key that held the filtered repos before the setting
    /// moved to the daemon. Read only by the one-time copy, which removes it.
    static let sidebarRegistryRemoteHiddenRepoIDsKey = "sidebarRegistryRemoteHiddenRepoIDs"

    /// Absent and empty both mean no repo is filtered; unreadable entries are dropped.
    static func restoredSidebarRegistryRemoteHiddenRepoIDs(defaults: UserDefaults) -> Set<UUID> {
        let strings = defaults.stringArray(forKey: sidebarRegistryRemoteHiddenRepoIDsKey) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    func isSidebarRegistryRemoteFilterOn(repoID: UUID) -> Bool {
        sidebarRegistryRemoteHiddenRepoIDs.contains(repoID)
    }

    /// Flips the repo's filter in the mirror and the repo list at once, then
    /// sends `repo.setRegistryRemoteHidden` after any earlier toggle of the
    /// repo has returned. A failed call puts back what the daemon holds; a
    /// refresh that lands meanwhile keeps the new value.
    func toggleSidebarRegistryRemoteFilter(repoID: UUID) {
        let wasOn = sidebarRegistryRemoteHiddenRepoIDs.contains(repoID)
        let hidden = !wasOn
        let index = repos.firstIndex { $0.id == repoID }
        let previousValue = index.flatMap { repos[$0].registryRemoteHidden }
        let earlier = pendingRegistryFilterToggles[repoID]

        if hidden {
            sidebarRegistryRemoteHiddenRepoIDs.insert(repoID)
        } else {
            sidebarRegistryRemoteHiddenRepoIDs.remove(repoID)
        }
        if let index {
            repos[index].registryRemoteHidden = hidden
        }

        let token = nextRegistryFilterToggleToken
        nextRegistryFilterToggleToken += 1
        let earlierSend = earlier?.send
        let send = Task { [weak self] in
            await earlierSend?.value
            guard let self else { return }
            do {
                try await self.registryRemoteHiddenSender(repoID, hidden)
                self.registryFilterToggleSucceeded(repoID: repoID, token: token, hidden: hidden)
            } catch {
                self.registryFilterToggleFailed(repoID: repoID, token: token, error: error)
            }
        }
        // A toggle overtaking one still pending inherits what the daemon is
        // known to hold; otherwise the daemon holds what the app showed.
        pendingRegistryFilterToggles[repoID] = PendingRegistryFilterToggle(
            token: token, hidden: hidden,
            committedMirror: earlier?.committedMirror ?? wasOn,
            committedValue: earlier.map(\.committedValue) ?? previousValue,
            fence: nil, send: send)
    }

    /// The call replied, so the daemon holds `hidden`. For the latest toggle,
    /// a fetch sent from now on reads it, and one sent earlier still gets the
    /// overlay. For an earlier toggle, it is what a failure of the later one
    /// puts back.
    private func registryFilterToggleSucceeded(repoID: UUID, token: UInt64, hidden: Bool) {
        guard var latest = pendingRegistryFilterToggles[repoID] else { return }
        latest.committedMirror = hidden
        latest.committedValue = hidden
        if latest.token == token {
            latest.fence = nextRepoFetchNumber
        }
        pendingRegistryFilterToggles[repoID] = latest
    }

    /// The call threw, so the daemon kept what it had. The latest toggle puts
    /// that back. An earlier toggle, overtaken by a later click, changes
    /// nothing: the later toggle's call is sent next, and what it would put
    /// back is still what the daemon holds.
    private func registryFilterToggleFailed(repoID: UUID, token: UInt64, error: any Error) {
        logger.error(
            "repo.setRegistryRemoteHidden for \(repoID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        handleConnectionError(error)
        guard let latest = pendingRegistryFilterToggles[repoID], latest.token == token else { return }
        pendingRegistryFilterToggles[repoID] = nil
        if latest.committedMirror {
            sidebarRegistryRemoteHiddenRepoIDs.insert(repoID)
        } else {
            sidebarRegistryRemoteHiddenRepoIDs.remove(repoID)
        }
        if let index = repos.firstIndex(where: { $0.id == repoID }) {
            repos[index].registryRemoteHidden = latest.committedValue
        }
    }

    /// `fetched` with every pending toggle's value laid over it. A toggle
    /// whose call succeeded before this fetch was sent is retired first: the
    /// fetch read its commit, and anything the daemon holds now, such as a
    /// later change from the phone, wins.
    func mergingRegistryFilterToggles(into fetched: [Repo], fetchNumber: UInt64) -> [Repo] {
        pendingRegistryFilterToggles = pendingRegistryFilterToggles.filter { _, toggle in
            guard let fence = toggle.fence else { return true }
            return fetchNumber < fence
        }
        guard !pendingRegistryFilterToggles.isEmpty else { return fetched }
        return fetched.map { repo in
            guard let toggle = pendingRegistryFilterToggles[repo.id] else { return repo }
            var kept = repo
            kept.registryRemoteHidden = toggle.hidden
            return kept
        }
    }

    /// Sets the mirror to the repos whose value is `true`.
    func syncSidebarRegistryRemoteHiddenRepoIDs() {
        let on = Set(repos.filter { $0.registryRemoteHidden == true }.map(\.id))
        if on != sidebarRegistryRemoteHiddenRepoIDs {
            sidebarRegistryRemoteHiddenRepoIDs = on
        }
    }

    /// Copies the set the app kept in `UserDefaults` before the setting moved
    /// to the daemon, once, after a successful repo refresh.
    ///
    /// Each listed repo that is in the repo list with no value of its own is
    /// set on (`hidden: true`). A repo with a value keeps it, whoever set it,
    /// and a listed ID with no repo is dropped. The key is removed only when
    /// every call succeeded; after any failure, such as a daemon that does not
    /// know the call, the key stays and the copy runs again at the next
    /// refresh. Setting a value twice is harmless.
    func copyLegacySidebarRegistryFilterIfNeeded() async {
        guard registryFilterLegacyCopy == .pending else { return }
        let key = Self.sidebarRegistryRemoteHiddenRepoIDsKey
        guard userDefaults.object(forKey: key) != nil else {
            registryFilterLegacyCopy = .done
            return
        }
        let saved = Self.restoredSidebarRegistryRemoteHiddenRepoIDs(defaults: userDefaults)
        let unset = repos.filter { saved.contains($0.id) && $0.registryRemoteHidden == nil }.map(\.id)
        registryFilterLegacyCopy = .running
        var failures = 0
        for repoID in unset {
            do {
                try await registryRemoteHiddenSender(repoID, true)
                // A click or a refresh during the call may have given the
                // repo a value since; that value stands.
                if pendingRegistryFilterToggles[repoID] == nil,
                   let index = repos.firstIndex(where: { $0.id == repoID }),
                   repos[index].registryRemoteHidden == nil {
                    repos[index].registryRemoteHidden = true
                }
            } catch {
                failures += 1
                logger.error(
                    "Copying the registry filter of \(repoID, privacy: .public) to the daemon failed: \(error.localizedDescription, privacy: .public)")
                handleConnectionError(error)
            }
        }
        syncSidebarRegistryRemoteHiddenRepoIDs()
        if failures == 0 {
            userDefaults.removeObject(forKey: key)
            registryFilterLegacyCopy = .done
        } else {
            registryFilterLegacyCopy = .pending
        }
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
