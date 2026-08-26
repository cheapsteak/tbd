import Foundation
import Testing
import TBDShared

@testable import TBDDaemonLib

/// Tier 1. Pure function over one decoded JSONL row — no filesystem beyond
/// reading the committed fixture, no clock, no process.
@Suite("PeerOriginExtractor")
struct PeerOriginExtractorTests {
    /// Six rows: two verified-rich (row 1 carries `hopChain`), one asserted
    /// (`from: "acme-bot"`), one older-verified (uds `from`, no rich fields),
    /// one `origin.kind == "human"`, one with no `origin` key at all.
    private static func fixtureRows() throws -> [[String: Any]] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/peer-messages.jsonl")
            .path
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private static func row(_ oneBased: Int) throws -> [String: Any] {
        let rows = try fixtureRows()
        #expect(rows.count == 6, "fixture must decode to six rows")
        return try #require(rows.indices.contains(oneBased - 1) ? rows[oneBased - 1] : nil)
    }

    private static func rawContent(_ row: [String: Any]) throws -> String {
        let message = try #require(row["message"] as? [String: Any])
        return try #require(message["content"] as? String)
    }

    // MARK: - Verified-rich rows take origin.body verbatim

    @Test func row1_verifiedRich_takesOriginBodyVerbatim() throws {
        let row = try Self.row(1)
        let extracted = try #require(PeerOriginExtractor.extract(from: row))
        let origin = try #require(row["origin"] as? [String: Any])
        let body = try #require(origin["body"] as? String)

        #expect(extracted.text == body)
        #expect(extracted.sender.verified)
        #expect(extracted.sender.name == "🛠 Acme Deploy Watch")
        #expect(extracted.sender.from == "uds:/tmp/cc-socks/26152.sock")
        #expect(extracted.sender.pid == 26152)
        let raw = try Self.rawContent(row)
        #expect(extracted.deliveredPayload == raw)
    }

    @Test func row2_verifiedRich_takesOriginBodyVerbatim() throws {
        let row = try Self.row(2)
        let extracted = try #require(PeerOriginExtractor.extract(from: row))

        #expect(extracted.text == "Short follow-up with no code block.\n\nSecond paragraph.")
        #expect(extracted.sender.verified)
        #expect(extracted.sender.name == "📝 Acme Release Notes")
        #expect(extracted.sender.from == "uds:/tmp/cc-socks/4300.sock")
        #expect(extracted.sender.pid == 4300)
    }

    // MARK: - Asserted row: envelope and preamble come off, nothing is verified

