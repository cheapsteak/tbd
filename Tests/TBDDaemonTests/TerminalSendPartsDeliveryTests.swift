import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// What actually reaches the pane for a parts payload.
///
/// The ordering assertion is a documented contract, not an incident: the whole
/// reason parts exist is that Claude Code turns a paste into an image attachment
/// only when the WHOLE paste is one quoted path, so an image part pasted
/// together with its surrounding words silently becomes literal text.
@Suite("terminal.send parts delivery", .clockDriven)
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

    /// An image part before the first text part must carry no envelope; the
    /// envelope belongs on the first TEXT part, not the first part outright.
    @Test func anImagePartBeforeTextCarriesNoEnvelope() async throws {
        let harness = try await SendHarness.make()
        _ = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.imagePath("/tmp/a.png"), .text("hi")]),
            actor: .app)

        let bodies = harness.tmux.pastedBodies
        #expect(bodies.count == 2)
        #expect(bodies[0] == "'/tmp/a.png'")
        #expect(bodies[1].hasPrefix("<tbd-dispatch"))
        #expect(bodies[1].hasSuffix("\nhi"))
        #expect(harness.tmux.sentKeys == ["Enter"])
    }

    @Test func emptyTextPartsAreSkipped() async throws {
        let harness = try await SendHarness.make()
        _ = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.text(""), .imagePath("/tmp/a.png"), .text("")]),
            actor: .app)

        // Nothing empty was pasted. Every text part being empty makes this an
        // IMAGE-ONLY payload, so the envelope takes a leading paste of its own
        // rather than being dropped — the image paste stays bare and alone.
        let bodies = harness.tmux.pastedBodies
        try #require(bodies.count == 2)
        #expect(try #require(bodies.first).hasPrefix("<tbd-dispatch"))
        #expect(bodies[1] == "'/tmp/a.png'")
        #expect(harness.tmux.sentKeys == ["Enter"])
    }

    // MARK: - The image-only payload, and why it is not unattributed

    /// **An image-only send is still a user turn, so it is still attributed.**
    /// The envelope cannot ride ON the image part — Claude Code attaches an
    /// image only when the whole paste is one quoted path — so it takes its own
    /// leading paste instead. Each part is already its own bracketed paste, so
    /// the image paste stays bare and alone and still attaches, and this is the
    /// same "text + image as separate pastes" shape the design already relies on.
    ///
    /// Without it, any local process could submit an unattributed user turn
    /// carrying an image, on a request that needs no authentication.
    @Test func anUnauthenticatedImageOnlySendPastesTheEnvelopeFirst() async throws {
        let harness = try await SendHarness.make()
        _ = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.imagePath("/tmp/a.png")]),
            actor: .app)

        let bodies = harness.tmux.pastedBodies
        try #require(bodies.count == 2)
        #expect(try #require(bodies.first).hasPrefix("<tbd-dispatch"))
        #expect(bodies[1] == "'/tmp/a.png'")
        #expect(harness.tmux.sentKeys == ["Enter"])
    }

    /// The other branch: on an authenticated connection that asked for
    /// suppression, the person is speaking in their own voice, so there is no
    /// envelope to place anywhere and the image is the only paste.
    @Test func anAuthenticatedImageOnlySendPastesOnlyThePath() async throws {
        let harness = try await SendHarness.makeAuthenticated()
        let response = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.imagePath("/tmp/a.png")], envelope: .suppressed),
            actor: .app,
            connection: SendHarness.AuthenticatedApp.connection)

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(harness.tmux.pastedBodies == ["'/tmp/a.png'"])
        #expect(harness.tmux.sentKeys == ["Enter"])
    }

    /// A shell row carries no envelope at all, so an image-only send there has
    /// nothing to place ahead of the path — the leading paste is the envelope's,
    /// not the image-only shape's.
    @Test func anImageOnlySendToAShellRowPastesOnlyThePath() async throws {
        let harness = try await SendHarness.make(kind: .shell)
        _ = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.imagePath("/tmp/a.png")]),
            actor: .app)

        #expect(harness.tmux.pastedBodies == ["'/tmp/a.png'"])
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

    // MARK: - The not-running rails apply to parts too

    /// A parts send into a parked row must be refused exactly as a text send
    /// is — PR A's park rail was guarded on `.text` alone, which let a parts
    /// payload paste into a pane whose Claude session had already exited.
    @Test func aPartsSendIntoAParkedRowIsRefused() async throws {
        let harness = try await SendHarness.make()
        try await harness.db.terminals.setHibernated(
            id: harness.terminal.id, sessionID: "sess-1", reason: .manual,
            at: Date(timeIntervalSince1970: 1_800_000_000))

        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.text("look at "), .imagePath("/tmp/a.png")]),
            actor: .app)

        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("is not running"))
        #expect(harness.tmux.pastedBodies.isEmpty)
        #expect(harness.tmux.sentKeys.isEmpty)
    }

    /// A parts send whose pane has no foreground agent must be refused exactly
    /// as a text send is — PR A's foreground rail was guarded on `.text` alone,
    /// which let a parts payload paste into a shell the agent had left behind.
    /// No emptiness guard applies here: a validated parts payload always has
    /// content.
    @Test func aPartsSendWithNoForegroundAgentIsRefused() async throws {
        let harness = try await SendHarness.make(foregroundByAgent: [:])

        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.text("look at "), .imagePath("/tmp/a.png")]),
            actor: .app)

        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("foreground process"))
        #expect(harness.tmux.pastedBodies.isEmpty)
        #expect(harness.tmux.sentKeys.isEmpty)
    }

    // MARK: - The settle after an image paste

    /// **The image token lands where the caret is when the attach finishes.**
    /// Claude Code turns a pasted quoted path into an attachment
    /// asynchronously; pasting the next part before that lands moves the caret,
    /// so the `[Image#N]` token arrives at the END of the message and an Enter
    /// that arrives mid-attach is swallowed. Both were observed live against
    /// 2.1.261, on the first image a Claude process had ever been given.
    ///
    /// **The wait is once per image part, not once per successor.** It belongs
    /// to the image paste and is taken before whatever comes next, so an image
    /// followed by text waits ONCE — between the two pastes — and not again
    /// before Enter: the token has already landed by then, and Enter after a
    /// plain text paste is what the single-text arm has always done. The image
    /// being LAST is the case where that same one wait covers the Enter, which
    /// `anImageAsTheLastPartSettlesBeforeEnter` pins.
    ///
    /// Pinned by advancing: the second paste has not happened before the
    /// advance and has after.
    @Test func anImagePartSettlesBeforeTheNextPaste() async throws {
        let clock = EventDrivenTestClock()
        let harness = try await SendHarness.make(clock: clock)
        let send = Task {
            try await harness.send(TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.imagePath("/tmp/a.png"), .text(" and tell me what it is")]),
                actor: .app)
        }

        // Armed on the settle, with the image pasted and NOTHING after it.
        await clock.sleeperArmed()
        #expect(harness.tmux.pastedBodies == ["'/tmp/a.png'"])
        #expect(harness.tmux.sentKeys.isEmpty)

        await clock.advance(by: RPCRouter.imageAttachSettle)
        // Bounded rather than `await send.value`, so a regression that arms a
        // SECOND sleeper reports itself instead of wedging the suite.
        _ = try await waitFor(
            "the trailing text part and the Enter",
            observed: { "pastes \(harness.tmux.pastedBodies), keys \(harness.tmux.sentKeys)" }
        ) { harness.tmux.sentKeys == ["Enter"] }
        send.cancel()
        _ = await send.result

        let bodies = harness.tmux.pastedBodies
        try #require(bodies.count == 2)
        #expect(bodies[0] == "'/tmp/a.png'")
        #expect(bodies[1].hasSuffix(" and tell me what it is"))
        // Once, not twice: nothing is still parked on the clock.
        #expect(clock.sleeperCount == 0)
    }

    /// The image as the LAST part: the same one settle stands between its paste
    /// and the Enter, which is the swallowed-Enter half of the defect.
    @Test func anImageAsTheLastPartSettlesBeforeEnter() async throws {
        let clock = EventDrivenTestClock()
        let harness = try await SendHarness.make(clock: clock)
        let send = Task {
            try await harness.send(TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.text("look at "), .imagePath("/tmp/a.png")]),
                actor: .app)
        }

        await clock.sleeperArmed()
        #expect(harness.tmux.pastedBodies.count == 2)
        #expect(harness.tmux.sentKeys.isEmpty, "Enter must not race the attach")

        await clock.advance(by: RPCRouter.imageAttachSettle)
        _ = try await waitFor(
            "the Enter after the settle",
            observed: { "keys \(harness.tmux.sentKeys)" }
        ) { harness.tmux.sentKeys == ["Enter"] }
        send.cancel()
        _ = await send.result
        #expect(clock.sleeperCount == 0)
    }

    /// **A payload with no image part waits for nothing.** The settle is the
    /// image paste's, so a text-only parts send must cost exactly what it cost
    /// before — it runs to completion with the clock never advanced, and
    /// nothing is ever parked on it.
    @Test func aTextOnlyPartsSendNeverTouchesTheClock() async throws {
        let clock = EventDrivenTestClock()
        let harness = try await SendHarness.make(clock: clock)
        let send = Task {
            try await harness.send(TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.text("look at "), .text("this")]),
                actor: .app)
        }

        // Nothing advances the clock here. Completing at all is the assertion:
        // a send that slept would still be parked.
        _ = try await waitFor(
            "the text-only send to finish with the clock never advanced",
            observed: { "keys \(harness.tmux.sentKeys), sleepers \(clock.sleeperCount)" }
        ) { harness.tmux.sentKeys == ["Enter"] }
        send.cancel()
        _ = await send.result

        #expect(harness.tmux.pastedBodies.count == 2)
        #expect(clock.sleeperCount == 0)
        #expect(clock.now == EventDrivenTestClock.Instant(), "virtual time never moved")
    }
}
