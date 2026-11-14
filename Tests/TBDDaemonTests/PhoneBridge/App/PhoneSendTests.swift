import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// `message.send` and `session.setModel`, driven through `handleAppMessage`.
/// Tier 1: the service over an in-memory database with seeded terminals, and
/// fake session actions that record what would have reached the daemon.
/// Nothing touches the disk, tmux or the network.
@Suite("Phone message.send and session.setModel", .fastPassBounded)
struct PhoneSendTests {
    private static let remoteSession = PhoneSessionRef.remote(provider: "acme-cloud", sessionID: "rs-1")

    /// The fields of a `TerminalSendParams`, which is not `Equatable`, so a
    /// test can compare whole sends.
    private struct SendShape: Equatable {
        let terminalID: UUID
        let text: String?
        let keys: String?
        let submit: Bool?
        let verify: Bool?
        let parts: [SendPart]?
        let envelope: EnvelopeDisposition?
        let gateOnAwaitingInput: Bool?

        init(_ p: TerminalSendParams) {
            terminalID = p.terminalID
            text = p.text
            keys = p.keys
            submit = p.submit
            verify = p.verify
            parts = p.parts
            envelope = p.envelope
            gateOnAwaitingInput = p.gateOnAwaitingInput
        }
    }

    /// The send the laptop's composer makes for `text`.
    private static func composerSend(_ terminalID: UUID, _ text: String) -> SendShape {
        SendShape(TerminalSendParams(
            terminalID: terminalID, submit: true, parts: [.text(text)], envelope: .suppressed,
            gateOnAwaitingInput: true))
    }

    private static func outcome(_ bytes: Data) throws -> String {
        try JSONDecoder().decode(PhoneReplyEnvelope<ActionOutcomeResult>.self, from: bytes).result.outcome
    }

    private static func message(_ ref: PhoneSessionRef, _ text: String) -> MessageSendParams {
        MessageSendParams(session: ref, text: text)
    }

    // MARK: - A local session

