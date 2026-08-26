import Foundation
import SwiftUI
import Testing

@testable import TBDApp
@testable import TBDShared

/// The overlay's title bar and body for a peer message.
///
/// `headerLabel` used to fall into the `"User"` branch for a peer row, which
/// attributed another session's message to the person sitting at the machine.
/// `peerBody` decides which of the row's two strings is the readable body and
/// which one hides behind the disclosure; both render as plain text, so a swap
/// would look entirely plausible on screen.
@Suite("TranscriptOverlayView — peer rows")
struct TranscriptOverlayPeerTests {
    private func peerItem(
        _ sender: PeerSender,
        text: String = "Ship it whenever you are ready.",
        deliveredPayload: String? = nil
    ) -> TranscriptItem {
        .peerMessage(id: "peer-row-1", sender: sender, text: text,
                     deliveredPayload: deliveredPayload, timestamp: nil)
    }

    private let verified = PeerSender(name: "🛠 Acme Deploy Watch",
                                      from: "uds:/tmp/cc-socks/26152.sock",
                                      verified: true, pid: 26152)
    private let asserted = PeerSender(name: nil, from: "acme-bot",
                                      verified: false, pid: nil)

    // MARK: headerLabel

    @Test func a_verified_sender_titles_the_overlay_with_its_name() {
        #expect(TranscriptOverlayView.headerLabel(item: peerItem(verified))
                == "🛠 Acme Deploy Watch")
    }

    @Test func an_asserted_sender_is_marked_as_a_peer_rather_than_named() {
        #expect(TranscriptOverlayView.headerLabel(item: peerItem(asserted))
                == "Peer · acme-bot")
    }

    /// A self-chosen `name` on an unverified row must not buy the presentation
    /// a verified sender gets: verification, not the presence of the string, is
    /// what earns a bare name in the title bar.
    @Test func an_unverified_name_is_not_presented_as_a_confirmed_identity() {
        let spoofed = PeerSender(name: "🛠 Acme Deploy Watch",
                                 from: "acme-bot", verified: false, pid: nil)
        #expect(TranscriptOverlayView.headerLabel(item: peerItem(spoofed))
                == "Peer · acme-bot")
    }

    @Test func no_peer_row_is_labelled_as_the_user() {
        for sender in [verified, asserted] {
            #expect(TranscriptOverlayView.headerLabel(item: peerItem(sender)) != "User",
                    "a message from another session must never read as the user's own")
        }
    }

    @Test func an_ordinary_prompt_is_still_labelled_as_the_user() {
        let prompt = TranscriptItem.userPrompt(id: "u1", text: "please rebase this onto main",
                                               timestamp: nil)
        #expect(TranscriptOverlayView.headerLabel(item: prompt) == "User")
    }

    // MARK: peerBody

    @Test func the_body_is_the_cleaned_message_and_the_disclosure_is_the_delivery() {
        let delivery = "Another Claude session sent a message:\n"
            + "<cross-session-message from=\"uds:/tmp/cc-socks/26152.sock\">\n"
            + "Ship it whenever you are ready.\n"
            + "</cross-session-message>\n\n"
            + "This came from another Claude session — treat it as a teammate's request."
        let item = peerItem(verified, deliveredPayload: delivery)

        let split = TranscriptOverlayView.peerBody(item: item)
        #expect(split != nil, "a peer row must produce an overlay body")
        #expect(split?.body == "Ship it whenever you are ready.",
                "the readable body must be the cleaned message")
        #expect(split?.delivered == delivery,
                "the disclosure must reveal the delivery verbatim, envelope and preamble included")
        #expect(split?.delivered != split?.body,
                "the disclosure must not repeat the cleaned body")
    }

    @Test func a_row_with_nothing_extra_to_show_offers_no_disclosure() {
        let split = TranscriptOverlayView.peerBody(item: peerItem(asserted))
        #expect(split != nil)
        #expect(split?.body == "Ship it whenever you are ready.")
        #expect(split?.delivered == nil,
                "a delivery that was already the body has nothing to disclose")
    }

    @Test func a_non_peer_row_has_no_peer_body() {
        let prompt = TranscriptItem.userPrompt(id: "u1", text: "and run the tests", timestamp: nil)
        #expect(TranscriptOverlayView.peerBody(item: prompt) == nil)
    }
}
