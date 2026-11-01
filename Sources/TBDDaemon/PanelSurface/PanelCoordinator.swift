import Foundation
import os
import TBDShared

private let panelCoordinatorLog = Logger(subsystem: "com.tbd.daemon", category: "panelCoordinator")

/// Errors `PanelCoordinator.apply` and `syncTabs` can throw (panel tabs spec,
/// "Coordinator").
public enum PanelCoordinatorError: LocalizedError, Equatable, Sendable {
    /// The envelope's `tabID` has no readable surface under its worktree.
    case tabNotFound(UUID)
    /// `baseRevision` was stale AND the reducer's target panel is gone — the
    /// caller acted on a picture that no longer holds. State is unchanged.
    case staleTarget(PanelOperationError)
    /// An `open`/`navigate` destination referenced a note or transcript that
    /// doesn't exist or isn't in this worktree.
    case invalidResource(String)
    /// The reducer rejected the operation against current state.
    case operation(PanelOperationError)
    /// The envelope's `operationID` already has a receipt for another tab.
    /// Reusing an operation ID is a caller bug: a replay would answer with
    /// the other tab's result, and applying anew would overwrite its receipt,
    /// so nothing is applied.
    case operationIDReused(UUID)

    public var errorDescription: String? {
        switch self {
        case .tabNotFound(let tabID):
            return "no panel surface exists for tab \(tabID.uuidString)"
        case .staleTarget(let underlying):
            return "the operation's target changed under a stale base revision: "
                + (underlying.errorDescription ?? "\(underlying)")
        case .invalidResource(let detail):
            return "the operation referenced a resource that does not exist in this worktree: \(detail)"
        case .operation(let underlying):
            return "the panel operation was rejected: " + (underlying.errorDescription ?? "\(underlying)")
        case .operationIDReused(let operationID):
            return "operation ID \(operationID.uuidString) was already applied to another panel tab; "
                + "each operation needs a fresh ID"
        }
    }
}

