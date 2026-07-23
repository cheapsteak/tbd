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

/// Encodes/decodes `PanelApplyResult` for the `panel_operation_receipt.result`
/// column. Deliberately separate from `PanelSurfaceStore`'s private
/// file-scoped JSON helpers — this is the coordinator's own encode of its own
/// wire type, not a store-internal concern.
private func encodeReceiptResult(_ result: PanelApplyResult) throws -> String {
    let data = try JSONEncoder().encode(result)
    guard let string = String(bytes: data, encoding: .utf8) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "PanelApplyResult JSON is not valid UTF-8"))
    }
    return string
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

        // 2. Idempotency: a prior commit for this operationID replays verbatim
        // — no re-application, no re-persist, no broadcast.
        if let priorResult = try await db.panelSurface.receipt(operationID: envelope.operationID) {
            return PanelApplyResult(tab: priorResult.tab, replayed: true)
        }

        // 3. `.selectTab` is Task 9 — short-circuit until then.
        if case .selectTab = envelope.operation {
            throw PanelCoordinatorError.operation(.notTabScoped)
        }

        // 4. Load current state.
        guard let state = try await db.panelSurface.state(tabID: envelope.tabID) else {
            throw PanelCoordinatorError.tabNotFound(envelope.tabID)
        }

        // 5. §5.5 resource-existence check for open/navigate destinations.
        try await validateResourceExists(in: envelope.operation, worktreeID: envelope.worktreeID)

        // 6. Placement rewrite (`.automatic` recency resolution) is Task 9 —
        // pass the operation through unchanged until then.

        // 7. Reduce.
        let newState: PanelSurfaceState
        do {
            newState = try PanelSurfaceReducer.apply(envelope.operation, to: state, makeID: makeID)
        } catch let error as PanelOperationError {
            let baseIsStale = envelope.baseRevision.map { $0 != state.surface.revision } ?? false
            if baseIsStale, isVanishedTarget(error) {
                throw PanelCoordinatorError.staleTarget(error)
            }
            throw PanelCoordinatorError.operation(error)
        }

        // 8. Persist atomically (surface + histories + receipt in one transaction).
        let result = PanelApplyResult(tab: newState.surface, replayed: false)
        let receipt = PanelOperationReceiptRecord(
            operationID: envelope.operationID.uuidString,
            worktreeID: envelope.worktreeID.uuidString,
            tabID: envelope.tabID.uuidString,
            revision: Int64(newState.surface.revision),
            result: try encodeReceiptResult(result),
            appliedAt: now())
        try await db.panelSurface.commit(state: newState, position: nil, receipt: receipt, now: now())

        // 9. Broadcast AFTER commit — never before (a rolled-back op must not
        // reach subscribers).
        broadcast(.panelSurfaceChanged(PanelSurfaceDelta(
            worktreeID: envelope.worktreeID,
            tabs: [newState.surface],
            removedTabIDs: [],
            activeTabID: nil,
            originOperationID: envelope.operationID)))

        // 10. Return.
        return result
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
