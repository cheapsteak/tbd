import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// The two internal send rails: the queued prompt and a paired phone.
///
/// Both run the send core with the envelope suppressed, so the agent sees
/// only the person's words. Neither reaches the socket's `terminal.send`, which
/// still grants suppression only to the authenticated app
/// (`EnvelopeSuppressionAuthTests`). Every phone send is gated on awaiting
/// input, whatever its params ask for, so a send into an open prompt is refused
/// by the existing gate and types nothing. A phone send carries no keys and
/// never reaches a shell.
///
/// Tier 2: the router runs in full over an in-memory database and a dry-run
/// tmux, and the actuation log is a real file under the run's scratch dir.
@Suite("phone send rail")
struct PhoneSendRailTests {

    @Test func aPairedPhoneSendTypesOnlyTheMessage() async throws {
        let harness = try await SendHarness.make()
        let device = UUID()
        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.text("hi")], envelope: .suppressed, gateOnAwaitingInput: true),
            deviceID: device)

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(harness.tmux.pastedBodies == ["hi"])

        let logPath = await harness.router.actuationLog.path
        let rows = ActuationRecordReader(activePath: logPath).readRows()
        let sendRow = rows.first { $0.method == RPCMethod.terminalSend }
        let request = try #require(sendRow)
        #expect(
            request.actor == ActuationActor.phone(deviceID: device),
            "the record names the phone's pairing")
    }

    /// The phone rail forces the gate on, so a caller that turns it off still
    /// cannot type into an open prompt. This is the test that fails if the
    /// forcing in `sendFromPairedPhone` is removed.
    @Test func aPairedPhoneSendIsGatedEvenWhenItsParamsTurnTheGateOff() async throws {
        let harness = try await SendHarness.make()
        try await harness.seedPrompt()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.text("hi")], envelope: .suppressed, gateOnAwaitingInput: false),
            deviceID: UUID())

        #expect(!response.success)
        #expect(try #require(response.error).contains("Allow Bash(rm -rf)?"))
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
    }

    /// `verify` is stripped, never honored: a suppressed send carries no
    /// dispatch id to observe, and the shape check refuses `verify` with parts.
    /// So the send is delivered unverified rather than refused.
    @Test func aPairedPhoneSendThatAsksToVerifyIsDeliveredUnverified() async throws {
        let harness = try await SendHarness.make()
        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true, verify: true,
                parts: [.text("hi")]),
            deviceID: UUID())

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(harness.tmux.pastedBodies == ["hi"])
    }

    @Test func aPairedPhoneSendIntoAPromptIsRefusedAndTypesNothing() async throws {
        let harness = try await SendHarness.make()
        try await harness.seedPrompt()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.text("hi")], envelope: .suppressed, gateOnAwaitingInput: true),
            deviceID: UUID())

        #expect(!response.success)
        #expect(try #require(response.error).contains("Allow Bash(rm -rf)?"))
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
    }

    /// Keys are not part of a phone's message, so the rail drops them. A send
    /// that carried nothing else has no payload left, and the shape check
    /// refuses it before any row is written.
    @Test func aPairedPhoneSendOfKeysAloneIsRefusedAndTypesNothing() async throws {
        let harness = try await SendHarness.make()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: harness.terminal.id, keys: "Escape"),
            deviceID: UUID())

        #expect(!response.success)
        #expect(try #require(response.error).contains("needs a payload"))
        #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        let logPath = await harness.router.actuationLog.path
        let rows = ActuationRecordReader(activePath: logPath).readRows()
        #expect(!rows.contains { $0.method == RPCMethod.terminalSend })
    }

    /// Keys beside a message are dropped, not refused: the message is
    /// delivered and the keys are never pressed. With the keys kept, the shape
    /// check would refuse two payloads in one call.
    @Test func aPairedPhoneSendDropsKeysBesideAMessage() async throws {
        let harness = try await SendHarness.make()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: harness.terminal.id, text: "hi", keys: "Escape"),
            deviceID: UUID())

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(harness.tmux.pastedBodies == ["hi"])
        #expect(!harness.tmux.sentKeys.contains("Escape"))
    }

    /// Shells are hidden from the phone, and a shell runs what is typed into
    /// it, so the rail refuses one before anything is typed. Without the
    /// refusal this send would reach the pane: a shell has no agent for the
    /// foreground rail to look for, and no prompt for the gate to find.
    @Test func aPairedPhoneSendToAShellIsRefusedAndTypesNothing() async throws {
        let harness = try await SendHarness.make(kind: .shell)

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true, parts: [.text("ls")]),
            deviceID: UUID())

        #expect(response.error == RPCRouter.phoneShellSendRefusal)
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
    }

    /// A row with no recorded kind and no Claude session id is a shell to the
    /// send core: the foreground rail skips it, so nothing else would stop the
    /// paste. The phone's refusal reads it the same way and types nothing.
    @Test func aPairedPhoneSendToAKindlessRowWithNoSessionIsRefusedAndTypesNothing() async throws {
        let harness = try await SendHarness.make()
        let kindless = try await harness.addKindlessTerminal(claudeSessionID: nil)

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: kindless.id, submit: true, parts: [.text("ls")]),
            deviceID: UUID())

        #expect(response.error == RPCRouter.phoneShellSendRefusal)
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
    }

    /// A row with no recorded kind that carries a Claude session id is
    /// Claude's, so the phone's message reaches it.
    @Test func aPairedPhoneSendToAKindlessRowWithASessionIsDelivered() async throws {
        let harness = try await SendHarness.make()
        let kindless = try await harness.addKindlessTerminal(claudeSessionID: "sess-2")

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: kindless.id, submit: true, parts: [.text("hi")]),
            deviceID: UUID())

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(harness.tmux.pastedBodies == ["hi"])
    }

    /// An image part names a path on the laptop, which a phone cannot know.
    /// The whole send is refused, so the text part beside it is not typed.
    @Test func aPairedPhoneSendWithAnImagePartIsRefusedAndTypesNothing() async throws {
        let harness = try await SendHarness.make()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.text("hi"), .imagePath("/tmp/acme/shot.png")]),
            deviceID: UUID())

        #expect(response.error == RPCRouter.phoneNonTextPartRefusal)
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
    }

    /// A terminal with no row is not the shell check's to judge: the send core
    /// reports it missing, as it does for every caller.
    @Test func aPairedPhoneSendToAMissingTerminalFallsThroughToTheSendCore() async throws {
        let harness = try await SendHarness.make()
        let missing = UUID()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: missing, submit: true, parts: [.text("hi")]),
            deviceID: UUID())

        #expect(response.error == "Terminal not found: \(missing)")
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
    }

    /// The queued prompt now runs through the shared rail, and still reaches
    /// the pane with no envelope in front of it.
    @Test func theQueuedPromptRailStillSuppresses() async throws {
        let harness = try await SendHarness.make()

        #expect(await harness.router.sendQueuedPromptVerbatim(
            terminalID: harness.terminal.id, text: "q", submit: true))
        #expect(harness.tmux.pastedBodies == ["q"])
    }
}

private extension SendHarness {
    /// A standing permission prompt with its text, the same one
    /// `AwaitingInputSendGateTests` seeds, so a refusal can be shown to quote
    /// it.
    func seedPrompt() async throws {
        _ = try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .waitingForUser,
            source: .programStatus,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            awaitingInputReason: AwaitingInputReason(
                message: "Allow Bash(rm -rf)?", hookEventName: "Notification",
                notificationType: "permission_prompt"))
    }

    /// A second terminal in the harness's worktree whose row predates the
    /// `kind` column: no kind recorded, and the given Claude session id.
    func addKindlessTerminal(claudeSessionID: String?) async throws -> TBDShared.Terminal {
        try await db.terminals.create(
            worktreeID: terminal.worktreeID, tmuxWindowID: "@4", tmuxPaneID: "%8",
            claudeSessionID: claudeSessionID, kind: nil)
    }
}
