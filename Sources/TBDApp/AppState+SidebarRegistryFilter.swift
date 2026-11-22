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
/// back. A failed call removes it, puts back what the daemon holds and tells
/// the person, unless the daemon could not be reached.
struct PendingRegistryFilterToggle {
    /// Tells this toggle from a later one of the same repo.
    let token: UInt64
    /// The value the toggle set.
    let hidden: Bool
    /// What a failure puts back, as the app knows the daemon holds it:
    /// whether the repo was in the mirror and its `registryRemoteHidden`
    /// before the first click of the run of toggles this one ends, or the
    /// value of the last call that succeeded since: one of those toggles', or
    /// the one-time copy's `true`.
    var committedMirror: Bool
    var committedValue: Bool?
    /// The number the next repo fetch would get when the call succeeded. A
    /// fetch numbered at or above it was sent after the commit and so reads
    /// it. nil while the call is in flight.
    var fence: UInt64?
    /// The task that sends the call. The next toggle of the repo waits for
    /// it, so the daemon applies a repo's toggles in click order, and the
    /// one-time copy waits for it before deciding whether to set the repo.
    let send: Task<Void, Never>
}

/// Where the one-time copy of the old `UserDefaults` set stands.
enum RegistryFilterLegacyCopy: Equatable {
    /// Not run yet: the next applied repo refresh starts it.
    case pending
    /// A run is awaiting its calls.
    case running
    /// A run that started when `AppState.stateSubscriptionStarts` was
    /// `subscriptionStarts` had a failure, such as a daemon too old to know
    /// the call. The key stays, and the copy runs again at the first applied
    /// refresh after the next state subscription starts, which may reach a
    /// newer daemon; no refresh before that runs it.
    case failed(subscriptionStarts: UInt64)
    /// The key is gone: it was absent, or every call succeeded. It never runs
    /// again in this process.
    case done
}

