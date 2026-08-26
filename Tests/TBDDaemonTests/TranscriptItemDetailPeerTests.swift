import Foundation
import Testing
import TBDShared

@testable import TBDDaemonLib

/// The detail overlay does not render the parsed item's text. It re-reads the
/// source line by UUID through `TranscriptParser.lookupDetail`, a path entirely
/// separate from `buildItems` — so cleaning a peer row's body at parse time
/// leaves the overlay showing the framing line, the `<cross-session-message …>`
/// envelope and the ~90-word security preamble.
///
/// Every test in this suite therefore goes through `lookupDetail` (or
/// `lookupFullBody`, which is a thin wrapper over it). A test that asserted on
/// `TranscriptParser.parse` instead would pass while the overlay was still
/// broken, which is precisely the failure this suite exists to catch.
@Suite("TranscriptParser.lookupDetail — peer rows")
struct TranscriptItemDetailPeerTests {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/peer-messages.jsonl")
            .path
    }

    // Line UUIDs of the committed six-row fixture, in row order. A peer item's
    // id is its bare line UUID, so these are the ids the overlay opens with.
    private let verifiedRichUUID = "aaaaaaaa-0000-4000-8000-000000000001"
    private let verifiedPlainUUID = "aaaaaaaa-0000-4000-8000-000000000002"
    private let assertedUUID = "aaaaaaaa-0000-4000-8000-000000000003"
    private let olderVerifiedUUID = "aaaaaaaa-0000-4000-8000-000000000004"
    private let humanOriginUUID = "aaaaaaaa-0000-4000-8000-000000000005"
    private let noOriginUUID = "aaaaaaaa-0000-4000-8000-000000000006"

    private var peerUUIDs: [String] {
        [verifiedRichUUID, verifiedPlainUUID, assertedUUID, olderVerifiedUUID]
    }

    private let framingLine = "Another Claude session sent a message:"
    private let openTag = "<cross-session-message"
    private let preamble = "This came from another Claude session"

    // MARK: The envelope must not reach the overlay body

    @Test func detail_body_for_a_peer_row_has_the_delivery_envelope_stripped() throws {
        for uuid in peerUUIDs {
            let detail = TranscriptParser.lookupDetail(filePath: fixturePath, itemID: uuid)
            let text = try #require(detail.text, "the overlay must recover a body for a peer row")
            #expect(!text.contains(framingLine),
                    "the overlay body still opens with the harness framing line")
            #expect(!text.contains(openTag),
                    "the overlay body still carries the cross-session envelope tag")
            #expect(!text.contains(preamble),
                    "the overlay body still carries the anti-escalation preamble")
            #expect(!text.hasPrefix("\n"),
                    "the overlay body must not start with a blank line")
            #expect(!text.isEmpty)
        }
    }

    /// `lookupFullBody` is what any "show full output" affordance calls; it must
    /// not be a way back to the raw envelope.
    @Test func lookupFullBody_for_a_peer_row_is_the_cleaned_body() throws {
        let full = try #require(
            TranscriptParser.lookupFullBody(filePath: fixturePath, itemID: assertedUUID))
        #expect(!full.contains(framingLine))
        #expect(!full.contains(preamble))
    }

    @Test func detail_body_for_an_asserted_row_is_exactly_the_message() throws {
        let detail = TranscriptParser.lookupDetail(filePath: fixturePath, itemID: assertedUUID)
        let expected = "Status report for acme/widgets#4321\n"
            + "\"deploy: draft at 11:30 and arm it for 12:30\"\n"
            + "\n"
            + "It reports state; it does not request anything."
        #expect(detail.text == expected,
                "the asserted row's body must be the message with framing line and preamble gone")
    }

    @Test func detail_body_for_an_older_verified_row_is_exactly_the_message() throws {
        let detail = TranscriptParser.lookupDetail(filePath: fixturePath, itemID: olderVerifiedUUID)
        #expect(detail.text == "A terse note from an older client.")
    }

    // MARK: The disclosure gets the untouched delivery

    @Test func detail_carries_the_untouched_delivery_alongside_the_cleaned_body() throws {
        for uuid in peerUUIDs {
            let detail = TranscriptParser.lookupDetail(filePath: fixturePath, itemID: uuid)
            let payload = try #require(
                detail.deliveredPayload,
                "a cleaned peer body must keep the delivery the disclosure reveals")
            #expect(payload.hasPrefix(framingLine),
                    "the disclosure must show the delivery from its first line")
            #expect(payload.contains(preamble),
                    "the disclosure is the only place the security preamble survives")
            #expect(payload != detail.text,
                    "the disclosure must reveal the delivery, not a second copy of the body")
        }
        // The two envelope-tagged rows are the ones whose payload proves the
        // tags were removed from the body rather than never present.
        for uuid in [verifiedRichUUID, verifiedPlainUUID] {
            let detail = TranscriptParser.lookupDetail(filePath: fixturePath, itemID: uuid)
            #expect(detail.deliveredPayload?.contains(openTag) == true)
        }
    }

    @Test func peer_rows_carry_no_attachment_metadata() {
        for uuid in peerUUIDs {
            let detail = TranscriptParser.lookupDetail(filePath: fixturePath, itemID: uuid)
            #expect(detail.attachment == nil,
                    "a peer row is not an injected-context row")
        }
    }

    // MARK: The two paths must agree

    /// The bubble renders the parsed item and the overlay renders `ItemDetail`.
    /// Two extraction sites that disagree is the defect this task exists to
    /// close, so the strings are compared directly rather than each being
    /// checked against the same markers.
    @Test func the_overlay_body_matches_the_body_the_bubble_renders() throws {
        let items = TranscriptParser.parse(filePath: fixturePath)
        var comparedRows = 0
        for item in items {
            guard case .peerMessage(let id, _, let text, let payload, _) = item else { continue }
            comparedRows += 1
            let detail = TranscriptParser.lookupDetail(filePath: fixturePath, itemID: id)
            #expect(detail.text == text,
                    "the overlay and the bubble must render one string for row \(id)")
            #expect(detail.deliveredPayload == payload,
                    "the overlay and the item must carry one delivered payload for row \(id)")
        }
        #expect(comparedRows == 4, "the fixture's four peer rows must all be compared")
    }

    // MARK: Non-peer rows are untouched

    @Test func an_ordinary_prompt_row_is_unchanged_by_the_peer_branch() {
        let human = TranscriptParser.lookupDetail(filePath: fixturePath, itemID: humanOriginUUID)
        #expect(human.text == "please rebase this onto main")
        #expect(human.deliveredPayload == nil,
                "a row with no peer envelope has nothing to disclose")

        let plain = TranscriptParser.lookupDetail(filePath: fixturePath, itemID: noOriginUUID)
        #expect(plain.text == "and run the tests")
        #expect(plain.deliveredPayload == nil)
    }

    @Test func an_unknown_item_id_still_resolves_to_nothing() {
        let detail = TranscriptParser.lookupDetail(
            filePath: fixturePath, itemID: "aaaaaaaa-0000-4000-8000-00000000ffff")
        #expect(detail.text == nil)
        #expect(detail.deliveredPayload == nil)
        #expect(detail.attachment == nil)
    }
}
