import Foundation
import TBDShared
import os

/// Phase 3b (`docs/specs/2026-07-31-panel-3b-app-rendering-design.md`) — the
/// app-side mirror of the daemon-owned panel surface, plus the single
/// chokepoint every app gesture goes through.
///
/// The daemon owns the surface. This file holds a read cache of it
/// (`AppState.panelSurfaces`, declared in `AppState.swift` because Swift
/// forbids stored properties in extensions), keeps it current from
/// `.panelSurfaceChanged` deltas, and turns gestures into `panel.apply`
/// round-trips. There is no local reducer: `panel.apply` is a local
/// unix-socket hop that returns the authoritative tab synchronously, so the
/// app renders from the response and the broadcast delta that follows lands
/// as a no-op at the same revision.
///
/// Everything here is inert with `enableDaemonManagedPanels` off — the daemon
/// broadcasts panel deltas during the store-only soak (its own
/// `daemon_panel_surface_enabled` flag), and nothing on that path may touch
/// app state.
private let logger = Logger(subsystem: "com.tbd.app", category: "panelSurface")

extension AppState {

    // MARK: - The switch

    /// The user half of the render switch — `enableDaemonManagedPanels` read
    /// from this instance's defaults domain. Gates every mirror mutation
    /// below. Deliberately NOT `daemonManagedPanelsActive`: the mirror is a
    /// plain cache, and dropping delta updates because a capabilities refresh
    /// transiently failed would leave it silently stale.
    var daemonManagedPanelsFlagEnabled: Bool {
        Self.daemonManagedPanelsEnabled(defaults: userDefaults)
    }

    /// The effective switch, and the one thing the render site reads: the app
    /// may render from the daemon surface only when the user enabled it AND
    /// the daemon reports the store is on. A surface that was never imported
    /// cannot be rendered, so with `panelSurfaceEnabled` false the workspace
    /// stays on the legacy path.
    var daemonManagedPanelsActive: Bool {
        daemonManagedPanelsFlagEnabled && daemonCapabilities?.panelSurfaceEnabled == true
    }

    // MARK: - Loading

    /// Populate (or refresh) the mirror for one worktree from `panel.get`.
    /// Also the snap-to-truth path after a rejected apply. Failures are
    /// logged and swallowed — the mirror keeps its last known value, and the
    /// next delta or load repairs it.
    ///
    /// The result is merged per tab rather than assigned wholesale, because
    /// `panel.get` is an `await`: a delta can commit a newer revision of one
    /// tab while this fetch is in flight, and assigning the snapshot over it
    /// would revert the mirror one operation with no delta left to correct it
    /// (the daemon emits deltas only on change). See `mergePanelSurface`.
    func loadPanelSurface(worktreeID: UUID) async {
        guard daemonManagedPanelsFlagEnabled else { return }
        do {
            mergePanelSurface(try await panelGetFetcher(worktreeID), worktreeID: worktreeID)
        } catch {
            logger.error("""
                panel.get failed for \(worktreeID, privacy: .public): \
                \(error, privacy: .public)
                """)
        }
    }

    // MARK: - The apply chokepoint

    /// The single path from an app gesture to daemon-owned state. Sends the
    /// mirror's current `revision` for the target tab as `baseRevision`; a
    /// stale value means an agent applied to the same tab in between, the
    /// daemon rejects, and the catch below refetches so the UI snaps to
    /// daemon truth and the user retries (last-writer-wins, spec §Conflicts).
    ///
    /// Never throws: a gesture that cannot commit is a logged diagnostic plus
    /// a resync, not an error the view layer has to handle.
    func applyPanelOperation(
        worktreeID: UUID, tabID: WorkspaceTabID, operation: PanelOperation
    ) async {
        guard daemonManagedPanelsFlagEnabled else { return }
        let envelope = PanelOperationEnvelope(
            operationID: UUID(),
            worktreeID: worktreeID,
            tabID: tabID,
            baseRevision: panelSurfaceTab(worktreeID: worktreeID, tabID: tabID)?.revision,
            origin: .appUser,
            operation: operation)
        do {
            let result = try await panelApplyTrigger(envelope)
            upsertPanelSurfaceTabs([result.tab], worktreeID: worktreeID)
        } catch {
            logger.error("""
                panel.apply rejected for worktree=\(worktreeID, privacy: .public) \
                tab=\(tabID, privacy: .public): \(error, privacy: .public) — refetching
                """)
            await loadPanelSurface(worktreeID: worktreeID)
        }
    }

    // MARK: - Delta reconciliation

