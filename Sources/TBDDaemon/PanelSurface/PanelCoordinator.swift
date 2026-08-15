import Foundation
import TBDShared

/// Errors `PanelCoordinator.apply` can throw. See spec C §7.2/§7.4.
public enum PanelCoordinatorError: LocalizedError, Equatable, Sendable {
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

    public var errorDescription: String? {
        switch self {
        case .surfaceDisabled:
            return "the panel surface is disabled (daemon_panel_surface_enabled is off)"
        case .agentControlDisabled:
            return "agent panel control is disabled (agent_panel_control_enabled is off)"
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

/// §6.1 rule 1 / Phase 1 decision record #3: rewrites `open(_, .automatic)`
/// to `.replace(panelID:)`, targeting the most-recently-navigated viewer
/// panel. `move`'s `.automatic` is deliberately left alone — the reducer
/// itself rejects that combination with `.invalidPlacement`, and rewriting
/// it here would silently paper over what should surface as a caller error.
///
/// `state` and `recency` MUST come from the same read — see
/// `PanelSurfaceStore.applyReducing`, which derives both from one
/// transaction-scoped fetch of `panel_history` so this rewrite can never
/// disagree with the tree the reducer is about to apply it to.
///
/// Ties, and "no recency at all" (empty `recency` — panels seeded but never
/// separately navigated), both fall back to the first panel in pre-order —
/// the exact rule `PanelSurfaceReducer`'s own `.automatic` case uses for its
/// no-rewrite default — so a present-vs-missing recency row never changes
/// the outcome. Zero panels returns the operation untouched; the reducer's
/// `.automatic` then splits right of the primary anchor.
private func rewritingAutomaticPlacement(
    _ operation: PanelOperation, in state: PanelSurfaceState, recency: [PanelID: Date]
) -> PanelOperation {
    guard case .open(let content, .automatic) = operation else { return operation }
    let panelIDs = state.surface.layout.allPanelIDs
    guard var winner = panelIDs.first else { return operation }
    var winnerRecency = recency[winner]
    for candidate in panelIDs.dropFirst() {
        guard let candidateRecency = recency[candidate] else { continue }
        if winnerRecency == nil || candidateRecency > winnerRecency! {
            winner = candidate
            winnerRecency = candidateRecency
        }
    }
    return .open(content: content, placement: .replace(panelID: winner))
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
    /// to that one tab; absent returns every tab in the worktree plus the
    /// worktree's active tab (the same `worktree.activeTabID` column that
    /// `selectTab`/`importLegacy` write — no separate active-tab authority).
    /// A tab-scoped get leaves `activeTabID` nil: it answers about one tab, and
    /// active-tab is a worktree-level concept, not part of a single-tab query.
    public func get(worktreeID: UUID, tabID: UUID?) async throws -> PanelGetResult {
        if let tabID {
            guard let state = try await db.panelSurface.state(tabID: tabID),
                  state.surface.worktreeID == worktreeID else {
                return PanelGetResult(tabs: [], activeTabID: nil)
            }
            return PanelGetResult(tabs: [state.surface], activeTabID: nil)
        }
        let surfaces = try await db.panelSurface.surfaces(worktreeID: worktreeID)
        let activeTabID = try await db.worktrees.getActiveTabID(worktreeID: worktreeID)
        return PanelGetResult(tabs: surfaces, activeTabID: activeTabID)
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

        // 3. `.selectTab` is worktree-scoped, not tab-scoped (the reducer
        // throws `.notTabScoped` for it) — the coordinator handles it
        // directly: no surface mutation, no reducer call.
        if case .selectTab(let selectedTabID) = envelope.operation {
            return try await applySelectTab(selectedTabID: selectedTabID, envelope: envelope)
        }

        // 4. §5.5 resource-existence check for open/navigate destinations.
        // (Reads other tables, so it stays outside the apply transaction; a
        // resource vanishing right after this is a separate, inherent race,
        // not the surface-state lost-update the transaction closes.)
        try await validateResourceExists(in: envelope.operation, worktreeID: envelope.worktreeID)

        // 5. Placement rewrite (`.automatic` §6.1 recency resolution) happens
        // INSIDE the `reduce` closure below, fed by the recency map
        // `applyReducing` derives from the same transaction-scoped
        // `panel_history` read it uses to build `current` — see
        // `rewritingAutomaticPlacement`'s doc comment for why that's what
        // keeps the rewrite coherent with the tree it's rewriting against.

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
        let reduce: @Sendable (PanelSurfaceState, [PanelID: Date]) throws -> PanelSurfaceState = { current, recency in
            do {
                let resolvedOperation = rewritingAutomaticPlacement(operation, in: current, recency: recency)
                return try PanelSurfaceReducer.apply(resolvedOperation, to: current, makeID: makeID)
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

    /// `selectTab` is worktree-scoped: it updates which tab is active, not
    /// any tab's panel layout. Reuses `worktree.activeTabID` via
    /// `WorktreeStore` — the existing active-tab authority (already read by
    /// non-panel-surface code) — rather than standing up a second one.
    /// Validates the tab exists (has a persisted surface row) under the
    /// claimed worktree, persists a stand-alone receipt (no surface/history
    /// write) so the generic idempotency check in `apply` can replay a
    /// duplicate without re-selecting/re-broadcasting, then broadcasts a
    /// delta carrying only `activeTabID` — no `tabs`, no revision bump.
    ///
    /// ponytail: the idempotency check for `selectTab` is the early
    /// `receipt(operationID:)` read in `apply` (step 2), not an
    /// inside-one-transaction check like `applyReducing`'s — two concurrent
    /// calls with the SAME `operationID` could both pass it and both write
    /// (harmless: same `activeTabID` value, a redundant second broadcast).
    /// Upgrade to a single cross-store transaction if that duplicate
    /// broadcast ever matters; `selectTab` has no revision/lost-update risk
    /// the way surface mutations do, so it wasn't worth one for this task.
    private func applySelectTab(
        selectedTabID: WorkspaceTabID, envelope: PanelOperationEnvelope
    ) async throws -> PanelApplyResult {
        guard let state = try await db.panelSurface.state(tabID: selectedTabID),
              state.surface.worktreeID == envelope.worktreeID else {
            throw PanelCoordinatorError.tabNotFound(selectedTabID)
        }

        try await db.worktrees.setActiveTabID(worktreeID: envelope.worktreeID, tabID: selectedTabID)

        let result = PanelApplyResult(tab: state.surface, replayed: false)
        let appliedAt = now()
        let resultData = try JSONEncoder().encode(result)
        guard let resultJSON = String(bytes: resultData, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "JSON-encoded receipt result is not valid UTF-8"))
        }
        let receipt = PanelOperationReceiptRecord(
            operationID: envelope.operationID.uuidString, worktreeID: envelope.worktreeID.uuidString,
            tabID: selectedTabID.uuidString, revision: Int64(state.surface.revision),
            result: resultJSON, appliedAt: appliedAt)
        try await db.panelSurface.saveReceipt(receipt, now: appliedAt)

        broadcast(.panelSurfaceChanged(PanelSurfaceDelta(
            worktreeID: envelope.worktreeID,
            tabs: [],
            removedTabIDs: [],
            activeTabID: selectedTabID,
            originOperationID: envelope.operationID)))
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
