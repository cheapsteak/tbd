import Foundation
import Testing
@testable import TBDShared

/// The one rule the daemon and the app both read to answer "is this worktree's
/// primary agent still coming?" — the question a first message parked at
/// creation time turns on.
///
/// The pairs below are the whole point: `[preSession hook tab]` and
/// `[plain shell]` are both lists of shell-kind rows, and they want opposite
/// answers. Only the label separates them.
@Suite("PrimaryTerminal")
struct PrimaryTerminalTests {

    private func terminal(kind: TerminalKind?, label: String? = nil) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: label, kind: kind)
    }

    private var preSessionTab: Terminal {
        terminal(kind: .shell, label: TerminalLabel.preSession)
    }

    @Test("Nothing spawned yet: the primary is still coming")
    func emptyListIsStillComing() {
        #expect(PrimaryTerminal.spawnIsStillComing(terminals: []))
        #expect(PrimaryTerminal.agent(in: []) == nil)
    }

    @Test("A worktree behind its preSession hook is still coming")
    func preSessionHookTabIsStillComing() {
        // The hook tab exists before `worktree.create` returns and is the only
        // row until the hook exits; the primary agent spawns after it.
        #expect(PrimaryTerminal.spawnIsStillComing(terminals: [preSessionTab]))
        #expect(PrimaryTerminal.agent(in: [preSessionTab]) == nil)
    }

    @Test("A spawn that produced a plain shell is not still coming")
    func plainShellPrimaryIsNotStillComing() {
        #expect(PrimaryTerminal.spawnIsStillComing(terminals: [terminal(kind: .shell)]) == false)
        // A row with no kind recorded reads as a shell, and carries no label
        // either, so it is a spawn that happened.
        #expect(PrimaryTerminal.spawnIsStillComing(terminals: [terminal(kind: nil)]) == false)
    }

    @Test("A shell beside the hook tab means the spawn already happened")
    func hookTabPlusShellIsNotStillComing() {
        let terminals = [preSessionTab, terminal(kind: .shell)]
        #expect(PrimaryTerminal.spawnIsStillComing(terminals: terminals) == false)
        #expect(PrimaryTerminal.agent(in: terminals) == nil)
    }

    @Test("An agent row is an agent that arrived, not one still coming")
    func agentRowIsNotStillComing() {
        let terminals = [preSessionTab, terminal(kind: .claude)]
        #expect(PrimaryTerminal.spawnIsStillComing(terminals: terminals) == false)
        #expect(PrimaryTerminal.agent(in: terminals)?.kind == .claude)
    }

    @Test("The primary is the first agent-kind row, oldest-first")
    func primaryIsTheFirstAgentRow() {
        let shell = terminal(kind: .shell)
        let claude = terminal(kind: .claude)
        let codex = terminal(kind: .codex)
        // Shell tabs ahead of it do not make a worktree agentless: the daemon
        // picks the first non-shell row, not row zero.
        #expect(PrimaryTerminal.agent(in: [shell, claude, codex])?.id == claude.id)
        #expect(PrimaryTerminal.agent(in: [codex, claude])?.id == codex.id)
    }
}
