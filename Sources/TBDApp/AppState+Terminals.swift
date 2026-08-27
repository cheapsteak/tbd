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
    }

    /// Adopt a daemon snapshot without allowing a response that overlaps an
    /// authoritative deletion to resurrect that terminal locally. Snapshot
    /// absence itself is observational only because responses may be unordered;
    /// it must not alter deletion or recovery-budget state.
    func adoptTerminalSnapshot(
        _ snapshots: [Terminal],
        worktreeID: UUID,
        date: Date = Date()
    ) {
        pruneRecentTerminalDeletions(date: date)
        let existing = terminals[worktreeID] ?? []
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let visible = snapshots.compactMap { snapshot -> Terminal? in
            guard !terminalDeletionsAwaitingRecreationCompletion.contains(snapshot.id),
                  recentlyDeletedTerminalIDs[snapshot.id] == nil else { return nil }
            guard snapshot.isCodexTerminal else {
                // Claude and shell rows retain terminal.list's established
                // arrival-order replacement. The hidden ordering rails belong
                // only to Codex transcript presentation and must not survive a
                // terminal incarnation changing away from Codex.
                terminalPresentationOrderObservedAt.removeValue(forKey: snapshot.id)
                terminalSessionOrderObservedAt.removeValue(forKey: snapshot.id)
                return snapshot
            }
            var merged = snapshot
            let current = existingByID[snapshot.id]
            let incomingActivityOrderObservedAt = snapshot.activityStateOrderObservedAt
                ?? snapshot.activityStateObservedAt
            let incomingSessionOrderObservedAt = snapshot.sessionOrderObservedAt
                ?? incomingActivityOrderObservedAt
            let currentSessionOrderObservedAt = terminalSessionOrderObservedAt[snapshot.id]
                ?? current?.sessionOrderObservedAt
                ?? current.flatMap { terminal in
                    guard terminal.activityStateSource == .hookEvent("SessionStart") else {
                        return nil
                    }
                    return terminal.activityStateOrderObservedAt
                        ?? terminal.activityStateObservedAt
                }
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
            let snapshotPredatesCurrentSession = current != nil
                && currentSessionOrderObservedAt.map { currentOrder in
                    incomingActivityOrderObservedAt.map { $0 < currentOrder } ?? true
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
            // A list response may have scanned the same transcript path before
            // an accepted SessionStart boundary. Its later response timestamp
            // does not make that pre-boundary presentation current.
            if shouldKeepCurrentIdentity || snapshotPredatesCurrentSession,
               let current {
                merged.presentationActivityState = current.presentationActivityState
                merged.presentationActivityObservedAt = current.presentationActivityObservedAt
            }
            let presentationOrderObservedAt = merged.reconcileActivityObservation(
                against: current,
                presentationOrderObservedAt: terminalPresentationOrderObservedAt[snapshot.id]
                    ?? current?.presentationActivityObservedAt)
            if let presentationOrderObservedAt {
                terminalPresentationOrderObservedAt[snapshot.id] = presentationOrderObservedAt
            } else {
                terminalPresentationOrderObservedAt.removeValue(forKey: snapshot.id)
            }
            return merged
        }
        let visibleIDs = Set(visible.map(\.id))
        for terminal in existing where !visibleIDs.contains(terminal.id) {
            terminalPresentationOrderObservedAt.removeValue(forKey: terminal.id)
            terminalSessionOrderObservedAt.removeValue(forKey: terminal.id)
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

    /// Treat an explicit user interrupt (Ctrl+C, or Esc for Claude) as "not
    /// working" for Claude and Codex terminals. This clears the sidebar spinner
    /// immediately and mirrors the state to the daemon best-effort. Shell
    /// terminals are never affected.
    func handleTerminalInterrupt(terminalID: UUID, viaEscape: Bool = false) {
        guard let terminal = terminals.values.flatMap({ $0 })
            .first(where: { $0.id == terminalID })
        else {
            return
        }

        // Shells have no agent spinner to clear.
        guard terminal.kind != .shell else { return }

        let isCodex = terminal.kind == .codex || terminal.label == TerminalLabel.codex
        // Esc is Claude's interrupt key, not Codex's. Ignoring Esc for Codex avoids
        // falsely idling a still-working Codex session.
        if viaEscape && isCodex { return }

        // Remaining terminals: Codex (Ctrl+C), Claude, or legacy nil-kind sessions.
        if let idx = terminals[terminal.worktreeID]?.firstIndex(where: { $0.id == terminalID }) {
            terminals[terminal.worktreeID]?[idx].activityState = .idle
            // Clear the cached presentation value for every agent kind. The
            // daemon drops its own claim on the `userInterrupt` origin below,
            // but `TerminalActivityDelta` — the real-time push rail — carries
            // no presentation field, so only a full `terminal.list` refresh
            // would deliver that clear. Without this line the stale claim keeps
            // the sidebar spinner lit until the next unscoped poll (~2s), which
            // is the false-thinking direction the rail must never fail toward.
            // Clearing it for Codex too is safe: Codex's foreground-working
            // test requires a `.working` presentation value, so the row can
            // only reach idle sooner.
            terminals[terminal.worktreeID]?[idx].presentationActivityState = nil
            if isCodex {
                let observedAt = Date()
                terminals[terminal.worktreeID]?[idx].activityStateSource = .terminalInterrupt
                terminals[terminal.worktreeID]?[idx].activityStateObservedAt = observedAt
                terminals[terminal.worktreeID]?[idx].activityStateOrderObservedAt = observedAt
            }
        }

        Task {
            do {
                // The origin travels for EVERY agent kind, not just Codex. The
                // local optimistic assignments above stay Codex-only because
                // they carry Codex's ordering semantics, but the daemon needs
                // the interrupt fact for Claude too: an interrupted Claude turn
                // often writes no `turn_duration`, so without this the
                // delegation rail would re-read the pre-interrupt record on the
                // next poll and relight the spinner with no agents running.
                // The handler's other origin-conditional branches — the
                // hook-event counter and the Stop-hook transcript sync — already
                // read a present origin as "a user action, not an agent hook",
                // which is what an Esc on a Claude session is.
                try await daemonClient.setTerminalActivity(
                    terminalID: terminalID,
                    activityState: .idle,
                    origin: .userInterrupt
                )
            } catch {
                logger.debug("Failed to publish terminal interrupt state: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

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
        // An already-dispatched recreation RPC cannot be unsent. Keep its
        // in-flight claim intact so no second request can race it, and defer
        // budget cleanup until its `finishTerminalRecreation` runs.
        recordTerminalRemoval(terminalID: terminalID, date: date)
        reconcileTabs(worktreeID: worktreeID, terminals: terminals[worktreeID] ?? [])
    }

    /// Preserve an active recreation claim across removal; otherwise discard
    /// recovery history immediately. Shared by terminal and worktree removal.
    func recordTerminalRemoval(terminalID: UUID, date: Date = Date()) {
        terminalPresentationOrderObservedAt.removeValue(forKey: terminalID)
        terminalSessionOrderObservedAt.removeValue(forKey: terminalID)
        pruneRecentTerminalDeletions(date: date)
        recentlyDeletedTerminalIDs[terminalID] = date
        if recreatingTerminalIDs.contains(terminalID) {
            terminalDeletionsAwaitingRecreationCompletion.insert(terminalID)
        } else {
            terminalRecoveryBudget.reset(for: terminalID)
        }
    }

    /// A replacement Terminal is a new observation generation even when its
    /// UUID is reused. Seed both hidden ordering rails from that row rather
    /// than retaining watermarks from the terminal incarnation it replaced.
    private func replaceTerminalObservationOrder(with terminal: Terminal) {
        guard terminal.isCodexTerminal else {
            terminalPresentationOrderObservedAt.removeValue(forKey: terminal.id)
            terminalSessionOrderObservedAt.removeValue(forKey: terminal.id)
            return
        }
        if let observedAt = terminal.presentationActivityObservedAt {
            terminalPresentationOrderObservedAt[terminal.id] = observedAt
        } else {
            terminalPresentationOrderObservedAt.removeValue(forKey: terminal.id)
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
    /// session (daemon auto-types `/login`); it requires `profileID`.
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
    /// Provenance is one atomic pair: a partial incoming pair is either ignored
    /// as a same-value legacy echo or applied with both halves cleared. When
    /// timestamps tie, explicit interrupts and permission waits are preserved,
    /// while ambiguous working/non-working ties resolve toward non-working.
    @discardableResult
    mutating func reconcileActivityObservation(
        against current: Terminal?,
        presentationOrderObservedAt: Date?
    ) -> Date? {
        let incomingIsComplete = activityStateSource != nil && activityStateObservedAt != nil
        guard let current else {
            if !incomingIsComplete {
                activityStateSource = nil
                activityStateObservedAt = nil
                activityStateOrderObservedAt = nil
            }
            return self.presentationActivityObservedAt
        }

        let reconciledPresentationOrderObservedAt = reconcilePresentationObservation(
            against: current,
            orderObservedAt: presentationOrderObservedAt)

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
                    && current.preservesActivityAtEqualOrder(
                        over: activityState,
                        source: activityStateSource))
            shouldPreserveCurrentSemanticFact = !shouldKeepCurrent
                && activityState == current.activityState
                && !isMeaningfulSameStateReplacement(source: activityStateSource)
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
        return reconciledPresentationOrderObservedAt
    }

    /// Transcript presentation is response-derived and has its own ordering;
    /// raw hook timestamps do not order it. Legacy responses with no timestamp
    /// remain arrival-ordered until a timestamped observation has been adopted.
    /// On an exact tie, a non-working result wins because false working is the
    /// costlier error. A timestamped nil is authoritative "could not establish
    /// activity" evidence (unreadable, incomplete, or capped), so it clears a
    /// prior working presentation instead of serving cached positive state.
    private mutating func reconcilePresentationObservation(
        against current: Terminal,
        orderObservedAt: Date?
    ) -> Date? {
        let identityIsUnchanged = claudeSessionID == current.claudeSessionID
            && transcriptPath == current.transcriptPath
        // Presentation ordering is scoped to one transcript identity. A new
        // identity must not inherit either positive state or an ordering
        // watermark from the transcript it replaced; legacy rows without a
        // timestamp therefore conservatively clear a prior working result.
        guard identityIsUnchanged else { return presentationActivityObservedAt }

        let currentOrderObservedAt = orderObservedAt
            ?? current.presentationActivityObservedAt
        let incomingObservedAt = presentationActivityObservedAt
        let shouldKeepCurrent: Bool
        switch (incomingObservedAt, currentOrderObservedAt) {
        case let (incomingAt?, currentAt?) where incomingAt < currentAt:
            shouldKeepCurrent = true
        case let (incomingAt?, currentAt?) where incomingAt == currentAt:
            shouldKeepCurrent = presentationActivityState == .working
                && current.presentationActivityState != .working
        case (nil, .some):
            shouldKeepCurrent = true
        default:
            shouldKeepCurrent = false
        }

        let stableValue = presentationActivityState == current.presentationActivityState
            && identityIsUnchanged
        if shouldKeepCurrent || stableValue {
            presentationActivityState = current.presentationActivityState
            presentationActivityObservedAt = current.presentationActivityObservedAt
        }
        guard !shouldKeepCurrent else { return currentOrderObservedAt }
        if let incomingObservedAt,
           let currentOrderObservedAt {
            return max(incomingObservedAt, currentOrderObservedAt)
        }
        return incomingObservedAt ?? currentOrderObservedAt
    }

    private func preservesActivityAtEqualOrder(
        over incomingState: TerminalActivityState,
        source incomingSource: FactSource?
    ) -> Bool {
        if incomingSource == .terminalInterrupt { return false }
        if activityStateSource == .terminalInterrupt { return true }
        if activityState == .waitingForUser, incomingState != .waitingForUser { return true }
        return activityState != .working && incomingState == .working
    }

    private func isMeaningfulSameStateReplacement(source: FactSource?) -> Bool {
        source == .terminalInterrupt || source == .hookEvent("SessionStart")
    }

    private func canReplacePresentation(
        observedAt incomingObservedAt: Date?,
        orderObservedAt: Date?
    ) -> Bool {
        guard let currentObservedAt = orderObservedAt
            ?? presentationActivityObservedAt else { return true }
        guard let incomingObservedAt else { return false }
        return incomingObservedAt >= currentObservedAt
    }

    /// Apply a pushed activity observation under the same ordering and legacy
    /// rules used for snapshots. SessionStart is the sole idle hook entitled
    /// to clear transcript presentation, and only after its complete fact wins
    /// the timestamp comparison.
    @discardableResult
    mutating func applyActivityDelta(
        _ delta: TerminalActivityDelta,
        presentationOrderObservedAt: Date?
    ) -> Date? {
        let currentPresentationOrderObservedAt = presentationOrderObservedAt
            ?? self.presentationActivityObservedAt
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
                && preservesActivityAtEqualOrder(
                    over: delta.activityState,
                    source: delta.activityStateSource)) {
            return currentPresentationOrderObservedAt
        }

        if !incomingIsComplete {
            if currentIsComplete, delta.activityState == activityState {
                return currentPresentationOrderObservedAt
            }
            activityState = delta.activityState
            activityStateSource = nil
            activityStateObservedAt = nil
            activityStateOrderObservedAt = nil
            return currentPresentationOrderObservedAt
        }

        if currentIsComplete,
           delta.activityState == activityState,
           !isMeaningfulSameStateReplacement(source: delta.activityStateSource) {
            activityStateOrderObservedAt = incomingOrderObservedAt
            return currentPresentationOrderObservedAt
        }

        activityState = delta.activityState
        activityStateSource = delta.activityStateSource
        activityStateObservedAt = delta.activityStateObservedAt
        activityStateOrderObservedAt = delta.activityStateOrderObservedAt
        if isCodexTerminal,
           delta.activityState == .idle,
           delta.activityStateSource == .hookEvent("SessionStart"),
           canReplacePresentation(
               observedAt: incomingOrderObservedAt,
               orderObservedAt: currentPresentationOrderObservedAt) {
            presentationActivityState = .idle
            presentationActivityObservedAt = incomingOrderObservedAt
            return incomingOrderObservedAt
        }
        return currentPresentationOrderObservedAt
    }
}
