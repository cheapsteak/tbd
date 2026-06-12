import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// App-side behavior for the blocking `preSession` worktree hook:
/// `.terminalCreated` delta consumption, tab selection hand-off from the
/// pre-session tab to the agent, the sidebar "Running setup…" subtitle, and
/// the terminal-panel banner gating.
@MainActor
@Suite("Pre-session hook app state")
struct PreSessionAppStateTests {

    /// Build an isolated AppState (never `UserDefaults.standard` — that's the
    /// developer's real TBDApp.plist) and tear the suite down afterward.
    private func withAppState(_ body: (AppState) throws -> Void) rethrows {
        let suiteName = "PreSessionAppStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(AppState(userDefaults: defaults))
    }

    private func makeTerminal(
        id: UUID = UUID(), worktreeID: UUID, label: String, kind: TerminalKind
    ) -> Terminal {
        Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: "@w-\(id.uuidString.prefix(4))",
            tmuxPaneID: "%p-\(id.uuidString.prefix(4))",
            label: label,
            kind: kind
        )
    }

    /// Seed a worktree whose terminals are loaded with just the pre-session
    /// hook terminal and its tab (the state right after the daemon's early
    /// `.terminalCreated` broadcast was consumed).
    private func seedPreSessionOnly(_ state: AppState, worktreeID: UUID) -> Terminal {
        let pre = makeTerminal(worktreeID: worktreeID, label: AppState.preSessionTerminalLabel, kind: .shell)
        state.terminals[worktreeID] = [pre]
        state.tabs[worktreeID] = [Tab(id: pre.id, content: .terminal(terminalID: pre.id), label: nil)]
        return pre
    }

    private func makeWorktree(status: WorktreeStatus) -> Worktree {
        Worktree(
            repoID: UUID(), name: "acme", displayName: "acme",
            branch: "tbd/acme", path: "/tmp/acme", status: status,
            tmuxServer: "tbd-test"
        )
    }

    /// Seed a worktree row into app state (keyed by repoID, as
    /// `findWorktree(id:)` expects) so status-scoped gates can resolve it.
    @discardableResult
    private func seedWorktree(_ state: AppState, status: WorktreeStatus) -> Worktree {
        let wt = makeWorktree(status: status)
        state.worktrees[wt.repoID] = [wt]
        return wt
    }

    // MARK: - terminalCreated append + dedupe

    @Test func appendCreatedTerminalAppendsTerminalAndTab() {
        withAppState { state in
            let worktreeID = UUID()
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)
            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)

            state.appendCreatedTerminal(claude)

            #expect(state.terminals[worktreeID]?.map(\.id) == [pre.id, claude.id])
            #expect(state.tabs[worktreeID]?.map(\.id) == [pre.id, claude.id])
            #expect(state.tabs[worktreeID]?.last?.content == .terminal(terminalID: claude.id))
        }
    }

    @Test func appendCreatedTerminalDedupesAfterDirectAppend() {
        withAppState { state in
            let worktreeID = UUID()
            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)
            // Direct-append path (createTerminal RPC response) landed first.
            state.terminals[worktreeID] = [claude]
            state.tabs[worktreeID] = [Tab(id: claude.id, content: .terminal(terminalID: claude.id), label: nil)]

            // The racing delta-driven append must be a no-op.
            state.appendCreatedTerminal(claude)

            #expect(state.terminals[worktreeID]?.count == 1)
            #expect(state.tabs[worktreeID]?.count == 1)
        }
    }

    @Test func terminalCreatedDeltaForKnownTerminalIsSynchronousNoOp() {
        withAppState { state in
            let worktreeID = UUID()
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)

            // Routed through the real delta switch; the dedupe fast path is
            // synchronous, so no daemon fetch fires and nothing duplicates.
            state.handleDelta(.terminalCreated(TerminalDelta(
                terminalID: pre.id, worktreeID: worktreeID, label: pre.label
            )))

            #expect(state.terminals[worktreeID]?.count == 1)
            #expect(state.tabs[worktreeID]?.count == 1)
        }
    }

    @Test func appendCreatedTerminalSkipsTabWhenTerminalLivesInASplitLayout() {
        withAppState { state in
            let worktreeID = UUID()
            let rootID = UUID()
            let splitChild = makeTerminal(worktreeID: worktreeID, label: "shell", kind: .shell)
            state.terminals[worktreeID] = []
            state.tabs[worktreeID] = [Tab(id: rootID, content: .terminal(terminalID: rootID), label: nil)]
            state.layouts[rootID] = .split(
                direction: .horizontal,
                children: [
                    .pane(.terminal(terminalID: rootID)),
                    .pane(.terminal(terminalID: splitChild.id)),
                ],
                ratios: [0.5, 0.5]
            )

            state.appendCreatedTerminal(splitChild)

            #expect(state.terminals[worktreeID]?.map(\.id) == [splitChild.id])
            // No new tab: the terminal is already represented inside a layout.
            #expect(state.tabs[worktreeID]?.map(\.id) == [rootID])
        }
    }

    // MARK: - Selection hand-off

    @Test func selectionSwitchesFromPreSessionTabToNewClaudeTab() {
        withAppState { state in
            let worktreeID = UUID()
            _ = seedPreSessionOnly(state, worktreeID: worktreeID)
            // Unset index defaults to 0 at the view layer = the pre-session tab.
            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)

            state.appendCreatedTerminal(claude)

            #expect(state.activeTabIndices[worktreeID] == 1)
            #expect(state.tabs[worktreeID]?[1].id == claude.id)
        }
    }

    @Test func selectionDoesNotSwitchWhenUserIsOnADifferentTab() {
        withAppState { state in
            let worktreeID = UUID()
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)
            let shell = makeTerminal(worktreeID: worktreeID, label: "shell", kind: .shell)
            state.terminals[worktreeID] = [pre, shell]
            state.tabs[worktreeID]?.append(Tab(id: shell.id, content: .terminal(terminalID: shell.id), label: nil))
            // User deliberately navigated to the plain shell tab.
            state.activeTabIndices[worktreeID] = 1

            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)
            state.appendCreatedTerminal(claude)

            #expect(state.activeTabIndices[worktreeID] == 1)
        }
    }

    @Test func setupShellTerminalDoesNotStealSelectionFromPreSessionTab() {
        withAppState { state in
            let worktreeID = UUID()
            _ = seedPreSessionOnly(state, worktreeID: worktreeID)

            // Phase 3 also broadcasts the parallel `setup` hook terminal —
            // it must never steal the selection.
            let setup = makeTerminal(worktreeID: worktreeID, label: "setup", kind: .shell)
            state.appendCreatedTerminal(setup)

            #expect(state.activeTabIndices[worktreeID] == nil)
        }
    }

    @Test func shellPrimaryTerminalTakesSelectionFromPreSessionTab() {
        withAppState { state in
            let worktreeID = UUID()
            _ = seedPreSessionOnly(state, worktreeID: worktreeID)

            // skipClaude worktrees spawn a plain shell as the PRIMARY terminal
            // (label "shell", kind .shell) — it must take the hand-off exactly
            // like an agent terminal would.
            let shell = makeTerminal(worktreeID: worktreeID, label: "shell", kind: .shell)
            state.appendCreatedTerminal(shell)

            #expect(state.activeTabIndices[worktreeID] == 1)
            #expect(state.tabs[worktreeID]?[1].id == shell.id)
        }
    }

    @Test func codexTerminalAlsoTakesSelectionFromPreSessionTab() {
        withAppState { state in
            let worktreeID = UUID()
            _ = seedPreSessionOnly(state, worktreeID: worktreeID)
            let codex = makeTerminal(worktreeID: worktreeID, label: "Codex", kind: .codex)

            state.appendCreatedTerminal(codex)

            #expect(state.activeTabIndices[worktreeID] == 1)
        }
    }

    // MARK: - Tab order convergence with the daemon's persisted order

    @Test func tabOrderConvergesToDaemonPersistedOrderAfterPrimaryDelta() {
        withAppState { state in
            // The reconcile gate is scoped to the creation phase: the
            // worktree must be known to app state and still `.creating`.
            let worktreeID = seedWorktree(state, status: .creating).id
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)
            // The full refresh triggered by the pre-session terminal's delta
            // cached the daemon's phase-1 order: just the pre-session tab.
            state.worktreeTabOrders[worktreeID] = [pre.id]

            // Phase-3 deltas land: primary agent, then the parallel setup shell.
            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)
            let setup = makeTerminal(worktreeID: worktreeID, label: "setup", kind: .shell)
            state.appendCreatedTerminal(claude)
            state.appendCreatedTerminal(setup)

            // Plain appends leave the diverged [preSession, primary, setup]…
            #expect(state.tabs[worktreeID]?.map(\.id) == [pre.id, claude.id, setup.id])
            // …and the primary append arms the re-fetch.
            #expect(state.shouldReconcileTabOrderFromDaemon(after: claude))

            // The re-fetch lands the daemon's persisted [primary, preSession, setup].
            state.adoptPersistedTabOrder(worktreeID: worktreeID, order: [claude.id, pre.id, setup.id])

            #expect(state.tabs[worktreeID]?.map(\.id) == [claude.id, pre.id, setup.id])
            #expect(state.worktreeTabOrders[worktreeID] == [claude.id, pre.id, setup.id])
            // The selection hand-off survives the re-sort: still on the primary.
            #expect(state.activeTabIndices[worktreeID] == 0)
        }
    }

    @Test func adoptPersistedTabOrderFollowsDeliberateUserSelectionByID() {
        withAppState { state in
            let worktreeID = UUID()
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)
            state.worktreeTabOrders[worktreeID] = [pre.id]
            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)
            state.appendCreatedTerminal(claude)
            // User deliberately clicked back to the pre-session tab before
            // the order re-fetch landed.
            state.activeTabIndices[worktreeID] = 0

            state.adoptPersistedTabOrder(worktreeID: worktreeID, order: [claude.id, pre.id])

            #expect(state.tabs[worktreeID]?.map(\.id) == [claude.id, pre.id])
            // Selection follows the pre-session tab to its new index.
            #expect(state.activeTabIndices[worktreeID] == 1)
        }
    }

    @Test func adoptPersistedTabOrderIgnoresEmptyOrder() {
        withAppState { state in
            let worktreeID = UUID()
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)
            state.worktreeTabOrders[worktreeID] = [pre.id]

            state.adoptPersistedTabOrder(worktreeID: worktreeID, order: [])

            // Nothing persisted daemon-side — keep the cached order and tabs.
            #expect(state.worktreeTabOrders[worktreeID] == [pre.id])
            #expect(state.tabs[worktreeID]?.map(\.id) == [pre.id])
        }
    }

    // MARK: - Re-fetch gate branches

    @Test func reconcileGateArmsForPrimaryMissingFromCachedOrder() {
        withAppState { state in
            let worktreeID = seedWorktree(state, status: .creating).id
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)
            state.worktreeTabOrders[worktreeID] = [pre.id]
            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)
            #expect(state.shouldReconcileTabOrderFromDaemon(after: claude))
            // Order not loaded at all yet counts as stale too.
            state.worktreeTabOrders[worktreeID] = nil
            #expect(state.shouldReconcileTabOrderFromDaemon(after: claude))
            // Codex is also a primary.
            let codex = makeTerminal(worktreeID: worktreeID, label: "Codex", kind: .codex)
            #expect(state.shouldReconcileTabOrderFromDaemon(after: codex))
        }
    }

    @Test func reconcileGateArmsForShellPrimaryWhenSkipClaude() {
        withAppState { state in
            let worktreeID = seedWorktree(state, status: .creating).id
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)
            state.worktreeTabOrders[worktreeID] = [pre.id]
            // skipClaude primary: kind .shell, label "shell" — still a primary,
            // so the converging-from-creation re-fetch must arm.
            let shell = makeTerminal(worktreeID: worktreeID, label: "shell", kind: .shell)
            #expect(state.shouldReconcileTabOrderFromDaemon(after: shell))
        }
    }

    @Test func reconcileGateStaysOffForNonPrimaryTerminals() {
        withAppState { state in
            let worktreeID = seedWorktree(state, status: .creating).id
            _ = seedPreSessionOnly(state, worktreeID: worktreeID)
            let setup = makeTerminal(worktreeID: worktreeID, label: "setup", kind: .shell)
            #expect(!state.shouldReconcileTabOrderFromDaemon(after: setup))
        }
    }

    @Test func reconcileGateStaysOffWithoutPreSessionTerminal() {
        withAppState { state in
            // Worktree seeded as .creating so the missing pre-session
            // terminal is the only conjunct that can turn the gate off.
            let worktreeID = seedWorktree(state, status: .creating).id
            state.terminals[worktreeID] = []
            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)
            #expect(!state.shouldReconcileTabOrderFromDaemon(after: claude))
        }
    }

    @Test func reconcileGateStaysOffWhenCachedOrderAlreadyContainsPrimary() {
        withAppState { state in
            let worktreeID = seedWorktree(state, status: .creating).id
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)
            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)
            state.worktreeTabOrders[worktreeID] = [claude.id, pre.id]
            #expect(!state.shouldReconcileTabOrderFromDaemon(after: claude))
        }
    }

    @Test func reconcileGateStaysOffOnceWorktreeIsActive() {
        withAppState { state in
            // Same shape as the arming case — primary delta, pre-session tab
            // present, primary missing from the cached order — but the
            // worktree already finished creating. A pre-session tab the user
            // kept around must not re-arm the reconcile for terminals
            // created after setup.
            let worktreeID = seedWorktree(state, status: .active).id
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)
            state.worktreeTabOrders[worktreeID] = [pre.id]
            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)
            #expect(!state.shouldReconcileTabOrderFromDaemon(after: claude))
        }
    }

    @Test func reconcileGateStaysOffWhenWorktreeNotInState() {
        withAppState { state in
            // No worktree row seeded at all — the gate must resolve the
            // worktree before trusting any other conjunct.
            let worktreeID = UUID()
            let pre = seedPreSessionOnly(state, worktreeID: worktreeID)
            state.worktreeTabOrders[worktreeID] = [pre.id]
            let claude = makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude)
            #expect(!state.shouldReconcileTabOrderFromDaemon(after: claude))
        }
    }

    // MARK: - Sidebar subtitle

    @Test func hasPreSessionTerminalTrueWhenHookTerminalLoaded() {
        withAppState { state in
            let worktreeID = UUID()
            _ = seedPreSessionOnly(state, worktreeID: worktreeID)
            #expect(state.hasPreSessionTerminal(worktreeID: worktreeID))
        }
    }

    @Test func hasPreSessionTerminalFalseWithoutHookTerminal() {
        withAppState { state in
            let worktreeID = UUID()
            // Not loaded at all.
            #expect(!state.hasPreSessionTerminal(worktreeID: worktreeID))
            // Loaded, but only ordinary terminals.
            state.terminals[worktreeID] = [
                makeTerminal(worktreeID: worktreeID, label: "Claude Code", kind: .claude),
            ]
            #expect(!state.hasPreSessionTerminal(worktreeID: worktreeID))
        }
    }

    @Test func creatingSubtitleCoversBothBranches() {
        #expect(WorktreeRowView.creatingSubtitle(hasPreSessionTerminal: true) == "Running setup…")
        #expect(WorktreeRowView.creatingSubtitle(hasPreSessionTerminal: false) == "Creating worktree…")
    }

    // MARK: - Banner gating

    @Test func bannerShowsWhileCreatingWithPreSessionTabActive() {
        withAppState { state in
            let worktree = makeWorktree(status: .creating)
            _ = seedPreSessionOnly(state, worktreeID: worktree.id)
            // Unset index defaults to 0 = the pre-session tab.
            #expect(state.showsPreSessionBanner(for: worktree))
        }
    }

    @Test func bannerHiddenOnceWorktreeIsActive() {
        withAppState { state in
            let worktree = makeWorktree(status: .active)
            _ = seedPreSessionOnly(state, worktreeID: worktree.id)
            #expect(!state.showsPreSessionBanner(for: worktree))
        }
    }

    @Test func bannerHiddenWhenADifferentTabIsActive() {
        withAppState { state in
            let worktree = makeWorktree(status: .creating)
            let pre = seedPreSessionOnly(state, worktreeID: worktree.id)
            let claude = makeTerminal(worktreeID: worktree.id, label: "Claude Code", kind: .claude)
            state.terminals[worktree.id] = [pre, claude]
            state.tabs[worktree.id]?.append(Tab(id: claude.id, content: .terminal(terminalID: claude.id), label: nil))
            state.activeTabIndices[worktree.id] = 1
            #expect(!state.showsPreSessionBanner(for: worktree))
        }
    }

    @Test func bannerHiddenWhenNoTabsExist() {
        withAppState { state in
            let worktree = makeWorktree(status: .creating)
            #expect(!state.showsPreSessionBanner(for: worktree))
        }
    }
}
