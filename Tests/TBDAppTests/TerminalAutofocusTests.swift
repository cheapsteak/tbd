import Foundation
import Testing

@testable import TBDApp

@MainActor
@Suite("Terminal autofocus")
struct TerminalAutofocusTests {
    @Test func activeTerminalInSelectedWorktreeIsFocusTarget() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        let tabID = UUID()

        state.tabs[worktreeID] = [
            Tab(id: tabID, content: .terminal(terminalID: terminalID), label: nil),
        ]
        state.activeTabIndices[worktreeID] = 0

        #expect(state.terminalIDForAutofocus(worktreeID: worktreeID) == terminalID)
    }

    @Test func activeTabLayoutChoosesFirstVisibleTerminal() {
        let state = AppState()
        let worktreeID = UUID()
        let firstTerminalID = UUID()
        let secondTerminalID = UUID()
        let tabID = UUID()

        state.tabs[worktreeID] = [
            Tab(id: tabID, content: .note(noteID: UUID()), label: nil),
        ]
        state.layouts[tabID] = .split(
            direction: .horizontal,
            children: [
                .pane(.codeViewer(id: UUID(), path: "/tmp/file.swift")),
                .pane(.terminal(terminalID: firstTerminalID)),
                .pane(.terminal(terminalID: secondTerminalID)),
            ],
            ratios: [0.3, 0.35, 0.35]
        )

        #expect(state.terminalIDForAutofocus(worktreeID: worktreeID) == firstTerminalID)
    }

    @Test func historyViewDoesNotStealFocus() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        let tabID = UUID()

        state.tabs[worktreeID] = [
            Tab(id: tabID, content: .terminal(terminalID: terminalID), label: nil),
        ]
        state.historyActiveWorktrees.insert(worktreeID)

        #expect(state.terminalIDForAutofocus(worktreeID: worktreeID) == nil)
    }

    @Test func nonTerminalActiveTabDoesNotAutofocusTerminal() {
        let state = AppState()
        let worktreeID = UUID()
        let tabID = UUID()

        state.tabs[worktreeID] = [
            Tab(id: tabID, content: .note(noteID: UUID()), label: nil),
        ]

        #expect(state.terminalIDForAutofocus(worktreeID: worktreeID) == nil)
    }
}