/// The per-repo "hide registry remote sessions" sidebar filter.
///
/// The setting lives on the daemon's repo row (`Repo.registryRemoteHidden`),
/// which the phone sets too. `sidebarRegistryRemoteHiddenRepoIDs` mirrors the
/// repos whose value is `true`, set from the repo list after each fetch and
/// by a toggle at once. Until the one-time copy of the old `UserDefaults` set
/// has settled, a repo that set lists and that has no value of its own shows
/// as on too.
/// Specs: docs/specs/2026-11-19-sidebar-remote-session-filter-design.md and
/// docs/specs/2026-11-22-phone-remote-session-filter-design.md.
extension AppState {
    /// The `UserDefaults` key that held the filtered repos before the setting
    /// moved to the daemon. Read once, into `registryFilterLegacySeed`, for
    /// the one-time copy, which removes it.
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
    /// repo, and any call of the one-time copy for it, has returned. A failed
    /// call puts back what the daemon holds; a refresh that lands meanwhile
    /// keeps the new value.
    func toggleSidebarRegistryRemoteFilter(repoID: UUID) {
        let wasOn = sidebarRegistryRemoteHiddenRepoIDs.contains(repoID)
        let hidden = !wasOn
        let index = repos.firstIndex { $0.id == repoID }
        let previousValue = index.flatMap { repos[$0].registryRemoteHidden }
        let earlier = pendingRegistryFilterToggles[repoID]
        // The copy sends nothing for a repo while a toggle of it is pending,
        // so a copy call in flight for the repo began before every pending
        // toggle. Waiting for it as well as for the earlier toggle has the
        // daemon apply the repo's calls in the order they were made.
        let copySend = registryFilterCopySends[repoID]

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
            _ = await copySend?.value
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
    /// that back and tells the person why the button flipped back, unless the
    /// daemon could not be reached, which the app's connection state already
    /// shows. An earlier toggle, overtaken by a later click, changes nothing:
    /// the later toggle's call is sent next, and what it would put back is
    /// still what the daemon holds.
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
        if !Self.isDisconnectError(error) {
            let name = repoName(for: repoID) ?? "this repository"
            let change = latest.hidden ? "turn on" : "turn off"
            showAlert(
                "Couldn't \(change) the remote session filter for \(name): \(error.localizedDescription)",
                isError: true)
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

    /// Sets the mirror to the repos whose value is `true`, and to the repos
    /// the old `UserDefaults` set lists that have no value of their own: the
    /// choice saved before the setting moved shows from the first refresh,
    /// before the one-time copy's calls reach the daemon, and while they fail.
    func syncSidebarRegistryRemoteHiddenRepoIDs() {
        let seed = registryFilterLegacySeed
        let on = Set(repos.filter { $0.registryRemoteHidden ?? seed.contains($0.id) }.map(\.id))
        if on != sidebarRegistryRemoteHiddenRepoIDs {
            sidebarRegistryRemoteHiddenRepoIDs = on
        }
    }

    /// Empties the old set's seed once a fetch sent after the one-time copy
    /// succeeded has been applied: that list reads every value the copy set,
    /// so the seed has nothing left to show, and a listed ID whose repo was
    /// not in the list when the copy ran stays dropped.
    func retireRegistryFilterLegacySeedIfSettled(appliedFetch fetchNumber: UInt64) {
        guard let fence = registryFilterLegacySeedFence, fetchNumber >= fence else { return }
        registryFilterLegacySeedFence = nil
        registryFilterLegacySeed = []
    }

    /// Starts the one-time copy of the set the app kept in `UserDefaults`
    /// before the setting moved to the daemon, after an applied repo refresh,
    /// in a task of its own so that refresh does not wait for its calls.
    ///
    /// It starts when it has not run yet, or when its last run failed and a
    /// state subscription has started since. Without the key it never runs.
    func startLegacyRegistryFilterCopyIfNeeded() {
        switch registryFilterLegacyCopy {
        case .pending:
            break
        case .failed(let starts) where starts != stateSubscriptionStarts:
            break
        case .failed, .running, .done:
            return
        }
        guard userDefaults.object(forKey: Self.sidebarRegistryRemoteHiddenRepoIDsKey) != nil else {
            registryFilterLegacyCopy = .done
            registryFilterLegacySeed = []
            return
        }
        let starts = stateSubscriptionStarts
        registryFilterLegacyCopy = .running
        registryFilterLegacyCopyTask = Task { [weak self] in
            await self?.copyLegacySidebarRegistryFilter(subscriptionStarts: starts)
        }
    }

    /// One run of the copy. Each listed repo that is in the repo list is set
    /// on (`hidden: true`) when, just before its call, it has no value of its
    /// own and no toggle pending. A repo with a toggle in flight waits for
    /// that toggle's call first: when it succeeded, the click's value stands;
    /// when it failed, the repo is copied. A repo with a value keeps it,
    /// whoever set it, and a listed ID with no repo is dropped. A toggle made
    /// while the repo's call is in flight is sent after it returns.
    ///
    /// The key is removed only when every call succeeded. After a failure
    /// the key stays, the failures make one log line, and the copy runs
    /// again once the next state subscription starts. Setting a value twice
    /// is harmless.
    private func copyLegacySidebarRegistryFilter(subscriptionStarts: UInt64) async {
        let saved = registryFilterLegacySeed
        let candidates = repos.map(\.id).filter { saved.contains($0) }
        var attempted = 0
        var failures: [any Error] = []
        for repoID in candidates {
            await awaitRegistryFilterToggleSends(repoID: repoID)
            // Nothing suspends from this check until the call is registered
            // in `registryFilterCopySends`, where a click finds it.
            guard pendingRegistryFilterToggles[repoID] == nil,
                  let index = repos.firstIndex(where: { $0.id == repoID }),
                  repos[index].registryRemoteHidden == nil
            else { continue }
            attempted += 1
            let send = Task<(any Error)?, Never> { [weak self] in
                guard let self else { return nil }
                do {
                    try await self.registryRemoteHiddenSender(repoID, true)
                    self.registryFilterCopySucceeded(repoID: repoID)
                    return nil
                } catch {
                    self.handleConnectionError(error)
                    return error
                }
            }
            registryFilterCopySends[repoID] = send
            if let error = await send.value {
                failures.append(error)
            }
            registryFilterCopySends[repoID] = nil
        }
        syncSidebarRegistryRemoteHiddenRepoIDs()
        if let first = failures.first {
            logger.error(
                "Copying the registry filter to the daemon failed for \(failures.count, privacy: .public) of \(attempted, privacy: .public) repos, first: \(first.localizedDescription, privacy: .public); it runs again when the next state subscription starts")
            registryFilterLegacyCopy = .failed(subscriptionStarts: subscriptionStarts)
        } else {
            userDefaults.removeObject(forKey: Self.sidebarRegistryRemoteHiddenRepoIDsKey)
            registryFilterLegacyCopy = .done
            registryFilterLegacySeedFence = nextRepoFetchNumber
        }
    }

    /// Returns once the latest toggle of the repo has had its call answered,
    /// including a toggle clicked while an earlier one was being waited for.
    private func awaitRegistryFilterToggleSends(repoID: UUID) async {
        var awaited: Task<Void, Never>?
        while let send = pendingRegistryFilterToggles[repoID]?.send, send != awaited {
            await send.value
            awaited = send
        }
    }

    /// The copy's call replied, so the daemon holds `true`. A toggle clicked
    /// during the call keeps its value, with `true` as what its failure puts
    /// back. Otherwise the repo takes `true`, unless a refresh gave it a
    /// value meanwhile.
    private func registryFilterCopySucceeded(repoID: UUID) {
        if var toggle = pendingRegistryFilterToggles[repoID] {
            toggle.committedMirror = true
            toggle.committedValue = true
            pendingRegistryFilterToggles[repoID] = toggle
        } else if let index = repos.firstIndex(where: { $0.id == repoID }),
                  repos[index].registryRemoteHidden == nil {
            repos[index].registryRemoteHidden = true
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
