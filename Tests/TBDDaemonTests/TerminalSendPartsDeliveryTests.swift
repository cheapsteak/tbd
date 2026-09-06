import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// What actually reaches the pane for a parts payload.
///
/// The ordering assertion is a documented contract, not an incident: the whole
/// reason parts exist is that Claude Code turns a paste into an image attachment
/// only when the WHOLE paste is one quoted path, so an image part pasted
/// together with its surrounding words silently becomes literal text.
@Suite("terminal.send parts delivery")
struct TerminalSendPartsDeliveryTests {

    // MARK: - The image paste

    @Test func anImagePartIsPastedAsABareQuotedPath() {
        #expect(RPCRouter.quotedImagePath("/tmp/a b.png") == "'/tmp/a b.png'")
        #expect(RPCRouter.quotedImagePath("/tmp/it's.png") == #"'/tmp/it'\''s.png'"#)
    }

    // MARK: - Ordering

    @Test func partsArePastedInOrderThenOneEnter() async throws {
        let harness = try await SendHarness.make()
        _ = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [
                .text("look at "),
                .imagePath("/tmp/a.png"),
                .text(" and tell me"),
            ]),
            actor: .app)

        // One envelope, on the first text part; the rest verbatim and in order.
        let bodies = harness.tmux.pastedBodies
        #expect(bodies.count == 3)
        #expect(try #require(bodies.first).hasSuffix("look at "))
        #expect(bodies[1] == "'/tmp/a.png'")
        #expect(bodies[2] == " and tell me")
        #expect(harness.tmux.sentKeys == ["Enter"])
    }

    @Test func emptyTextPartsAreSkipped() async throws {
        let harness = try await SendHarness.make()
        _ = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.text(""), .imagePath("/tmp/a.png"), .text("")]),
            actor: .app)

        // Nothing empty was pasted. The envelope has no text part to ride on
        // here, so it rides on nothing: an image part is NEVER prefixed.
        #expect(harness.tmux.pastedBodies == ["'/tmp/a.png'"])
        #expect(harness.tmux.sentKeys == ["Enter"])
    }

    /// One envelope for one message, on the FIRST text part — not one per paste,
    /// which would put a `<tbd-dispatch/>` line in the middle of a sentence.
    @Test func aPartsSendCarriesOneEnvelopeOnTheFirstPart() async throws {
        let harness = try await SendHarness.make()
        _ = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.text("first"), .text("second")]),
            actor: ActuationActor.session(worktree: "W", terminal: "T"))

        let bodies = harness.tmux.pastedBodies
        #expect(bodies.count == 2)
        #expect(bodies[0].hasPrefix("<tbd-dispatch"))
        #expect(bodies[0].hasSuffix("\nfirst"))
        #expect(bodies[1] == "second")
    }

    /// `submit: false` pastes and presses nothing — the same reading the single
    /// text arm gives it.
    @Test func anUnsubmittedPartsSendPressesNoEnter() async throws {
        let harness = try await SendHarness.make()
        _ = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: false,
            parts: [.text("draft")]),
            actor: .app)
        #expect(harness.tmux.sentKeys.isEmpty)
    }
}
