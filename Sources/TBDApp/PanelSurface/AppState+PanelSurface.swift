import Foundation
import TBDShared
import os

/// The app's copy of the daemon-owned panel surfaces, the single chokepoint
/// every app gesture goes through, and the workspace-tab sync
/// (`docs/specs/2026-10-30-panel-tabs-design.md`, "The app's copy of the
/// surface" and "Tab sync").
///
/// The daemon owns what is inside a workspace tab; the app owns which tabs
/// exist, their order and selection. This file keeps `AppState.panelSurfaces`
/// (declared in `AppState.swift`, because extensions cannot hold stored
/// properties) current from `panel.get` and `panelSurfaceChanged` deltas, and
/// sends the app's tab list to the daemon with `panel.syncTabs` whenever it
/// changes. Everything here is inert while the daemon reports
/// `panel_tabs_enabled` off.
private let logger = Logger(subsystem: "com.tbd.app", category: "panelSurface")

/// A worktree → tab → surface map, the shape of `AppState.panelSurfaces`.
typealias PanelSurfaceCopy = [UUID: [WorkspaceTabID: WorkspaceTabSurface]]

/// Which renderer draws one workspace tab (panel tabs spec, "The render
/// branch").
enum WorkspaceRenderPath: Equatable {
    /// `SplitLayoutView` over the app-side `LayoutNode` tree, unchanged.
    case legacy
    /// `PanelSurfaceWorkspaceView` over this surface from the app's copy.
    case daemon(WorkspaceTabSurface)
}

extension AppState {

    // MARK: - The switch

    /// Whether the daemon reports `panel_tabs_enabled` on. False until
    /// capabilities have been fetched.
    var panelTabsActive: Bool {
        daemonCapabilities?.panelTabsEnabled == true
    }

    /// The copy's surface for one workspace tab, or nil when it holds none.
    func panelSurface(worktreeID: UUID, tabID: UUID) -> WorkspaceTabSurface? {
        panelSurfaces[worktreeID]?[tabID]
    }

    /// The renderer for one workspace tab. The daemon path needs both the flag
    /// and a surface in the copy: the copy fills asynchronously, so a tab with
    /// nothing loaded yet renders legacy rather than blank.
    func workspaceRenderPath(worktreeID: UUID, tabID: UUID) -> WorkspaceRenderPath {
        guard panelTabsActive,
              let surface = panelSurface(worktreeID: worktreeID, tabID: tabID)
        else { return .legacy }
        return .daemon(surface)
    }

    // MARK: - Loading

