import Foundation
import Testing
@testable import TBDDaemonLib

/// `transcript read`'s stderr envelope, resolved against the contract's rules
/// (`docs/remote-provider-contract.md` § `transcript read <id> [--since <cursor>]`).
///
/// Tier 1: pure parsing, no IO.
@Suite("RemoteTranscriptEnvelope")
struct RemoteTranscriptEnvelopeTests {
    private func parse(_ stderr: String, since: Bool = true) -> RemoteTranscriptEnvelope {
        RemoteTranscriptEnvelope.parse(stderr: stderr, requestedSince: since)
    }

    @Test func cursorAloneIsAnAppendThatIsCaughtUp() {
        let envelope = parse(#"{"cursor": "c-2"}"#)
        #expect(envelope == RemoteTranscriptEnvelope(cursor: "c-2", reset: false, more: false, source: .envelope))
    }

    @Test func resetFlagIsCarried() {
        let envelope = parse(#"{"cursor": "c-2", "reset": true}"#)
        #expect(envelope.reset)
        #expect(envelope.cursor == "c-2")
        #expect(!envelope.more)
    }

    @Test func moreWithACursorAsksForTheNextPage() {
        let envelope = parse(#"{"cursor": "c-2", "more": true}"#)
        #expect(envelope.more)
        #expect(!envelope.reset)
    }

    @Test func explicitFalseFlagsReadAsFalse() {
        let envelope = parse(#"{"cursor": "c-2", "reset": false, "more": false}"#)
        #expect(!envelope.reset)
        #expect(!envelope.more)
        #expect(envelope.source == .envelope)
    }

    /// A provider without incremental support emits nothing: the output is the
    /// whole conversation, so it is a reset, with no cursor, and caught up.
    @Test func noEnvelopeIsAResetThatIsCaughtUp() {
        for stderr in ["", "\n", "warming up the transport\n"] {
            let envelope = parse(stderr)
            #expect(envelope == RemoteTranscriptEnvelope(cursor: nil, reset: true, more: false, source: .absent))
        }
    }

    /// A call without `--since` is a reset by definition, whatever the flag says.
    @Test func aCallWithoutSinceIsAlwaysAReset() {
        #expect(parse(#"{"cursor": "c-1"}"#, since: false).reset)
        #expect(parse(#"{"cursor": "c-1", "reset": false}"#, since: false).reset)
        #expect(!parse(#"{"cursor": "c-1"}"#, since: true).reset)
    }

    /// `more` requires a cursor; without one it reads as though absent.
    @Test func moreWithoutACursorIsIgnored() {
        let envelope = parse(#"{"more": true}"#)
        #expect(!envelope.more)
        #expect(envelope.cursor == nil)
        #expect(envelope.source == .envelope)
    }

    /// A malformed envelope — an object naming an envelope key that fails the
    /// strict decode — reads as no envelope: a whole-conversation reset.
    @Test(arguments: [
        #"{"cursor": 42}"#,             // cursor not a string
        #"{"cursor": "c-2", "more": 1}"#, // flag not a boolean
        #"{"reset": "yes"}"#,
    ])
    func malformedEnvelopeReadsAsNoEnvelope(stderr: String) {
        let envelope = parse(stderr)
        #expect(envelope == RemoteTranscriptEnvelope(cursor: nil, reset: true, more: false, source: .malformed))
    }

    /// Diagnostics may sit beside the envelope; the envelope is the last line
    /// that is a JSON object naming one of its keys.
    @Test func envelopeIsFoundAmongDiagnostics() {
        let stderr = """
            connecting to acme-prod
            {"level": "info", "msg": "paging"}
            {"cursor": "c-9", "more": true}
            done

            """
        let envelope = parse(stderr)
        #expect(envelope == RemoteTranscriptEnvelope(cursor: "c-9", reset: false, more: true, source: .envelope))
    }

    /// A `{`-prefixed line that is not valid JSON is a diagnostic, not an
    /// envelope: it is passed over, so it cannot hide the envelope before it.
    @Test func aNonJSONBraceLineAfterTheEnvelopeKeepsTheCursor() {
        let stderr = """
            {"cursor": "c-9", "more": true}
            {retrying transport: connection reset}

            """
        let envelope = parse(stderr)
        #expect(envelope == RemoteTranscriptEnvelope(cursor: "c-9", reset: false, more: true, source: .envelope))
    }

    /// Alone, a line that is not valid JSON leaves no envelope at all.
    @Test func truncatedJSONAloneIsNoEnvelope() {
        let envelope = parse(#"{"cursor": "c-2""#)
        #expect(envelope == RemoteTranscriptEnvelope(cursor: nil, reset: true, more: false, source: .absent))
    }

    /// A structured log line alone is not an envelope.
    @Test func aJSONLogLineIsNotAnEnvelope() {
        let envelope = parse(#"{"level": "info", "msg": "hello"}"#)
        #expect(envelope.source == .absent)
        #expect(envelope.reset)
    }

    /// Cursors are opaque: passed through byte for byte.
    @Test func cursorIsPassedThroughVerbatim() throws {
        let cursor = "  a/b?c=d&e 😀 "
        let json = try #require(String(data: try JSONEncoder().encode(["cursor": cursor]), encoding: .utf8))
        #expect(parse(json).cursor == cursor)
    }
}
