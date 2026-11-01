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
/// changes.
private let logger = Logger(subsystem: "com.tbd.app", category: "panelSurface")

/// A worktree → tab → surface map, the shape of `AppState.panelSurfaces`.
typealias PanelSurfaceCopy = [UUID: [WorkspaceTabID: WorkspaceTabSurface]]

/// Which renderer draws one workspace tab (panel tabs spec, "The render
/// branch").
enum WorkspaceRenderPath: Equatable {
    /// `SplitLayoutView` over the app-side `LayoutNode` tree, unchanged: a tab
    /// whose layout still splits off a terminal.
    case legacy
    /// `PanelSurfaceWorkspaceView` over the copy's surface for the tab, or
    /// over none yet — nil draws the same layout with an empty side region
    /// until the surface arrives.
    case daemon(WorkspaceTabSurface?)
}

extension AppState {

    // MARK: - Reading the copy

    /// The copy's surface for one workspace tab, or nil when it holds none.
    func panelSurface(worktreeID: UUID, tabID: UUID) -> WorkspaceTabSurface? {
        panelSurfaces[worktreeID]?[tabID]
    }

    /// The renderer for one workspace tab. Legacy only for a tab whose layout
    /// still splits off a terminal: one the last tab sync skipped
    /// (`panelSyncSkippedTabIDs`), or, before any sync names it, one the copy
    /// holds no surface for and whose legacy layout holds a terminal outside
    /// the primary by the converter's own test
    /// (`legacyLayoutSplitsOffTerminal`). The skipped set lives only in
    /// memory, so after a launch that test draws such a tab legacy from its
    /// first frame, rather than flipping it to legacy once the first sync
    /// answers, which would rebuild its primary's terminal view.
    ///
    /// Every other tab takes the daemon path, a tab with a surface always.
    /// The copy fills asynchronously, so a tab with no surface yet takes it
    /// with none — the same view as once its surface arrives, so the
    /// primary's terminal view is never rebuilt.
    func workspaceRenderPath(worktreeID: UUID, tabID: UUID) -> WorkspaceRenderPath {
        guard !panelSyncSkippedTabIDs.contains(tabID) else { return .legacy }
        let surface = panelSurface(worktreeID: worktreeID, tabID: tabID)
        if surface == nil, legacyLayoutSplitsOffTerminal(worktreeID: worktreeID, tabID: tabID) {
            return .legacy
        }
        return .daemon(surface)
    }