/// Daemon actor that owns committed panel-surface state. Serializes every
/// call — one global actor for now (shard per worktree if cross-worktree
/// throughput ever matters; nothing here depends on the single-actor shape).
///
/// `apply` runs idempotency → resource check → reduce → persist → broadcast.
/// `syncTabs` runs legacy conversion → one store transaction → broadcast. No
/// setting gates either; `get` is a read.
public actor PanelCoordinator {
    private let db: TBDDatabase
    private let broadcast: @Sendable (StateDelta) -> Void
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        db: TBDDatabase,
        broadcast: @escaping @Sendable (StateDelta) -> Void,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.db = db
        self.broadcast = broadcast
        self.now = now
        self.makeID = makeID
    }

    /// Read. `tabID` present narrows to that one tab, and to none
    /// when the tab has no surface under this worktree; absent returns every
    /// tab in the worktree. Either way the result names the worktree's active
    /// tab — the `worktree.activeTabID` column the app writes through
    /// `worktree.setActiveTab`, one row to read — so a tab-scoped reply still
    /// says whether its tab is the one the user is looking at, and carries
    /// the worktree's panels, so a reader finds them even when no tab has a
    /// surface. The tabs and the panels come from one store read
    /// (`PanelSurfaceStore.panelSnapshot`), so they always agree.
    public func get(worktreeID: UUID, tabID: UUID?) async throws -> PanelGetResult {
        let activeTabID = try await db.worktrees.getActiveTabID(worktreeID: worktreeID)
        let snapshot = try await db.panelSurface.panelSnapshot(worktreeID: worktreeID, tabID: tabID)
        return PanelGetResult(
            tabs: snapshot.tabs, activeTabID: activeTabID, worktreePanels: snapshot.worktreePanels)
    }

    public func apply(_ envelope: PanelOperationEnvelope) async throws -> PanelApplyResult {
        // 1. Idempotency fast path: a prior committed result for this tab
        // replays verbatim — no re-application, no re-persist, no broadcast,
        // and no resource check below — and a receipt for another tab refuses
        // the reused ID. The authoritative check also runs inside
        // `applyReducing`'s transaction to cover a concurrent duplicate; this
        // early read handles the common reconnect/retry replay.
        if let prior = try await db.panelSurface.replayOutcome(
            operationID: envelope.operationID, tabID: envelope.tabID) {
            return try reply(to: prior, for: envelope)
        }

        // 2. Resource existence for open/navigate destinations, a cheap check
        // outside the apply transaction. A note can still be deleted right
        // after it, so `applyReducing` checks a note panel the operation adds
        // again inside its transaction, and that refusal maps to the same
        // `invalidResource`. A terminal vanishing after this is a separate,
        // inherent race.
        try await validateResourceExists(in: envelope.operation, worktreeID: envelope.worktreeID)

        // 3. Transactional load → reduce → persist. Loading inside the store's
        // write transaction is what makes concurrent same-tab applies safe on
        // a production DatabasePool: actor isolation does not span `await`,
        // and a separate pre-write read would observe a stale revision.
        //
        // `baseRevision` is diagnostic: the operation applies against current
        // state whatever the base. A stale base only relabels a failing
        // operation whose target panel is gone, because the caller then acted
        // on a picture that no longer holds.
        let operation = envelope.operation
        let baseRevision = envelope.baseRevision
        let makeID = self.makeID
        let reduce: @Sendable (WorkspaceTabSurface) throws -> WorkspaceTabSurface = { current in
            do {
                return try PanelSurfaceReducer.apply(operation, to: current, makeID: makeID)
            } catch let error as PanelOperationError {
                let baseIsStale = baseRevision.map { $0 != current.revision } ?? false
                if baseIsStale, case .panelNotFound = error {
                    throw PanelCoordinatorError.staleTarget(error)
                }
                throw PanelCoordinatorError.operation(error)
            }
        }

        let outcome: PanelSurfaceStore.ApplyOutcome?
        do {
            outcome = try await db.panelSurface.applyReducing(
                operationID: envelope.operationID, tabID: envelope.tabID,
                worktreeID: envelope.worktreeID, now: now(), reduce: reduce)
        } catch PanelSurfaceStoreError.noteNotInWorktree(let noteID, _) {
            throw PanelCoordinatorError.invalidResource("note \(noteID) not in worktree")
        }

        guard let outcome else {
            // No readable surface row for this tab under the claimed worktree.
            throw PanelCoordinatorError.tabNotFound(envelope.tabID)
        }
        return try reply(to: outcome, for: envelope)
    }

    /// `apply`'s reply to a store outcome. A replay — from the fast path, or
    /// a concurrent duplicate that committed first — returns the stored
    /// result without broadcasting; a reused operation ID is refused; and a
    /// fresh commit is broadcast (step 5), AFTER the commit, never before: a
    /// thrown reduce or persist rolls the transaction back and never gets
    /// here. The one delta carries the operated tab, then every other tab
    /// the commit rewrote because the worktree's panel list changed.
    private func reply(
        to outcome: PanelSurfaceStore.ApplyOutcome, for envelope: PanelOperationEnvelope
    ) throws -> PanelApplyResult {
        switch outcome {
        case .replayed(let prior):
            return PanelApplyResult(tab: prior.tab, replayed: true)
        case .operationIDReused:
            throw PanelCoordinatorError.operationIDReused(envelope.operationID)
        case .applied(let result, let siblings):
            broadcast(.panelSurfaceChanged(PanelSurfaceDelta(
                worktreeID: envelope.worktreeID,
                tabs: [result.tab] + siblings,
                removedTabIDs: [],
                activeTabID: nil,
                originOperationID: envelope.operationID)))
            return result
        }
    }

    /// `panel.syncTabs` (panel tabs spec, "Tab sync"): brings the worktree's
    /// surfaces in line with the app's workspace tabs in one store
    /// transaction. Each listed tab is converted from its legacy layout; the
    /// conversion is used only when the tab has no readable surface, so the
    /// daemon stays the authority for what is inside a tab: a readable
    /// surface is never overwritten, and an unreadable one is replaced. A tab
    /// the converter skips and that has no readable surface gets none, keeps
    /// rendering legacy, and is returned in `skippedTabIDs` with its reason in
    /// `skipped`. A tab with a readable surface keeps it and is never
    /// reported skipped.
    ///
    /// An empty `tabs` list is legal and deletes every surface of the
    /// worktree; the app syncs a worktree only once its tabs are loaded.
    ///
    /// Broadcasts exactly one `panelSurfaceChanged` when anything was
    /// inserted, updated or deleted, and none otherwise.
    public func syncTabs(_ params: PanelSyncTabsParams) async throws -> PanelSyncTabsResult {
        // Never trust the wire: drop any history whose legacy pane ID appears
        // in no listed tab's tree before handing histories to the converter.
        var liveLegacyPaneIDs = Set<UUID>()
        for tab in params.tabs {
            let tree = tab.layout ?? .pane(tab.content)
            liveLegacyPaneIDs.formUnion(tree.allPaneIDs())
        }
        let paneHistories = params.paneHistories.filter { liveLegacyPaneIDs.contains($0.key) }

        var entries: [SyncTabEntry] = []
        var skipReasons: [UUID: String] = [:]
        for (position, tab) in params.tabs.enumerated() {
            let importCandidate: WorkspaceTabSurface?
            switch LegacyTabConverter.convert(
                worktreeID: params.worktreeID, tab: tab, paneHistories: paneHistories, makeID: makeID) {
            case .converted(let surface):
                importCandidate = surface
            case .skipped(let reason):
                importCandidate = nil
                if skipReasons[tab.tabID] == nil {
                    skipReasons[tab.tabID] = reason
                }
            }
            entries.append(SyncTabEntry(
                tabID: tab.tabID, position: position, label: tab.label,
                primary: LegacyTabConverter.primaryContent(from: tab.content),
                importCandidate: importCandidate))
        }

        let outcome: SyncOutcome
        do {
            outcome = try await db.panelSurface.syncTabs(
                worktreeID: params.worktreeID, entries: entries, now: now())
        } catch {
            // One refused write rolls back the whole sync, so the worktree's
            // surfaces stay as they were; say which worktree is stuck.
            panelCoordinatorLog.error("""
                panel.syncTabs worktree=\(params.worktreeID, privacy: .public) \
                tabs=\(params.tabs.count, privacy: .public) failed: \(error, privacy: .public)
                """)
            throw error
        }

        // Only a tab the sync left without a readable surface is skipped: one
        // that already had a readable surface keeps it, whatever its legacy
        // layout holds.
        let skippedTabIDs = outcome.skipped
        let skipped = skippedTabIDs.compactMap { skipReasons[$0] }
        let skippedCount = skippedTabIDs.count
        panelCoordinatorLog.info("""
            panel.syncTabs worktree=\(params.worktreeID, privacy: .public) \
            tabs=\(params.tabs.count, privacy: .public) \
            imported=\(outcome.imported.count, privacy: .public) \
            reparented=\(outcome.reparented.count, privacy: .public) \
            removed=\(outcome.removed.count, privacy: .public) \
            changed=\(outcome.changed.count, privacy: .public) \
            skipped=\(skippedCount, privacy: .public)
            """)

        // Broadcast AFTER commit, once, and only when something changed.
        broadcastPanelSurfaceChanged(
            worktreeID: params.worktreeID, tabs: outcome.changed, removedTabIDs: outcome.removed,
            via: broadcast)

        return PanelSyncTabsResult(
            importedTabIDs: outcome.imported,
            reparentedTabIDs: outcome.reparented,
            removedTabIDs: outcome.removed,
            skippedTabIDs: skippedTabIDs,
            skipped: skipped)
    }

    /// Referenced notes and transcripts must belong to this worktree. Only
    /// `open`/`navigate` carry a `PanelContent` destination that can
    /// reference one; every other operation is a no-op here.
    private func validateResourceExists(in operation: PanelOperation, worktreeID: UUID) async throws {
        let content: PanelContent?
        switch operation {
        case .open(let destination, _): content = destination
        case .navigate(_, let destination): content = destination
        case .history, .select, .close, .setCollapsed, .resize: content = nil
        }
        guard let content else { return }
        switch content {
        case .transcript(let terminalID):
            guard let terminal = try await db.terminals.get(id: terminalID),
                  terminal.worktreeID == worktreeID else {
                throw PanelCoordinatorError.invalidResource("terminal \(terminalID) not in worktree")
            }
        case .note(let noteID):
            guard let note = try await db.notes.get(id: noteID),
                  note.worktreeID == worktreeID else {
                throw PanelCoordinatorError.invalidResource("note \(noteID) not in worktree")
            }
        case .file, .web, .changes:
            break
        }
    }
}

