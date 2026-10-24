import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("HibernationSafetyChecks")
struct HibernationSafetyChecksTests {

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
