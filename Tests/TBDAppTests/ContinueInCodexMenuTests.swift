import AppKit
import Foundation
import TBDShared
import Testing
@testable import TBDApp

@MainActor
@Suite("Continue in Codex UI placement")
struct ContinueInCodexMenuTests {
    private func terminal(kind: TerminalKind, sessionID: String? = nil) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            claudeSessionID: sessionID,
            kind: kind
        )
    }

    @Test func claudeTabShowsTakeoverImmediatelyAfterForkSession() {
        let actions = ClaudeTabSessionMenu.actions(
            for: terminal(kind: .claude, sessionID: "session-1")
        )

        #expect(actions == [.forkSession, .continueInCodex])
        #expect(actions.map(\.title) == ["Fork Session", "Continue in Codex"])
    }

    @Test func claudeActionsAreAbsentFromOtherTabs() {
        #expect(ClaudeTabSessionMenu.actions(for: terminal(kind: .codex)).isEmpty)
        #expect(ClaudeTabSessionMenu.actions(for: terminal(kind: .shell)).isEmpty)
        #expect(ClaudeTabSessionMenu.actions(for: nil).isEmpty)
    }

    @Test func addTabMenuStillOffersOrdinaryCodexCreation() throws {
        let coordinator = MenuCoordinator(
            onShell: {},
            onClaude: {},
            onClaudeProfile: { _ in },
            onCodex: {},
            onNote: {}
        )
        let menu = AddTabMenu.build(
            profiles: [],
            availability: .allAvailable,
            coordinator: coordinator
        )
        let codex = try #require(menu.items.first { $0.title == "Codex" })

        #expect(codex.action == #selector(MenuCoordinator.addCodex))
        #expect(codex.target as? MenuCoordinator === coordinator)
        #expect(menu.items.contains { $0.title == "Continue in Codex" } == false)
    }
}
