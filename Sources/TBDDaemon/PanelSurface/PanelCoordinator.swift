import Foundation
import TBDShared

/// Errors `PanelCoordinator.apply` can throw. See spec C §7.2/§7.4.
public enum PanelCoordinatorError: Error, Equatable, Sendable {
    /// `daemon_panel_surface_enabled` is off — no mutating origin may proceed.
    case surfaceDisabled
    /// `origin == .agentCLI` while `agent_panel_control_enabled` is off.
    case agentControlDisabled
    /// The envelope's `tabID` has no persisted surface row.
    case tabNotFound(UUID)
    /// `baseRevision` was stale AND the reducer's target vanished/changed
    /// incompatibly (§7.4 semantic rebase) — state is unchanged.
    case staleTarget(PanelOperationError)
    /// §5.5 daemon-half resource check: an `open`/`navigate` destination
    /// referenced a note/transcript that doesn't exist or isn't in this worktree.
    case invalidResource(String)
    /// The reducer rejected the operation against a FRESH base (baseRevision
    /// absent, current, or the error isn't a vanished-target case).
    case operation(PanelOperationError)
}

/// Vanished-target reducer errors — the only `PanelOperationError` cases a
/// stale `baseRevision` can legitimately explain (§7.4: "target was removed
/// or changed incompatibly").
private func isVanishedTarget(_ error: PanelOperationError) -> Bool {
    switch error {
    case .panelNotFound, .splitNotFound, .anchorNotFound:
        return true
    case .invalidRatios, .invalidPlacement, .historyUnavailable, .notTabScoped:
        return false
    }
}

/// Daemon actor that owns committed panel-surface state. Serializes every
/// `apply` call — one global actor for now (ponytail: global lock across all
/// worktrees; shard per-worktree if cross-worktree apply throughput ever
/// matters, nothing here depends on the single-actor shape). Runs the
/// gating → idempotency → resource-check → reduce → persist → broadcast
/// pipeline in spec C §7.2/§7.4.
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

    /// Ungated read (§10.2: `panel.get` is ungated). `tabID` present narrows
    /// to that one tab; absent returns every tab in the worktree.
    public func get(worktreeID: UUID, tabID: UUID?) async throws -> PanelGetResult {
        if let tabID {
            guard let state = try await db.panelSurface.state(tabID: tabID),
                  state.surface.worktreeID == worktreeID else {
                return PanelGetResult(tabs: [], activeTabID: nil)
            }
            return PanelGetResult(tabs: [state.surface], activeTabID: nil)
        }
        let surfaces = try await db.panelSurface.surfaces(worktreeID: worktreeID)
        return PanelGetResult(tabs: surfaces, activeTabID: nil)
    }

    public func apply(_ envelope: PanelOperationEnvelope) async throws -> PanelApplyResult {
        // 1. Gating (§10.2).
        let config = try await db.config.get()
        guard config.panelSurfaceEnabled else {
            throw PanelCoordinatorError.surfaceDisabled
        }
        if envelope.origin == .agentCLI, !config.agentPanelControlEnabled {
            throw PanelCoordinatorError.agentControlDisabled
        }

        // 2. Idempotency fast-path (§7.4): a prior committed result replays
        // verbatim — no re-application, no re-persist, no broadcast, and it
        // must NOT re-run resource validation below. The authoritative
        // idempotency check also lives inside `applyReducing`'s transaction to
        // cover a concurrent duplicate; this early read handles the common
        // reconnect/retry replay and preserves the spec's replay-before-
        // resource-check ordering.
        if let priorResult = try await db.panelSurface.receipt(operationID: envelope.operationID) {
            return PanelApplyResult(tab: priorResult.tab, replayed: true)
        }

        // 3. `.selectTab` is Task 9 — short-circuit until then.
        if case .selectTab = envelope.operation {
            throw PanelCoordinatorError.operation(.notTabScoped)
        }

        // 4. §5.5 resource-existence check for open/navigate destinations.
        // (Reads other tables, so it stays outside the apply transaction; a
        // resource vanishing right after this is a separate, inherent race,
        // not the surface-state lost-update the transaction closes.)
        try await validateResourceExists(in: envelope.operation, worktreeID: envelope.worktreeID)

        // 5. Placement rewrite (`.automatic` recency resolution) is Task 9 —
        // pass the operation through unchanged until then.

        // 6. Transactional load → reduce → persist. Doing the load inside the
        // store's write transaction is what makes this safe under concurrent
        // same-tab applies on a production DatabasePool: actor isolation does
        // not span `await`, and a separate pre-write pool read would observe a
        // stale revision and silently clobber a concurrent commit. The reduce
        // closure is the pure shared reducer plus baseRevision→staleTarget
        // mapping (evaluated against the state loaded INSIDE the transaction —
        // i.e. "the current authoritative tree", §7.4).
        let operation = envelope.operation
        let baseRevision = envelope.baseRevision
        let makeID = self.makeID
        let reduce: @Sendable (PanelSurfaceState) throws -> PanelSurfaceState = { current in
            do {
                return try PanelSurfaceReducer.apply(operation, to: current, makeID: makeID)
            } catch let error as PanelOperationError {
                let baseIsStale = baseRevision.map { $0 != current.surface.revision } ?? false
                if baseIsStale, isVanishedTarget(error) {
                    throw PanelCoordinatorError.staleTarget(error)
                }
                throw PanelCoordinatorError.operation(error)
            }
        }

        let outcome = try await db.panelSurface.applyReducing(
            operationID: envelope.operationID, tabID: envelope.tabID,
            worktreeID: envelope.worktreeID, now: now(), reduce: reduce)

        guard let outcome else {
            // No surface row for this tab under the claimed worktree.
            throw PanelCoordinatorError.tabNotFound(envelope.tabID)
        }

        switch outcome {
        case .replayed(let prior):
            // A concurrent duplicate committed first; return its result, no broadcast.
            return PanelApplyResult(tab: prior.tab, replayed: true)
        case .applied(let result):
            // 7. Broadcast AFTER commit — never before (a rolled-back op must
            // not reach subscribers; a thrown reduce/persist rolls the whole
            // transaction back and returns before reaching here).
            broadcast(.panelSurfaceChanged(PanelSurfaceDelta(
                worktreeID: envelope.worktreeID,
                tabs: [result.tab],
                removedTabIDs: [],
                activeTabID: nil,
                originOperationID: envelope.operationID)))
            return result
        }
    }

    /// §5.5: referenced notes and transcripts must belong to this worktree.
    /// Only `open`/`navigate` carry a `PanelContent` destination that can
    /// reference one; every other operation is a no-op here.
    private func validateResourceExists(in operation: PanelOperation, worktreeID: UUID) async throws {
        let content: PanelContent?
        switch operation {
        case .open(let destination, _): content = destination
        case .navigate(_, let destination): content = destination
        case .close, .move, .resize, .history, .selectTab: content = nil
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