    /// Fetches every surface of one worktree (`panel.get` without a tab) and
    /// merges it into the copy as it stands when the reply lands.
    ///
    /// The reply is a snapshot from somewhere inside the await, and deltas keep
    /// arriving meanwhile, so it is merged rather than assigned:
    ///
    /// - **Removal:** a tab the copy held when the get was issued, and the
    ///   result omits, is dropped whatever its revision.
    /// - **Content:** a listed tab the copy holds goes through the revision
    ///   guard, so a delta's newer revision is not reverted. Revisions are
    ///   daemon-wide and never decrease, so the guard holds across a daemon
    ///   restart and across a tab deleted and imported again.
    /// - **Changed in flight:** a tab a delta or an apply reply changed —
    ///   adopted or removed — while the get was in flight keeps what that
    ///   change left. One adopted then is not dropped by the result's
    ///   omission, and one removed then is not put back by its listing. A
    ///   surface the guard refused changed nothing, so it does not count.
    ///
    /// The result's `activeTabID` is ignored: workspace-tab selection is the
    /// app's. A failed fetch keeps the copy as it was, and a reply that
    /// crossed the flag turning off is discarded.
    func loadPanelSurfaces(worktreeID: UUID) async {
        guard panelTabsActive else { return }
        let heldAtIssue = Set((panelSurfaces[worktreeID] ?? [:]).keys)
        let issuedAt = panelTouchSequence
        panelLoadsInFlight += 1
        let fetched: PanelGetResult?
        do {
            fetched = try await panelGetFetcher(worktreeID)
        } catch {
            logger.error("""
                panel.get failed for worktree \(worktreeID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            fetched = nil
        }
        let touchedInFlight = panelTabsTouched(since: issuedAt)
        endPanelLoad()
        guard let result = fetched else { return }
        // Turning the flag off cleared the copy; a reply issued before it
        // must not refill it.
        guard panelTabsActive else {
            logger.debug("discarded a panel.get reply that crossed the flag turning off")
            return
        }
        var surfaces = panelSurfaces
        surfaces[worktreeID] = Self.merge(
            result, into: panelSurfaces[worktreeID] ?? [:],
            heldAtIssue: heldAtIssue, touchedInFlight: touchedInFlight)
        commitPanelSurfaces(surfaces)
    }

    /// The load key for a worktree's detail view showing `activeTabID`, read
    /// from the copy as it stands (see `PanelSurfaceLoadKey`).
    func panelSurfaceLoadKey(worktreeID: UUID, activeTabID: UUID?) -> PanelSurfaceLoadKey {
        PanelSurfaceLoadKey(
            worktreeID: worktreeID,
            active: panelTabsActive,
            activeTabLacksSurface: activeTabID.map {
                panelSurface(worktreeID: worktreeID, tabID: $0) == nil
            } ?? false)
    }

    /// The load a shown tab asks for when its key `loads`: any tab sync still
    /// pending goes out first, as before the flag's own load, so a tab that
    /// sync imports is in the snapshot even if its delta reaches no
    /// subscription. Nothing when the key does not load.
    func loadPanelSurfacesForShownTab(_ key: PanelSurfaceLoadKey) async {
        guard key.loads else { return }
        await flushPanelTabSync()
        await loadPanelSurfaces(worktreeID: key.worktreeID)
    }

    /// The merge rules `loadPanelSurfaces` documents, on one worktree's entry.
    /// Returns nil for an entry left empty.
    private static func merge(
        _ result: PanelGetResult,
        into current: [WorkspaceTabID: WorkspaceTabSurface],
        heldAtIssue: Set<WorkspaceTabID>,
        touchedInFlight: Set<WorkspaceTabID>
    ) -> [WorkspaceTabID: WorkspaceTabSurface]? {
        var merged = current
        let listed = Set(result.tabs.map(\.id))
        for tabID in heldAtIssue where !listed.contains(tabID) && !touchedInFlight.contains(tabID) {
            merged.removeValue(forKey: tabID)
        }
        for incoming in result.tabs {
            if let mine = current[incoming.id] {
                guard incoming.revision >= mine.revision else {
                    logRefusedRevision(incoming, held: mine.revision)
                    continue
                }
                merged[incoming.id] = incoming
            } else if !touchedInFlight.contains(incoming.id) {
                // Absent from the copy and untouched since the get was
                // issued: new to the copy. Absent but touched means a delta
                // removed it, or moved it to another worktree, in flight.
                merged[incoming.id] = incoming
            }
        }
        return merged.isEmpty ? nil : merged
    }

    /// Records that a delta or an apply reply changed these tabs — adopted or
    /// removed them — for any load in flight to see. Free when no load is in
    /// flight.
    private func notePanelTabsTouched(_ tabIDs: [WorkspaceTabID]) {
        guard panelLoadsInFlight > 0, !tabIDs.isEmpty else { return }
        panelTouchSequence += 1
        for tabID in tabIDs {
            panelTabsTouchedInFlight[tabID] = panelTouchSequence
        }
    }

    /// The tabs touched after `sequence`, the issue point of one load.
    private func panelTabsTouched(since sequence: UInt64) -> Set<WorkspaceTabID> {
        Set(panelTabsTouchedInFlight.compactMap { $0.value > sequence ? $0.key : nil })
    }

    /// Ends one load's window; the touch log empties when the last one ends.
    private func endPanelLoad() {
        panelLoadsInFlight -= 1
        if panelLoadsInFlight == 0 {
            panelTabsTouchedInFlight.removeAll()
        }
    }

    // MARK: - Adopting

    /// Adopts one tab's surface under the revision guard: a surface older than
    /// the one held is refused. An equal revision is the same content (the
    /// apply reply and the delta that follows it), so it changes nothing.
    func adoptPanelTab(_ surface: WorkspaceTabSurface) {
        var surfaces = panelSurfaces
        if Self.adopt(surface, into: &surfaces) {
            notePanelTabsTouched([surface.id])
        }
        commitPanelSurfaces(surfaces)
    }

    /// Reconciles a broadcast `panelSurfaceChanged` into the copy: removes
    /// `removedTabIDs` whatever revision the copy holds, then adopts `tabs`
    /// under the revision guard. `activeTabID` is ignored — it only reports
    /// back the selection the app itself recorded.
    func applyPanelSurfaceDelta(_ delta: PanelSurfaceDelta) {
        guard panelTabsActive else { return }
        // A removal counts as a change whether or not the copy held the tab:
        // a get in flight may list it from before the removal.
        notePanelTabsTouched(delta.removedTabIDs)
        var surfaces = panelSurfaces
        if var worktreeSurfaces = surfaces[delta.worktreeID] {
            for tabID in delta.removedTabIDs {
                worktreeSurfaces.removeValue(forKey: tabID)
            }
            surfaces[delta.worktreeID] = worktreeSurfaces.isEmpty ? nil : worktreeSurfaces
        }
        var adopted: [WorkspaceTabID] = []
        for surface in delta.tabs where Self.adopt(surface, into: &surfaces) {
            adopted.append(surface.id)
        }
        notePanelTabsTouched(adopted)
        commitPanelSurfaces(surfaces)
    }

    /// The revision guard, on a working copy; returns false when it refused
    /// the surface. A tab's ID is global, so a surface adopted under one
    /// worktree leaves every other worktree's entry: promoting a scratch
    /// worktree re-parents its tabs, and the delta for that reaches only the
    /// destination.
    private static func adopt(_ surface: WorkspaceTabSurface, into surfaces: inout PanelSurfaceCopy) -> Bool {
        if let held = surfaces[surface.worktreeID]?[surface.id], surface.revision < held.revision {
            logRefusedRevision(surface, held: held.revision)
            return false
        }
        for worktreeID in Array(surfaces.keys) where worktreeID != surface.worktreeID {
            guard surfaces[worktreeID]?[surface.id] != nil else { continue }
            surfaces[worktreeID]?.removeValue(forKey: surface.id)
            if surfaces[worktreeID]?.isEmpty == true {
                surfaces.removeValue(forKey: worktreeID)
            }
        }
        surfaces[surface.worktreeID, default: [:]][surface.id] = surface
        return true
    }

    /// Writes the copy only when it differs: every reader of the tracked
    /// dictionary is notified on any write, equal or not.
    private func commitPanelSurfaces(_ surfaces: PanelSurfaceCopy) {
        guard surfaces != panelSurfaces else { return }
        panelSurfaces = surfaces
    }

    private static func logRefusedRevision(_ surface: WorkspaceTabSurface, held: UInt64) {
        logger.debug("""
            refused panel surface for tab \(surface.id, privacy: .public): \
            revision \(surface.revision, privacy: .public) < held \(held, privacy: .public)
            """)
    }

    // MARK: - The apply chokepoint

    /// The one path from an app gesture to the daemon-owned surface: sends one
    /// `panel.apply` (a fresh operation ID, origin `.appUser`, the copy's
    /// revision as `baseRevision`) and adopts the tab the daemon returns.
    ///
    /// Returns the daemon's tab, or nil when the flag is off, the apply failed,
    /// or the reply crossed the flag turning off (it is then not adopted). A failure is logged, shown as an error toast, and
    /// followed by a refetch of the worktree, so the copy snaps to the
    /// daemon's truth.
    @discardableResult
    func applyPanelOperation(
        worktreeID: UUID, tabID: UUID, _ operation: PanelOperation
    ) async -> WorkspaceTabSurface? {
        guard panelTabsActive else { return nil }
        let envelope = PanelOperationEnvelope(
            operationID: UUID(),
            worktreeID: worktreeID,
            tabID: tabID,
            baseRevision: panelSurface(worktreeID: worktreeID, tabID: tabID)?.revision,
            origin: .appUser,
            operation: operation)
        do {
            let result = try await panelApplyTrigger(envelope)
            // Same reason as in `loadPanelSurfaces`: the flag going off
            // cleared the copy.
            guard panelTabsActive else {
                logger.debug("discarded a panel.apply reply that crossed the flag turning off")
                return nil
            }
            adoptPanelTab(result.tab)
            return result.tab
        } catch {
            logger.error("""
                panel.apply failed for worktree \(worktreeID, privacy: .public) \
                tab \(tabID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            showErrorToast(error.localizedDescription)
            await loadPanelSurfaces(worktreeID: worktreeID)
            return nil
        }
    }

    /// `applyPanelOperation` for a gesture handler, which cannot await: the
    /// operation goes out on a main-actor task, and the reply is adopted
    /// there.
    func sendPanelOperation(worktreeID: UUID, tabID: UUID, _ operation: PanelOperation) {
        Task { @MainActor [weak self] in
            _ = await self?.applyPanelOperation(worktreeID: worktreeID, tabID: tabID, operation)
        }
    }

    // MARK: - Tab sync

    /// The observer on `tabs`. Marks a worktree dirty when its tab IDs, order,
    /// labels or primaries changed — every field of `TBDShared.Tab`, so a plain
    /// comparison of the two lists — and schedules one flush for the next
    /// main-actor turn when a dirty worktree is ready to sync.
    ///
    /// Hung off the property rather than its call sites because tabs are
    /// created, closed, reordered, relabelled and re-pointed from many places
    /// (terminal and note reconciliation, notes, the PR tab, the file viewer,
    /// terminal revival). Free while the flag is off.
    ///
    /// A worktree that leaves `tabs` also leaves the copy.
    func notePanelTabsChanged(old: [UUID: [TBDShared.Tab]], new: [UUID: [TBDShared.Tab]]) {
        guard panelTabsActive else { return }
        var dirty = Set<UUID>()
        for (worktreeID, tabList) in new where old[worktreeID] != tabList {
            dirty.insert(worktreeID)
        }
        for worktreeID in old.keys where new[worktreeID] == nil {
            dirty.insert(worktreeID)
            forgetPanelSurfaces(worktreeID: worktreeID)
        }
        markPanelSyncDirty(dirty)
    }

    /// Drops one worktree from the copy: it left `tabs`, or it was archived.
    /// Archiving deletes its surfaces on the daemon (`WorktreeStore.archive`)
    /// without a delta, so an entry kept here would never be corrected.
    func forgetPanelSurfaces(worktreeID: UUID) {
        if panelSurfaces[worktreeID] != nil {
            panelSurfaces.removeValue(forKey: worktreeID)
        }
    }

    /// The observer on `layouts`, for the one tab whose legacy layout still
    /// matters while the flag is on: one the daemon skipped, because its
    /// layout holds a terminal outside the primary. It has no surface and
    /// renders legacy, and closing that extra terminal edits `layouts`, not
    /// `tabs`, so without this nothing would offer it to the daemon again.
    ///
    /// Marks dirty the worktree of each changed tab that has no surface in
    /// the copy. A tab with a surface is never marked: the daemon owns what
    /// is inside it, and its legacy layout is no longer read. Free while the
    /// flag is off.
    func notePanelLayoutsChanged(old: [UUID: LayoutNode], new: [UUID: LayoutNode]) {
        guard panelTabsActive else { return }
        let changedTabIDs = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        guard !changedTabIDs.isEmpty else { return }
        var dirty = Set<UUID>()
        for (worktreeID, tabList) in tabs {
            let resyncs = tabList.contains { tab in
                changedTabIDs.contains(tab.id) && panelSurface(worktreeID: worktreeID, tabID: tab.id) == nil
            }
            if resyncs { dirty.insert(worktreeID) }
        }
        markPanelSyncDirty(dirty)
    }

    /// Marks worktrees dirty, and schedules one flush when any dirty worktree
    /// is ready to sync.
    private func markPanelSyncDirty(_ worktreeIDs: Set<UUID>) {
        guard !worktreeIDs.isEmpty else { return }
        panelSyncDirty.formUnion(worktreeIDs)
        guard !panelSyncDirty.isDisjoint(with: panelSyncReadyWorktrees) else { return }
        schedulePanelTabSyncFlush()
    }

    /// Records that both of these worktrees' tab sources have been reconciled
    /// against a fetch (see `panelSyncReadyWorktrees`), and flushes any that
    /// were waiting dirty.
    func markPanelSyncReady(worktreeIDs: Set<UUID>) {
        let newlyReady = worktreeIDs.subtracting(panelSyncReadyWorktrees)
        guard !newlyReady.isEmpty else { return }
        panelSyncReadyWorktrees.formUnion(newlyReady)
        guard !panelSyncDirty.isDisjoint(with: newlyReady) else { return }
        schedulePanelTabSyncFlush()
    }

    /// Schedules one flush on the next main-actor turn, so every tab change
    /// made in this turn — several worktrees, several edits each — goes out
    /// as one sync per worktree.
    func schedulePanelTabSyncFlush() {
        guard panelTabsActive, !panelSyncFlushScheduled else { return }
        panelSyncFlushScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            await self?.flushPanelTabSync()
        }
    }

    /// Sends one `panel.syncTabs` per dirty, ready worktree, built from the
    /// tabs as they are when it goes out. A dirty worktree that is not ready
    /// stays dirty until it is.
    ///
    /// One flush runs at a time, so a change made while a sync is in flight
    /// is sent after it, never beside it: two syncs racing for one worktree
    /// could land out of order and leave the daemon holding the older tab
    /// list. A call made while a flush is sending waits for it, then runs its
    /// own pass, so when it returns every change made before the call has
    /// gone out — what a caller that loads surfaces next relies on. A failure
    /// is logged and not retried; the next change, or the next subscription,
    /// sends the worktree again.
    func flushPanelTabSync() async {
        // The flush clears its own handle as its last step, so once a waiter
        // resumes the handle names a newer flush or none.
        while let sending = panelSyncFlushTask {
            await sending.value
        }
        let flush = Task { @MainActor [weak self] in
            await self?.sendDirtyPanelTabSyncs()
            self?.panelSyncFlushTask = nil
        }
        panelSyncFlushTask = flush
        await flush.value
    }

    /// The body of one flush: keeps going until nothing ready is dirty.
    private func sendDirtyPanelTabSyncs() async {
        defer { panelSyncFlushScheduled = false }
        while panelTabsActive,
              let worktreeID = panelSyncDirty.first(where: { panelSyncReadyWorktrees.contains($0) }) {
            panelSyncDirty.remove(worktreeID)
            // nil: the worktree's tab list is gone. Nothing is sent — an empty
            // list would delete every surface of a worktree that may only be
            // reloading.
            guard let params = buildPanelSyncParams(worktreeID: worktreeID) else { continue }
            do {
                let result = try await panelSyncTrigger(params)
                if !result.skipped.isEmpty {
                    logger.debug("""
                        panel.syncTabs skipped \(result.skipped.count, privacy: .public) \
                        tab(s) of worktree \(worktreeID, privacy: .public): \
                        \(result.skipped.joined(separator: "; "), privacy: .public)
                        """)
                }
            } catch {
                logger.error("""
                    panel.syncTabs failed for worktree \(worktreeID, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    // MARK: - Capability transitions and resubscribe

    /// Keeps the copy and the sync in step with the daemon's flag after a
    /// capabilities fetch. Off clears the copy and forgets pending syncs, so
    /// a daemon-rendered tab falls back to legacy at once and nothing further
    /// is sent. Off to on marks every worktree with tabs dirty, syncs the
    /// ready ones, then loads every worktree's surfaces — loading after the
    /// sync, so a fetch taken before the sync's imports cannot drop them. A
    /// flush still sending from before the flag went off is waited out
    /// first, by `flushPanelTabSync` itself.
    func panelTabsCapabilityChanged(wasEnabled: Bool) {
        guard panelTabsActive else {
            if !panelSurfaces.isEmpty {
                panelSurfaces = [:]
            }
            panelSyncDirty.removeAll()
            return
        }
        guard !wasEnabled else { return }
        let worktreeIDs = Array(tabs.keys)
        guard !worktreeIDs.isEmpty else { return }
        panelSyncDirty.formUnion(worktreeIDs)
        Task { @MainActor [weak self] in
            await self?.flushPanelTabSync()
            for worktreeID in worktreeIDs {
                await self?.loadPanelSurfaces(worktreeID: worktreeID)
            }
        }
    }

    /// Called from `startSubscription()`. Deltas the daemon sent while no
    /// subscription was up — across a daemon restart or a dropped
    /// connection — were missed, so each worktree the copy holds is refetched
    /// and merged under the usual guard, which a restart does not disturb:
    /// revisions are daemon-wide and never decrease. The copy is kept
    /// meanwhile, so daemon-rendered tabs keep rendering rather than falling
    /// back to legacy and rebuilding their terminal views. A worktree the copy
    /// does not hold is not fetched here — at launch that is every worktree,
    /// and the flag turning on and showing a worktree load them, once.
    ///
    /// Readiness is cleared too: each worktree's tab list is re-checked
    /// against fresh fetches before it is sent, and every worktree with tabs
    /// is marked dirty so it is sent once it is ready.
    func resetPanelSurfacesForResubscribe() {
        panelSyncReadyWorktrees.removeAll()
        guard panelTabsActive else { return }
        panelSyncDirty.formUnion(tabs.keys)
        let heldWorktreeIDs = Array(panelSurfaces.keys)
        guard !heldWorktreeIDs.isEmpty else { return }
        Task { @MainActor [weak self] in
            for worktreeID in heldWorktreeIDs {
                await self?.loadPanelSurfaces(worktreeID: worktreeID)
            }
        }
    }
}
