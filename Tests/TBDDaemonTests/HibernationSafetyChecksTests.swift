import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("HibernationSafetyChecks")
struct HibernationSafetyChecksTests {

    // MARK: - Pending typed input

    @Test func emptyPromptIsSafe() {
        let capture = """
        ╭──────────────────────────────────────╮
        │ >                                    │
        ╰──────────────────────────────────────╯
        """
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: capture) == false)
    }

    @Test func placeholderPromptIsSafe() {
        let capture = """
        ╭──────────────────────────────────────╮
        │ > Try "fix the failing test"         │
        ╰──────────────────────────────────────╯
        """
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: capture) == false)
    }

    @Test func typedTextBlocksHibernation() {
        let capture = """
        some transcript output above
        ╭──────────────────────────────────────╮
        │ > refactor the auth module and add    │
        ╰──────────────────────────────────────╯
        """
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: capture) == true)
    }

    @Test func emptyCaptureIsSafe() {
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: "") == false)
    }

    @Test func plainPromptWithoutBoxWithText() {
        // A `>`-prefixed line without box drawing still counts.
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: "> hello world") == true)
    }

    // MARK: - Transcript tail validity

    @Test func validJSONTailPasses() {
        let body = #"""
        {"type":"user","text":"hi"}
        {"type":"assistant","text":"hello there"}
        """#
        #expect(HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) == true)
    }

    @Test func truncatedTailFails() {
        // Last line is a half-written JSON object — the #18880 corruption case.
        let body = #"""
        {"type":"user","text":"hi"}
        {"type":"assistant","text":"hel
        """#
        #expect(HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) == false)
    }

    @Test func emptyTranscriptIsValid() {
        #expect(HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: "") == true)
    }

    @Test func trailingNewlineIgnored() {
        let body = #"""
        {"type":"assistant","text":"done"}

        """#
        #expect(HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) == true)
    }
}
