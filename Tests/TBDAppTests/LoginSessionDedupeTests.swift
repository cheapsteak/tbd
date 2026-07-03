import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Unit tests for the "Open login session" duplicate guard: clicking the
/// button again while a live login session exists for the profile must focus
/// it instead of spawning another (`AppState.existingLoginSessionTerminal`).
@Suite("Login session dedupe")
struct LoginSessionDedupeTests {

    private func makeTerminal(
        worktreeID: UUID = UUID(),
        label: String? = TerminalLabel.login,
        profileID: UUID?,
        suspendedAt: Date? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: worktreeID,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: label,
            claudeSessionID: UUID().uuidString,
            suspendedAt: suspendedAt,
            profileID: profileID,
            kind: .claude
        )
    }

    @Test("finds a live login session for the profile across worktrees")
    func findsMatch() {
        let profileID = UUID()
        let wtA = UUID(), wtB = UUID()
        let match = makeTerminal(worktreeID: wtB, profileID: profileID)
        let terminals: [UUID: [Terminal]] = [
            wtA: [makeTerminal(worktreeID: wtA, label: TerminalLabel.claudeCode, profileID: nil)],
            wtB: [match],
        ]
        let found = AppState.existingLoginSessionTerminal(profileID: profileID, terminals: terminals)
        #expect(found?.id == match.id)
    }

    @Test("ignores login sessions pinned to a different profile")
    func ignoresOtherProfiles() {
        let terminals: [UUID: [Terminal]] = [
            UUID(): [makeTerminal(profileID: UUID())]
        ]
        #expect(AppState.existingLoginSessionTerminal(profileID: UUID(), terminals: terminals) == nil)
    }

    @Test("ignores plain Claude terminals on the same profile (not login sessions)")
    func ignoresNonLoginTerminals() {
        let profileID = UUID()
        let terminals: [UUID: [Terminal]] = [
            UUID(): [makeTerminal(label: TerminalLabel.claudeCode, profileID: profileID)]
        ]
        #expect(AppState.existingLoginSessionTerminal(profileID: profileID, terminals: terminals) == nil)
    }

    @Test("ignores suspended login sessions")
    func ignoresSuspended() {
        let profileID = UUID()
        let terminals: [UUID: [Terminal]] = [
            UUID(): [makeTerminal(profileID: profileID, suspendedAt: Date())]
        ]
        #expect(AppState.existingLoginSessionTerminal(profileID: profileID, terminals: terminals) == nil)
    }
}
