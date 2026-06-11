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
            // a plain shell must never steal the selection.
            let setup = makeTerminal(worktreeID: worktreeID, label: "setup", kind: .shell)
            state.appendCreatedTerminal(setup)

            #expect(state.activeTabIndices[worktreeID] == nil)
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
