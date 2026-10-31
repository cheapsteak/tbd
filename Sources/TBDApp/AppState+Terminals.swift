import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Terminals")

enum AutomaticTerminalRecreationClaim: Equatable {
    case alreadyInFlight
    case terminalUnavailable
    case claimed(attempt: Int)
    case budgetExhausted
}

enum ManualTerminalRecreationClaim: Equatable {
    case alreadyInFlight
    case terminalUnavailable
    case claimed
}

enum AutomaticTerminalRecreationOutcome: Equatable {
    case alreadyInFlight
    case terminalUnavailable
    case recreated(attempt: Int)
    case failed(attempt: Int)
    case budgetExhausted
}

extension AppState {
    /// Bounds stale-response suppression without retaining app-lifetime
    /// terminal tombstones or scheduling a cleanup timer. The fixed 30-second
    /// scheduling/settlement margin beyond DaemonClient's shared transport
    /// deadline covers response completion and main-actor callback ordering.
    nonisolated static let terminalDeletionTombstoneTTL: TimeInterval =
        DaemonClient.rpcRecvDeadlineSeconds + 30

    private func pruneRecentTerminalDeletions(date: Date) {
        recentlyDeletedTerminalIDs = recentlyDeletedTerminalIDs.filter { _, deletedAt in
            date.timeIntervalSince(deletedAt) < Self.terminalDeletionTombstoneTTL
        }
    }

    private func wasTerminalRecentlyDeleted(_ terminalID: UUID, date: Date) -> Bool {
        pruneRecentTerminalDeletions(date: date)
        return recentlyDeletedTerminalIDs[terminalID] != nil
    }

    /// Resolve a terminal only within its owning worktree bucket. Terminal IDs
    /// are globally unique in normal operation, but persisted split layouts can
    /// outlive terminal/worktree churn; scoped lookup prevents stale layouts
    /// from rendering another worktree's tmux window.
    func terminal(id: UUID, in worktreeID: UUID) -> Terminal? {
        terminals[worktreeID]?.first { $0.id == id }
    }

    func initialTabLabel(for terminal: Terminal) -> String? {
        terminal.kind == .codex || terminal.label == TerminalLabel.codex ? terminal.label : nil
    }

    // MARK: - Pre-session hook terminals

    /// Label the daemon assigns to the blocking `preSession` hook terminal
    /// (see WorktreeLifecycle+PreSession). The app keys "is this the
    /// pre-session tab?" decisions off this label. Canonical definition
    /// lives in `TBDShared.TerminalLabel`.
    static let preSessionTerminalLabel = TerminalLabel.preSession

    /// Label the daemon assigns to the parallel `setup` hook terminal
    /// (see spawnPrimaryTerminals in WorktreeLifecycle+Create). Canonical
    /// definition lives in `TBDShared.TerminalLabel`.
    static let setupTerminalLabel = TerminalLabel.setup

    /// True when `terminal` is a PRIMARY terminal in the pre-session flow:
    /// the tab the daemon makes active once the hook finishes. That's the
    /// agent (Claude/Codex) or — with skipClaude — a plain shell; the only
    /// non-primary phase-3 terminals are the pre-session hook tab itself and
    /// the parallel `setup` hook window. Keyed off labels rather than kinds
    /// because a skipClaude primary is kind `.shell`, same as `setup`.
    func isPrimaryTerminal(_ terminal: Terminal) -> Bool {
        terminal.label != Self.preSessionTerminalLabel
            && terminal.label != Self.setupTerminalLabel
    }

    /// True when a pre-session hook terminal exists in state for the worktree.
    /// Drives the sidebar "Running setup…" subtitle while the worktree is
    /// still `.creating`.
    func hasPreSessionTerminal(worktreeID: UUID) -> Bool {
        terminals[worktreeID]?.contains { $0.label == Self.preSessionTerminalLabel } ?? false
    }

    /// True when the terminal panel should show the thin "pre-session setup
    /// running" banner: the worktree is still `.creating` AND the active tab
    /// is the pre-session hook terminal.
    func showsPreSessionBanner(for worktree: Worktree) -> Bool {
        guard worktree.status == .creating,
              let activeID = activeTabTerminalID(worktreeID: worktree.id) else { return false }
        return terminal(id: activeID, in: worktree.id)?.label == Self.preSessionTerminalLabel
    }

    /// Terminal ID at the root of the active tab's content (nil for
    /// note/file tabs or when no tabs exist). Shares the view layer's
    /// active-tab resolution via `resolvedActiveTab`.
    private func activeTabTerminalID(worktreeID: UUID) -> UUID? {
        guard let tab = resolvedActiveTab(worktreeID: worktreeID),
              case .terminal(let id) = tab.content else { return nil }
        return id
    }

    // MARK: - terminalCreated delta