    /// Reconcile a broadcast `.panelSurfaceChanged` into the mirror: upsert
    /// the affected tabs, drop the removed ones, adopt a newly selected tab.
    ///
    /// A nil `activeTabID` means "unchanged", not "cleared" — the daemon
    /// sends nil on every ordinary surface mutation and only fills it for
    /// `selectTab` and the legacy import
    /// (`PanelCoordinator.apply` / `RPCRouter+PanelHandlers`).
    func applyPanelSurfaceDelta(_ delta: PanelSurfaceDelta) {
        guard daemonManagedPanelsFlagEnabled else { return }
        let existing = panelSurfaces[delta.worktreeID]
        // Removal is unconditional and comes first: a tab the daemon dropped
        // is gone whatever revision the mirror holds for it.
        var tabs = (existing?.tabs ?? []).filter { !delta.removedTabIDs.contains($0.id) }
        for tab in delta.tabs {
            merge(tab, into: &tabs)
        }
        var activeTabID = delta.activeTabID ?? existing?.activeTabID
        if let active = activeTabID, delta.removedTabIDs.contains(active) {
            activeTabID = nil
        }
        panelSurfaces[delta.worktreeID] = PanelGetResult(tabs: tabs, activeTabID: activeTabID)
    }

    // MARK: - Mirror reads and writes

    /// The mirrored surface for one tab, or nil when the mirror has no entry
    /// for that worktree/tab yet.
    func panelSurfaceTab(worktreeID: UUID, tabID: WorkspaceTabID) -> WorkspaceTabSurface? {
        panelSurfaces[worktreeID]?.tabs.first { $0.id == tabID }
    }

    /// Replace-or-append the given tabs in one worktree's mirror entry,
    /// leaving `activeTabID` and every other tab untouched.
    private func upsertPanelSurfaceTabs(
        _ updated: [WorkspaceTabSurface], worktreeID: UUID
    ) {
        let existing = panelSurfaces[worktreeID]
        var tabs = existing?.tabs ?? []
        for tab in updated {
            merge(tab, into: &tabs)
        }
        panelSurfaces[worktreeID] = PanelGetResult(
            tabs: tabs, activeTabID: existing?.activeTabID)
    }

    /// Adopt a whole `panel.get` snapshot, per tab.
    ///
    /// Two rules, and they cover different tabs:
    ///
    /// - **Which tabs exist** comes from the fetch, unconditionally. A tab the
    ///   mirror holds and the snapshot does not is removed — otherwise a
    ///   refetch could never drop anything and the merge would be append-only.
    /// - **What each surviving tab contains** goes through the revision guard,
    ///   so a snapshot that was taken before an in-flight delta cannot revert
    ///   that tab. Only tabs present in both are affected.
    ///
    /// `activeTabID` follows the snapshot: it is consistent with the tab set
    /// the snapshot just defined.
    private func mergePanelSurface(_ fetched: PanelGetResult, worktreeID: UUID) {
        let mirrored = panelSurfaces[worktreeID]?.tabs ?? []
        let tabs = fetched.tabs.map { fetchedTab -> WorkspaceTabSurface in
            guard let mirroredTab = mirrored.first(where: { $0.id == fetchedTab.id }),
                  mirroredTab.revision > fetchedTab.revision
            else { return fetchedTab }
            logDroppedStaleTab(fetchedTab, mirroredRevision: mirroredTab.revision)
            return mirroredTab
        }
        panelSurfaces[worktreeID] = PanelGetResult(
            tabs: tabs, activeTabID: fetched.activeTabID)
    }

    /// Replace-or-append one incoming tab, dropping it when the mirror already
    /// holds a strictly newer revision of that tab.
    ///
    /// The mirror is fed by two racing writers — the `panel.apply` response
    /// and the broadcast delta — and a `panel.get` refetch can resolve after
    /// either. Revisions are the daemon's monotonic per-tab counter, so
    /// "strictly lower wins nothing" is the whole rule. Equal revisions still
    /// assign: same revision means same content, so it is a no-op either way,
    /// and taking the newer object keeps the common apply-then-delta path on
    /// one code path.
    private func merge(_ incoming: WorkspaceTabSurface, into tabs: inout [WorkspaceTabSurface]) {
        guard let index = tabs.firstIndex(where: { $0.id == incoming.id }) else {
            tabs.append(incoming)
            return
        }
        guard incoming.revision >= tabs[index].revision else {
            logDroppedStaleTab(incoming, mirroredRevision: tabs[index].revision)
            return
        }
        tabs[index] = incoming
    }

    private func logDroppedStaleTab(_ tab: WorkspaceTabSurface, mirroredRevision: UInt64) {
        logger.debug("""
            dropped stale panel surface for tab \(tab.id, privacy: .public): \
            incoming revision \(tab.revision, privacy: .public) < \
            mirrored \(mirroredRevision, privacy: .public)
            """)
    }
}
