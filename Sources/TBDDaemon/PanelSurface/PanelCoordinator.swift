import Foundation
import os
import TBDShared

private let panelCoordinatorLog = Logger(subsystem: "com.tbd.daemon", category: "panelCoordinator")

/// Errors `PanelCoordinator.apply` and `syncTabs` can throw (panel tabs spec,
/// "Coordinator and gating").
public enum PanelCoordinatorError: LocalizedError, Equatable, Sendable {
    /// `panel_tabs_enabled` is off — no mutating origin may proceed.
    case surfaceDisabled
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

    public var errorDescription: String? {
        switch self {
        case .surfaceDisabled:
            return "the side panel with tabs is disabled (panel_tabs_enabled is off)"
        case .tabNotFound(let tabID):
            return "no panel surface exists for tab \(tabID.uuidString)"
        case .staleTarget(let underlying):
            return "the operation's target changed under a stale base revision: "
                + (underlying.errorDescription ?? "\(underlying)")
        case .invalidResource(let detail):
            return "the operation referenced a resource that does not exist in this worktree: \(detail)"
        case .operation(let underlying):
            return "the panel operation was rejected: " + (underlying.errorDescription ?? "\(underlying)")
        }
    }
}

/// Daemon actor that owns committed panel-surface state. Serializes every
/// call — one global actor for now (shard per worktree if cross-worktree
/// throughput ever matters; nothing here depends on the single-actor shape).
///
/// `apply` runs gating → idempotency → resource check → reduce → persist →
/// broadcast. `syncTabs` runs gating → legacy conversion → one store
/// transaction → broadcast. Both gate on `panel_tabs_enabled` for every
/// origin; `get` is ungated.
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

    /// Ungated read. `tabID` present narrows to that one tab; absent returns
    /// every tab in the worktree plus the worktree's active tab — the
    /// `worktree.activeTabID` column the app writes through
    /// `worktree.setActiveTab`. A tab-scoped get leaves `activeTabID` nil: it
    /// answers about one tab, and the active tab is a worktree-level fact.
    public func get(worktreeID: UUID, tabID: UUID?) async throws -> PanelGetResult {
        if let tabID {
            guard let surface = try await db.panelSurface.surface(tabID: tabID),
                  surface.worktreeID == worktreeID else {
                return PanelGetResult(tabs: [], activeTabID: nil)
            }
            return PanelGetResult(tabs: [surface], activeTabID: nil)
        }
        let surfaces = try await db.panelSurface.surfaces(worktreeID: worktreeID)
        let activeTabID = try await db.worktrees.getActiveTabID(worktreeID: worktreeID)
        return PanelGetResult(tabs: surfaces, activeTabID: activeTabID)
    }

    public func apply(_ envelope: PanelOperationEnvelope) async throws -> PanelApplyResult {
        // 1. Gating: one flag for every origin. `origin` is diagnostics only.
        try await requireEnabled()

        // 2. Idempotency fast path: a prior committed result replays verbatim
        // — no re-application, no re-persist, no broadcast, and no resource
        // check below. The authoritative check also runs inside
        // `applyReducing`'s transaction to cover a concurrent duplicate; this
        // early read handles the common reconnect/retry replay.
        if let priorResult = try await db.panelSurface.receipt(operationID: envelope.operationID) {
            return PanelApplyResult(tab: priorResult.tab, replayed: true)
        }

        // 3. Resource existence for open/navigate destinations. It reads other
        // tables, so it stays outside the apply transaction; a resource
        // vanishing right after this is a separate, inherent race.
        try await validateResourceExists(in: envelope.operation, worktreeID: envelope.worktreeID)

        // 4. Transactional load → reduce → persist. Loading inside the store's
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

        let outcome = try await db.panelSurface.applyReducing(
            operationID: envelope.operationID, tabID: envelope.tabID,
            worktreeID: envelope.worktreeID, now: now(), reduce: reduce)

        guard let outcome else {
            // No readable surface row for this tab under the claimed worktree.
            throw PanelCoordinatorError.tabNotFound(envelope.tabID)
        }

        switch outcome {
        case .replayed(let prior):
            // A concurrent duplicate committed first; return its result, no broadcast.
            return PanelApplyResult(tab: prior.tab, replayed: true)
        case .applied(let result):
            // 5. Broadcast AFTER commit, never before: a thrown reduce or
            // persist rolls the transaction back and returns before this.
            broadcast(.panelSurfaceChanged(PanelSurfaceDelta(
                worktreeID: envelope.worktreeID,
                tabs: [result.tab],
                removedTabIDs: [],
                activeTabID: nil,
                originOperationID: envelope.operationID)))
            return result
        }
    }

    /// `panel.syncTabs` (panel tabs spec, "Tab sync"): brings the worktree's
    /// surfaces in line with the app's workspace tabs in one store
    /// transaction. Each listed tab is converted from its legacy layout; the
    /// conversion is used only when the tab has no surface yet, so the daemon
    /// stays the authority for what is inside a tab. A tab the converter
    /// skips gets no surface, keeps rendering legacy, and its reason is
    /// returned in `skipped`.
    ///
    /// An empty `tabs` list is legal and deletes every surface of the
    /// worktree; the app syncs a worktree only once its tabs are loaded.
    ///
    /// Broadcasts exactly one `panelSurfaceChanged` when anything was
    /// inserted, updated or deleted, and none otherwise.
    public func syncTabs(_ params: PanelSyncTabsParams) async throws -> PanelSyncTabsResult {
        try await requireEnabled()

        // Never trust the wire: drop any history whose legacy pane ID appears
        // in no listed tab's tree before handing histories to the converter.
        var liveLegacyPaneIDs = Set<UUID>()
        for tab in params.tabs {
            let tree = tab.layout ?? .pane(tab.content)
            liveLegacyPaneIDs.formUnion(tree.allPaneIDs())
        }
        let paneHistories = params.paneHistories.filter { liveLegacyPaneIDs.contains($0.key) }

        var entries: [SyncTabEntry] = []
        var skipped: [String] = []
        for (position, tab) in params.tabs.enumerated() {
            let importCandidate: WorkspaceTabSurface?
            switch LegacyTabConverter.convert(
                worktreeID: params.worktreeID, tab: tab, paneHistories: paneHistories, makeID: makeID) {
            case .converted(let surface):
                importCandidate = surface
            case .skipped(let reason):
                importCandidate = nil
                skipped.append(reason)
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

        let skippedCount = skipped.count
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
        if !outcome.changed.isEmpty || !outcome.removed.isEmpty {
            broadcast(.panelSurfaceChanged(PanelSurfaceDelta(
                worktreeID: params.worktreeID,
                tabs: outcome.changed,
                removedTabIDs: outcome.removed,
                activeTabID: nil,
                originOperationID: nil)))
        }

        return PanelSyncTabsResult(
            importedTabIDs: outcome.imported,
            reparentedTabIDs: outcome.reparented,
            removedTabIDs: outcome.removed,
            skipped: skipped)
    }

    /// The one gate for every mutating call and origin.
    private func requireEnabled() async throws {
        let config = try await db.config.get()
        guard config.panelTabsEnabled else {
            throw PanelCoordinatorError.surfaceDisabled
        }
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
        case .file, .web:
            break
        }
    }
}