    /// Handle a `.terminalCreated` broadcast (pre-session hook flow, another
    /// client, or the echo of this app's own createTerminal RPC).
    ///
    /// Terminals never loaded for this worktree → a full refresh both loads
    /// the list and reconciles tabs. Already loaded → fetch the new terminal
    /// (the delta only carries ID + label) and append it.
    func applyTerminalCreatedDelta(_ delta: TerminalDelta) {
        guard let loaded = terminals[delta.worktreeID] else {
            Task { [weak self] in
                await self?.refreshTerminals(worktreeID: delta.worktreeID)
            }
            return
        }
        // Dedupe fast path: the direct-append in createTerminal et al. may
        // have already landed this terminal (its RPC response races the delta).
        guard !loaded.contains(where: { $0.id == delta.terminalID }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await self.daemonClient.listTerminals(worktreeID: delta.worktreeID)
                guard let terminal = fetched.first(where: { $0.id == delta.terminalID }) else { return }
                self.mergeCreatedTerminal(terminal)
            } catch {
                logger.error("terminalCreated delta fetch failed for \(delta.terminalID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Apply a removal broadcast from this or another daemon client. The
    /// payload has no worktree ID, so resolve it from the current snapshot and
    /// preserve the recreation claim even if that snapshot already dropped it.
    func applyTerminalRemovedDelta(_ delta: TerminalIDDelta) {
        if let worktreeID = worktreeIDRepresentingTerminal(delta.terminalID) {
            removeDeletedTerminalFromState(
                terminalID: delta.terminalID,
                worktreeID: worktreeID
            )
        } else {
            recordTerminalRemoval(terminalID: delta.terminalID)
        }
    }

    /// Apply an in-place provider replacement without touching the tab or its
    /// layout. The terminal ID is the tab anchor, so replacing only the cached
    /// row preserves selection and every split containing that terminal.
    func applyTerminalReplacedDelta(_ terminal: Terminal) {
        adoptProviderReplacement(terminal)
    }

    /// Adopt a provider replacement and clear only the tab's generated Codex
    /// label. A nil label lets the ordinary Claude/profile label resolver take
    /// over, while a user-renamed tab survives unchanged.
    private func adoptProviderReplacement(_ terminal: Terminal) {
        guard let source = terminals[terminal.worktreeID]?.first(where: {
            $0.id == terminal.id
        }) else { return }
        if source.kind != terminal.kind
            || source.sessionIncarnationID != terminal.sessionIncarnationID {
            terminalReplacementObservationGeneration &+= 1
            terminalReplacementObservedGeneration[terminal.id] =
                terminalReplacementObservationGeneration
        }
        adoptRecreatedTerminal(terminal)

        guard source.label != terminal.label,
              let tabIndex = tabs[terminal.worktreeID]?.firstIndex(where: { tab in
                  let layout = layouts[tab.id] ?? .pane(tab.content)
                  return layout.allTerminalIDs().contains(terminal.id)
                      && tab.label == source.label
              }) else { return }
        tabs[terminal.worktreeID]?[tabIndex].label = nil
    }

    private func worktreeIDRepresentingTerminal(_ terminalID: UUID) -> UUID? {
        if let worktreeID = terminals.first(where: { _, terminals in
            terminals.contains { $0.id == terminalID }
        })?.key {
            return worktreeID
        }
        return tabs.first(where: { _, worktreeTabs in
            worktreeTabs.contains { tab in
                (layouts[tab.id] ?? .pane(tab.content))
                    .allTerminalIDs().contains(terminalID)
            }
        })?.key
    }

    /// Merge a terminal returned by any creation path into local state, add a
    /// tab for it when needed, and — when an agent terminal lands while the
    /// user is still looking at the pre-session hook tab — move the selection
    /// to the agent (matches the daemon's "active = primary" default).
    ///
    /// Idempotent: a repeated UUID replaces the earlier terminal snapshot so
    /// whichever racing path lands last supplies the freshest daemon state.
    func mergeCreatedTerminal(_ terminal: Terminal, date: Date = Date()) {
        // A deletion that overlaps an already-dispatched recreation remains
        // authoritative until that request completes.
        guard !terminalDeletionsAwaitingRecreationCompletion.contains(terminal.id),
              !wasTerminalRecentlyDeleted(terminal.id, date: date) else { return }

        let worktreeID = terminal.worktreeID
        let previousActiveTabID = explicitActiveTabID(worktreeID: worktreeID)
        let inserted: Bool
        if let existingIndex = terminals[worktreeID]?.firstIndex(where: { $0.id == terminal.id }) {
            terminals[worktreeID]?[existingIndex] = terminal
            inserted = false
        } else {
            terminals[worktreeID, default: []].append(terminal)
            inserted = true
        }
        replaceTerminalObservationOrder(with: terminal)
        let splitRepresentationTabIDs = Set((tabs[worktreeID] ?? []).compactMap { tab -> UUID? in
            guard let layout = layouts[tab.id],
                  case .split = layout,
                  layout.allTerminalIDs().contains(terminal.id) else { return nil }
            return tab.id
        })

        // A split layout is the authoritative representation. Otherwise keep
        // the first standalone root and discard later racing copies.
        var retainedRoot = false
        var retainedSplitRootIDs = Set<UUID>()
        tabs[worktreeID]?.removeAll { tab in
            guard case .terminal(let terminalID) = tab.content,
                  terminalID == terminal.id else { return false }
            if splitRepresentationTabIDs.contains(tab.id) {
                return !retainedSplitRootIDs.insert(tab.id).inserted
            }
            if !splitRepresentationTabIDs.isEmpty {
                return true
            }
            if !retainedRoot {
                retainedRoot = true
                return false
            }
            return true
        }

        // Add a tab unless the terminal is already represented as a tab root
        // or inside a split layout (same rule as reconcileTabs).
        let represented = (tabs[worktreeID] ?? []).contains { tab in
            (layouts[tab.id] ?? .pane(tab.content)).allTerminalIDs().contains(terminal.id)
        }
        if !represented {
            tabs[worktreeID, default: []].append(
                Tab(id: terminal.id, content: .terminal(terminalID: terminal.id), label: initialTabLabel(for: terminal))
            )
        }
        repointActiveTab(worktreeID: worktreeID, to: previousActiveTabID)

        // When the primary terminal (agent, or shell with skipClaude) arrives
        // while the user is still on the pre-session hook tab, follow it. Any
        // other active tab means the user navigated deliberately — leave the
        // selection alone. The parallel `setup` window never steals selection.
        if inserted,
           isPrimaryTerminal(terminal),
           let activeID = activeTabTerminalID(worktreeID: worktreeID),
           activeID != terminal.id,
           self.terminal(id: activeID, in: worktreeID)?.label == Self.preSessionTerminalLabel,
           let newIdx = tabIndexRepresentingTerminal(terminal.id, worktreeID: worktreeID) {
            // The daemon already persisted the primary as the active tab
            // (setActiveTabID in spawnPrimaryTerminals) — only the in-memory
            // index needs to move, so skip setActiveTab's re-persist RPC.
            activeTabIndices[worktreeID] = newIdx
        }

        // Converging-from-creation reconcile: the daemon's pre-session flow
        // persists tab order [primary, preSession, setup] behind the app's
        // back, but the order this app cached (loaded while only the
        // pre-session tab existed) is just [preSession] — so plain appends
        // would show [preSession, primary, setup] until restart. When the
        // primary lands and the cached order doesn't know it yet, re-fetch
        // the persisted order and re-sort. applyStoredOrder follows the
        // active tab by ID, so neither the hand-off above nor a deliberate
        // user selection is clobbered.
        if inserted, shouldReconcileTabOrderFromDaemon(after: terminal) {
            Task { [weak self] in
                await self?.refreshStoredTabOrder(worktreeID: worktreeID)
            }
        }
    }

    /// Adopt a terminal returned by an explicit creation operation. Unlike a
    /// snapshot/event merge, this is positive evidence that a newly created
    /// UUID is new and may clear stale recovery history.
    func adoptCreatedTerminal(_ terminal: Terminal, date: Date = Date()) {
        guard !terminalDeletionsAwaitingRecreationCompletion.contains(terminal.id),
              !wasTerminalRecentlyDeleted(terminal.id, date: date) else { return }
        terminalRecoveryBudget.reset(for: terminal.id)
        mergeCreatedTerminal(terminal, date: date)
    }

    /// Apply a recreation RPC response only to the terminal row that initiated
    /// it. Replacement-only adoption plus the deletion guards prevent a late
    /// response from appending or reviving an authoritatively removed terminal.
    func adoptRecreatedTerminal(_ terminal: Terminal, date: Date = Date()) {
        guard !terminalDeletionsAwaitingRecreationCompletion.contains(terminal.id),
              !wasTerminalRecentlyDeleted(terminal.id, date: date),
              let index = terminals[terminal.worktreeID]?.firstIndex(where: {
                  $0.id == terminal.id
              }) else { return }
        terminals[terminal.worktreeID]?[index] = terminal
        replaceTerminalObservationOrder(with: terminal)
        // The veil of a transport move ends here: the row now reads holder, so
        // the pane's identity has changed once and the veil has nothing left to
        // cover. Parked or awake — a move whose wake failed lands a parked
        // holder row, and holding the veil over it until the bound expires
        // would stall the tab for nothing.
        if switchingAccountTerminals[terminal.id]?.isTransportMove == true,
           terminal.transport == .holder {
            switchingAccountTerminals[terminal.id] = nil
        }
    }

    /// Adopt a daemon snapshot without allowing a response that overlaps an
    /// authoritative deletion to resurrect that terminal locally, or a list
    /// begun before a provider-replacement delta to restore its source row.
    /// Snapshot absence itself is observational only because responses may be
    /// unordered; it must not alter deletion or recovery-budget state.
    func adoptTerminalSnapshot(
        _ snapshots: [Terminal],
        worktreeID: UUID,
        startedAtReplacementGeneration: UInt64? = nil,
        date: Date = Date()
    ) {
        let snapshotGeneration = startedAtReplacementGeneration
            ?? terminalReplacementObservationGeneration
        pruneRecentTerminalDeletions(date: date)
        let existing = terminals[worktreeID] ?? []
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let visible = snapshots.compactMap { snapshot -> Terminal? in
            guard !terminalDeletionsAwaitingRecreationCompletion.contains(snapshot.id),
                  recentlyDeletedTerminalIDs[snapshot.id] == nil else { return nil }
            let current = existingByID[snapshot.id]
            if let current,
               let replacementGeneration = terminalReplacementObservedGeneration[snapshot.id],
               replacementGeneration > snapshotGeneration,
               snapshot.isCodexTerminal != current.isCodexTerminal {
                return current
            }
            guard snapshot.isCodexTerminal else {
                // Claude and shell rows take terminal.list's arrival-order
                // replacement. The session-order rail is Codex-only and must
                // not survive a terminal incarnation changing away from Codex.
                terminalSessionOrderObservedAt.removeValue(forKey: snapshot.id)
                return snapshot
            }
            var merged = snapshot
            let incomingActivityOrderObservedAt = snapshot.activityStateOrderObservedAt
                ?? snapshot.activityStateObservedAt
            let incomingSessionOrderObservedAt = snapshot.sessionOrderObservedAt
                ?? incomingActivityOrderObservedAt
            let currentSessionOrderObservedAt = terminalSessionOrderObservedAt[snapshot.id]
                ?? current?.sessionOrderObservedAt
            let identityChanged = current.map {
                snapshot.claudeSessionID != $0.claudeSessionID
                    || snapshot.transcriptPath != $0.transcriptPath
            } ?? false
            let shouldKeepCurrentIdentity = identityChanged
                && currentSessionOrderObservedAt.map { currentOrder in
                    incomingSessionOrderObservedAt.map { $0 <= currentOrder } ?? true
                } == true
            let shouldKeepCurrentSessionOrder = current != nil
                && currentSessionOrderObservedAt.map { currentOrder in
                    incomingSessionOrderObservedAt.map { $0 < currentOrder } ?? true
                } == true
            if shouldKeepCurrentIdentity, let current {
                merged.claudeSessionID = current.claudeSessionID
                merged.transcriptPath = current.transcriptPath
            }
            if shouldKeepCurrentIdentity || shouldKeepCurrentSessionOrder, let current {
                merged.sessionOrderObservedAt = current.sessionOrderObservedAt
                    ?? currentSessionOrderObservedAt
                if let currentSessionOrderObservedAt {
                    terminalSessionOrderObservedAt[snapshot.id] = currentSessionOrderObservedAt
                }
            } else if current == nil || identityChanged {
                if let incomingSessionOrderObservedAt,
                   snapshot.claudeSessionID != nil || snapshot.transcriptPath != nil {
                    terminalSessionOrderObservedAt[snapshot.id] = incomingSessionOrderObservedAt
                } else {
                    terminalSessionOrderObservedAt.removeValue(forKey: snapshot.id)
                }
            } else if let incomingSessionOrderObservedAt,
                      currentSessionOrderObservedAt.map({ incomingSessionOrderObservedAt > $0 })
                        != false {
                terminalSessionOrderObservedAt[snapshot.id] = incomingSessionOrderObservedAt
            }
            merged.reconcileActivityObservation(against: current)
            return merged
        }
        let visibleIDs = Set(visible.map(\.id))
        for terminal in existing where !visibleIDs.contains(terminal.id) {
            terminalSessionOrderObservedAt.removeValue(forKey: terminal.id)
            terminalReplacementObservedGeneration.removeValue(forKey: terminal.id)
        }
        guard visible != existing else { return }
        terminals[worktreeID] = visible
        reconcileTabs(worktreeID: worktreeID, terminals: visible)
    }

    /// Merge a terminal returned by an explicit creation action and select
    /// whichever root tab currently represents it, including a split root.
    func mergeCreatedTerminalAndSelect(_ terminal: Terminal) {
        adoptCreatedTerminal(terminal)
        if let index = tabIndexRepresentingTerminal(
            terminal.id, worktreeID: terminal.worktreeID
        ) {
            setActiveTab(worktreeID: terminal.worktreeID, tabIndex: index)
        }
    }

    private func tabIndexRepresentingTerminal(
        _ terminalID: UUID, worktreeID: UUID
    ) -> Int? {
        tabs[worktreeID]?.firstIndex { tab in
            (layouts[tab.id] ?? .pane(tab.content))
                .allTerminalIDs().contains(terminalID)
        }
    }

    /// Gate for the converging-from-creation tab-order re-fetch: only a
    /// primary terminal (agent, or shell with skipClaude) landing in a
    /// worktree that is still `.creating` and has a pre-session hook
    /// terminal, while the cached order doesn't yet contain that primary,
    /// warrants reconciling against the daemon's persisted order. The
    /// `.creating` requirement scopes the gate to the creation phase: the
    /// pre-session tab outlives setup, so without it the gate could fire for
    /// terminals created long after the worktree went `.active`. Anything
    /// else — user reorders, the parallel `setup` shell, a worktree not in
    /// state — must leave the tab arrangement untouched.
    func shouldReconcileTabOrderFromDaemon(after terminal: Terminal) -> Bool {
        guard let worktree = findWorktree(id: terminal.worktreeID),
              worktree.status == .creating else { return false }
        return isPrimaryTerminal(terminal)
            && hasPreSessionTerminal(worktreeID: terminal.worktreeID)
            && worktreeTabOrders[terminal.worktreeID]?.contains(terminal.id) != true
    }

    /// Re-fetch the daemon's persisted tab order for a worktree and re-sort
    /// the in-memory tabs against it. Failure just logs — the order then
    /// converges on the next full refresh or restart, exactly as before.
    func refreshStoredTabOrder(worktreeID: UUID) async {
        do {
            let response = try await tabStatesFetcher(worktreeID)
            adoptPersistedTabOrder(worktreeID: worktreeID, order: response.order)
        } catch {
            logger.error("tab order re-fetch failed for \(worktreeID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Synchronous core of the converging-from-creation reconcile: adopt the
    /// daemon's persisted tab order and re-sort via the same applyStoredOrder
    /// path loadTabStates uses. Split from the fetch so tests (which can't
    /// stub the concrete DaemonClient actor) can drive it with a fixture
    /// order. An empty order means the daemon has nothing persisted — keep
    /// the current in-memory arrangement.
    func adoptPersistedTabOrder(worktreeID: UUID, order: [UUID]) {
        guard !order.isEmpty else { return }
        worktreeTabOrders[worktreeID] = order
        applyStoredOrder(worktreeID: worktreeID)
    }

    /// The JSONL path for a terminal's current Claude session, found without
    /// knowing which worktree the terminal belongs to.
    ///
    /// Transcript cards carry a `terminalID` and no `worktreeID`, so they
    /// cannot index `terminals` directly; this is the one lookup that lets a
    /// card hand `DaemonClient` the path its app-side read needs. Nil when the
    /// terminal is gone or has no session file yet, which keeps the caller on
    /// the RPC path.
    func transcriptPath(forTerminal terminalID: UUID) -> String? {
        terminals.values.flatMap { $0 }
            .first { $0.id == terminalID }?
            .transcriptPath
    }

    // MARK: - Terminal Actions

    /// Create a terminal in a worktree and add a new tab for it.
    func createTerminal(worktreeID: UUID, cmd: String? = nil) async {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(worktreeID: worktreeID, cmd: cmd, cols: size.cols, rows: size.rows, colorFgBg: colorFgBg)
            adoptCreatedTerminal(terminal)
        } catch {
            logger.error("Failed to create terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Delete a terminal (kills tmux window and removes from daemon DB).
    func deleteTerminal(terminalID: UUID, worktreeID: UUID) async {
        do {
            try await daemonClient.deleteTerminal(terminalID: terminalID)
            removeDeletedTerminalFromState(terminalID: terminalID, worktreeID: worktreeID)
        } catch {
            logger.error("Failed to delete terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Send text to a terminal.
    ///
    /// The daemon now refuses a send whose pane is gone, dead, or has been
    /// reused by a different session, so this can fail for a reason the user
    /// can act on ("recreate the window"). `handleConnectionError` only flips
    /// the connected flag for disconnects, which would leave such a refusal
    /// invisible — so it is surfaced the way this file's sibling failures are,
    /// as an error alert carrying the daemon's own message.
    func sendToTerminal(terminalID: UUID, text: String) async {
        do {
            try await daemonClient.sendToTerminal(terminalID: terminalID, text: text)
        } catch {
            logger.error("Failed to send to terminal: \(error)")
            handleConnectionError(error)
            showAlert("Couldn't send to terminal: \(error.localizedDescription)", isError: true)
        }
    }

    func removeDeletedTerminalFromState(
        terminalID: UUID,
        worktreeID: UUID,
        date: Date = Date()
    ) {
        terminals[worktreeID]?.removeAll { $0.id == terminalID }
        // This is the death every route shares — a pane close, an archive, a
        // daemon-reported removal — so it is where the composer's per-terminal
        // memory is reclaimed. Memory only, and safe: the row is gone above.
        forgetComposerState(for: terminalID)
        // An already-dispatched recreation RPC cannot be unsent. Keep its
        // in-flight claim intact so no second request can race it, and defer
        // budget cleanup until its `finishTerminalRecreation` runs.
        recordTerminalRemoval(terminalID: terminalID, date: date)
        reconcileTabs(worktreeID: worktreeID, terminals: terminals[worktreeID] ?? [])
    }

    /// Preserve an active recreation claim across removal; otherwise discard
    /// recovery history immediately. Shared by terminal and worktree removal.
    func recordTerminalRemoval(terminalID: UUID, date: Date = Date()) {
        terminalSessionOrderObservedAt.removeValue(forKey: terminalID)
        terminalReplacementObservedGeneration.removeValue(forKey: terminalID)
        if limitHits[terminalID] != nil { limitHits.removeValue(forKey: terminalID) }
        if terminalAttachRetries[terminalID] != nil {
            terminalAttachRetries.removeValue(forKey: terminalID)
        }
        pruneRecentTerminalDeletions(date: date)
        recentlyDeletedTerminalIDs[terminalID] = date
        if recreatingTerminalIDs.contains(terminalID) {
            terminalDeletionsAwaitingRecreationCompletion.insert(terminalID)
        } else {
            terminalRecoveryBudget.reset(for: terminalID)
        }
    }

    /// A replacement Terminal is a new observation generation even when its
    /// UUID is reused. Seed the session-order rail from that row rather than
    /// retaining a watermark from the terminal incarnation it replaced.
    private func replaceTerminalObservationOrder(with terminal: Terminal) {
        guard terminal.isCodexTerminal else {
            terminalSessionOrderObservedAt.removeValue(forKey: terminal.id)
            return
        }
        if terminal.claudeSessionID != nil || terminal.transcriptPath != nil,
           let observedAt = terminal.sessionOrderObservedAt
            ?? terminal.activityStateOrderObservedAt
            ?? terminal.activityStateObservedAt {
            terminalSessionOrderObservedAt[terminal.id] = observedAt
        } else {
            terminalSessionOrderObservedAt.removeValue(forKey: terminal.id)
        }
    }

    private func containsTerminal(_ terminalID: UUID) -> Bool {
        terminals.values.contains { terminals in
            terminals.contains { $0.id == terminalID }
        }
    }

    func claimAutomaticTerminalRecreation(
        terminalID: UUID
    ) -> AutomaticTerminalRecreationClaim {
        guard !recreatingTerminalIDs.contains(terminalID) else { return .alreadyInFlight }
        // A pane failing to attach mid-move is attaching to the window the
        // migration retires on purpose; recreating it would fight the move.
        guard switchingAccountTerminals[terminalID]?.isTransportMove != true else {
            return .alreadyInFlight
        }
        guard containsTerminal(terminalID) else { return .terminalUnavailable }
        guard let attempt = terminalRecoveryBudget.claimAttempt(for: terminalID) else {
            logger.error("Automatic terminal recovery budget exhausted for \(terminalID, privacy: .public)")
            return .budgetExhausted
        }
        recreatingTerminalIDs.insert(terminalID)
        logger.info("Claimed automatic terminal recovery attempt \(attempt, privacy: .public) for \(terminalID, privacy: .public)")
        return .claimed(attempt: attempt)
    }

    func claimManualTerminalRecreation(
        terminalID: UUID
    ) -> ManualTerminalRecreationClaim {
        guard !recreatingTerminalIDs.contains(terminalID) else { return .alreadyInFlight }
        // The recovery banner's Retry button reaches this, and can be clicked
        // while a move has the pane attached to the window it retires.
        guard switchingAccountTerminals[terminalID]?.isTransportMove != true else {
            return .alreadyInFlight
        }
        guard containsTerminal(terminalID) else { return .terminalUnavailable }
        recreatingTerminalIDs.insert(terminalID)
        return .claimed
    }

    func finishTerminalRecreation(terminalID: UUID) {
        recreatingTerminalIDs.remove(terminalID)
        if terminalDeletionsAwaitingRecreationCompletion.remove(terminalID) != nil {
            terminalRecoveryBudget.reset(for: terminalID)
        }
    }

    func terminalViewerDidStart(terminalID: UUID) {
        guard containsTerminal(terminalID),
              !terminalDeletionsAwaitingRecreationCompletion.contains(terminalID) else { return }
        terminalRecoveryBudget.reset(for: terminalID)
        logger.info("Reset automatic terminal recovery budget after attachment for \(terminalID, privacy: .public)")
    }

    func requestAutomaticTerminalRecreation(
        terminalID: UUID
    ) async -> AutomaticTerminalRecreationOutcome {
        switch claimAutomaticTerminalRecreation(terminalID: terminalID) {
        case .alreadyInFlight:
            return .alreadyInFlight
        case .terminalUnavailable:
            return .terminalUnavailable
        case .budgetExhausted:
            return .budgetExhausted
        case .claimed(let attempt):
            defer { finishTerminalRecreation(terminalID: terminalID) }
            do {
                try await performTerminalRecreation(terminalID: terminalID)
                guard containsTerminal(terminalID),
                      !terminalDeletionsAwaitingRecreationCompletion.contains(terminalID) else {
                    return .terminalUnavailable
                }
                return .recreated(attempt: attempt)
            } catch {
                guard containsTerminal(terminalID),
                      !terminalDeletionsAwaitingRecreationCompletion.contains(terminalID) else {
                    return .terminalUnavailable
                }
                logger.error("Automatic terminal recreation attempt \(attempt, privacy: .public) failed for \(terminalID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                handleConnectionError(error)
                return .failed(attempt: attempt)
            }
        }
    }

    /// User-triggered recreation is independent of the automatic recovery budget.
    func recreateTerminalWindow(terminalID: UUID) async {
        guard claimManualTerminalRecreation(terminalID: terminalID) == .claimed else {
            return
        }
        defer { finishTerminalRecreation(terminalID: terminalID) }

        do {
            try await performTerminalRecreation(terminalID: terminalID)
        } catch {
            logger.error("Failed to recreate terminal window: \(error)")
            handleConnectionError(error)
        }
    }

    private func performTerminalRecreation(terminalID: UUID) async throws {
        let size = mainAreaTerminalSize()
        let updated = try await daemonClient.recreateTerminalWindow(
            terminalID: terminalID,
            cols: size.cols,
            rows: size.rows
        )
        adoptRecreatedTerminal(updated)
    }

    /// Create a Claude terminal in a worktree and add a new tab for it.
    /// `profileID` pins the session to a specific model profile; when nil the
    /// daemon resolves the profile normally (repo override → global default →
    /// keychain login). `loginSession` marks the terminal as a profile login
    /// session (the person types `/login` there); it requires `profileID`.
    ///
    /// Returns the created terminal, or nil on failure — the daemon fails
    /// loud for broken login sessions (e.g. deleted profile), and surfacing
    /// that here prevents "ghost tab" states where the UI shows a session
    /// that the daemon never fully registered.
    @discardableResult
    func createClaudeTerminal(worktreeID: UUID, profileID: UUID? = nil, loginSession: Bool = false) async -> Terminal? {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(
                worktreeID: worktreeID,
                cmd: nil,
                type: .claude,
                overrideProfileID: profileID,
                loginSession: loginSession ? true : nil,
                cols: size.cols,
                rows: size.rows,
                colorFgBg: colorFgBg
            )
            adoptCreatedTerminal(terminal)
            return terminal
        } catch {
            logger.error("Failed to create Claude terminal: \(error)")
            if loginSession {
                showAlert("Failed to open login session: \(error.localizedDescription)", isError: true)
            }
            handleConnectionError(error)
            return nil
        }
    }

    /// Create a Codex terminal in a worktree and add a new tab for it.
    func createCodexTerminal(worktreeID: UUID) async {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(
                worktreeID: worktreeID,
                cmd: nil,
                type: .codex,
                cols: size.cols,
                rows: size.rows,
                colorFgBg: colorFgBg
            )
            adoptCreatedTerminal(terminal)
        } catch {
            logger.error("Failed to create Codex terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Import a Claude transcript through Codex's native app-server surface,
    /// then select the ordinary Codex tab created by the daemon.
    func continueInCodex(sourceTerminalID: UUID) async {
        guard let source = terminals.values
            .flatMap({ $0 })
            .first(where: { $0.id == sourceTerminalID }) else {
            showAlert("Couldn't continue in Codex: source terminal not found.", isError: true)
            return
        }

        do {
            let result = try await daemonClient.continueInCodex(
                terminalID: sourceTerminalID)
            let rows = try await daemonClient.listTerminals(
                worktreeID: source.worktreeID)
            guard let terminal = rows.first(where: { $0.id == result.terminalID }) else {
                throw DaemonClientError.invalidResponse
            }
            adoptCreatedTerminal(terminal)
            if let index = tabs[source.worktreeID]?.firstIndex(where: { tab in
                (layouts[tab.id] ?? .pane(tab.content))
                    .allTerminalIDs().contains(terminal.id)
            }) {
                setActiveTab(worktreeID: source.worktreeID, tabIndex: index)
            }
        } catch {
            logger.error(
                "Continue in Codex failed: \(error.localizedDescription, privacy: .public)")
            showAlert(
                "Couldn't continue in Codex: \(error.localizedDescription)",
                isError: true)
            handleConnectionError(error)
        }
    }

    /// Replace an idle Codex process with Claude in the same terminal row and
    /// tmux window. The daemon owns eligibility and rollback; this layer keeps
    /// the UI on the existing tab and adopts the returned replacement row.
    func continueInClaude(sourceTerminalID: UUID, profileID: UUID?) async {
        guard let source = terminals.values
            .flatMap({ $0 })
            .first(where: { $0.id == sourceTerminalID }) else {
            showAlert("Couldn't continue in Claude: source terminal not found.", isError: true)
            return
        }

        do {
            let size = mainAreaTerminalSize()
            let updated = try await daemonClient.continueInClaude(
                sourceTerminalID: sourceTerminalID,
                profileID: profileID,
                cols: size.cols,
                rows: size.rows)
            guard updated.id == source.id,
                  updated.worktreeID == source.worktreeID,
                  updated.tmuxWindowID == source.tmuxWindowID else {
                throw DaemonClientError.invalidResponse
            }
            adoptProviderReplacement(updated)
        } catch {
            logger.error(
                "Continue in Claude failed: \(error.localizedDescription, privacy: .public)")
            showAlert(
                "Couldn't continue in Claude: \(error.localizedDescription)",
                isError: true)
            handleConnectionError(error)
        }
    }

    /// Toggle pin state for a terminal.
    func setTerminalPin(id: UUID, pinned: Bool) async {
        // Optimistic local update
        for worktreeID in terminals.keys {
            if let idx = terminals[worktreeID]?.firstIndex(where: { $0.id == id }) {
                terminals[worktreeID]?[idx].pinnedAt = pinned ? Date() : nil
            }
        }

        do {
            try await daemonClient.setTerminalPin(id: id, pinned: pinned)
        } catch {
            logger.error("Failed to set terminal pin: \(error)")
            handleConnectionError(error)
        }
    }

    /// Cancel a pending session-limit auto-resume and clear the badge
    /// optimistically (the next terminal.list poll would reconcile anyway).
    func cancelScheduledResume(terminalID: UUID) async {
        do {
            try await daemonClient.cancelScheduledResume(terminalID: terminalID)
            for (worktreeID, rows) in terminals {
                if let idx = rows.firstIndex(where: { $0.id == terminalID }) {
                    terminals[worktreeID]?[idx].pendingResumeAt = nil
                    break
                }
            }
        } catch {
            showAlert("Failed to cancel scheduled resume: \(error.localizedDescription)",
                      isError: true)
        }
    }
}

extension Terminal {
    /// Merge the activity fact carried by a `terminal.list` row without
    /// letting an older response roll back a newer local or pushed fact.
    /// Facts are ordered by `activityStateOrderObservedAt`, falling back to
    /// `activityStateObservedAt`. Provenance is one atomic pair: a partial
    /// incoming pair is either ignored as a same-value legacy echo or applied
    /// with both halves cleared. A newer fact repeating the current state and
    /// source advances only the order watermark, keeping the observation
    /// stamp of the transition that began it; one that changes only the
    /// source is a new fact, and replaces both — a child exit over a
    /// never-reported `.unknown` is what hides the no-status mark. When
    /// timestamps tie, a wait for the user is preserved, and an ambiguous
    /// working/non-working tie resolves toward non-working.
    mutating func reconcileActivityObservation(against current: Terminal?) {
        let incomingIsComplete = activityStateSource != nil && activityStateObservedAt != nil
        guard let current else {
            if !incomingIsComplete {
                activityStateSource = nil
                activityStateObservedAt = nil
                activityStateOrderObservedAt = nil
            }
            return
        }

        let currentIsComplete = current.activityStateSource != nil
            && current.activityStateObservedAt != nil
        let incomingOrderObservedAt = activityStateOrderObservedAt
            ?? activityStateObservedAt
        let currentOrderObservedAt = current.activityStateOrderObservedAt
            ?? current.activityStateObservedAt
        let shouldKeepCurrent: Bool
        let shouldPreserveCurrentSemanticFact: Bool
        if incomingIsComplete,
           currentIsComplete,
           let incomingOrderObservedAt,
           let currentOrderObservedAt {
            shouldKeepCurrent = incomingOrderObservedAt < currentOrderObservedAt
                || (incomingOrderObservedAt == currentOrderObservedAt
                    && current.preservesActivityAtEqualOrder(over: activityState))
            shouldPreserveCurrentSemanticFact = !shouldKeepCurrent
                && activityState == current.activityState
                && activityStateSource == current.activityStateSource
        } else if !incomingIsComplete, currentIsComplete {
            shouldKeepCurrent = activityState == current.activityState
            shouldPreserveCurrentSemanticFact = false
        } else {
            shouldKeepCurrent = false
            shouldPreserveCurrentSemanticFact = false
        }

        if shouldKeepCurrent {
            activityState = current.activityState
            activityStateSource = current.activityStateSource
            activityStateObservedAt = current.activityStateObservedAt
            activityStateOrderObservedAt = current.activityStateOrderObservedAt
        } else if shouldPreserveCurrentSemanticFact {
            activityStateSource = current.activityStateSource
            activityStateObservedAt = current.activityStateObservedAt
            activityStateOrderObservedAt = incomingOrderObservedAt
        } else if !incomingIsComplete {
            activityStateSource = nil
            activityStateObservedAt = nil
            activityStateOrderObservedAt = nil
        }
    }

    private func preservesActivityAtEqualOrder(
        over incomingState: TerminalActivityState
    ) -> Bool {
        if activityState == .waitingForUser, incomingState != .waitingForUser { return true }
        return activityState != .working && incomingState == .working
    }

    /// Apply a pushed activity observation under the same ordering and legacy
    /// rules used for snapshots: a newer delta repeating the state and source
    /// advances only the order watermark, and one that changes either is
    /// applied whole.
    mutating func applyActivityDelta(_ delta: TerminalActivityDelta) {
        let incomingIsComplete = delta.activityStateSource != nil
            && delta.activityStateObservedAt != nil
        let currentIsComplete = activityStateSource != nil && activityStateObservedAt != nil
        let incomingOrderObservedAt = delta.activityStateOrderObservedAt
            ?? delta.activityStateObservedAt
        let currentOrderObservedAt = activityStateOrderObservedAt
            ?? activityStateObservedAt

        if incomingIsComplete,
           currentIsComplete,
           let incomingOrderObservedAt,
           let currentOrderObservedAt,
           incomingOrderObservedAt < currentOrderObservedAt
            || (incomingOrderObservedAt == currentOrderObservedAt
                && preservesActivityAtEqualOrder(over: delta.activityState)) {
            return
        }

        if !incomingIsComplete {
            if currentIsComplete, delta.activityState == activityState {
                return
            }
            activityState = delta.activityState
            activityStateSource = nil
            activityStateObservedAt = nil
            activityStateOrderObservedAt = nil
            return
        }

        if currentIsComplete, delta.activityState == activityState,
           delta.activityStateSource == activityStateSource {
            activityStateOrderObservedAt = incomingOrderObservedAt
            return
        }

        activityState = delta.activityState
        activityStateSource = delta.activityStateSource
        activityStateObservedAt = delta.activityStateObservedAt
        activityStateOrderObservedAt = delta.activityStateOrderObservedAt
    }
}

// MARK: - Moving sessions to the pty holder

/// Pure decisions behind the transport-migration gestures, so each branch is
/// testable without SwiftUI (same pattern as `SwapProfileMenu`).
enum TransportMigrationMenu {
    static let title = "Move to Holder (No tmux)"

    /// Offered for any row that is not already holder-backed, and only when the
    /// daemon can run a holder (the capability the Settings toggle reads).
    static func isOffered(for terminal: Terminal?, holderSupported: Bool) -> Bool {
        guard holderSupported, let terminal else { return false }
        return terminal.transport != .holder
    }

    /// Fleet-run reasons that are app-local report concerns, not wire outcomes.
    static let paneBusyReason =
        "Another operation is using this session's pane right now. Try again once it finishes."
    static let outcomeUnknownReason =
        "The app stopped waiting for an answer about this session, so where it ended up is unknown. Check it before moving it again."
    static let runStoppedReason =
        "The run stopped before reaching this session, so nothing was attempted for it."

    /// Prefix for a single-session alert, by group.
    static let skippedAlertPrefix = "Not moved — change this and try again: "
    static let refusedAlertPrefix = "Can't be moved until this changes: "
    /// Neither of the above: the session DID move, and only its program was not
    /// started again. Saying "can't be moved" about it would be false.
    static let movedNotResumedAlertPrefix = "Moved to the holder, but not restarted: "

    /// Every line a single-session alert shows, in the order a person acts on
    /// them. Empty when the session moved and restarted, which is the case that
    /// shows no alert at all.
    static func alertLines(_ result: TerminalMigrateTransportResult) -> [String] {
        result.skipped.map { skippedAlertPrefix + $0.reason }
            + result.refused.map { refusedAlertPrefix + $0.reason }
            + result.movedNotResumed.map { movedNotResumedAlertPrefix + $0.reason }
    }

    /// Accumulate the per-session results a fleet run is composed from.
    static func merging(
        _ base: TerminalMigrateTransportResult, _ next: TerminalMigrateTransportResult
    ) -> TerminalMigrateTransportResult {
        TerminalMigrateTransportResult(
            migrated: base.migrated + next.migrated,
            movedNotResumed: base.movedNotResumed + next.movedNotResumed,
            skipped: base.skipped + next.skipped,
            refused: base.refused + next.refused,
            alreadyHolder: base.alreadyHolder + next.alreadyHolder)
    }

    /// One line per session the run left alone.
    struct Line: Equatable {
        let label: String
        let reason: String
    }

    /// What a run came to, in the order a person acts on it. A skip names a
    /// state the person can change and retry; a refusal does not help until
    /// the named fact changes, so the two are kept apart and worded apart.
    struct Report: Equatable {
        let headline: String
        let skippedHeading = "Check these and try again"
        let refusedHeading = "Can't be moved until this changes"
        /// Its own heading, because these sessions moved. Grouping them under
        /// the refusals would tell a person a session "can't be moved" that is
        /// already on the holder, and the headline would undercount the run.
        let movedNotResumedHeading =
            "Moved to the holder, but not restarted — they resume there when next woken"
        let skipped: [Line]
        let refused: [Line]
        let movedNotResumed: [Line]
    }

    static func report(
        _ result: TerminalMigrateTransportResult, label: (UUID) -> String
    ) -> Report {
        var parts = ["Moved \(result.migrated.count)"]
        if !result.movedNotResumed.isEmpty {
            parts.append("\(result.movedNotResumed.count) moved but not restarted")
        }
        if !result.alreadyHolder.isEmpty {
            parts.append("\(result.alreadyHolder.count) already on the holder")
        }
        if !result.skipped.isEmpty { parts.append("\(result.skipped.count) skipped") }
        if !result.refused.isEmpty { parts.append("\(result.refused.count) refused") }
        func lines(_ list: [TerminalMigrationSkip]) -> [Line] {
            list.map { Line(label: label($0.terminalID), reason: $0.reason) }
        }
        return Report(
            headline: parts.joined(separator: " · "),
            skipped: lines(result.skipped), refused: lines(result.refused),
            movedNotResumed: lines(result.movedNotResumed))
    }
}

extension AppState {
    /// A short name for a session in a result list.
    func transportMigrationLabel(for terminalID: UUID) -> String {
        let row = terminals.values.lazy.flatMap { $0 }.first(where: { $0.id == terminalID })
        return row?.label ?? "Session \(terminalID.uuidString.prefix(8))"
    }

    /// Poll step and bound for the veil's wait on adoption.
    nonisolated static let transportMovePollInterval: Duration = .milliseconds(100)
    nonisolated static let transportMoveAdoptionBound: Duration = .seconds(5)

    /// Hold the veil of each migrated row until `adoptRecreatedTerminal` clears
    /// it, bounded so a lost `.terminalReplaced` cannot strand it. The delta and
    /// the RPC reply travel on different sockets with no ordering, so the reply
    /// cannot be taken as the end of the move.
    ///
    /// Cancellation ends the wait rather than spinning through the remaining
    /// steps: a cancelled sleep returns at once, and the caller's `defer` is
    /// what takes the veil down.
    private func awaitTransportMoveAdoption(_ ids: [UUID]) async {
        var waited: Duration = .zero
        while waited < Self.transportMoveAdoptionBound, !Task.isCancelled,
              ids.contains(where: { switchingAccountTerminals[$0]?.isTransportMove == true }) {
            try? await transportMoveClock.sleep(for: Self.transportMovePollInterval)
            waited += Self.transportMovePollInterval
        }
    }

    /// One session's move, veil and all — the piece both app surfaces are
    /// composed from, so the fleet run cannot drift from the gesture.
    ///
    /// The veil of an account switch covers the park and wake and stays up
    /// until the refreshed row arrives as `.terminalReplaced`, which
    /// `adoptRecreatedTerminal` overwrites in place (and which ends the veil),
    /// so nothing is refreshed here. The reply cannot stand in for that delta:
    /// the two travel on different sockets with no ordering between them.
    ///
    /// `ownsRecord` is what keeps the veil to the rows it belongs to — a row
    /// already veiled by something else is left alone, and a parked or
    /// holder-backed row has no live pane to cover.
    ///
    /// Throws whatever the RPC threw; the caller decides what to tell the
    /// person.
    private func moveOneTerminalToHolder(
        terminalID: UUID
    ) async throws -> TerminalMigrateTransportResult {
        let cached = terminals.values.lazy.flatMap { $0 }.first(where: { $0.id == terminalID })
        let ownsRecord = switchingAccountTerminals[terminalID] == nil
            && cached.map { $0.transport != .holder && !$0.isParked } == true
        if ownsRecord { switchingAccountTerminals[terminalID] = .transportMove }
        defer {
            if ownsRecord, switchingAccountTerminals[terminalID]?.isTransportMove == true {
                switchingAccountTerminals[terminalID] = nil
            }
        }
        let result = try await terminalTransportMigrator(terminalID)
        // Both lists name a row that now reads holder-backed, so both have an
        // adoption coming — a move whose wake failed has still moved the row,
        // and its pane must not stay attached to the retired window.
        let moved = result.migrated.contains(terminalID)
            || result.movedNotResumed.contains { $0.terminalID == terminalID }
        if ownsRecord, moved { await awaitTransportMoveAdoption([terminalID]) }
        return result
    }

    /// Move one session to the holder. A session that did not move, or moved
    /// without restarting, says so in an alert.
    func migrateTerminalToHolder(terminalID: UUID) async {
        do {
            let lines = TransportMigrationMenu.alertLines(
                try await moveOneTerminalToHolder(terminalID: terminalID))
            if !lines.isEmpty { showAlert(lines.joined(separator: "\n"), isError: true) }
        } catch {
            logger.error("Failed to move terminal to the holder: \(error, privacy: .public)")
            showAlert("Failed to move this session off tmux: \(error.localizedDescription)", isError: true)
        }
    }

    /// Move every session the app holds to the holder, **one single-session RPC
    /// at a time**, and return the accumulated report.
    ///
    /// **Composed from the per-session move rather than the daemon's `--all`.**
    /// A sequential park-and-respawn of a real fleet outruns the app's 300 s
    /// receive deadline (`DaemonClient.rpcRecvDeadlineSeconds`), and when it
    /// does, `sendRaw` throws while the daemon keeps migrating: the person is
    /// told the daemon is unresponsive, every veil drops at once, and the
    /// report — which this run's whole product is — is lost. One RPC per row
    /// has no deadline to outrun, and gives each row the veil and the adoption
    /// wait the single gesture already has. The daemon's `--all` stays exactly
    /// as it is, for the CLI.
    ///
    /// **Already-holder rows are answered from the cache**, not by a no-op RPC
    /// each: the daemon reports them from the row alone, and on a fleet that is
    /// mostly migrated already that would be a round trip per row for an answer
    /// the app can read off what it is displaying.
    ///
    /// A throw stops the run and names that row as skipped with an unknown
    /// outcome, and every row after it as untried, rather than discarding
    /// everything: the rows already moved are finished sessions, and
    /// their report is what the person asked for.
    @discardableResult
    func migrateAllTerminalsToHolder() async -> TerminalMigrateTransportResult {
        let rows = terminals.values.flatMap { $0 }
        var accumulated = TerminalMigrateTransportResult(
            migrated: [], skipped: [], refused: [],
            alreadyHolder: rows.filter { $0.transport == .holder }.map(\.id))
        let nonHolder = rows.filter { $0.transport != .holder }.map(\.id)
        // A row another operation has veiled is not safe to move while that
        // operation owns its pane, but it is still a considered session: it is
        // named rather than left out of every list.
        let busy = nonHolder.filter { switchingAccountTerminals[$0] != nil }
        accumulated = TransportMigrationMenu.merging(
            accumulated,
            TerminalMigrateTransportResult(
                migrated: [],
                skipped: busy.map {
                    TerminalMigrationSkip(
                        terminalID: $0, reason: TransportMigrationMenu.paneBusyReason)
                },
                refused: []))
        let candidates = nonHolder.filter { switchingAccountTerminals[$0] == nil }
        for (index, id) in candidates.enumerated() {
            if Task.isCancelled { break }
            do {
                accumulated = TransportMigrationMenu.merging(
                    accumulated, try await moveOneTerminalToHolder(terminalID: id))
            } catch {
                logger.error("Failed to move sessions to the holder: \(error, privacy: .public)")
                showAlert("Failed to move sessions off tmux: \(error.localizedDescription)", isError: true)
                // The thrown row's outcome is unknown (a receive deadline means
                // the app stopped waiting, not that the daemon stopped), so it
                // is not reported as still on tmux; the tail was never tried.
                let unknown = TerminalMigrationSkip(
                    terminalID: id, reason: TransportMigrationMenu.outcomeUnknownReason)
                let untried = candidates[(index + 1)...].map {
                    TerminalMigrationSkip(
                        terminalID: $0, reason: TransportMigrationMenu.runStoppedReason)
                }
                return TransportMigrationMenu.merging(
                    accumulated,
                    TerminalMigrateTransportResult(
                        migrated: [], skipped: [unknown] + untried, refused: []))
            }
        }
        return accumulated
    }
}
