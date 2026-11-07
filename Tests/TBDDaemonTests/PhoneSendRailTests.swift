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
/// by the existing gate and types nothing.
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
}
