import Foundation
import Testing
@testable import TBDApp
import TBDShared

@MainActor
@Suite("AppState terminal reconciliation")
struct AppStateTerminalReconciliationTests {
    @Test func reconcileTabsPrunesForeignTerminalFromPersistedSplitLayout() {
        let state = AppState()
        let worktreeID = UUID()
        let localID = UUID()
        let foreignID = UUID()
        let localTerminal = Terminal(
            id: localID,
            worktreeID: worktreeID,
            tmuxWindowID: "@local",
            tmuxPaneID: "%local",
            label: "Claude Code",
            kind: .claude
        )
        state.tabs[worktreeID] = [
            Tab(id: localID, content: .terminal(terminalID: localID), label: nil),
        ]
        state.layouts[localID] = .split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: localID)),
                .pane(.terminal(terminalID: foreignID)),
            ],
            ratios: [0.5, 0.5]
        )

        state.reconcileTabs(worktreeID: worktreeID, terminals: [localTerminal])

        #expect(state.layouts[localID] == .pane(.terminal(terminalID: localID)))
        #expect(state.tabs[worktreeID]?.map(\.id) == [localID])
    }

    @Test func reconcileTabsDoesNotLetForeignLayoutPaneMaskLocalTerminalNeedingATab() {
        let state = AppState()
        let worktreeID = UUID()
        let staleTabID = UUID()
        let localID = UUID()
        let foreignID = UUID()
        let localTerminal = Terminal(
            id: localID,
            worktreeID: worktreeID,
            tmuxWindowID: "@local",
            tmuxPaneID: "%local",
            label: "Codex",
            kind: .codex
        )
        state.tabs[worktreeID] = [
            Tab(id: staleTabID, content: .codeViewer(id: staleTabID, path: "/tmp/file.swift"), label: "file.swift"),
        ]
        state.layouts[staleTabID] = .pane(.terminal(terminalID: foreignID))

        state.reconcileTabs(worktreeID: worktreeID, terminals: [localTerminal])

        #expect(state.layouts[staleTabID] == nil)
        #expect(state.tabs[worktreeID]?.map(\.content) == [
            .codeViewer(id: staleTabID, path: "/tmp/file.swift"),
            .terminal(terminalID: localID),
        ])
        #expect(state.tabs[worktreeID]?.last?.label == "Codex")
    }

    @Test func reconcileTabsKeepsNonTerminalPanesWhilePruningForeignTerminalChildren() {
        let state = AppState()
        let worktreeID = UUID()
        let tabID = UUID()
        let localID = UUID()
        let foreignID = UUID()
        let webID = UUID()
        let localTerminal = Terminal(
            id: localID,
            worktreeID: worktreeID,
            tmuxWindowID: "@local",
            tmuxPaneID: "%local",
            label: "shell",
            kind: .shell
        )
        state.tabs[worktreeID] = [
            Tab(id: tabID, content: .terminal(terminalID: localID), label: nil),
        ]
        state.layouts[tabID] = .split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: localID)),
                .pane(.webview(id: webID, url: URL(string: "https://example.com")!)),
                .pane(.terminal(terminalID: foreignID)),
            ],
            ratios: [0.25, 0.5, 0.25]
        )

        state.reconcileTabs(worktreeID: worktreeID, terminals: [localTerminal])

        #expect(state.layouts[tabID] == .split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: localID)),
                .pane(.webview(id: webID, url: URL(string: "https://example.com")!)),
            ],
            ratios: [1.0 / 3.0, 2.0 / 3.0]
        ))
    }
}
