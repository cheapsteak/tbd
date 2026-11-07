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

    /// The core's shape check runs before the phone's refusals, so a payload
    /// that is malformed and aimed at a shell gets the shape error
    /// `terminal.send` gives, not the shell refusal, and leaves no row.
    @Test func aPairedPhoneSendToAShellWithAMalformedPayloadGetsTheShapeError() async throws {
        let harness = try await SendHarness.make(kind: .shell)
        let textBesideParts = TerminalSendParams(
            terminalID: harness.terminal.id, text: "ls", submit: true, parts: [.text("ls")])
        guard case .malformed(let shapeError) = RPCRouter.validateSendShape(textBesideParts) else {
            Issue.record("the send core's shape check must call text beside parts malformed")
            return
        }

        let response = try await harness.router.sendFromPairedPhone(textBesideParts, deviceID: UUID())

        #expect(response.error == shapeError, "a malformed payload gets the core's shape error")
        #expect(response.error != RPCRouter.phoneShellSendRefusal)
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
        let logPath = await harness.router.actuationLog.path
        let sendRows = ActuationRecordReader(activePath: logPath).readRows()
            .filter { row in row.method == RPCMethod.terminalSend }
        #expect(sendRows.isEmpty, "a malformed payload leaves no row")
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

    /// A refusal of a well-formed send is an act the daemon declined, so it is
    /// recorded as the send core records one: a `terminal.send` row naming the
    /// phone, then a refused outcome carrying the refusal.
    @Test func aPairedPhoneSendToAShellIsRecordedAsRefused() async throws {
        let harness = try await SendHarness.make(kind: .shell)
        let device = UUID()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true, parts: [.text("ls")]),
            deviceID: device)

        #expect(response.error == RPCRouter.phoneShellSendRefusal)
        try await harness.expectRecordedRefusal(
            device: device, message: "ls", error: RPCRouter.phoneShellSendRefusal)
    }

    /// The text-only refusal is recorded the same way.
    @Test func aPairedPhoneSendWithAnImagePartIsRecordedAsRefused() async throws {
        let harness = try await SendHarness.make()
        let device = UUID()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.text("hi"), .imagePath("/tmp/acme/shot.png")]),
            deviceID: device)

        #expect(response.error == RPCRouter.phoneNonTextPartRefusal)
        try await harness.expectRecordedRefusal(
            device: device, message: "hi[image /tmp/acme/shot.png]",
            error: RPCRouter.phoneNonTextPartRefusal)
    }

    /// An empty message with submit would reach the pane as a bare Enter and
    /// submit whatever draft the person left in the laptop's composer, so the
    /// rail refuses it before anything is typed or pressed. Empty text is a
    /// well-formed send the daemon declined, so it is recorded as refused.
    @Test func aPairedPhoneSendOfEmptyTextIsRefusedAndTypesNothing() async throws {
        let harness = try await SendHarness.make()
        let device = UUID()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: harness.terminal.id, text: "", submit: true),
            deviceID: device)

        #expect(response.error == RPCRouter.phoneEmptySendRefusal)
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
        try await harness.expectRecordedRefusal(
            device: device, message: "", error: RPCRouter.phoneEmptySendRefusal)
    }

    /// Whitespace text is empty too. Parts are the send core's shape check's
    /// to judge, not the phone rail's: text parts that carry only whitespace,
    /// and text beside parts, are shapes it calls malformed, so each gets the
    /// core's refusal and leaves no row.
    @Test func aPairedPhoneSendOfWhitespaceIsRefusedAndTypesNothing() async throws {
        let harness = try await SendHarness.make()
        let blankParts = TerminalSendParams(
            terminalID: harness.terminal.id, submit: true, parts: [.text(" "), .text("\n")])
        let textBesideParts = TerminalSendParams(
            terminalID: harness.terminal.id, text: " ", submit: true, parts: [.text("hi")])
        guard case .malformed(let blankPartsRefusal) = RPCRouter.validateSendShape(blankParts),
              case .malformed(let textBesidePartsRefusal) = RPCRouter.validateSendShape(textBesideParts) else {
            Issue.record("the send core's shape check must call both part shapes malformed")
            return
        }

        let textResponse = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: harness.terminal.id, text: " \n\t", submit: true),
            deviceID: UUID())
        let partsResponse = try await harness.router.sendFromPairedPhone(blankParts, deviceID: UUID())
        let textBesidePartsResponse = try await harness.router.sendFromPairedPhone(
            textBesideParts, deviceID: UUID())

        #expect(textResponse.error == RPCRouter.phoneEmptySendRefusal)
        #expect(partsResponse.error == blankPartsRefusal, "blank parts get the core's refusal")
        #expect(
            textBesidePartsResponse.error == textBesidePartsRefusal,
            "text beside parts gets the core's refusal")
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
        let logPath = await harness.router.actuationLog.path
        let requests = ActuationRecordReader(activePath: logPath).readRows()
            .filter { $0.method == RPCMethod.terminalSend }
        #expect(requests.count == 1, "only the text send is a well-formed act")
        #expect(requests.first?.message == " \n\t")
    }

    /// A message of invisible characters types nothing a person could see,
    /// and with submit it would press Enter on the laptop's draft. So a
    /// message whose every scalar is whitespace or a format character (a
    /// zero-width space, a word joiner, a byte-order mark) is empty, in `text`
    /// and in a text part. The shape check counts such a part as content, so
    /// the phone's refusal is what stops it, and the refusal is recorded.
    @Test(arguments: ["\u{200B}", "\u{2060}", "\u{FEFF}", " \u{200B}\n", "\u{3164}", "\u{FE0F}"])
    func aPairedPhoneSendOfInvisibleCharactersIsRefusedAsEmpty(text: String) async throws {
        let textHarness = try await SendHarness.make()
        let partsHarness = try await SendHarness.make()
        let device = UUID()

        let textResponse = try await textHarness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: textHarness.terminal.id, text: text, submit: true),
            deviceID: device)
        let partsResponse = try await partsHarness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: partsHarness.terminal.id, submit: true, parts: [.text(text)]),
            deviceID: device)

        #expect(textResponse.error == RPCRouter.phoneEmptySendRefusal)
        #expect(partsResponse.error == RPCRouter.phoneEmptySendRefusal)
        for harness in [textHarness, partsHarness] {
            #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
            #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
            try await harness.expectRecordedRefusal(
                device: device, message: text, error: RPCRouter.phoneEmptySendRefusal)
        }
    }

    /// A format character beside visible text is part of what a person wrote,
    /// so that message is delivered as written.
    @Test func aPairedPhoneSendKeepsAZeroWidthSpaceBesideText() async throws {
        let harness = try await SendHarness.make()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: harness.terminal.id, text: "a\u{200B}b", submit: true),
            deviceID: UUID())

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(harness.tmux.pastedBodies == ["a\u{200B}b"])
    }

    /// A zero width joiner inside an emoji sequence is part of a visible
    /// message, so the message is delivered as written.
    @Test func aPairedPhoneSendKeepsAZeroWidthJoinerInAnEmojiSequence() async throws {
        let harness = try await SendHarness.make()
        let text = "\u{1F469}\u{200D}\u{1F4BB}"

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: harness.terminal.id, text: text, submit: true),
            deviceID: UUID())

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(harness.tmux.pastedBodies == [text])
    }

    /// The rail drops keys, but text can carry a key's byte. A pane whose
    /// child has bracketed paste off reads ESC as Escape, so a message holding
    /// a control character is refused before anything is typed. It is a
    /// well-formed send the daemon declined, so it is recorded as refused.
    @Test func aPairedPhoneSendWithAnEscapeIsRefusedAndTypesNothing() async throws {
        let harness = try await SendHarness.make()
        let device = UUID()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: harness.terminal.id, text: "a\u{1b}b", submit: true),
            deviceID: device)

        #expect(response.error == RPCRouter.phoneControlCharacterRefusal)
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
        try await harness.expectRecordedRefusal(
            device: device, message: "a\u{1b}b", error: RPCRouter.phoneControlCharacterRefusal)
    }

    /// Ctrl-C, a lone CR (an early Enter), DEL and a C1 control are refused
    /// too, in a text part as in `text`.
    @Test(arguments: ["a\u{3}b", "a\rb", "a\u{7f}b", "a\u{9b}b"])
    func aPairedPhoneSendWithAControlCharacterInAPartIsRefused(text: String) async throws {
        let harness = try await SendHarness.make()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: harness.terminal.id, submit: true, parts: [.text(text)]),
            deviceID: UUID())

        #expect(response.error == RPCRouter.phoneControlCharacterRefusal)
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
    }

    /// A phone can end its lines with CRLF. The rail makes each CRLF a bare
    /// LF, in `text` and in a text part, so the CR is never typed and the
    /// message is not refused for it.
    @Test func aPairedPhoneSendMakesCRLFLineEndingsLF() async throws {
        let textHarness = try await SendHarness.make()
        let partsHarness = try await SendHarness.make()

        let textResponse = try await textHarness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: textHarness.terminal.id, text: "a\r\nb", submit: true),
            deviceID: UUID())
        let partsResponse = try await partsHarness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: partsHarness.terminal.id, submit: true, parts: [.text("c\r\nd")]),
            deviceID: UUID())

        #expect(textResponse.success, "error was: \(textResponse.error ?? "none")")
        #expect(textHarness.tmux.pastedBodies == ["a\nb"])
        #expect(partsResponse.success, "error was: \(partsResponse.error ?? "none")")
        #expect(partsHarness.tmux.pastedBodies == ["c\nd"])
    }

    /// A tab and a newline are text, not keys, so they reach the pane as
    /// written.
    @Test func aPairedPhoneSendKeepsATabAndANewline() async throws {
        let harness = try await SendHarness.make()

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: harness.terminal.id, text: "a\tb\nc", submit: true),
            deviceID: UUID())

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(harness.tmux.pastedBodies == ["a\tb\nc"])
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

    /// The phone's refusals judge only a target the send core would record.
    /// A send the text-only refusal would decline, aimed at a terminal whose
    /// row is gone, gets the core's own not-found answer rather than "a phone
    /// can send text only", and leaves no row.
    @Test func aPairedPhoneSendWithAnImagePartToADeletedTerminalGetsTheCoresNotFound() async throws {
        let harness = try await SendHarness.make()
        let deleted = harness.terminal.id
        try await harness.db.terminals.delete(id: deleted)

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(
                terminalID: deleted, submit: true,
                parts: [.text("hi"), .imagePath("/tmp/acme/shot.png")]),
            deviceID: UUID())

        #expect(response.error == "Terminal not found: \(deleted)")
        #expect(response.error != RPCRouter.phoneNonTextPartRefusal)
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        let logPath = await harness.router.actuationLog.path
        let sendRows = ActuationRecordReader(activePath: logPath).readRows()
            .filter { row in row.method == RPCMethod.terminalSend }
        #expect(sendRows.isEmpty, "a missing target leaves no row")
    }

    /// The phone's refusals run after the send core's own terminal and
    /// worktree lookup. A send to a terminal whose worktree is not local gets
    /// the core's own answer and leaves no row, even when the terminal is a
    /// shell the phone's shell refusal would otherwise decline.
    @Test func aPairedPhoneSendToANonLocalWorktreeGetsTheCoresNotFound() async throws {
        let harness = try await SendHarness.make()
        let remote = try await harness.addRemoteTerminal(kind: .shell)

        let response = try await harness.router.sendFromPairedPhone(
            TerminalSendParams(terminalID: remote.id, submit: true, parts: [.text("ls")]),
            deviceID: UUID())

        #expect(response.error == "Worktree not found for terminal: \(remote.id)")
        #expect(response.error != RPCRouter.phoneShellSendRefusal)
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
        #expect(harness.tmux.sentKeys.isEmpty, "no key may be pressed")
        let logPath = await harness.router.actuationLog.path
        let sendRows = ActuationRecordReader(activePath: logPath).readRows()
            .filter { row in row.method == RPCMethod.terminalSend }
        #expect(sendRows.isEmpty, "a non-local target leaves no row")
    }

    /// The queued prompt now runs through the shared rail, and still reaches
    /// the pane with no envelope in front of it.
    @Test func theQueuedPromptRailStillSuppresses() async throws {
        let harness = try await SendHarness.make()

        #expect(await harness.router.sendQueuedPromptVerbatim(
            terminalID: harness.terminal.id, text: "q", submit: true))
        #expect(harness.tmux.pastedBodies == ["q"])
    }

    /// The phone's checks stay on the phone's rail. The queued prompt shares
    /// the internal rail and the send core, and delivers a lone CR, which the
    /// phone would refuse as a control character, byte for byte.
    @Test func theQueuedPromptRailDeliversALoneCRUnchanged() async throws {
        let harness = try await SendHarness.make()

        #expect(await harness.router.sendQueuedPromptVerbatim(
            terminalID: harness.terminal.id, text: "a\rb", submit: true))
        #expect(harness.tmux.pastedBodies == ["a\rb"])
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

    /// The record holds one `terminal.send` request row, naming the phone,
    /// this harness's terminal and `message`, and its outcome is a refusal
    /// carrying `error`.
    func expectRecordedRefusal(device: UUID, message: String, error: String) async throws {
        let logPath = await router.actuationLog.path
        let rows = ActuationRecordReader(activePath: logPath).readRows()
        let requests = rows.filter { $0.method == RPCMethod.terminalSend }
        #expect(requests.count == 1, "one request row, got \(requests.count)")
        let request = try #require(requests.first)
        #expect(request.actor == ActuationActor.phone(deviceID: device))
        #expect(request.target?.terminal == terminal.id.uuidString)
        #expect(request.target?.worktree == terminal.worktreeID.uuidString)
        #expect(request.message == message)
        let outcome = try #require(rows.first { $0.confirms == request.id })
        #expect(outcome.result == .synchronous(.refused))
        #expect(outcome.reason == .notEligible)
        #expect(outcome.error == error)
    }

    /// A second terminal in the harness's worktree whose row predates the
    /// `kind` column: no kind recorded, and the given Claude session id.
    func addKindlessTerminal(claudeSessionID: String?) async throws -> TBDShared.Terminal {
        try await db.terminals.create(
            worktreeID: terminal.worktreeID, tmuxWindowID: "@4", tmuxPaneID: "%8",
            claudeSessionID: claudeSessionID, kind: nil)
    }

    /// A terminal of `kind` in a remote worktree of the harness's repo: a
    /// worktree with no files on this machine, which `getLocal` refuses.
    func addRemoteTerminal(kind: TerminalKind) async throws -> TBDShared.Terminal {
        let local = try await db.worktrees.get(id: terminal.worktreeID)
        let repoID = try #require(local?.repoID)
        let remote = try await db.worktrees.createRemote(
            repoID: repoID, name: "acme-remote", branch: "main",
            provider: "acme-provider", sessionID: "acme-session")
        return try await db.terminals.create(
            worktreeID: remote.id, tmuxWindowID: "@5", tmuxPaneID: "%9",
            claudeSessionID: nil, kind: kind)
    }
}