    /// Whether the tab's legacy layout (`layouts`) holds a terminal anywhere
    /// but its primary, by the very test the converter skips a tab by
    /// (`LegacyTabConverter.terminalOutsidePrimary`). False for a tab with no
    /// layout, or one this worktree's tab list does not hold.
    private func legacyLayoutSplitsOffTerminal(worktreeID: UUID, tabID: UUID) -> Bool {
        guard let layout = layouts[tabID],
              let tab = tabs[worktreeID]?.first(where: { $0.id == tabID })
        else { return false }
        return LegacyTabConverter.terminalOutsidePrimary(content: tab.content, layout: layout) != nil
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
    /// - **Content:** a listed tab the copy holds, under any worktree, goes
    ///   through the revision guard, so a delta's newer revision is not
    ///   reverted. Revisions are daemon-wide and never decrease, so the guard
    ///   holds across a daemon restart and across a tab deleted and imported
    ///   again. A tab the result adopts leaves every other worktree's entry,
    ///   as it does from a delta: a scratch promote re-parents tabs.
    /// - **Changed in flight:** a tab a delta or an apply reply changed —
    ///   adopted or removed — while the get was in flight keeps what that
    ///   change left. One adopted then is not dropped by the result's
    ///   omission, and one removed then is not put back by its listing. A
    ///   surface the guard refused changed nothing, so it does not count.
    ///
    /// So two loads of one worktree may overlap safely. A get the daemon
    /// answered before it registered a new subscription, or one that failed,
    /// needs nothing of its own: the acknowledgement refetches every worktree
    /// with a tab list (`panelSubscriptionRegistered`).
    ///
    /// The result's `activeTabID` is ignored: workspace-tab selection is the
    /// app's. A failed fetch keeps the copy as it was.
    func loadPanelSurfaces(worktreeID: UUID) async {
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
        var surfaces = panelSurfaces
        Self.merge(
            result, worktreeID: worktreeID, into: &surfaces,
            heldAtIssue: heldAtIssue, touchedInFlight: touchedInFlight)
        commitPanelSurfaces(surfaces)
    }

    /// The load key for a worktree's detail view showing `activeTabID`, read
    /// from the copy as it stands (see `PanelSurfaceLoadKey`).
    func panelSurfaceLoadKey(worktreeID: UUID, activeTabID: UUID?) -> PanelSurfaceLoadKey {
        PanelSurfaceLoadKey(
            worktreeID: worktreeID,
            activeTabAwaitsSurface: activeTabID.map {
                panelSurface(worktreeID: worktreeID, tabID: $0) == nil
                    && !panelSyncSkippedTabIDs.contains($0)
            } ?? false)
    }

    /// The load a shown tab asks for when its key `loads`: any tab sync still
    /// pending goes out first, so a tab that sync imports is in the snapshot
    /// even if its delta reaches no subscription. Nothing when the key does
    /// not load.
    func loadPanelSurfacesForShownTab(_ key: PanelSurfaceLoadKey) async {
        guard key.loads else { return }
        await flushPanelTabSync()
        await loadPanelSurfaces(worktreeID: key.worktreeID)
    }

    /// The merge rules `loadPanelSurfaces` documents, for `worktreeID`'s
    /// result, on the whole copy: an entry left empty is dropped, and a tab
    /// adopted here leaves every other worktree's entry.
    private static func merge(
        _ result: PanelGetResult,
        worktreeID: UUID,
        into surfaces: inout PanelSurfaceCopy,
        heldAtIssue: Set<WorkspaceTabID>,
        touchedInFlight: Set<WorkspaceTabID>
    ) {
        var merged = surfaces[worktreeID] ?? [:]
        let listed = Set(result.tabs.map(\.id))
        for tabID in heldAtIssue where !listed.contains(tabID) && !touchedInFlight.contains(tabID) {
            merged.removeValue(forKey: tabID)
        }
        var adopted: [WorkspaceTabID] = []
        for incoming in result.tabs {
            if let held = heldRevision(of: incoming.id, in: surfaces) {
                guard incoming.revision >= held else {
                    logRefusedRevision(incoming, held: held)
                    continue
                }
            } else if touchedInFlight.contains(incoming.id) {
                // Absent from the copy but touched since the get was issued:
                // a delta removed it in flight, and the listing predates that.
                continue
            }
            merged[incoming.id] = incoming
            adopted.append(incoming.id)
        }
        surfaces[worktreeID] = merged.isEmpty ? nil : merged
        for tabID in adopted {
            evict(tabID, fromAllBut: worktreeID, in: &surfaces)
        }
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
    ///
    /// A removed tab leaves every worktree's entry, not only the delta's: tab
    /// IDs are global, and a copy that missed a re-parent while disconnected
    /// still holds the tab under the worktree it left.
    func applyPanelSurfaceDelta(_ delta: PanelSurfaceDelta) {
        // A removal counts as a change whether or not the copy held the tab:
        // a get in flight may list it from before the removal.
        notePanelTabsTouched(delta.removedTabIDs)
        var surfaces = panelSurfaces
        for tabID in delta.removedTabIDs {
            Self.evict(tabID, fromAllBut: nil, in: &surfaces)
        }
        var adopted: [WorkspaceTabID] = []
        for surface in delta.tabs where Self.adopt(surface, into: &surfaces) {
            adopted.append(surface.id)
        }
        notePanelTabsTouched(adopted)
        commitPanelSurfaces(surfaces)
    }

    /// The revision guard, on a working copy; returns false when it refused
    /// the surface. A tab's ID is global and its revisions daemon-wide, so the
    /// guard compares against the tab under any worktree, and a surface
    /// adopted under one worktree leaves every other worktree's entry:
    /// promoting a scratch worktree re-parents its tabs, and the delta for
    /// that reaches only the destination.
    private static func adopt(_ surface: WorkspaceTabSurface, into surfaces: inout PanelSurfaceCopy) -> Bool {
        if let held = heldRevision(of: surface.id, in: surfaces), surface.revision < held {
            logRefusedRevision(surface, held: held)
            return false
        }
        evict(surface.id, fromAllBut: surface.worktreeID, in: &surfaces)
        surfaces[surface.worktreeID, default: [:]][surface.id] = surface
        return true
    }

    /// The revision the copy holds for a tab, under whichever worktree holds
    /// it, or nil when it holds none.
    private static func heldRevision(of tabID: WorkspaceTabID, in surfaces: PanelSurfaceCopy) -> UInt64? {
        surfaces.values.compactMap { $0[tabID]?.revision }.max()
    }

    /// Removes a tab from every worktree's entry but `worktreeID`'s — from
    /// every entry when `worktreeID` is nil — dropping an entry that leaves
    /// empty.
    private static func evict(
        _ tabID: WorkspaceTabID, fromAllBut worktreeID: UUID?, in surfaces: inout PanelSurfaceCopy
    ) {
        for other in Array(surfaces.keys) where other != worktreeID {
            guard surfaces[other]?[tabID] != nil else { continue }
            surfaces[other]?.removeValue(forKey: tabID)
            if surfaces[other]?.isEmpty == true {
                surfaces.removeValue(forKey: other)
            }
        }
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
    /// A tab with no surface in the copy may be one the daemon has not
    /// imported yet, so any tab sync still pending goes out first
    /// (`flushPanelTabSync`), and the apply after it. A worktree not ready to
    /// sync sends nothing then, and the apply still goes out once.
    ///
    /// Returns the daemon's tab, or nil when the apply failed. A failure is
    /// logged, shown as an error toast, and followed by a refetch of the
    /// worktree, so the copy snaps to the daemon's truth.
    @discardableResult
    func applyPanelOperation(
        worktreeID: UUID, tabID: UUID, _ operation: PanelOperation
    ) async -> WorkspaceTabSurface? {
        if panelSurface(worktreeID: worktreeID, tabID: tabID) == nil {
            await flushPanelTabSync()
        }
        let envelope = PanelOperationEnvelope(
            operationID: UUID(),
            worktreeID: worktreeID,
            tabID: tabID,
            baseRevision: panelSurface(worktreeID: worktreeID, tabID: tabID)?.revision,
            origin: .appUser,
            operation: operation)
        do {
            let result = try await panelApplyTrigger(envelope)
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

    /// Closes one side-region panel from its tab's ×. A note panel closes as
    /// a workspace note tab does (`closeTab`): when the note has content the
    /// user is asked first, and a declined confirmation sends nothing; then
    /// the panel closes, and only once the daemon has applied that close is
    /// the note deleted. Nothing in the app lists notes, so a note closed and
    /// kept would be unreachable. Any other panel just closes.
    ///
    /// The `close` operation itself keeps the note — the daemon action set's
    /// close sends it alone — so an agent's `tbd panel close` does too.
    func closeSidePanel(
        worktreeID: UUID, tabID: UUID, panelID: PanelID, content: PanelContent
    ) async {
        let close = PanelOperation.close(panelID: panelID)
        guard case .note(let noteID) = content else {
            await applyPanelOperation(worktreeID: worktreeID, tabID: tabID, close)
            return
        }
        if let note = notes[worktreeID]?.first(where: { $0.id == noteID }),
           noteHasContent(worktreeID: worktreeID, noteID: noteID),
           !noteCloseConfirmer(note, noteContentPathResolver(worktreeID, noteID)) {
            return
        }
        // A refused close leaves the panel on screen, so its note must stay.
        guard await applyPanelOperation(worktreeID: worktreeID, tabID: tabID, close) != nil else {
            return
        }
        await deleteNote(noteID: noteID, worktreeID: worktreeID)
    }

    // MARK: - Tab sync

    /// The observer on `tabs`. Marks a worktree dirty when its tab IDs, order,
    /// labels or primaries differ from `panelTabSignatures` — every field of
    /// `TBDShared.Tab`, so a plain comparison of the two lists — records the
    /// new list there, and schedules one flush for the next main-actor turn
    /// when a dirty worktree is ready to sync. A worktree whose list went away
    /// is dropped from the signatures, so a list that comes back is new.
    ///
    /// Hung off the property rather than its call sites because tabs are
    /// created, closed, reordered, relabelled and re-pointed from many places
    /// (terminal and note reconciliation, notes, the PR tab, the file viewer,
    /// terminal revival). A worktree's list arriving for the first time —
    /// at connect, or for a new worktree — differs from the absent signature,
    /// so it is marked dirty too.
    func notePanelTabsChanged() {
        var dirty = Set<UUID>()
        for (worktreeID, tabList) in tabs where panelTabSignatures[worktreeID] != tabList {
            dirty.insert(worktreeID)
            panelTabSignatures[worktreeID] = tabList
        }
        // Every key of `tabs` is now a key here, so a larger count means a
        // worktree whose list went away.
        if panelTabSignatures.count > tabs.count {
            panelTabSignatures = panelTabSignatures.filter { tabs[$0.key] != nil }
        }
        markPanelSyncDirty(dirty)
    }

    /// Drops an archived worktree from the copy. Archiving deletes its
    /// surfaces on the daemon (`WorktreeStore.archive`), which broadcasts
    /// their removal; the entry goes here without waiting for that delta. Its
    /// sync state goes too: a pending sync would send the archived tab list,
    /// which the daemon ignores, and a revive marks the worktree ready again
    /// from fresh fetches before its tabs are synced.
    func forgetPanelSurfaces(worktreeID: UUID) {
        if panelSurfaces[worktreeID] != nil {
            panelSurfaces.removeValue(forKey: worktreeID)
        }
        panelSyncDirty.remove(worktreeID)
        panelSyncReadyWorktrees.remove(worktreeID)
        if let tabList = tabs[worktreeID] {
            setPanelSyncSkippedTabIDs(panelSyncSkippedTabIDs.subtracting(tabList.map(\.id)))
        }
    }

    /// The observer on `layouts`, for the one tab whose legacy layout still
    /// matters: one the daemon skipped, because its layout holds a terminal
    /// outside the primary. It has no surface and renders legacy, and closing
    /// that extra terminal edits `layouts`, not `tabs`, so without this
    /// nothing would offer it to the daemon again.
    ///
    /// Marks dirty the worktree of each tab the last sync skipped
    /// (`panelSyncSkippedTabIDs`) whose layout differs from
    /// `panelSkippedTabLayouts`, records the new layout there, and marks no
    /// other. A tab with a surface is the daemon's, and its legacy layout is
    /// no longer read; a tab the copy has merely not loaded would otherwise
    /// send a sync on every ordinary legacy layout write. Does nothing, not
    /// even a comparison, while nothing is skipped.
    func notePanelLayoutsChanged() {
        guard !panelSyncSkippedTabIDs.isEmpty else { return }
        var changedTabIDs = Set<UUID>()
        for tabID in panelSyncSkippedTabIDs where layouts[tabID] != panelSkippedTabLayouts[tabID] {
            changedTabIDs.insert(tabID)
            panelSkippedTabLayouts[tabID] = layouts[tabID]
        }
        guard !changedTabIDs.isEmpty else { return }
        var dirty = Set<UUID>()
        for (worktreeID, tabList) in tabs where tabList.contains(where: { changedTabIDs.contains($0.id) }) {
            dirty.insert(worktreeID)
        }
        markPanelSyncDirty(dirty)
    }

    /// Retakes `panelSkippedTabLayouts` for the skipped set as it now stands.
    func snapshotPanelSkippedTabLayouts() {
        var snapshot: [UUID: LayoutNode] = [:]
        for tabID in panelSyncSkippedTabIDs {
            snapshot[tabID] = layouts[tabID]
        }
        panelSkippedTabLayouts = snapshot
    }

    /// Writes the skipped set only when it differs: it is tracked, and an
    /// in-place mutation notifies every reader even when it changes nothing.
    private func setPanelSyncSkippedTabIDs(_ skippedTabIDs: Set<UUID>) {
        guard skippedTabIDs != panelSyncSkippedTabIDs else { return }
        panelSyncSkippedTabIDs = skippedTabIDs
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
        guard !panelSyncFlushScheduled else { return }
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
        while let worktreeID = panelSyncDirty.first(where: { panelSyncReadyWorktrees.contains($0) }) {
            panelSyncDirty.remove(worktreeID)
            // nil: the worktree's tab list is gone. Nothing is sent — an empty
            // list would delete every surface of a worktree that may only be
            // reloading.
            guard let params = buildPanelSyncParams(worktreeID: worktreeID) else { continue }
            do {
                let result = try await panelSyncTrigger(params)
                // This sync's verdict on the tabs it listed replaces the last.
                setPanelSyncSkippedTabIDs(
                    panelSyncSkippedTabIDs
                        .subtracting(params.tabs.map(\.tabID))
                        .union(result.skippedTabIDs))
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

    // MARK: - Resubscribe

    /// Called from `startSubscription()`, before the new subscription is up.
    /// Readiness is cleared: each worktree's tab list is re-checked against
    /// fresh fetches before it is sent, and every worktree with tabs is
    /// marked dirty so it is sent once it is ready. The copy is kept, so side
    /// regions stay on screen through a reconnect; it is refetched once the
    /// daemon registers the subscription (`panelSubscriptionRegistered`).
    func resetPanelSurfacesForResubscribe() {
        panelSyncReadyWorktrees.removeAll()
        panelSyncDirty.formUnion(tabs.keys)
    }

    /// Called when the daemon acknowledges a subscription `startSubscription()`
    /// opened. The daemon registers the subscriber before it sends the ack,
    /// so a `panel.get` issued from here on cannot miss a change: the change
    /// lands either in the reply or in a later delta.
    ///
    /// Deltas the daemon sent before that — while no subscription was up,
    /// across a daemon restart or a dropped connection — were missed, so
    /// every worktree with a tab list is refetched, whether or not the copy
    /// holds a surface for it. That one rule also recovers a get answered
    /// before the registration, one that failed, and a worktree that loaded
    /// with no surface. Each refetch merges under the usual guard, which a
    /// restart does not disturb (revisions are daemon-wide and never
    /// decrease), and overlaps any other load of the worktree safely.
    func panelSubscriptionRegistered() {
        let worktreeIDs = Array(tabs.keys)
        guard !worktreeIDs.isEmpty else { return }
        syncThenLoadPanelSurfaces(worktreeIDs)
    }

    /// Sends any tab sync still pending, after waiting out one in flight,
    /// then loads each worktree's surfaces in turn — loading after the sync,
    /// so a fetch taken before the sync's imports cannot drop them.
    private func syncThenLoadPanelSurfaces(_ worktreeIDs: [UUID]) {
        Task { @MainActor [weak self] in
            await self?.flushPanelTabSync()
            for worktreeID in worktreeIDs {
                await self?.loadPanelSurfaces(worktreeID: worktreeID)
            }
        }
    }
}
