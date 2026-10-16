import Foundation
import Testing

@testable import TBDShared

/// The one decision every path that would run `claude --resume` against an
/// existing row asks. The tab's kind decides; a session id on the row is
/// necessary and never sufficient.
@Suite("Claude resume decision")
struct ClaudeResumeDecisionTests {
    private static func row(
        kind: TerminalKind?, label: String? = nil, sessionID: String?
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1", label: label,
            claudeSessionID: sessionID, kind: kind)
    }

    @Test func aClaudeTabWithASessionResumesIt() {
        #expect(Self.row(kind: .claude, sessionID: "S").claudeResumeDecision
            == .resume(sessionID: "S"))
    }

    /// A row written before kinds existed reads as a Claude tab here, exactly
    /// as `isClaudeResumable` has always read it.
    @Test func aRowWithNoKindAndASessionResumesIt() {
        #expect(Self.row(kind: nil, sessionID: "S").claudeResumeDecision
            == .resume(sessionID: "S"))
    }

    @Test(arguments: [TerminalKind.claude, .shell, .codex, nil])
    func aRowWithNoSessionResumesNothing(kind: TerminalKind?) {
        #expect(Self.row(kind: kind, sessionID: nil).claudeResumeDecision == .noSession)
    }

    /// The case the decision exists for: `SessionStart` records an id onto a
    /// shell row whose hand-started Claude carries TBD's hook, and a resume of
    /// it would replace the tab's shell with a bare `claude --resume`.
    @Test func aShellTabCarryingASessionIsNotAClaudeTab() {
        let decision = Self.row(kind: .shell, sessionID: "S").claudeResumeDecision
        #expect(decision == .notAClaudeTab(.shell))
        #expect(decision.resumableSessionID == nil)
    }

    /// A Codex tab keeps its thread id in the same column; it is never a Claude
    /// session to resume, whichever of the two markers says it is Codex.
    @Test func aCodexTabIsNotAClaudeTab() {
        #expect(Self.row(kind: .codex, sessionID: "T").claudeResumeDecision
            == .notAClaudeTab(.codex))
        #expect(Self.row(kind: nil, label: TerminalLabel.codex, sessionID: "T")
            .claudeResumeDecision == .notAClaudeTab(.codex))
    }

    /// The decision and the predicate the app and the rest of the daemon read
    /// never disagree.
    @Test(arguments: [TerminalKind.claude, .shell, .codex, nil])
    func theDecisionAgreesWithIsClaudeResumable(kind: TerminalKind?) {
        for sessionID in [nil, "S"] as [String?] {
            let terminal = Self.row(kind: kind, sessionID: sessionID)
            #expect((terminal.claudeResumeDecision.resumableSessionID != nil)
                == terminal.isClaudeResumable)
        }
    }

    /// `isClaudeTab` reads the kind alone: a Claude row or a row with no
    /// recorded kind is a Claude tab, a shell or Codex row is not, and the
    /// session id never moves the answer.
    @Test(arguments: [
        (TerminalKind.claude as TerminalKind?, true),
        (nil, true),
        (.shell, false),
        (.codex, false),
    ])
    func isClaudeTabReadsTheKindAlone(kind: TerminalKind?, expected: Bool) {
        #expect(Self.row(kind: kind, sessionID: "S").isClaudeTab == expected)
        #expect(Self.row(kind: kind, sessionID: nil).isClaudeTab == expected)
    }

    /// A Codex label marks a Codex tab whatever the kind column says.
    @Test func aCodexLabelIsNeverAClaudeTab() {
        #expect(!Self.row(kind: nil, label: TerminalLabel.codex, sessionID: "T").isClaudeTab)
    }

    @Test func theRefusalIsOneLineNamingTheKind() {
        let reason = ClaudeResumeDecision.notAClaudeTabReason(.shell)
        #expect(!reason.contains("\n"))
        #expect(reason.contains("shell"))
    }
}
