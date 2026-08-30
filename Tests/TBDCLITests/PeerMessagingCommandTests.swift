import Foundation
import Testing

@testable import TBDCLI

/// Tier 1. `tbd peer messaging on|off` — the only supported way to move
/// `remote_peer_messaging_enabled`, and therefore the answer to "how is this
/// feature enabled for its soak".
///
/// What it prints is asserted as composed output, for the reason
/// `ConfigCommandsTests` states: the failure worth guarding against is one
/// state's explanation being printed for both, and the user who just turned the
/// feature off is the one least able to catch it.
@Suite("tbd peer messaging")
struct PeerMessagingCommandTests {

    /// The whole message, both directions.
    @Test func bothDirectionsDescribeTheBranchTheyTook() {
        #expect(PeerMessaging.confirmation(value: .on) == """
            Set remote peer messaging to on (config remote_peer_messaging_enabled). \
            The gate is read when a provider's streams are armed, so a change made \
            since then takes effect at the next daemon restart.
            """)
        #expect(PeerMessaging.confirmation(value: .off) == """
            Set remote peer messaging to off (config remote_peer_messaging_enabled). \
            The gate is read when a provider's streams are armed, so a change made \
            since then takes effect at the next daemon restart.
            """)
    }

    /// The property behind the pinned strings: the two directions cannot report
    /// the same thing, and each names the state it was actually given.
    @Test func theTwoDirectionsCannotBeConfused() {
        let on = PeerMessaging.confirmation(value: .on)
        let off = PeerMessaging.confirmation(value: .off)
        #expect(on != off)
        #expect(on.contains("messaging to on"), on)
        #expect(off.contains("messaging to off"), off)
    }

    /// The restart caveat rides on both, because both are subject to it: the
    /// gate is read where a provider's streams are armed, so neither direction
    /// moves a bridge that is already running. A confirmation without it reads
    /// as "done" when nothing has changed yet.
    @Test func bothDirectionsCarryTheRestartCaveat() {
        #expect(PeerMessaging.confirmation(value: .on).contains(peerMessagingRestartCaveat))
        #expect(PeerMessaging.confirmation(value: .off).contains(peerMessagingRestartCaveat))
    }

    /// One phrasing, shared with `tbd peer list`. If the caveat is ever copied
    /// into a second wording, this and the listing's own warning drift apart —
    /// so the listing's gated-provider warning is asserted to be built from the
    /// same sentence.
    @Test func theCaveatIsTheOneTheListingUses() {
        #expect(peerMessagingRestartCaveat == """
            The gate is read when a provider's streams are armed, so a change made \
            since then takes effect at the next daemon restart.
            """)
    }

    /// Argument parsing: the command takes the same `on|off` word every other
    /// TBD toggle takes, and rejects anything else rather than guessing.
    @Test func parsesOnAndOffAndRejectsAnythingElse() throws {
        #expect(try PeerMessaging.parse(["on"]).value == .on)
        #expect(try PeerMessaging.parse(["off"]).value == .off)
        #expect(throws: (any Error).self) { _ = try PeerMessaging.parse(["maybe"]) }
    }
}