extension StateSubscriptionManager {
    /// Tells the app that an archive deleted these workspace tabs' panel
    /// surfaces (`WorktreeStore.archive` returns their IDs), as one
    /// `panelSurfaceChanged` naming them in `removedTabIDs`. Every site that
    /// archives a worktree sends it after the archive commits, beside its
    /// `.worktreeArchived`; nothing is sent when no surface was deleted.
    func broadcastPanelSurfacesRemoved(worktreeID: UUID, tabIDs: [UUID]) {
        broadcastPanelSurfaceChanged(
            worktreeID: worktreeID, tabs: [], removedTabIDs: tabIDs,
            via: { broadcast(delta: $0) })
    }

    /// Tells the app that a write outside a panel operation stored these
    /// surfaces under `worktreeID`, as one `panelSurfaceChanged` carrying
    /// them; the app adopts each under `worktreeID`. Sent after the write
    /// commits, and nothing is sent when no surface changed. The writes:
    ///
    /// - **A scratch promote** moved these surfaces to `worktreeID`, the new
    ///   repo's main worktree, with their tabs, and rewrote the main
    ///   worktree's own surfaces that the merged worktree panels changed
    ///   (`WorktreeStore.promoteScratchMigration` returns both). Adopting a
    ///   moved surface under `worktreeID` drops it from the scratch
    ///   worktree's entry.
    /// - **A change to `worktreeID`'s panel list** rewrote these surfaces:
    ///   `note.delete` removing the note's panel (`NoteStore.delete`).
    func broadcastPanelSurfacesChanged(worktreeID: UUID, surfaces: [WorkspaceTabSurface]) {
        broadcastPanelSurfaceChanged(
            worktreeID: worktreeID, tabs: surfaces, removedTabIDs: [],
            via: { broadcast(delta: $0) })
    }
}

/// Sends one `panelSurfaceChanged` for `worktreeID` through `broadcast`,
/// carrying `tabs` and naming `removedTabIDs`, with no `activeTabID` and no
/// originating operation: every panel broadcast but an apply's, which names
/// its operation. Sends nothing when both lists are empty.
private func broadcastPanelSurfaceChanged(
    worktreeID: UUID, tabs: [WorkspaceTabSurface], removedTabIDs: [UUID],
    via broadcast: (StateDelta) -> Void
) {
    guard !tabs.isEmpty || !removedTabIDs.isEmpty else { return }
    broadcast(.panelSurfaceChanged(PanelSurfaceDelta(
        worktreeID: worktreeID, tabs: tabs, removedTabIDs: removedTabIDs,
        activeTabID: nil, originOperationID: nil)))
}
