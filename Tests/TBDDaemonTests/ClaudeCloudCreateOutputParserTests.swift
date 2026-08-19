import Foundation
import Testing
@testable import TBDDaemonLib

// Tier 1: pure string work.
@Suite("ClaudeCloudCreateOutputParser")
struct ClaudeCloudCreateOutputParserTests {
    /// The measured three-line success form (design §11).
    private let threeLines = """
        Created cloud session: Add probe pong reply
        View: https://claude.ai/code/session_01AAAAAAAAAAAAAAAAAAAAAA?from=cli&m=0
        Resume with: claude --teleport session_01AAAAAAAAAAAAAAAAAAAAAA
        """

    // MARK: - The id: strict, cross-checked, fails loudly

    @Test func theThreeLineSuccessFormYieldsTheSessionID() throws {
        #expect(try ClaudeCloudCreateOutputParser.sessionID(fromOutput: threeLines).get()
            == "session_01AAAAAAAAAAAAAAAAAAAAAA")
    }

    @Test func ansiControlSequencesAroundTheSameLinesYieldTheSameID() throws {
        let decorated = "\u{1B}[1mCreated cloud session: Add probe pong reply\u{1B}[0m\r\n"
            + "\u{1B}[2mView: https://claude.ai/code/session_01AAAAAAAAAAAAAAAAAAAAAA?from=cli\u{1B}[0m\r\n"
            + "\u{1B}]0;title\u{07}Resume with: claude --teleport session_01AAAAAAAAAAAAAAAAAAAAAA\r\n"
        #expect(try ClaudeCloudCreateOutputParser.sessionID(fromOutput: decorated).get()
            == "session_01AAAAAAAAAAAAAAAAAAAAAA")
    }

    @Test func noMatchIsAFailureRatherThanAnEmptyID() {
        #expect(
            ClaudeCloudCreateOutputParser.sessionID(
                fromOutput: "Error: --cloud requires an interactive terminal.")
                == .failure(.noSessionID))
    }

    @Test func emptyOutputIsAFailure() {
        #expect(ClaudeCloudCreateOutputParser.sessionID(fromOutput: "") == .failure(.noSessionID))
    }

    /// All three printed lines carry the id, so disagreement is a signal, not
    /// noise — the strict shape checked three times over is what lets an
    /// unreadable id fail loudly instead of costing the lane its identity.
    @Test func twoDistinctIDsAreAFailureNamingBoth() {
        let result = ClaudeCloudCreateOutputParser.sessionID(fromOutput: """
            Created cloud session: two
            View: https://claude.ai/code/session_01AAA?from=cli
            Resume with: claude --teleport session_01BBB
            """)
        #expect(result == .failure(.conflictingSessionIDs(["session_01AAA", "session_01BBB"])))
    }

    /// The bounded message quotes what the provider received, so a
    /// `contractBug` on screen names the evidence rather than a bare code.
    @Test func theFailureMessageQuotesTheReceivedTextAndIsBounded() {
        let message = ClaudeCloudCreateOutputParser.failureMessage(
            .noSessionID, received: String(repeating: "x", count: 5_000))
        #expect(message.contains("xxx"))
        #expect(message.count <= 600)
    }

    // MARK: - The title: lenient, uncross-checked, never fails a create

    @Test func theTitleIsTheFirstLineAfterItsPrefixTrimmed() {
        #expect(ClaudeCloudCreateOutputParser.title(fromOutput: threeLines)
            == "Add probe pong reply")
    }

    /// The pty reports 400 columns, but a child that formats to a narrower
    /// width would insert a REAL newline, so a wrapped title line must still
    /// read as one title rather than as a truncated one.
    @Test func aWrappedTitleLineIsRejoined() {
        let wrapped = "Created cloud session: Add probe pong\nreply\n"
            + "View: https://claude.ai/code/session_01AAA?from=cli\n"
            + "Resume with: claude --teleport session_01AAA"
        #expect(ClaudeCloudCreateOutputParser.title(fromOutput: wrapped)
            == "Add probe pong reply")
    }

    /// The three lenient cases are ONE outcome — take the fallback — not
    /// three to distinguish on screen.
    @Test func aMissingPrefixAMissingLineAndABlankRemainderAllYieldNil() {
        #expect(ClaudeCloudCreateOutputParser.title(fromOutput: """
            Started a cloud session: Add probe pong reply
            Resume with: claude --teleport session_01AAA
            """) == nil)
        #expect(ClaudeCloudCreateOutputParser.title(fromOutput: "") == nil)
        #expect(ClaudeCloudCreateOutputParser.title(fromOutput: "Created cloud session:    \n") == nil)
    }

    /// The two parses have deliberately opposite failure postures, and this
    /// is the pair that proves it: output whose title is unreadable still
    /// yields an id, so the create succeeds and the lane is named from its id.
    @Test func anUnreadableTitleStillYieldsAReadableID() throws {
        let output = """
            Something else entirely
            Resume with: claude --teleport session_01AAAAAAAAAAAAAAAAAAAAAA
            """
        #expect(ClaudeCloudCreateOutputParser.title(fromOutput: output) == nil)
        #expect(try ClaudeCloudCreateOutputParser.sessionID(fromOutput: output).get()
            == "session_01AAAAAAAAAAAAAAAAAAAAAA")
    }

    /// A pty's canonical line discipline emits `\r\n`, and `"\r\n"` is ONE
    /// `Character` in Swift — distinct from `"\n"` — so a naive
    /// `split(separator: "\n")` does not split this at all. Built by
    /// concatenation with explicit `\r\n`, not a triple-quoted literal:
    /// Swift's compiler normalizes triple-quoted literals to bare `\n`, which
    /// is exactly why the suite's other wrapped-title test could not have
    /// caught this — it structurally cannot construct CRLF.
    @Test func aWrappedTitleLineWithRealCRLFIsStillRejoinedCleanly() {
        let wrapped = "Created cloud session: Add probe pong\r\nreply\r\n"
            + "View: https://claude.ai/code/session_01AAA?from=cli\r\n"
            + "Resume with: claude --teleport session_01AAA\r\n"
        #expect(ClaudeCloudCreateOutputParser.title(fromOutput: wrapped)
            == "Add probe pong reply")
    }

    // MARK: - The title's three line-terminator branches, independently

    /// A blank line ends the title even with no trailing `View:`/`Resume
    /// with:` line to catch it.
    @Test func aBlankLineEndsTheTitle() {
        let output = "Created cloud session: Add probe pong reply\n\nignored trailer\n"
        #expect(ClaudeCloudCreateOutputParser.title(fromOutput: output)
            == "Add probe pong reply")
    }

    /// A `View:` line ends the title even with no blank line before it.
    @Test func aViewLineEndsTheTitle() {
        let output = "Created cloud session: Add probe pong reply\n"
            + "View: https://claude.ai/code/session_01AAA?from=cli\n"
        #expect(ClaudeCloudCreateOutputParser.title(fromOutput: output)
            == "Add probe pong reply")
    }

    /// A `Resume with:` line ends the title even with no `View:` line before
    /// it (the `--print`-refused form never omits `View:`, but the parser
    /// does not assume that — each terminator is checked independently).
    @Test func aResumeWithLineEndsTheTitle() {
        let output = "Created cloud session: Add probe pong reply\n"
            + "Resume with: claude --teleport session_01AAA\n"
        #expect(ClaudeCloudCreateOutputParser.title(fromOutput: output)
            == "Add probe pong reply")
    }
}