    @Test func aRunningSessionGetsTheComposerSend() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "hi"), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == "sent")
        let sends = h.actions.sends.map(SendShape.init)
        #expect(sends == [Self.composerSend(terminal.id, "hi")])
        // The identity is the verified peer's, and the record names only the
        // session.
        #expect(h.actions.calls == [FakeSessionActions.Call(method: .send, deviceID: h.peer.deviceID)])
        #expect(h.recorder.records == [PhoneActionRecord(
            deviceName: "Acme Phone", action: "message.send", target: "local:\(terminal.id.uuidString)")])
    }

    @Test func aParkedSessionIsWokenWithTheMessage() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        try await h.park(terminal.id)
        h.actions.respond(to: .wake, with: try RPCResponse(result: TerminalWakeResult(woken: true)))
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "hi"), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == "woken")
        let wakes = h.actions.wakes.map { [$0.terminalID.uuidString, $0.prompt ?? "<none>"] }
        #expect(wakes == [[terminal.id.uuidString, "hi"]])
        #expect(h.actions.sends.isEmpty)
        #expect(h.actions.calls == [FakeSessionActions.Call(method: .wake, deviceID: h.peer.deviceID)])
    }

    /// A long message goes to the wake whole: the phone holds it to no
    /// first-message limit of its own, since a wake respawns on the pty
    /// holder. 20,000 bytes is past the roughly 16 KB a tmux command could
    /// carry.
    @Test func aLongWakeMessageGoesToTheWakeWhole() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal(transport: .holder)
        try await h.park(terminal.id)
        h.actions.respond(to: .wake, with: try RPCResponse(result: TerminalWakeResult(woken: true)))
        let outbox = await h.connect()
        let message = String(repeating: "a", count: 20_000)

        let (reply, bytes) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), message), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == "woken")
        let prompts = h.actions.wakes.map(\.prompt)
        #expect(prompts == [message])
    }

    /// A running session takes a long message, on tmux too: it is typed into
    /// the session, not carried in a command.
    @Test func aRunningTmuxSessionTakesALongMessage() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal(transport: .tmux)
        let outbox = await h.connect()
        let message = String(repeating: "a", count: 20_000)

        let (reply, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), message), on: outbox)

        #expect(reply.error == nil)
        let sends = h.actions.sends.map(SendShape.init)
        #expect(sends == [Self.composerSend(terminal.id, message)])
    }

    /// A session parked on tmux takes no message and no model: either would
    /// wake it, and only a holder session wakes. Both are `unsupported` with
    /// the reason the sessions list shows, and no wake reaches the daemon.
    @Test(arguments: [false, true])
    func aSessionParkedOnTmuxIsRefusedBeforeAnyWake(setsModel: Bool) async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal(transport: .tmux)
        try await h.park(terminal.id)
        h.actions.respond(to: .wake, with: try RPCResponse(result: TerminalWakeResult(woken: true)))
        let outbox = await h.connect()
        let session = PhoneSessionRef.local(terminalID: terminal.id)

        let reply: PhoneTestReply
        if setsModel {
            reply = try await h.request(
                .sessionSetModel, params: SessionSetModelParams(session: session, model: "opus"), on: outbox).reply
        } else {
            reply = try await h.request(.messageSend, params: Self.message(session, "hi"), on: outbox).reply
        }

        #expect(reply.error == PhoneAppError(code: .unsupported, message: PhoneSessionStatus.parkedOnTmuxReason))
        #expect(h.actions.wakes.isEmpty)
        #expect(h.actions.sends.isEmpty)
        #expect(h.actions.calls.isEmpty)
    }

    @Test func aWakeThatFindsItRunningIsRefused() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        try await h.park(terminal.id)
        h.actions.respond(to: .wake, with: try RPCResponse(result: TerminalWakeResult(woken: false)))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "hi"), on: outbox)

        #expect(reply.error == PhoneAppError(
            code: .refused,
            message: "This session was already running, so the message was not delivered. Send it again."))
    }

    /// A wake the daemon refuses passes its reason through.
    @Test func aFailedWakeIsRefusedWithTheDaemonsReason() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        try await h.park(terminal.id)
        h.actions.respond(to: .wake, with: RPCResponse(error: "No session ID to resume"))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "hi"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: "No session ID to resume"))
    }

    /// A wake that answers success with no result it can read is never taken
    /// for a delivered message.
    @Test func aWakeResultThatDoesNotDecodeIsInternal() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        try await h.park(terminal.id)
        h.actions.respond(to: .wake, with: .ok())
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "hi"), on: outbox)

        #expect(reply.error?.code == .internalError)
    }

    @Test func aRefusedSendReturnsTheDaemonsReason() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        h.actions.respond(to: .send, with: RPCResponse(error: "Claude is asking: Allow Bash(rm -rf)?"))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "hi"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: "Claude is asking: Allow Bash(rm -rf)?"))
        #expect(h.actions.sends.count == 1)
    }

    /// A daemon reason longer than `refusalLimit` is cut, so the error reply
    /// still fits one frame.
    @Test func aLongRefusalIsCut() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        h.actions.respond(to: .send, with: RPCResponse(error: String(repeating: "é", count: 70_000)))
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "hi"), on: outbox)

        #expect(reply.error?.code == .refused)
        let length = reply.error?.message.utf8.count ?? 0
        #expect(length <= PhoneAppService.refusalLimit)
        #expect(length > 0)
        #expect(PhoneAppCoding.framedSize(bytes) <= PhoneFrameBudget.maxPlaintext)
    }

    @Test func aBlockedSessionIsRefusedBeforeAnySend() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        try await h.showPrompt(on: terminal.id, message: "Allow Bash(rm -rf)?")
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "hi"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: "Allow Bash(rm -rf)?"))
        #expect(h.actions.sends.isEmpty)
        #expect(h.actions.calls.isEmpty)
    }

    @Test(arguments: [TerminalKind.codex, .shell])
    func aCodexSessionIsUnsupported(_ kind: TerminalKind) async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal(kind: kind)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "hi"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .unsupported, message: "This session cannot take messages."))
        #expect(h.actions.calls.isEmpty)
    }

    /// A Claude tab in a remote lane's row is judged by its worktree's real
    /// location: its remote session takes messages, the tab does not.
    @Test func aTabInARemoteLaneIsUnsupported() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal(inRemoteLane: true)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "hi"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .unsupported, message: "This session cannot take messages."))
        #expect(h.actions.calls.isEmpty)
    }

    @Test func aMissingTerminalIsNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: UUID()), "hi"), on: outbox)

        #expect(reply.error?.code == .notFound)
        #expect(h.actions.calls.isEmpty)
    }

    @Test(arguments: ["", "   ", " \n\t "])
    func anEmptyMessageIsABadRequest(_ text: String) async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), text), on: outbox)

        #expect(reply.error == PhoneAppError(code: .badRequest, message: "Write a message first."))
        #expect(h.actions.calls.isEmpty)
    }

    /// A message of only invisible format characters is blank by the phone
    /// message rule (`PhoneMessageText.isBlank`), so the service refuses it
    /// with the same words on every path: a parked session is not woken, and
    /// no remote provider is asked anything.
    @Test func aZeroWidthMessageIsABadRequestOnEveryPath() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        try await h.park(terminal.id)
        h.actions.respond(to: .wake, with: try RPCResponse(result: TerminalWakeResult(woken: true)))
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.sendSubmit])
        let outbox = await h.connect()

        let (local, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), "\u{200B}"), on: outbox)
        let (remote, _) = try await h.request(
            .messageSend, params: Self.message(Self.remoteSession, "\u{200B}"), on: outbox)

        #expect(local.error == PhoneAppError(code: .badRequest, message: "Write a message first."))
        #expect(remote.error == PhoneAppError(code: .badRequest, message: "Write a message first."))
        #expect(h.actions.calls.isEmpty)
    }

    /// `messageMaxBytes` is the most a message may hold: one byte over it is
    /// refused before anything is sent, and exactly that many is sent.
    @Test func aMessageOverTheCapIsABadRequest() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()
        let longest = String(repeating: "a", count: PhoneAppConstants.messageMaxBytes)

        let (over, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), longest + "a"), on: outbox)
        #expect(over.error == PhoneAppError(
            code: .badRequest, message: "That message is too long to send from a phone."))
        #expect(h.actions.calls.isEmpty)

        let (atCap, _) = try await h.request(
            .messageSend, params: Self.message(.local(terminalID: terminal.id), longest), on: outbox)
        #expect(atCap.error == nil)
        let sends = h.actions.sends.map(SendShape.init)
        #expect(sends == [Self.composerSend(terminal.id, longest)])
    }

    /// The same request ID twice types once, and the resend gets the first
    /// reply byte for byte.
    @Test func aResentSendTypesOnce() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()
        let params = Self.message(.local(terminalID: terminal.id), "hi")

        let (first, firstBytes) = try await h.request(.messageSend, id: "send-1", params: params, on: outbox)
        let (again, againBytes) = try await h.request(.messageSend, id: "send-1", params: params, on: outbox)

        #expect(first.error == nil)
        #expect(again.error == nil)
        #expect(h.actions.sends.count == 1)
        #expect(againBytes == firstBytes)
    }

    // MARK: - session.setModel

    @Test func setModelSendsTheSlashCommand() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .sessionSetModel,
            params: SessionSetModelParams(session: .local(terminalID: terminal.id), model: "opus"), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == "sent")
        let parts = h.actions.sends.map { $0.parts ?? [] }
        let slashCommand: [[SendPart]] = [[.text("/model opus")]]
        #expect(parts == slashCommand)
        let sends = h.actions.sends.map(SendShape.init)
        #expect(sends == [Self.composerSend(terminal.id, "/model opus")])
        // The record names the session and never the model.
        #expect(h.recorder.records == [PhoneActionRecord(
            deviceName: "Acme Phone", action: "session.setModel", target: "local:\(terminal.id.uuidString)")])
    }

    /// A parked session is woken with the command as its prompt, as a
    /// message would be.
    @Test func setModelWakesAParkedSession() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        try await h.park(terminal.id)
        h.actions.respond(to: .wake, with: try RPCResponse(result: TerminalWakeResult(woken: true)))
        let outbox = await h.connect()

        let (_, bytes) = try await h.request(
            .sessionSetModel,
            params: SessionSetModelParams(session: .local(terminalID: terminal.id), model: "opus"), on: outbox)

        #expect(try Self.outcome(bytes) == "woken")
        let prompts = h.actions.wakes.map { $0.prompt ?? "<none>" }
        #expect(prompts == ["/model opus"])
    }

    @Test func setModelRejectsAnInjectedNewline() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionSetModel,
            params: SessionSetModelParams(session: .local(terminalID: terminal.id), model: "opus\nrm"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .badRequest, message: "That is not a model name."))
        #expect(h.actions.calls.isEmpty)
    }

    /// Every name the pattern refuses is refused through the service, and
    /// nothing is sent.
    @Test(arguments: [
        "", "opus\n", "\nopus", "opus\r", "opus rm", "opus;rm", "opus\t", "opus\u{0}", "ópus",
        "opus\u{200B}", "opus/model", String(repeating: "a", count: 101),
    ])
    func setModelRejectsANameOutsideThePattern(_ model: String) async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionSetModel,
            params: SessionSetModelParams(session: .local(terminalID: terminal.id), model: model), on: outbox)

        #expect(reply.error?.code == .badRequest)
        #expect(h.actions.calls.isEmpty)
    }

    @Test(arguments: [
        "opus", "claude-sonnet-4-5", "claude-opus-4-1[1m]", "acme.model_v2:latest", "A", "0",
        String(repeating: "a", count: 100),
    ])
    func modelNamesInsideThePatternPass(_ model: String) {
        #expect(PhoneAppService.isModelName(model))
    }

    @Test(arguments: [
        "", "opus\n", "opus\r\n", "opus rm", "opus;rm", "opus|rm", "opus$", "ópus", "opus\u{301}",
        String(repeating: "a", count: 101),
    ])
    func modelNamesOutsideThePatternFail(_ model: String) {
        #expect(!PhoneAppService.isModelName(model))
    }

    // MARK: - A remote session

    @Test func aRemoteSendNeedsSendSubmit() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.transcriptRead])
        let outbox = await h.connect()

        let (reply, _) = try await h.request(.messageSend, params: Self.message(Self.remoteSession, "hi"), on: outbox)

        // The reason the sessions list shows for the same provider.
        let shown = PhoneSessionStatus.remoteCapabilities(
            declared: [RemoteCapability.transcriptRead], promptAnswerEnabled: true).send
        #expect(reply.error == PhoneAppError(code: .unsupported, message: "This provider does not support sending messages."))
        #expect(reply.error?.message == shown.reason)
        #expect(h.actions.remoteSends.isEmpty)
    }

    @Test func aRemoteSendWithSendSubmitIsSent() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.sendSubmit])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        h.actions.respond(to: .remoteSendMessage, with: try RPCResponse(result: RemoteSendMessageResult(outcome: .sent)))
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(.messageSend, params: Self.message(Self.remoteSession, "hi"), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == "sent")
        let sends = h.actions.remoteSends.map { [$0.provider, $0.sessionID, $0.text] }
        #expect(sends == [["acme-cloud", "rs-1", "hi"]])
        let acting = h.actions.calls.filter { $0.method == .remoteSendMessage }
        #expect(acting == [FakeSessionActions.Call(method: .remoteSendMessage, deviceID: h.peer.deviceID)])
    }

    /// The setting for answering prompts gates answering only: a remote send
    /// goes through the same capability check as a remote answer
    /// (`checkPhoneCapableRemoteSession`), and is sent with the setting off.
    @Test func aRemoteSendIgnoresTheAnswerSetting() async throws {
        let h = try await PhoneServiceHarness.make()
        try await h.db.config.setTranscriptPromptAnswerEnabled(false)
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.sendSubmit, RemoteCapability.answer])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        h.actions.respond(to: .remoteSendMessage, with: try RPCResponse(result: RemoteSendMessageResult(outcome: .sent)))
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(.messageSend, params: Self.message(Self.remoteSession, "hi"), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == "sent")
        let sends = h.actions.remoteSends.map { [$0.provider, $0.sessionID, $0.text] }
        #expect(sends == [["acme-cloud", "rs-1", "hi"]])
    }

    /// A remote send and a remote model change never read the setting for
    /// answering prompts, which gates neither (`listedCapability`), so a
    /// config row that cannot be read does not stop them: both are sent. A
    /// remote answer on the same session does read it, and is refused for
    /// the unreadable setting, which shows the row is unreadable.
    @Test func aRemoteSendAndModelChangeDoNotReadTheAnswerSetting() async throws {
        let h = try await PhoneServiceHarness.make(phoneControlAlwaysOn: true)
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.sendSubmit, RemoteCapability.answer])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        h.actions.respond(to: .remoteSendMessage, with: try RPCResponse(result: RemoteSendMessageResult(outcome: .sent)))
        let outbox = await h.connect()
        try await h.makeConfigUnreadable()

        let (sent, sentBytes) = try await h.request(
            .messageSend, params: Self.message(Self.remoteSession, "hi"), on: outbox)
        let (modelSet, _) = try await h.request(
            .sessionSetModel, params: SessionSetModelParams(session: Self.remoteSession, model: "opus"), on: outbox)
        let (answered, _) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(
                session: Self.remoteSession, promptID: "rp-1", answer: .permission(decision: .allow, message: nil)),
            on: outbox)

        #expect(sent.error == nil)
        #expect(try Self.outcome(sentBytes) == "sent")
        #expect(modelSet.error == nil)
        let sends = h.actions.remoteSends.map { [$0.provider, $0.sessionID, $0.text] }
        #expect(sends == [["acme-cloud", "rs-1", "hi"], ["acme-cloud", "rs-1", "/model opus"]])
        #expect(answered.error == PhoneAppError(
            code: .unsupported, message: PhoneSessionStatus.answerSettingUnreadReason))
        #expect(h.actions.remoteAnswers.isEmpty)
    }

    /// The provider may have pressed Enter before its call ended: the phone
    /// hears `unknown`, never a failure it could resend.
    @Test func aRemoteSendWithNoExitStatusIsUnknown() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.sendSubmit])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        h.actions.respond(to: .remoteSendMessage, with: try RPCResponse(result: RemoteSendMessageResult(outcome: .unknown)))
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(.messageSend, params: Self.message(Self.remoteSession, "hi"), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == "unknown")
    }

    /// A remote send's refusal reaches the phone only in words TBD wrote,
    /// told by its code: the phone message rule's and a session state's
    /// carry codes and pass as they are. A refusal with no code becomes
    /// `remoteRefusedReason`: a provider's own words, which can quote a
    /// token, and TBD's own words sent with no code, which the phone cannot
    /// tell from a provider's.
    @Test func aRefusedRemoteSendKeepsOnlyTBDsOwnWords() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.sendSubmit])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        let outbox = await h.connect()
        let cases: [(daemon: RPCResponse, phone: String)] = [
            (RPCResponse(error: PhoneProviderSecret.error), PhoneAppService.remoteRefusedReason),
            (PhoneMessageText.controlCharacterRefusal.response, PhoneMessageText.controlCharacterRefusal.text),
            (PhoneMessageText.emptyRefusal.response, PhoneMessageText.emptyRefusal.text),
            (RemoteSendMessageRefusal.waitingInput.response, RemoteSendMessageRefusal.waitingInput.text),
            (RemoteSendMessageRefusal.exited.response, RemoteSendMessageRefusal.exited.text),
            (RemoteGateRefusal.claudeCloudDisabled.response, RemoteGateRefusal.claudeCloudDisabled.text),
            (RPCResponse(error: RemoteSendMessageRefusal.exited.text), PhoneAppService.remoteRefusedReason),
        ]

        for (daemon, phone) in cases {
            let said = "the daemon said \(daemon.error ?? "nothing") with code \(daemon.errorCode ?? "none")"
            h.actions.respond(to: .remoteSendMessage, with: daemon)
            let (reply, bytes) = try await h.request(
                .messageSend, params: Self.message(Self.remoteSession, "hi"), on: outbox)
            #expect(reply.error == PhoneAppError(code: .refused, message: phone), "\(said)")
            #expect(!PhoneProviderSecret.leaks(bytes), "\(said)")
        }
    }

    @Test func aRemoteSessionOfAnUnregisteredProviderIsNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-other", capabilities: [RemoteCapability.sendSubmit])
        let outbox = await h.connect()

        let (reply, _) = try await h.request(.messageSend, params: Self.message(Self.remoteSession, "hi"), on: outbox)

        #expect(reply.error?.code == .notFound)
        #expect(h.actions.remoteSends.isEmpty)
    }

    @Test func setModelOnARemoteSessionNeedsSendSubmit() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.answer])
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionSetModel, params: SessionSetModelParams(session: Self.remoteSession, model: "opus"), on: outbox)

        #expect(reply.error == PhoneAppError(
            code: .unsupported, message: "This provider does not support changing the model."))
        #expect(h.actions.remoteSends.isEmpty)
    }

    @Test func setModelOnARemoteSessionSendsTheSlashCommand() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.sendSubmit])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        h.actions.respond(to: .remoteSendMessage, with: try RPCResponse(result: RemoteSendMessageResult(outcome: .sent)))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionSetModel, params: SessionSetModelParams(session: Self.remoteSession, model: "opus"), on: outbox)

        #expect(reply.error == nil)
        let texts = h.actions.remoteSends.map { $0.text }
        #expect(texts == ["/model opus"])
    }
}