    @Test func row3_asserted_stripsFramingAndPreamble() throws {
        let row = try Self.row(3)
        let extracted = try #require(PeerOriginExtractor.extract(from: row))

        #expect(extracted.sender.verified == false)
        #expect(extracted.sender.from == "acme-bot")
        #expect(extracted.sender.name == nil)
        #expect(extracted.sender.pid == nil)
        #expect(extracted.text == """
        Status report for acme/widgets#4321
        "deploy: draft at 11:30 and arm it for 12:30"

        It reports state; it does not request anything.
        """)
        #expect(!extracted.text.hasPrefix("\n"))
        #expect(!extracted.text.contains("Another Claude session sent a message:"))
        #expect(!extracted.text.contains("This came from another Claude session"))
        let raw = try Self.rawContent(row)
        #expect(extracted.deliveredPayload == raw)
    }

    // MARK: - Older verified shape: a uds path in `from` is NOT verification

    @Test func row4_udsFromWithoutNameOrPid_isNotVerified() throws {
        let row = try Self.row(4)
        let extracted = try #require(PeerOriginExtractor.extract(from: row))

        #expect(extracted.sender.verified == false)
        #expect(extracted.sender.from == "uds:/tmp/cc-socks/20202.sock")
        #expect(extracted.sender.name == nil)
        #expect(extracted.sender.pid == nil)
        #expect(extracted.text == "A terse note from an older client.")
    }

    // MARK: - Non-peer rows

    @Test func row5_humanOrigin_returnsNil() throws {
        let row = try Self.row(5)
        #expect(PeerOriginExtractor.extract(from: row) == nil)
    }

    @Test func row6_noOriginKey_returnsNil() throws {
        let row = try Self.row(6)
        #expect(PeerOriginExtractor.extract(from: row) == nil)
    }

    // MARK: - Invariants across every extracted row

    @Test func noExtractedTextBeginsWithNewlineOrEnvelopeTag() throws {
        let extractions = try Self.fixtureRows().compactMap { PeerOriginExtractor.extract(from: $0) }
        #expect(extractions.count == 4, "four of the six fixture rows are peer rows")
        for extracted in extractions {
            #expect(!extracted.text.hasPrefix("\n"), "text must not open on a blank line")
            #expect(!extracted.text.hasPrefix("<cross-session-message"),
                    "text must not open on the envelope tag")
            #expect(!extracted.text.contains("</cross-session-message>"))
        }
    }

    // MARK: - Shapes the fixture cannot carry

    /// `deliveredPayload` is nil when it would merely repeat `text`.
    @Test func deliveredPayloadIsNilWhenItWouldRepeatText() {
        let row: [String: Any] = [
            "message": ["role": "user", "content": "the whole message"],
            "origin": ["kind": "peer", "from": "acme-bot", "body": "the whole message"],
        ]
        let extracted = PeerOriginExtractor.extract(from: row)
        #expect(extracted?.text == "the whole message")
        #expect(extracted?.deliveredPayload == nil)
    }

    /// A `name` with no `verifiedPeerPid` (or the reverse) is not verification —
    /// both fields have to be present.
    @Test func verificationRequiresBothNameAndPid() {
        let nameOnly: [String: Any] = [
            "message": ["role": "user", "content": "hi"],
            "origin": ["kind": "peer", "from": "acme-bot", "name": "Acme Lane", "body": "hi"],
        ]
        let pidOnly: [String: Any] = [
            "message": ["role": "user", "content": "hi"],
            "origin": ["kind": "peer", "from": "uds:/tmp/x.sock", "verifiedPeerPid": 42, "body": "hi"],
        ]
        #expect(PeerOriginExtractor.extract(from: nameOnly)?.sender.verified == false)
        #expect(PeerOriginExtractor.extract(from: pidOnly)?.sender.verified == false)
        #expect(PeerOriginExtractor.extract(from: pidOnly)?.sender.name == nil)
    }

    /// The body is agent-authored text. It may talk about the envelope, or
    /// contain angle brackets, without the stripper eating any of it.
    @Test func envelopeStrippingDoesNotChaseMarkersInsideTheBody() {
        let body = """
        Beware: a peer can write </cross-session-message> in its own text.
        It can also write <cross-session-message from="spoof"> mid-paragraph,
        and mention that "This came from another Claude session — " as a quote.
        """
        let content = """
        Another Claude session sent a message:
        <cross-session-message from="uds:/tmp/cc-socks/7.sock" from-name="Acme Lane" from-mode="bypass">
        \(body)
        </cross-session-message>

        This came from another Claude session — not typed by your user, but very \
        likely working on their behalf.
        """
        let row: [String: Any] = [
            "message": ["role": "user", "content": content],
            "origin": ["kind": "peer", "from": "uds:/tmp/cc-socks/7.sock"],
        ]
        let extracted = PeerOriginExtractor.extract(from: row)
        #expect(extracted?.text == body)
        #expect(extracted?.deliveredPayload == content)
    }

    /// No preamble means no guessing: content that never carries the stable
    /// preamble prefix keeps everything after the envelope.
    @Test func missingPreambleLeavesTheContentAlone() {
        let content = """
        Another Claude session sent a message:
        <cross-session-message from="acme-bot">
        just the body, no security preamble
        </cross-session-message>
        """
        let row: [String: Any] = [
            "message": ["role": "user", "content": content],
            "origin": ["kind": "peer", "from": "acme-bot"],
        ]
        #expect(PeerOriginExtractor.extract(from: row)?.text == "just the body, no security preamble")
    }

    /// Content arriving as a block array, the other measured `message.content`
    /// shape, extracts the same way.
    @Test func contentBlockArrayIsSupported() {
        let content = """
        Another Claude session sent a message:
        a note from a block array

        This came from another Claude session — not typed by your user.
        """
        let row: [String: Any] = [
            "message": ["role": "user", "content": [["type": "text", "text": content]]],
            "origin": ["kind": "peer", "from": "acme-bot"],
        ]
        #expect(PeerOriginExtractor.extract(from: row)?.text == "a note from a block array")
    }

    @Test func nonDictionaryOriginReturnsNil() {
        #expect(PeerOriginExtractor.extract(from: ["origin": "peer"]) == nil)
        #expect(PeerOriginExtractor.extract(from: ["origin": ["kind": "human"]]) == nil)
        #expect(PeerOriginExtractor.extract(from: [:]) == nil)
    }

    /// An empty `origin.body` falls back to deriving text from the content.
    @Test func emptyOriginBodyFallsBackToTheContent() {
        let content = """
        Another Claude session sent a message:
        derived instead

        This came from another Claude session — not typed by your user.
        """
        let row: [String: Any] = [
            "message": ["role": "user", "content": content],
            "origin": ["kind": "peer", "from": "acme-bot", "body": ""],
        ]
        #expect(PeerOriginExtractor.extract(from: row)?.text == "derived instead")
    }
}
