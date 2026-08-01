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
    func loadPanelSurface(worktreeID: UUID) async {
        guard daemonManagedPanelsFlagEnabled else { return }
        do {
            panelSurfaces[worktreeID] = try await panelGetFetcher(worktreeID)
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
        var tabs = (existing?.tabs ?? []).filter { !delta.removedTabIDs.contains($0.id) }
        for tab in delta.tabs {
            if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                tabs[index] = tab
            } else {
                tabs.append(tab)
            }
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
            if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                tabs[index] = tab
            } else {
                tabs.append(tab)
            }
        }
        panelSurfaces[worktreeID] = PanelGetResult(
            tabs: tabs, activeTabID: existing?.activeTabID)
    }
}
