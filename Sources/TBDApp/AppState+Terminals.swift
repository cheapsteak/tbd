import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Terminals")

extension AppState {
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
    /// note/file tabs or when no tabs exist). Mirrors the view layer's
    /// `?? 0` default for an unset active index.
    private func activeTabTerminalID(worktreeID: UUID) -> UUID? {
        let arr = tabs[worktreeID] ?? []
        guard !arr.isEmpty else { return nil }
        let idx = min(activeTabIndices[worktreeID] ?? 0, arr.count - 1)
        guard case .terminal(let id) = arr[idx].content else { return nil }
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
                self.appendCreatedTerminal(terminal)
            } catch {
                logger.error("terminalCreated delta fetch failed for \(delta.terminalID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Append a terminal announced by a `.terminalCreated` delta to state,
    /// add a tab for it, and — when an agent terminal lands while the user is
    /// still looking at the pre-session hook tab — move the selection to the
    /// agent (matches the daemon's "active = primary" default).
    ///
    /// Idempotent: re-checks for the terminal so the direct-append path in
    /// `createTerminal` (which races the delta) never produces duplicates.
    func appendCreatedTerminal(_ terminal: Terminal) {
        let worktreeID = terminal.worktreeID
        guard !(terminals[worktreeID] ?? []).contains(where: { $0.id == terminal.id }) else { return }
        terminals[worktreeID, default: []].append(terminal)

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

        // When the primary terminal (agent, or shell with skipClaude) arrives
        // while the user is still on the pre-session hook tab, follow it. Any
        // other active tab means the user navigated deliberately — leave the
        // selection alone. The parallel `setup` window never steals selection.
        if isPrimaryTerminal(terminal),
           let activeID = activeTabTerminalID(worktreeID: worktreeID),
           activeID != terminal.id,
           self.terminal(id: activeID, in: worktreeID)?.label == Self.preSessionTerminalLabel,
           let newIdx = tabs[worktreeID]?.firstIndex(where: { $0.id == terminal.id }) {
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
        if shouldReconcileTabOrderFromDaemon(after: terminal) {
            Task { [weak self] in
                await self?.refreshStoredTabOrder(worktreeID: worktreeID)
            }
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
            let response = try await daemonClient.listTabs(worktreeID: worktreeID)
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
        }

        Task {
            do {
                try await daemonClient.setTerminalActivity(
                    terminalID: terminalID,
                    activityState: .idle
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
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id), label: initialTabLabel(for: terminal))
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to create terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Create a terminal via the daemon without adding a tab.
    /// Used when splitting an existing tab — the terminal lives inside
    /// the parent tab's layout tree, not as its own tab.
    func createTerminalForSplit(worktreeID: UUID) async -> Terminal? {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(worktreeID: worktreeID, cols: size.cols, rows: size.rows, colorFgBg: colorFgBg)
            terminals[worktreeID, default: []].append(terminal)
            return terminal
        } catch {
            logger.error("Failed to create terminal for split: \(error)")
            handleConnectionError(error)
            return nil
        }
    }

    /// Delete a terminal (kills tmux window and removes from daemon DB).
    func deleteTerminal(terminalID: UUID, worktreeID: UUID) async {
        do {
            try await daemonClient.deleteTerminal(terminalID: terminalID)
            terminals[worktreeID]?.removeAll { $0.id == terminalID }
        } catch {
            logger.error("Failed to delete terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Send text to a terminal.
    func sendToTerminal(terminalID: UUID, text: String) async {
        do {
            try await daemonClient.sendToTerminal(terminalID: terminalID, text: text)
        } catch {
            logger.error("Failed to send to terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Recreate a dead tmux window for an existing terminal.
    /// The daemon creates a new tmux window and updates the terminal record.
    /// A state refresh picks up the new tmuxWindowID, causing the view to rebuild.
    func recreateTerminalWindow(terminalID: UUID) async {
        guard !recreatingTerminalIDs.contains(terminalID) else { return }
        recreatingTerminalIDs.insert(terminalID)
        defer { recreatingTerminalIDs.remove(terminalID) }

        do {
            let size = mainAreaTerminalSize()
            let updated = try await daemonClient.recreateTerminalWindow(terminalID: terminalID, cols: size.cols, rows: size.rows)
            // Update local state so the view rebuilds with the new tmuxWindowID
            if let idx = terminals[updated.worktreeID]?.firstIndex(where: { $0.id == terminalID }) {
                terminals[updated.worktreeID]?[idx] = updated
            }
        } catch {
            logger.error("Failed to recreate terminal window: \(error)")
            handleConnectionError(error)
        }
    }

    /// Create a Claude terminal in a worktree and add a new tab for it.
    /// `profileID` pins the session to a specific model profile; when nil the
    /// daemon resolves the profile normally (repo override → global default →
    /// keychain login).
    func createClaudeTerminal(worktreeID: UUID, profileID: UUID? = nil) async {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(
                worktreeID: worktreeID,
                cmd: nil,
                type: .claude,
                overrideProfileID: profileID,
                cols: size.cols,
                rows: size.rows,
                colorFgBg: colorFgBg
            )
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id), label: initialTabLabel(for: terminal))
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to create Claude terminal: \(error)")
            handleConnectionError(error)
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
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id), label: initialTabLabel(for: terminal))
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to create Codex terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Fork a Claude terminal by resuming from an existing session ID.
    func forkClaudeTerminal(worktreeID: UUID, sessionID: String, tokenID: UUID? = nil) async {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(
                worktreeID: worktreeID,
                resumeSessionID: sessionID,
                overrideProfileID: tokenID,
                cols: size.cols,
                rows: size.rows,
                colorFgBg: colorFgBg
            )
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id), label: initialTabLabel(for: terminal))
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to fork Claude terminal: \(error)")
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
}
