import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// `prompt.answer` and `prompt.changed`: the shaper, the ledger of phone
/// answers, the attribution of closed prompts, the prompt set, and the
/// service driven through `handleAppMessage`. Tier 1: the service over an
/// in-memory database, its own `PendingPromptStore` and
/// `StateSubscriptionManager`, and fake session actions that record what
/// would have reached the daemon. Nothing touches the disk, tmux or the
/// network.
@Suite("Phone prompt.answer and prompt.changed", .fastPassBounded)
struct PhonePromptTests {
    private static let remoteSession = PhoneSessionRef.remote(provider: "acme-cloud", sessionID: "rs-1")
    private static let allow = PromptAnswer.permission(decision: .allow, message: nil)
    private static let bashInput = #"{"command":"ls -la"}"#

    // MARK: - Helpers

    /// The fields of a `PromptAnswerParams`, which is not `Equatable`.
    private struct AnswerShape: Equatable {
        let terminalID: UUID
        let promptID: String
        let answer: PromptAnswer

        init(terminalID: UUID, promptID: String, answer: PromptAnswer) {
            self.terminalID = terminalID
            self.promptID = promptID
            self.answer = answer
        }

        init(_ p: PromptAnswerParams) {
            self.init(terminalID: p.terminalID, promptID: p.promptID, answer: p.answer)
        }
    }

    /// The fields of a `RemoteAnswerParams`, which is not `Equatable`.
    private struct RemoteAnswerShape: Equatable {
        let provider: String
        let sessionID: String
        let promptID: String
        let answer: PromptAnswer

        init(provider: String, sessionID: String, promptID: String, answer: PromptAnswer) {
            self.provider = provider
            self.sessionID = sessionID
            self.promptID = promptID
            self.answer = answer
        }

        init(_ p: RemoteAnswerParams) {
            self.init(provider: p.provider, sessionID: p.sessionID, promptID: p.promptID, answer: p.answer)
        }
    }

    /// The fields every app body has, so a test can tell replies from events.
    private struct BodyHead: Decodable {
        let kind: String
        let event: String?
        let requestID: String?
    }

    /// The core's reply for an answer that ended with `outcome`.
    private static func answered(_ outcome: PromptAnswerOutcome) throws -> RPCResponse {
        try RPCResponse(result: PromptAnswerResult(outcome: outcome))
    }

    /// The core's refusal of an answer that does not fit its prompt, as the
    /// answer handlers build it: the validation's message and its code.
    private static func refusing(_ validation: PromptAnswerValidation) -> RPCResponse {
        RPCResponse(error: validation.message, code: validation.code.rawValue)
    }

    private static func outcome(_ bytes: Data) throws -> PromptAnswerOutcome {
        try JSONDecoder().decode(PhoneReplyEnvelope<PromptAnswerResult>.self, from: bytes).result.outcome
    }

    private static func local(_ terminalID: UUID, _ promptID: String, _ answer: PromptAnswer = PhonePromptTests.allow) -> PhonePromptAnswerParams {
        PhonePromptAnswerParams(session: .local(terminalID: terminalID), promptID: promptID, answer: answer)
    }

    private static func payload(
        _ id: String, tool: String, input: String, suggestions: String? = nil
    ) -> PendingPromptPayload {
        PendingPromptPayload(
            id: id, kind: tool == "AskUserQuestion" ? .question : .permission, toolUseID: id, toolName: tool,
            toolInputJSON: input, suggestionsJSON: suggestions, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func askInput(_ questions: [[String: Any]]) throws -> String {
        try json(["questions": questions])
    }

    /// Connects the phone and makes the connection live with a fresh
    /// `sessions.subscribe`, so events go out on it. Returns once the
    /// sessions publisher holds its subscriber, so the subscriber count is
    /// steady from here.
    private static func liveConnection(_ h: PhoneServiceHarness) async throws -> CapturingOutbox {
        let outbox = await h.connect()
        let (reply, _) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: nil, sinceSeq: nil), on: outbox)
        #expect(reply.error == nil)
        let deviceID = h.peer.deviceID
        try await waitUntil("the sessions publisher to subscribe") {
            await h.service.sessionsPublisher(for: deviceID)?.isSubscribed == true
        }
        return outbox
    }

    /// Every `prompt.changed` event `outbox` has received, in order.
    private static func promptEvents(in outbox: CapturingOutbox) throws -> [PhoneEventEnvelope<PromptChangedData>] {
        var events: [PhoneEventEnvelope<PromptChangedData>] = []
        for body in outbox.bodies {
            let head = try JSONDecoder().decode(BodyHead.self, from: body)
            guard head.kind == "event", head.event == PhoneAppEventName.promptChanged.rawValue else { continue }
            events.append(try JSONDecoder().decode(PhoneEventEnvelope<PromptChangedData>.self, from: body))
        }
        return events
    }

    /// The `index`th `prompt.changed` event (from 0), once it has arrived.
    private static func promptEvent(_ index: Int, in outbox: CapturingOutbox) async throws -> PhoneEventEnvelope<PromptChangedData> {
        try await waitUntil("prompt.changed #\(index)") {
            ((try? promptEvents(in: outbox)) ?? []).count > index
        }
        return try promptEvents(in: outbox)[index]
    }

    /// The reply to the request `requestID`, once it has arrived.
    private static func reply(_ requestID: String, in outbox: CapturingOutbox) async throws -> Data {
        func find() -> Data? {
            outbox.bodies.first { body in
                let head = try? JSONDecoder().decode(BodyHead.self, from: body)
                return head?.kind == "reply" && head?.requestID == requestID
            }
        }
        try await waitUntil("the reply to \(requestID)") { find() != nil }
        return try #require(find())
    }

    // MARK: - prompt.answer, a local session

    @Test func answeringAnOpenPromptDelivers() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminalID = try await h.seedTerminal().id
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.delivered))
        let outbox = await h.connect()
        let answer = PromptAnswer.question(answers: ["Which branches?": "main, release"])

        let (reply, bytes) = try await h.request(
            .promptAnswer, params: Self.local(terminalID, "toolu-1", answer), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == .delivered)
        // The answer reaches the core exactly as the phone sent it, under the
        // verified peer's device, and the record names only the session.
        let answers = h.actions.answers.map(AnswerShape.init)
        #expect(answers == [AnswerShape(terminalID: terminalID, promptID: "toolu-1", answer: answer)])
        #expect(h.actions.calls == [FakeSessionActions.Call(method: .answerPrompt, deviceID: h.peer.deviceID)])
        #expect(h.recorder.records == [PhoneActionRecord(
            deviceName: "Acme Phone", action: "prompt.answer", target: "local:\(terminalID.uuidString)")])
    }

    @Test func answeringAnAnsweredPromptSaysAlreadyAnswered() async throws {
        let h = try await PhoneServiceHarness.make()
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.alreadyResolved))
        let outbox = await h.connect()

        let terminalID = try await h.seedTerminal().id
        let (reply, bytes) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == .alreadyResolved)
    }

    /// A core that could not say whether the answer landed says `unknown`,
    /// and the phone hears the same.
    @Test func anUnconfirmedAnswerSaysUnknown() async throws {
        let h = try await PhoneServiceHarness.make()
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.unknown))
        let outbox = await h.connect()

        let terminalID = try await h.seedTerminal().id
        let (reply, bytes) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == .unknown)
    }

    @Test func theHookDetachedRefusalIsRefused() async throws {
        let h = try await PhoneServiceHarness.make()
        h.actions.respond(to: .answerPrompt, with: RPCResponse(error: RPCRouter.promptHookDetachedRefusal))
        let outbox = await h.connect()

        let terminalID = try await h.seedTerminal().id
        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: RPCRouter.promptHookDetachedRefusal))
    }

    /// The core refuses while `transcript_prompt_answer_enabled` is off, in
    /// words written for a developer, and the phone gets the words its
    /// sessions list shows for the same thing instead, told by the refusal's
    /// code. The phone's own check reads the setting first, so this is the
    /// answer whose setting was turned off between the two reads: the setting
    /// here is on, and the fake core refuses as the real one would after the
    /// change. `PhonePromptAnswerRouterTests` runs the setting through the
    /// real core.
    @Test func theSettingsRefusalReachesThePhone() async throws {
        let h = try await PhoneServiceHarness.make()
        h.actions.respond(to: .answerPrompt, with: PromptAnswerRefusal.disabled.response)
        let outbox = await h.connect()

        let terminalID = try await h.seedTerminal().id
        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: PhoneSessionStatus.answerTurnedOffReason))
    }

    @Test func aRefusalWithNoReasonIsRefusedWithAFixedLine() async throws {
        let h = try await PhoneServiceHarness.make()
        h.actions.respond(to: .answerPrompt, with: RPCResponse(error: ""))
        let outbox = await h.connect()

        let terminalID = try await h.seedTerminal().id
        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: PhoneAppService.answerRefusedReason))
    }

    /// A success whose result does not decode is never taken for an answer.
    @Test func aResultThatDoesNotDecodeIsInternal() async throws {
        let h = try await PhoneServiceHarness.make()
        h.actions.respond(to: .answerPrompt, with: .ok())
        let outbox = await h.connect()

        let terminalID = try await h.seedTerminal().id
        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)

        #expect(reply.error?.code == .internalError)
    }

    @Test func aDenyMessagePassesThroughUnchanged() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminalID = try await h.seedTerminal().id
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.delivered))
        let outbox = await h.connect()
        let deny = PromptAnswer.permission(decision: .deny, message: "Not on main.\nUse a branch \u{2013} \u{E9}\u{540D} \"now\"")

        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1", deny), on: outbox)

        #expect(reply.error == nil)
        let answers = h.actions.answers.map(AnswerShape.init)
        #expect(answers == [AnswerShape(terminalID: terminalID, promptID: "toolu-1", answer: deny)])
    }

    /// A Deny reason of `promptTextCap` UTF-8 bytes is sent; one byte more
    /// is `bad_request`, and nothing reaches the core.
    @Test func aDenyReasonOverTheCapIsABadRequest() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminalID = try await h.seedTerminal().id
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.delivered))
        let outbox = await h.connect()
        let atCap = String(repeating: "\u{E9}", count: PhoneAppConstants.promptTextCap / 2)
        #expect(atCap.utf8.count == PhoneAppConstants.promptTextCap)

        let (tooLong, _) = try await h.request(
            .promptAnswer,
            params: Self.local(terminalID, "toolu-1", .permission(decision: .deny, message: atCap + "a")), on: outbox)

        #expect(tooLong.error == PhoneAppError(code: .badRequest, message: PhoneAppService.answerReasonTooLongReason))
        #expect(h.actions.calls.isEmpty)

        let (sent, _) = try await h.request(
            .promptAnswer, params: Self.local(terminalID, "toolu-1", .permission(decision: .deny, message: atCap)),
            on: outbox)

        #expect(sent.error == nil)
        #expect(h.actions.answers.count == 1)
    }

    @Test func aResentAnswerActsOnce() async throws {
        let h = try await PhoneServiceHarness.make()
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.delivered))
        let outbox = await h.connect()
        let terminalID = try await h.seedTerminal().id
        let params = Self.local(terminalID, "toolu-1")

        let (first, firstBytes) = try await h.request(.promptAnswer, id: "answer-1", params: params, on: outbox)
        let (again, againBytes) = try await h.request(.promptAnswer, id: "answer-1", params: params, on: outbox)

        #expect(first.error == nil)
        #expect(again.error == nil)
        #expect(h.actions.answers.count == 1)
        #expect(againBytes == firstBytes)
    }

    /// A local session whose `answer` the sessions list shows unavailable (a
    /// Codex session, a tab in a remote lane), and a shell, which the list
    /// does not show, are refused before anything is called, with the
    /// list's reason where it gives one.
    @Test(arguments: [
        (TerminalKind.codex, false, "Codex sessions show status only."),
        (TerminalKind.shell, false, "Only a Claude session can answer prompts."),
        (TerminalKind.claude, true, "This tab belongs to a remote lane. Use its remote session."),
    ])
    func anAnswerOnALocalSessionThatIsNotClaudeIsUnsupported(
        _ kind: TerminalKind, _ inRemoteLane: Bool, _ reason: String
    ) async throws {
        let h = try await PhoneServiceHarness.make()
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.delivered))
        let terminal = try await h.seedTerminal(kind: kind, inRemoteLane: inRemoteLane)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminal.id, "toolu-1"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .unsupported, message: reason))
        #expect(h.actions.answers.isEmpty)
        #expect(h.actions.calls.isEmpty)
    }

    /// Off, the setting for answering prompts refuses a local answer
    /// `unsupported` with the reason the sessions list shows, and the core is
    /// never called. On, the answer reaches the core.
    @Test(arguments: [false, true])
    func aLocalAnswerFollowsTheAnswerSetting(enabled: Bool) async throws {
        let h = try await PhoneServiceHarness.make()
        try await h.db.config.setTranscriptPromptAnswerEnabled(enabled)
        let terminalID = try await h.seedTerminal().id
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.delivered))
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)

        if enabled {
            #expect(reply.error == nil)
            #expect(try Self.outcome(bytes) == .delivered)
            #expect(h.actions.calls == [FakeSessionActions.Call(method: .answerPrompt, deviceID: h.peer.deviceID)])
        } else {
            #expect(reply.error == PhoneAppError(code: .unsupported, message: PhoneSessionStatus.answerTurnedOffReason))
            #expect(h.actions.answers.isEmpty)
            #expect(h.actions.calls.isEmpty)
        }
        // The refusal and the sessions list say the same.
        let snapshot = try await h.service.gatherSnapshot()
        let listed = snapshot.rows.flatMap(\.sessions).first { $0.ref == .local(terminalID: terminalID) }
        let session = try #require(listed)
        #expect(session.capabilities.answer.available == enabled)
        if !enabled {
            #expect(session.capabilities.answer.reason == reply.error?.message)
        }
    }

    /// A local session that cannot answer anyway keeps its own reason while
    /// the setting is off, as the sessions list shows it.
    @Test(arguments: [
        (TerminalKind.codex, false, "Codex sessions show status only."),
        (TerminalKind.shell, false, "Only a Claude session can answer prompts."),
        (TerminalKind.claude, true, "This tab belongs to a remote lane. Use its remote session."),
    ])
    func aSessionThatCannotAnswerKeepsItsReasonWhileTheSettingIsOff(
        _ kind: TerminalKind, _ inRemoteLane: Bool, _ reason: String
    ) async throws {
        let h = try await PhoneServiceHarness.make()
        try await h.db.config.setTranscriptPromptAnswerEnabled(false)
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.delivered))
        let terminal = try await h.seedTerminal(kind: kind, inRemoteLane: inRemoteLane)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminal.id, "toolu-1"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .unsupported, message: reason))
        #expect(h.actions.calls.isEmpty)
    }

    /// A setting for answering prompts that cannot be read refuses the
    /// answer before the core is called, local and remote, as `unsupported`
    /// with `answerSettingUnreadReason`, the reason the sessions list shows
    /// then. An `internal` reply would be remembered, and a phone reads it
    /// as an answer that may have landed. Phone control reads as on without
    /// the database, or the request would stop at that check.
    @Test func anUnreadableAnswerSettingRefusesTheAnswerBeforeTheCore() async throws {
        let h = try await PhoneServiceHarness.make(phoneControlAlwaysOn: true)
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.delivered))
        h.actions.respond(to: .answerRemotePrompt, with: try Self.answered(.delivered))
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.answer])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()
        try await h.makeConfigUnreadable()

        let (local, _) = try await h.request(.promptAnswer, params: Self.local(terminal.id, "toolu-1"), on: outbox)
        let (remote, _) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(session: Self.remoteSession, promptID: "rp-1", answer: Self.allow),
            on: outbox)

        let refused = PhoneAppError(code: .unsupported, message: PhoneSessionStatus.answerSettingUnreadReason)
        #expect(local.error == refused)
        #expect(remote.error == refused)
        #expect(h.actions.answers.isEmpty)
        #expect(h.actions.remoteAnswers.isEmpty)
        let answering = h.actions.calls.filter { $0.method == .answerPrompt || $0.method == .answerRemotePrompt }
        #expect(answering.isEmpty)
    }

    // MARK: - prompt.answer, a remote session

    @Test func aRemoteAnswerNeedsTheAnswerCapability() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.sendSubmit])
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(session: Self.remoteSession, promptID: "rp-1", answer: Self.allow),
            on: outbox)

        #expect(reply.error == PhoneAppError(
            code: .unsupported, message: "This provider does not support answering prompts."))
        #expect(h.actions.remoteAnswers.isEmpty)
        #expect(h.actions.calls == [FakeSessionActions.Call(method: .cachedRemoteProviders, deviceID: nil)])
    }

    @Test func aRemoteAnswerGoesToItsProvider() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.answer])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        h.actions.respond(to: .answerRemotePrompt, with: try Self.answered(.delivered))
        let outbox = await h.connect()
        let answer = PromptAnswer.permission(decision: .deny, message: "Not yet")

        let (reply, bytes) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(session: Self.remoteSession, promptID: "rp-1", answer: answer),
            on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.outcome(bytes) == .delivered)
        let remoteAnswers = h.actions.remoteAnswers.map(RemoteAnswerShape.init)
        #expect(remoteAnswers == [
            RemoteAnswerShape(provider: "acme-cloud", sessionID: "rs-1", promptID: "rp-1", answer: answer),
        ])
        #expect(h.actions.calls == [
            FakeSessionActions.Call(method: .cachedRemoteProviders, deviceID: nil),
            FakeSessionActions.Call(method: .remoteSessions, deviceID: nil),
            FakeSessionActions.Call(method: .answerRemotePrompt, deviceID: h.peer.deviceID),
        ])
        #expect(h.recorder.records == [PhoneActionRecord(
            deviceName: "Acme Phone", action: "prompt.answer", target: "remote:acme-cloud/rs-1")])
    }

    /// Off, the setting refuses a remote answer `unsupported` with the reason
    /// the sessions list shows, before the session list is read or the
    /// provider called, even where the provider declares `answer`. On, the
    /// answer reaches the provider. Either way the sessions list shows the
    /// session's `answer` as the refusal reads it.
    @Test(arguments: [false, true])
    func aRemoteAnswerFollowsTheAnswerSetting(enabled: Bool) async throws {
        let h = try await PhoneServiceHarness.make()
        try await h.db.config.setTranscriptPromptAnswerEnabled(enabled)
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.answer])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        h.actions.respond(to: .answerRemotePrompt, with: try Self.answered(.delivered))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(session: Self.remoteSession, promptID: "rp-1", answer: Self.allow),
            on: outbox)

        if enabled {
            #expect(reply.error == nil)
            #expect(h.actions.remoteAnswers.count == 1)
        } else {
            #expect(reply.error == PhoneAppError(code: .unsupported, message: PhoneSessionStatus.answerTurnedOffReason))
            #expect(h.actions.remoteAnswers.isEmpty)
            #expect(h.actions.calls == [FakeSessionActions.Call(method: .cachedRemoteProviders, deviceID: nil)])
        }
        let snapshot = try await h.service.gatherSnapshot()
        let shown = snapshot.rows.flatMap(\.sessions).first { $0.ref == Self.remoteSession }
        let session = try #require(shown)
        #expect(session.capabilities.answer.available == enabled)
    }

    /// A provider that does not declare `answer` keeps its own reason while
    /// the setting is off.
    @Test func aProviderThatCannotAnswerKeepsItsReasonWhileTheSettingIsOff() async throws {
        let h = try await PhoneServiceHarness.make()
        try await h.db.config.setTranscriptPromptAnswerEnabled(false)
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.sendSubmit])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(session: Self.remoteSession, promptID: "rp-1", answer: Self.allow),
            on: outbox)

        #expect(reply.error == PhoneAppError(
            code: .unsupported, message: "This provider does not support answering prompts."))
        #expect(h.actions.remoteAnswers.isEmpty)
    }

    @Test func aRemoteAnswerToAnUnregisteredProviderIsNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-other", capabilities: [RemoteCapability.answer])
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(session: Self.remoteSession, promptID: "rp-1", answer: Self.allow),
            on: outbox)

        #expect(reply.error?.code == .notFound)
        #expect(h.actions.remoteAnswers.isEmpty)
    }

    /// A remote answer's refusal reaches the phone only in words TBD wrote,
    /// told by its code and never by its words. The setting's codes get the
    /// words the sessions list shows for them, and `answerDoesNotFit` gets
    /// the phone's own sentence, whichever question its text names. A session
    /// state's and the remote gates' codes pass their text as it is. A
    /// refusal with no code becomes `remoteRefusedReason`: a provider's own
    /// words, which can quote a token, even ones shaped like TBD's
    /// `invalid_params` text, and TBD's own words sent with no code, which
    /// the phone cannot tell from a provider's.
    @Test func aRefusedRemoteAnswerKeepsOnlyTBDsOwnWords() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.answer])
        try h.actions.listRemoteSession("acme-cloud", "rs-1")
        let outbox = await h.connect()
        let question = PromptAnswer.question(answers: ["Which branch?": "main"])
        let cases: [(daemon: RPCResponse, answer: PromptAnswer, phone: String)] = [
            (RPCResponse(error: PhoneProviderSecret.error), Self.allow, PhoneAppService.remoteRefusedReason),
            (RPCResponse(error: "invalid_params: \(PhoneProviderSecret.error)"), Self.allow,
             PhoneAppService.remoteRefusedReason),
            (RPCResponse(error: ""), Self.allow, PhoneAppService.remoteRefusedReason),
            (PromptAnswerRefusal.disabled.response, Self.allow, PhoneSessionStatus.answerTurnedOffReason),
            (PromptAnswerRefusal.disabled.response, Self.allow, PhoneSessionStatus.answerTurnedOffReason),
            (PromptAnswerRefusal.settingUnread.response, Self.allow, PhoneSessionStatus.answerSettingUnreadReason),
            (PromptAnswerRefusal.notMirrored.response, Self.allow, PromptAnswerRefusal.notMirrored.text),
            (RemoteSendMessageRefusal.exited.response, Self.allow, RemoteSendMessageRefusal.exited.text),
            (RemoteGateRefusal.backendsDisabled.response, Self.allow, RemoteGateRefusal.backendsDisabled.text),
            (RemoteGateRefusal.claudeCloudDisabled.response, Self.allow, RemoteGateRefusal.claudeCloudDisabled.text),
            (Self.refusing(.kindMismatch), Self.allow, PhoneAppService.answerDoesNotFitReason),
            (Self.refusing(.unknownQuestion("Which branch?")), question, PhoneAppService.answerDoesNotFitReason),
            (Self.refusing(.missingAnswer(question: "Which repo?")), question, PhoneAppService.answerDoesNotFitReason),
            (RPCResponse(error: "any text at all", code: RPCErrorCode.answerDoesNotFit.rawValue),
             Self.allow, PhoneAppService.answerDoesNotFitReason),
            (RPCResponse(error: PromptAnswerRefusal.notMirrored.text), Self.allow, PhoneAppService.remoteRefusedReason),
            (RPCResponse(error: PromptAnswerValidation.kindMismatch.message), Self.allow,
             PhoneAppService.remoteRefusedReason),
        ]

        for (daemon, answer, phone) in cases {
            let said = "the daemon said \(daemon.error ?? "nothing") with code \(daemon.errorCode ?? "none")"
            h.actions.respond(to: .answerRemotePrompt, with: daemon)
            let (reply, bytes) = try await h.request(
                .promptAnswer,
                params: PhonePromptAnswerParams(session: Self.remoteSession, promptID: "rp-1", answer: answer),
                on: outbox)
            #expect(reply.error == PhoneAppError(code: .refused, message: phone), "\(said)")
            #expect(!PhoneProviderSecret.leaks(bytes), "\(said)")
        }
        #expect(h.actions.remoteAnswers.count == cases.count)
    }

    /// A code from the laptop's own verbs is decided too: the start-admission
    /// hold's reason is the user's own command's words and is shown, and a
    /// code this build does not know counts as none.
    @Test func aPreExistingCodeIsShownByItsOwnWordsAndAnUnknownOneIsNot() {
        let held = RPCResponse(error: "held: freeze until noon", code: RPCErrorCode.startHeld.rawValue)
        #expect(PhoneAppService.refusalWording(for: .startHeld) == .text)
        #expect(PhoneAppService.remoteRefusal(held, method: "remote.create")
            == PhoneAppError(code: .refused, message: "held: freeze until noon"))
        let unknown = RPCResponse(error: PhoneProviderSecret.error, code: "a_code_from_a_newer_build")
        #expect(unknown.knownErrorCode == nil)
        #expect(PhoneAppService.remoteRefusal(unknown, method: "remote.create")
            == PhoneAppError(code: .refused, message: PhoneAppService.remoteRefusedReason))
    }

    /// A local answer's refusal is told by its code too: the setting's codes
    /// get the words the sessions list shows for them, and `answerDoesNotFit`
    /// gets the phone's own sentence, whichever question its text names.
    @Test func aLocalAnswersCodedRefusalGetsThePhonesSentence() async throws {
        let h = try await PhoneServiceHarness.make()
        let outbox = await h.connect()
        let terminalID = try await h.seedTerminal().id
        let cases: [(daemon: RPCResponse, phone: String)] = [
            (Self.refusing(.allowAlwaysWithoutSuggestions), PhoneAppService.answerDoesNotFitReason),
            (Self.refusing(.unknownQuestion("Which branch?")), PhoneAppService.answerDoesNotFitReason),
            (PromptAnswerRefusal.disabled.response, PhoneSessionStatus.answerTurnedOffReason),
            (PromptAnswerRefusal.settingUnread.response, PhoneSessionStatus.answerSettingUnreadReason),
        ]

        for (index, (daemon, phone)) in cases.enumerated() {
            let said = "the daemon said \(daemon.error ?? "nothing") with code \(daemon.errorCode ?? "none")"
            h.actions.respond(to: .answerPrompt, with: daemon)
            let (reply, _) = try await h.request(
                .promptAnswer, params: Self.local(terminalID, "toolu-\(index)"), on: outbox)
            #expect(reply.error == PhoneAppError(code: .refused, message: phone), "\(said)")
        }
    }

    /// Answering one of a remote prompt's two questions is refused by TBD's
    /// validator, naming the question the phone left out. The refusal carries
    /// `answerDoesNotFit`, so the phone gets its own sentence for an answer
    /// that does not fit, not the generic provider line.
    @Test func answeringOneOfTwoQuestionsGetsThePhonesSentence() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let session = Self.remoteSession
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.answer])
        let prompt = RemotePendingPrompt(
            id: "rp-1", kind: .question,
            questions: [RemotePendingQuestionItem(prompt: "Which branch?"), RemotePendingQuestionItem(prompt: "Which repo?")])
        try Self.listRemoteSessions(h, open: prompt, elsewhere: nil)
        let outbox = try await Self.liveConnection(h)
        await h.service.openPrompts(session, for: deviceID)
        let first = try await Self.promptEvent(0, in: outbox)
        let sentIDs = first.data.prompts.map(\.id)
        #expect(sentIDs == ["rp-1"])
        h.actions.respond(
            to: .answerRemotePrompt, with: Self.refusing(.missingAnswer(question: "Which repo?")))

        let (reply, bytes) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(
                session: session, promptID: "rp-1", answer: .question(answers: ["Which branch?": "main"])),
            on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: PhoneAppService.answerDoesNotFitReason))
        #expect(!PhoneProviderSecret.leaks(bytes))
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A local answer's refusal is TBD's own, so the text of one with no code
    /// reaches the phone as it is: `remoteRefusedReason` is the remote path's
    /// alone.
    @Test func aLocalAnswersRefusalIsNotFiltered() async throws {
        let h = try await PhoneServiceHarness.make()
        h.actions.respond(to: .answerPrompt, with: RPCResponse(error: "invalid_params: the prompt has no question \"x\""))
        let outbox = await h.connect()

        let terminalID = try await h.seedTerminal().id
        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)

        #expect(reply.error == PhoneAppError(
            code: .refused, message: "invalid_params: the prompt has no question \"x\""))
    }

    // MARK: - The ledger of phone answers

    /// A phone's answer is kept for `answeredBy` when it was delivered or may
    /// have been, and dropped when the prompt was already answered, the core
    /// refused, or the result did not decode.
    @Test func onlyAnAnswerThatMayHaveLandedIsKept() async throws {
        let cases: [(response: RPCResponse, kept: Bool)] = try [
            (Self.answered(.delivered), true),
            (Self.answered(.unknown), true),
            (Self.answered(.alreadyResolved), false),
            (RPCResponse(error: RPCRouter.promptHookDetachedRefusal), false),
            (.ok(), false),
        ]
        for (response, kept) in cases {
            let h = try await PhoneServiceHarness.make()
            let terminalID = try await h.seedTerminal().id
            h.actions.respond(to: .answerPrompt, with: response)
            let outbox = await h.connect()

            _ = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)

            let key = PhonePromptAnswerLedger.Key(session: .local(terminalID: terminalID), promptID: "toolu-1")
            let answers = await h.service.phoneAnswers(for: [key])
            let expected: [String: PhonePromptAnswerLedger.Answerer] = kept ? ["toolu-1": .device(h.peer.deviceID)] : [:]
            #expect(answers == expected, "response: \(response)")
        }
    }

    /// Two phones answer one prompt: the one whose answer lost is dropped,
    /// the one whose answer was delivered is kept, and the prompt counts as
    /// being answered until both calls end.
    @Test func theLedgerKeepsTheWinnerOfARace() {
        var ledger = PhonePromptAnswerLedger()
        let key = PhonePromptAnswerLedger.Key(session: .local(terminalID: UUID()), promptID: "toolu-1")
        let winner = UUID()
        let loser = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        ledger.begin(key, token: 1, deviceID: winner, now: now)
        ledger.begin(key, token: 2, deviceID: loser, now: now)
        #expect(ledger.isAnswering(key))
        _ = ledger.finish(key, token: 2, settled: nil, now: now)
        #expect(ledger.isAnswering(key), "the winner's call still runs")
        #expect(ledger.answeredBy(key) == nil)
        _ = ledger.finish(key, token: 1, settled: .delivered, now: now)

        #expect(!ledger.isAnswering(key))
        #expect(ledger.answeredBy(key) == .device(winner))
    }

    /// A delivered answer beats one whose outcome is unknown, whichever
    /// began first: the prompt took the delivered one.
    @Test func aDeliveredAnswerBeatsAnUnknownOne() {
        var ledger = PhonePromptAnswerLedger()
        let key = PhonePromptAnswerLedger.Key(session: .local(terminalID: UUID()), promptID: "toolu-1")
        let unsure = UUID()
        let delivered = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        ledger.begin(key, token: 1, deviceID: unsure, now: now)
        ledger.begin(key, token: 2, deviceID: delivered, now: now)
        _ = ledger.finish(key, token: 1, settled: .unknown, now: now)
        _ = ledger.finish(key, token: 2, settled: .delivered, now: now)

        #expect(ledger.answeredBy(key) == .device(delivered))
    }

    /// Two phones whose answers both ended unknown: either may have landed,
    /// so the ledger names no phone, and the resolution says a phone
    /// answered with no device. One phone with two unknown answers is still
    /// named.
    @Test func twoPhonesWhoseAnswersBothEndedUnknownNameNoPhone() {
        let key = PhonePromptAnswerLedger.Key(session: .local(terminalID: UUID()), promptID: "toolu-1")
        let first = UUID()
        let second = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var two = PhonePromptAnswerLedger()
        two.begin(key, token: 1, deviceID: first, now: now)
        two.begin(key, token: 2, deviceID: second, now: now)
        _ = two.finish(key, token: 1, settled: .unknown, now: now)
        _ = two.finish(key, token: 2, settled: .unknown, now: now)
        #expect(two.answeredBy(key) == .unknownDevice)

        var one = PhonePromptAnswerLedger()
        one.begin(key, token: 1, deviceID: first, now: now)
        one.begin(key, token: 2, deviceID: first, now: now)
        _ = one.finish(key, token: 1, settled: .unknown, now: now)
        _ = one.finish(key, token: 2, settled: .unknown, now: now)
        #expect(one.answeredBy(key) == .device(first))

        let attribution = PhonePromptAttribution(phoneAnswers: ["toolu-1": .unknownDevice], localResolutions: nil)
        #expect(attribution.resolution(of: "toolu-1") == PhonePromptResolution(
            promptID: "toolu-1", answeredBy: .phone, deviceID: nil))
    }

    /// A running answer counts only for a read that stopped waiting for it,
    /// and then as one that may have landed: one phone answering is named,
    /// two are not, and a delivered answer still wins.
    @Test func aRunningAnswerCountsOnlyWhenTheReadStoppedWaiting() {
        var ledger = PhonePromptAnswerLedger()
        let key = PhonePromptAnswerLedger.Key(session: .local(terminalID: UUID()), promptID: "toolu-1")
        let first = UUID()
        let second = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        ledger.begin(key, token: 1, deviceID: first, now: now)
        #expect(ledger.answeredBy(key) == nil)
        #expect(ledger.answeredBy(key, countingRunning: true) == .device(first))
        ledger.begin(key, token: 2, deviceID: second, now: now)
        #expect(ledger.answeredBy(key, countingRunning: true) == .unknownDevice)
        _ = ledger.finish(key, token: 2, settled: .delivered, now: now)
        #expect(ledger.answeredBy(key, countingRunning: true) == .device(second))
    }

    /// A wait that expired parks no more reads, and one that ended ignores a
    /// late expiry.
    @Test func aWaitThatEndedIgnoresItsExpiry() {
        var ledger = PhonePromptAnswerLedger()
        ledger.beginWait(1)
        #expect(ledger.isWaiting(1))
        let expired = ledger.expire(1)
        #expect(expired.isEmpty)
        #expect(!ledger.isWaiting(1))
        ledger.endWait(1)

        ledger.beginWait(2)
        ledger.endWait(2)
        #expect(!ledger.isWaiting(2))
        let late = ledger.expire(2)
        #expect(late.isEmpty)
    }

    @Test func theLedgerDropsAnswersPastItsLifetimeAndItsLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let terminalID = UUID()
        func key(_ id: String) -> PhonePromptAnswerLedger.Key {
            PhonePromptAnswerLedger.Key(session: .local(terminalID: terminalID), promptID: id)
        }
        let device = UUID()

        var aged = PhonePromptAnswerLedger()
        aged.begin(key("old"), token: 1, deviceID: device, now: now)
        _ = aged.finish(key("old"), token: 1, settled: .delivered, now: now)
        aged.begin(key("new"), token: 2, deviceID: device, now: now.addingTimeInterval(PhonePromptAnswerLedger.lifetime + 1))
        #expect(aged.answeredBy(key("old")) == nil)

        var full = PhonePromptAnswerLedger()
        let count = PhonePromptAnswerLedger.settledLimit + 1
        for index in 0..<count {
            full.begin(key("p-\(index)"), token: UInt64(index + 1), deviceID: device, now: now)
            _ = full.finish(key("p-\(index)"), token: UInt64(index + 1), settled: .delivered, now: now)
        }
        #expect(full.answeredBy(key("p-0")) == nil)
        #expect(full.answeredBy(key("p-1")) == .device(device))
        #expect(full.answeredBy(key("p-\(count - 1)")) == .device(device))
    }

    /// A prompt opened again under the same ID: an answer that settled
    /// before its latest opening answered an earlier one and does not count.
    @Test func anAnswerToAnEarlierOpeningOfAPromptDoesNotCount() {
        var ledger = PhonePromptAnswerLedger()
        let key = PhonePromptAnswerLedger.Key(session: .local(terminalID: UUID()), promptID: "toolu-1")
        let device = UUID()
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.begin(key, token: 1, deviceID: device, now: opened.addingTimeInterval(5))
        _ = ledger.finish(key, token: 1, settled: .delivered, now: opened.addingTimeInterval(6))

        #expect(ledger.answeredBy(key) == .device(device))
        #expect(ledger.answeredBy(key, openedAt: opened) == .device(device))
        #expect(ledger.answeredBy(key, openedAt: opened.addingTimeInterval(60)) == nil)
    }

    // MARK: - Who answered

    @Test func aLocalPromptsResolutionSaysWhoAnswered() {
        let phone = UUID()
        let attribution = PhonePromptAttribution(
            phoneAnswers: [
                "by-phone": .device(phone), "phone-then-terminal": .device(phone),
                "phone-unrecorded": .device(phone), "phone-gone": .device(phone),
            ],
            localResolutions: [
                "by-phone": .answered,
                "by-app": .answered,
                "in-terminal": .answeredInTerminal,
                "phone-then-terminal": .answeredInTerminal,
                "phone-gone": .terminalGone,
                "session-ended": .sessionEnded,
                "mod-gone": .modDisconnected,
                "shutdown": .daemonShutdown,
            ])
        func by(_ id: String) -> PhonePromptResolution { attribution.resolution(of: id) }

        #expect(by("by-phone") == PhonePromptResolution(promptID: "by-phone", answeredBy: .phone, deviceID: phone))
        #expect(by("phone-unrecorded") == PhonePromptResolution(
            promptID: "phone-unrecorded", answeredBy: .phone, deviceID: phone))
        #expect(by("by-app") == PhonePromptResolution(promptID: "by-app", answeredBy: .laptop, deviceID: nil))
        #expect(by("in-terminal") == PhonePromptResolution(promptID: "in-terminal", answeredBy: .laptop, deviceID: nil))
        #expect(by("phone-then-terminal") == PhonePromptResolution(
            promptID: "phone-then-terminal", answeredBy: .laptop, deviceID: nil))
        for id in ["phone-gone", "session-ended", "mod-gone", "shutdown", "no-record"] {
            #expect(by(id) == PhonePromptResolution(promptID: id, answeredBy: .unknown, deviceID: nil))
        }
    }

    @Test func aRemotePromptsResolutionIsPhoneOrUnknown() {
        let phone = UUID()
        let attribution = PhonePromptAttribution(phoneAnswers: ["by-phone": .device(phone)], localResolutions: nil)

        #expect(attribution.resolution(of: "by-phone") == PhonePromptResolution(
            promptID: "by-phone", answeredBy: .phone, deviceID: phone))
        #expect(attribution.resolution(of: "elsewhere") == PhonePromptResolution(
            promptID: "elsewhere", answeredBy: .unknown, deviceID: nil))
    }

    /// A local prompt source decodes a delta only when it names the source's
    /// terminal: a prompt change of another terminal is passed over, and one
    /// of its own, as the subscription manager encodes it, is taken. The
    /// byte search looks for the ID as the manager writes it.
    @Test func aLocalPromptSourceTakesOnlyItsOwnTerminalsPromptChange() throws {
        let mine = UUID()
        let other = UUID()
        let subscriptions = StateSubscriptionManager()
        let broadcast = FireRecorder<Data>()
        subscriptions.addSubscriber { data in
            broadcast.record(data)
            return true
        }
        for terminalID in [mine, other] {
            subscriptions.broadcast(delta: .terminalPendingPromptsChanged(
                TerminalPendingPromptsDelta(terminalID: terminalID, captures: [], prompts: [])))
        }
        let deltas = broadcast.values
        try #require(deltas.count == 2)
        let own = deltas[0]
        let others = deltas[1]

        let marker = PhoneLocalPromptSource.idMarker(of: mine)
        #expect(own.range(of: marker) != nil)
        #expect(others.range(of: marker) == nil)
        #expect(PhoneLocalPromptSource.isPromptChange(own, for: mine, idMarker: marker))
        #expect(!PhoneLocalPromptSource.isPromptChange(others, for: mine, idMarker: marker))
        #expect(PhoneLocalPromptSource.isPromptChange(others, for: other))
    }

    /// The store keeps how each recently closed prompt ended, at most
    /// `recentResolutionLimit` of them for one terminal, and forgets a
    /// prompt's ending when it opens again.
    @Test func theStoreKeepsRecentResolutionsBounded() async {
        let store = PendingPromptStore()
        let terminalID = UUID()
        await store.open(
            terminalID: terminalID, sessionID: nil, toolUseID: "toolu-1", toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        await store.receipt(terminalID: terminalID, toolUseID: "toolu-1")

        let closed = await store.promptsAndResolutions(forTerminal: terminalID)
        #expect(closed.open.isEmpty)
        #expect(closed.resolved == ["toolu-1": .answered])
        #expect(await store.promptsAndResolutions(forTerminal: UUID()).resolved.isEmpty)

        await store.open(
            terminalID: terminalID, sessionID: nil, toolUseID: "toolu-1", toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        let reopened = await store.promptsAndResolutions(forTerminal: terminalID)
        let reopenedIDs = reopened.open.map(\.id)
        #expect(reopenedIDs == ["toolu-1"])
        #expect(reopened.resolved.isEmpty)

        let limit = PendingPromptStore.recentResolutionLimit
        for index in 0...limit {
            await store.open(
                terminalID: terminalID, sessionID: nil, toolUseID: "toolu-b\(index)", toolName: "Bash",
                toolInputJSON: Self.bashInput, suggestionsJSON: nil)
            await store.closed(terminalID: terminalID, toolUseID: "toolu-b\(index)")
        }
        let many = await store.promptsAndResolutions(forTerminal: terminalID)
        #expect(many.resolved.count == limit)
        #expect(many.resolved["toolu-b0"] == nil)
        #expect(many.resolved["toolu-b\(limit)"] == .answeredInTerminal)
    }

    /// A burst of closed prompts in one terminal pushes out only that
    /// terminal's oldest endings: another terminal's ending stays, though the
    /// burst is longer than the store keeps for all terminals together.
    @Test func oneTerminalsBurstLeavesAnothersResolutions() async {
        let store = PendingPromptStore()
        let quiet = UUID()
        let busy = UUID()
        await Self.openAndClose(store, terminalID: quiet, toolUseID: "toolu-q")

        let limit = PendingPromptStore.recentResolutionLimit
        let burst = PendingPromptStore.recentResolutionTerminalLimit + limit
        for index in 0..<burst {
            await Self.openAndClose(store, terminalID: busy, toolUseID: "toolu-b\(index)")
        }

        let quietResolved = await store.promptsAndResolutions(forTerminal: quiet).resolved
        #expect(quietResolved == ["toolu-q": .answeredInTerminal])
        let busyResolved = await store.promptsAndResolutions(forTerminal: busy).resolved
        #expect(busyResolved.count == limit)
        #expect(busyResolved["toolu-b\(burst - limit - 1)"] == nil)
        #expect(busyResolved["toolu-b\(burst - limit)"] == .answeredInTerminal)
        #expect(busyResolved["toolu-b\(burst - 1)"] == .answeredInTerminal)
    }

    /// The store keeps endings for at most `recentResolutionTerminalLimit`
    /// terminals, dropping the one whose last ending is oldest: a terminal
    /// that closes a prompt again moves to the newest.
    @Test func theStoreKeepsResolutionsForBoundedTerminals() async {
        let store = PendingPromptStore()
        let terminalLimit = PendingPromptStore.recentResolutionTerminalLimit
        let terminals = (0...terminalLimit).map { _ in UUID() }
        for terminalID in terminals.dropLast() {
            await Self.openAndClose(store, terminalID: terminalID, toolUseID: "toolu-1")
        }
        // The first terminal closes another prompt, so the second is now the
        // one whose last ending is oldest.
        await Self.openAndClose(store, terminalID: terminals[0], toolUseID: "toolu-2")

        await Self.openAndClose(store, terminalID: terminals[terminalLimit], toolUseID: "toolu-1")

        let first = await store.promptsAndResolutions(forTerminal: terminals[0]).resolved
        #expect(first == ["toolu-1": .answeredInTerminal, "toolu-2": .answeredInTerminal])
        let second = await store.promptsAndResolutions(forTerminal: terminals[1]).resolved
        #expect(second.isEmpty)
        let third = await store.promptsAndResolutions(forTerminal: terminals[2]).resolved
        #expect(third == ["toolu-1": .answeredInTerminal])
        let newest = await store.promptsAndResolutions(forTerminal: terminals[terminalLimit]).resolved
        #expect(newest == ["toolu-1": .answeredInTerminal])
    }

    /// Opens a Bash prompt in `terminalID` and closes it in the terminal.
    private static func openAndClose(_ store: PendingPromptStore, terminalID: UUID, toolUseID: String) async {
        await store.open(
            terminalID: terminalID, sessionID: nil, toolUseID: toolUseID, toolName: "Bash",
            toolInputJSON: bashInput, suggestionsJSON: nil)
        await store.closed(terminalID: terminalID, toolUseID: toolUseID)
    }

    // MARK: - Shaping

    @Test func aPermissionPromptOffersAllowAlwaysOnlyWithSuggestions() {
        let plain = PhonePromptShaper.local(Self.payload("toolu-1", tool: "Bash", input: #"{"command":"rm -rf build"}"#))
        #expect(plain == PhonePrompt(
            id: "toolu-1", kind: "permission", toolName: "Bash", summary: "Bash rm -rf build",
            target: "rm -rf build", targetTruncated: false, questions: nil, suggestions: nil, allowAlways: false))

        let suggestions = #"[{"behavior":"allow","destination":"localSettings","rules":[{"ruleContent":"rm:*","toolName":"Bash"}],"type":"addRules"}]"#
        let offered = PhonePromptShaper.local(Self.payload(
            "toolu-2", tool: "Bash", input: #"{"command":"rm -rf build"}"#, suggestions: suggestions))
        #expect(offered.allowAlways)
        #expect(offered.suggestions == ["allows Bash(rm:*)"])

        let none = PhonePromptShaper.local(Self.payload(
            "toolu-3", tool: "Bash", input: #"{"command":"rm -rf build"}"#, suggestions: "[]"))
        #expect(!none.allowAlways)
        #expect(none.suggestions == nil)
    }

    /// The target is the input's `command`, else its `file_path`, else the
    /// whole input as compact sorted-key JSON, cut to `promptTextCap`.
    @Test func aPermissionsTargetIsWhatTheLaptopCardPreviews() throws {
        let write = PhonePromptShaper.local(Self.payload(
            "toolu-1", tool: "Write", input: #"{"content":"x","file_path":"/acme/widgets/main.swift"}"#))
        #expect(write.target == "/acme/widgets/main.swift")
        #expect(write.summary == "Write main.swift")

        let fetch = PhonePromptShaper.local(Self.payload(
            "toolu-2", tool: "WebFetch", input: #"{"url":"https://acme.example/a","prompt":"read it"}"#))
        #expect(fetch.target == #"{"prompt":"read it","url":"https://acme.example/a"}"#)
        #expect(fetch.targetTruncated == false)

        let longCommand = String(repeating: "a", count: PhoneAppConstants.promptTextCap + 100)
        let long = PhonePromptShaper.local(Self.payload(
            "toolu-3", tool: "Bash", input: try Self.json(["command": longCommand])))
        #expect(long.target == String(repeating: "a", count: PhoneAppConstants.promptTextCap))
        #expect(long.targetTruncated)
    }

    @Test func aQuestionPromptKeepsItsOptions() throws {
        let questions: [[String: Any]] = [
            ["question": "Which database?", "header": "Database", "multiSelect": false,
             "options": [["label": "Postgres", "description": "The default"], ["label": "SQLite"]]],
            ["question": "Which features?", "header": "Features", "multiSelect": true,
             "options": [["label": "Search", "description": "Full text"], ["label": "Export"]]],
        ]

        let prompt = PhonePromptShaper.local(Self.payload("toolu-q", tool: "AskUserQuestion", input: try Self.askInput(questions)))

        #expect(prompt == PhonePrompt(
            id: "toolu-q", kind: "question", toolName: "AskUserQuestion", summary: nil, target: nil,
            targetTruncated: false,
            questions: [
                PhoneQuestion(text: "Which database?", header: "Database", multiSelect: false, options: [
                    PhoneOption(label: "Postgres", description: "The default"),
                    PhoneOption(label: "SQLite", description: nil),
                ]),
                PhoneQuestion(text: "Which features?", header: "Features", multiSelect: true, options: [
                    PhoneOption(label: "Search", description: "Full text"),
                    PhoneOption(label: "Export", description: nil),
                ]),
            ],
            suggestions: nil, allowAlways: false))
    }

    /// A question's text and an option's label go whole however long they
    /// are, since an answer is keyed on them; a long option description is
    /// cut.
    @Test func aQuestionsTextAndLabelsGoWholeAndALongDescriptionIsCut() throws {
        let longLabel = String(repeating: "x", count: PhoneAppConstants.promptOptionCap + 1)
        let longText = String(repeating: "q", count: PhoneAppConstants.promptTextCap + 10)
        let longDescription = String(repeating: "d", count: PhoneAppConstants.promptOptionCap + 10)
        let questions: [[String: Any]] = [
            ["question": longText,
             "options": [["label": longLabel, "description": longDescription], ["label": "Fine"]]],
        ]

        let prompt = PhonePromptShaper.local(Self.payload("toolu-q", tool: "AskUserQuestion", input: try Self.askInput(questions)))

        let question = try #require(prompt.questions?.first)
        #expect(question.text == longText)
        #expect(question.options == [
            PhoneOption(label: longLabel, description: String(repeating: "d", count: PhoneAppConstants.promptOptionCap)),
            PhoneOption(label: "Fine", description: nil),
        ])
    }

    /// A permission shows at most `suggestionLimit` suggestion lines, the
    /// last saying how many more there are, and still offers allow-always.
    @Test func aPermissionShowsAtMostTheSuggestionLimit() throws {
        let rules: [[String: String]] = (0..<40).map { ["toolName": "Bash", "ruleContent": "cmd\($0):*"] }
        let suggestion: [String: Any] = [
            "type": "addRules", "behavior": "allow", "destination": "localSettings", "rules": rules,
        ]
        let suggestions = String(
            decoding: try JSONSerialization.data(withJSONObject: [suggestion], options: [.sortedKeys]), as: UTF8.self)

        let prompt = PhonePromptShaper.local(Self.payload(
            "toolu-1", tool: "Bash", input: Self.bashInput, suggestions: suggestions))

        let lines = try #require(prompt.suggestions)
        try #require(lines.count == PhonePromptShaper.suggestionLimit)
        #expect(lines.first == "allows Bash(cmd0:*)")
        #expect(lines[30] == "allows Bash(cmd30:*)")
        #expect(lines.last == "and 9 more")
        #expect(prompt.allowAlways)
        let atTheLimit = (0..<PhonePromptShaper.suggestionLimit).map { "line \($0)" }
        #expect(PhonePromptShaper.limited(atTheLimit) == atTheLimit)
    }

    @Test func aRemotePromptIsShapedLikeALocalOne() {
        let question = PhonePromptShaper.remote(RemotePendingPrompt(
            id: "rp-1", kind: .question,
            questions: [RemotePendingQuestionItem(
                prompt: "Ship it?", label: "Ship", multi: false,
                options: [RemotePendingQuestionOption(label: "Yes", description: "Now"),
                          RemotePendingQuestionOption(label: "No")])]))
        #expect(question.kind == "question")
        #expect(question.questions == [PhoneQuestion(text: "Ship it?", header: "Ship", multiSelect: false, options: [
            PhoneOption(label: "Yes", description: "Now"), PhoneOption(label: "No", description: nil),
        ])])

        // A target the provider cut counts as truncated, however short.
        let permission = PhonePromptShaper.remote(RemotePendingPrompt(
            id: "rp-2", kind: .permission, toolName: "Bash", toolInputJSON: #"{"command":"make"}"#,
            toolInputTruncated: true))
        #expect(permission.target == "make")
        #expect(permission.targetTruncated)
        #expect(permission.allowAlways == false)
    }

    // MARK: - One frame

    /// Four questions of four options, made of characters that take the
    /// most bytes once encoded, with each question's text at
    /// `promptTextCap` and each label at `promptOptionCap` (the shaper cuts
    /// neither, so the test does), every other text over its cap, plus 64
    /// resolutions, fit one frame with nothing left out.
    @Test func fourQuestionsOfFourOptionsAtTheCapsFitOneFrame() throws {
        // 2 + 2 + 6 + 3 bytes once encoded.
        let unit = "\u{E9}\"\u{1}\u{540D}"
        let long = String(repeating: unit, count: 1_000)
        let label: (Int) -> String = { index in
            PhonePromptShaper.cut("\(index)" + long, to: PhoneAppConstants.promptOptionCap).text
        }
        let text: (Int) -> String = { index in
            PhonePromptShaper.cut("\(index)" + long, to: PhoneAppConstants.promptTextCap).text
        }
        let questions: [[String: Any]] = (0..<4).map { index -> [String: Any] in
            ["question": text(index), "header": long, "multiSelect": true,
             "options": (0..<4).map { option -> [String: String] in ["label": label(option), "description": long] }]
        }
        let prompt = PhonePromptShaper.local(Self.payload(
            "toolu_01ABCDEFGHIJKLMNOPQRSTUVWX", tool: "AskUserQuestion", input: try Self.askInput(questions)))

        let shaped = try #require(prompt.questions)
        #expect(shaped.count == 4)
        let labels = (0..<4).map(label)
        let texts = shaped.map(\.text)
        let expectedTexts = (0..<4).map(text)
        #expect(texts == expectedTexts, "question text goes whole")
        for question in shaped {
            let shapedLabels = question.options.map(\.label)
            #expect(shapedLabels == labels)
            #expect(PhonePromptShaper.escapedLength(question.text) == PhoneAppConstants.promptTextCap)
            #expect(PhonePromptShaper.escapedLength(question.header ?? "") <= PhoneText.fieldLimit)
            for option in question.options {
                #expect(PhonePromptShaper.escapedLength(option.label) <= PhoneAppConstants.promptOptionCap)
                #expect(PhonePromptShaper.escapedLength(option.description ?? "") <= PhoneAppConstants.promptOptionCap)
            }
        }
        let resolved = (0..<64).map { index in
            PhonePromptResolution(promptID: "toolu_01ABCDEFGHIJKLMNOPQR\(1_000 + index)", answeredBy: .phone, deviceID: UUID())
        }
        let data = PromptChangedData(session: .local(terminalID: UUID()), prompts: [prompt], resolved: resolved)

        #expect(PhonePromptShaper.fitted(data) == data, "nothing is left out")
        #expect(try PhoneAppCoding.makeEncoder().encode(data).count <= PhoneFrameBudget.eventDataBytes)
        let event = try PhoneAppCoding.event(.promptChanged, seq: Int.max, data: data)
        #expect(PhoneAppCoding.framedSize(event) <= PhoneFrameBudget.maxPlaintext)
    }

    /// Prompts that together pass the frame: the oldest are kept whole, the
    /// newest left out.
    @Test func fittingLeavesOutTheNewestPromptsThatDoNotFit() throws {
        let session = PhoneSessionRef.local(terminalID: UUID())
        let big = String(repeating: "a", count: 40_000)
        func prompt(_ id: String) -> PhonePrompt {
            PhonePrompt(
                id: id, kind: "permission", toolName: "Bash", summary: nil, target: big, targetTruncated: false,
                questions: nil, suggestions: nil, allowAlways: false)
        }
        let earlier = PhonePromptResolution(promptID: "toolu-0", answeredBy: .laptop, deviceID: nil)

        let fitted = PhonePromptShaper.fitted(PromptChangedData(
            session: session, prompts: [prompt("toolu-1"), prompt("toolu-2")], resolved: [earlier]))

        let keptIDs = fitted.prompts.map(\.id)
        #expect(keptIDs == ["toolu-1"])
        #expect(fitted.resolved == [earlier])
        #expect(try PhoneAppCoding.makeEncoder().encode(fitted).count <= PhoneFrameBudget.eventDataBytes)
    }

    /// A prompt too large for any frame is left out, and the newer prompts
    /// after it still show. It was never sent, so its closing is never
    /// reported.
    @Test func aPromptTooLargeForAnyFrameIsLeftOutAndNewerOnesShow() throws {
        let session = PhoneSessionRef.local(terminalID: UUID())
        func prompt(_ id: String, target: String) -> PhonePrompt {
            PhonePrompt(
                id: id, kind: "permission", toolName: "Bash", summary: nil, target: target, targetTruncated: false,
                questions: nil, suggestions: nil, allowAlways: false)
        }
        let huge = prompt("toolu-1", target: String(repeating: "a", count: PhoneFrameBudget.eventDataBytes))
        let small = prompt("toolu-2", target: "make")
        let later = prompt("toolu-3", target: "make test")

        let fitted = PhonePromptShaper.fitted(PromptChangedData(
            session: session, prompts: [huge, small, later], resolved: nil))

        let keptIDs = fitted.prompts.map(\.id)
        #expect(keptIDs == ["toolu-2", "toolu-3"])
        #expect(try PhoneAppCoding.makeEncoder().encode(fitted).count <= PhoneFrameBudget.eventDataBytes)

        var set = PhonePromptSet(session: session)
        let firstChange = set.advance(to: [huge, small], attribution: PhonePromptAttribution())
        let first = try #require(firstChange)
        let firstIDs = first.prompts.map(\.id)
        #expect(firstIDs == ["toolu-2"])
        #expect(set.advance(to: [small], attribution: PhonePromptAttribution()) == nil, "nothing the phone has changed")
    }

    /// Resolutions past the budget are left out, the newest first, and the
    /// result fills the budget exactly when one fits exactly.
    @Test func fittingLeavesOutResolutionsThatDoNotFit() throws {
        let session = PhoneSessionRef.local(terminalID: UUID())
        let resolutions = (1...3).map { PhonePromptResolution(promptID: "toolu-\($0)", answeredBy: .unknown, deviceID: nil) }
        let one = PromptChangedData(session: session, prompts: [], resolved: [resolutions[0]])
        let budget = try PhoneAppCoding.makeEncoder().encode(one).count

        let fitted = PhonePromptShaper.fitted(
            PromptChangedData(session: session, prompts: [], resolved: resolutions), budget: budget)

        #expect(fitted == one)
    }

    // MARK: - The prompt set

    @Test func aPromptSetSendsItsFirstSetThenOnlyChanges() {
        let session = PhoneSessionRef.local(terminalID: UUID())
        let prompt = PhonePromptShaper.local(Self.payload("toolu-a", tool: "Bash", input: Self.bashInput))
        var set = PhonePromptSet(session: session)

        #expect(set.advance(to: [], attribution: PhonePromptAttribution())
            == PromptChangedData(session: session, prompts: [], resolved: nil))
        #expect(set.advance(to: [], attribution: PhonePromptAttribution()) == nil)
        #expect(set.advance(to: [prompt], attribution: PhonePromptAttribution())
            == PromptChangedData(session: session, prompts: [prompt], resolved: nil))
        let closed = PhonePromptAttribution(phoneAnswers: [:], localResolutions: ["toolu-a": .answeredInTerminal])
        #expect(set.advance(to: [], attribution: closed) == PromptChangedData(
            session: session, prompts: [],
            resolved: [PhonePromptResolution(promptID: "toolu-a", answeredBy: .laptop, deviceID: nil)]))
    }

    /// The set keeps when each prompt it sent was opened, and updates it
    /// even when the prompts themselves are unchanged.
    @Test func aPromptSetKeepsWhenEachSentPromptWasOpened() {
        let session = PhoneSessionRef.local(terminalID: UUID())
        let prompt = PhonePromptShaper.local(Self.payload("toolu-a", tool: "Bash", input: Self.bashInput))
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let again = first.addingTimeInterval(30)
        var set = PhonePromptSet(session: session)

        #expect(set.advance(to: [prompt], openedAt: ["toolu-a": first, "toolu-x": first],
                            attribution: PhonePromptAttribution()) != nil)
        #expect(set.openedAt(of: ["toolu-a", "toolu-x"]) == ["toolu-a": first], "only prompts sent are kept")
        #expect(set.advance(to: [prompt], openedAt: ["toolu-a": again], attribution: PhonePromptAttribution()) == nil)
        #expect(set.openedAt(of: ["toolu-a"]) == ["toolu-a": again])
    }

    // MARK: - prompt.changed through the service

    /// The open session's full set goes out when the feed starts, empty
    /// included, and again on every change, with how each closed prompt
    /// ended. Each event is numbered on the device's stream.
    @Test func aPromptChangeSendsTheFullSet() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let terminalID = UUID()
        let session = PhoneSessionRef.local(terminalID: terminalID)
        let outbox = try await Self.liveConnection(h)

        await h.service.openPrompts(session, for: deviceID)
        let first = try await Self.promptEvent(0, in: outbox)
        #expect(first.data == PromptChangedData(session: session, prompts: [], resolved: nil))

        await h.pendingPrompts.open(
            terminalID: terminalID, sessionID: nil, toolUseID: "toolu-1", toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        await h.pendingPrompts.open(
            terminalID: terminalID, sessionID: nil, toolUseID: "toolu-2", toolName: "AskUserQuestion",
            toolInputJSON: try Self.askInput([["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]),
            suggestionsJSON: nil)
        let expected = await h.pendingPrompts.prompts(forTerminal: terminalID).map(PhonePromptShaper.local)
        let expectedIDs = expected.map(\.id)
        #expect(expectedIDs == ["toolu-1", "toolu-2"])
        await h.subscriptions.broadcastPendingPrompts(terminalID: terminalID, from: h.pendingPrompts)
        let opened = try await Self.promptEvent(1, in: outbox)
        #expect(opened.data == PromptChangedData(session: session, prompts: expected, resolved: nil))

        // Answered in the terminal: the laptop.
        await h.pendingPrompts.closed(terminalID: terminalID, toolUseID: "toolu-1")
        await h.subscriptions.broadcastPendingPrompts(terminalID: terminalID, from: h.pendingPrompts)
        let one = try await Self.promptEvent(2, in: outbox)
        #expect(one.data == PromptChangedData(
            session: session, prompts: [expected[1]],
            resolved: [PhonePromptResolution(promptID: "toolu-1", answeredBy: .laptop, deviceID: nil)]))

        // The session ended: nobody knows who answered.
        await h.pendingPrompts.resolvePrompts(terminalID: terminalID, .sessionEnded)
        await h.subscriptions.broadcastPendingPrompts(terminalID: terminalID, from: h.pendingPrompts)
        let none = try await Self.promptEvent(3, in: outbox)
        #expect(none.data == PromptChangedData(
            session: session, prompts: [],
            resolved: [PhonePromptResolution(promptID: "toolu-2", answeredBy: .unknown, deviceID: nil)]))

        let seqs = [first.seq, opened.seq, one.seq, none.seq]
        #expect(seqs == seqs.sorted() && Set(seqs).count == 4)
        #expect(try Self.promptEvents(in: outbox).count == 4)
        await h.service.phoneRevoked(deviceID: deviceID)
        #expect(h.subscriptions.subscriberCount == 0)
    }

    /// A prompt the phone answered, closed by the mod's receipt, says
    /// `phone` with the phone's device.
    @Test func aPromptThePhoneAnsweredSaysPhone() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let terminalID = try await h.seedTerminal().id
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.delivered))
        await h.pendingPrompts.open(
            terminalID: terminalID, sessionID: nil, toolUseID: "toolu-1", toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        let outbox = try await Self.liveConnection(h)
        await h.service.openPrompts(.local(terminalID: terminalID), for: deviceID)
        let first = try await Self.promptEvent(0, in: outbox)
        let firstIDs = first.data.prompts.map(\.id)
        #expect(firstIDs == ["toolu-1"])

        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)
        #expect(reply.error == nil)
        await h.pendingPrompts.receipt(terminalID: terminalID, toolUseID: "toolu-1")
        await h.subscriptions.broadcastPendingPrompts(terminalID: terminalID, from: h.pendingPrompts)

        let closed = try await Self.promptEvent(1, in: outbox)
        #expect(closed.data == PromptChangedData(
            session: .local(terminalID: terminalID), prompts: [],
            resolved: [PhonePromptResolution(promptID: "toolu-1", answeredBy: .phone, deviceID: deviceID)]))
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A prompt the phone answered, opened again under the same ID and then
    /// answered from the laptop's TBD app, says `laptop`: the phone's answer
    /// was to its earlier opening.
    @Test func aReopenedPromptAnsweredOnTheLaptopSaysLaptop() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let terminalID = try await h.seedTerminal().id
        let session = PhoneSessionRef.local(terminalID: terminalID)
        h.actions.respond(to: .answerPrompt, with: try Self.answered(.delivered))
        await h.pendingPrompts.open(
            terminalID: terminalID, sessionID: nil, toolUseID: "toolu-1", toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        let outbox = try await Self.liveConnection(h)
        await h.service.openPrompts(session, for: deviceID)
        _ = try await Self.promptEvent(0, in: outbox)
        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)
        #expect(reply.error == nil)
        await h.pendingPrompts.receipt(terminalID: terminalID, toolUseID: "toolu-1")
        await h.subscriptions.broadcastPendingPrompts(terminalID: terminalID, from: h.pendingPrompts)
        let byPhone = try await Self.promptEvent(1, in: outbox)
        #expect(byPhone.data.resolved == [
            PhonePromptResolution(promptID: "toolu-1", answeredBy: .phone, deviceID: deviceID),
        ])

        await h.pendingPrompts.open(
            terminalID: terminalID, sessionID: nil, toolUseID: "toolu-1", toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        await h.subscriptions.broadcastPendingPrompts(terminalID: terminalID, from: h.pendingPrompts)
        let reopened = try await Self.promptEvent(2, in: outbox)
        let reopenedIDs = reopened.data.prompts.map(\.id)
        #expect(reopenedIDs == ["toolu-1"])
        await h.pendingPrompts.receipt(terminalID: terminalID, toolUseID: "toolu-1")
        await h.subscriptions.broadcastPendingPrompts(terminalID: terminalID, from: h.pendingPrompts)

        let byLaptop = try await Self.promptEvent(3, in: outbox)
        #expect(byLaptop.data == PromptChangedData(
            session: session, prompts: [],
            resolved: [PhonePromptResolution(promptID: "toolu-1", answeredBy: .laptop, deviceID: nil)]))
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A prompt that closes while a phone's answer to it is still in the
    /// core waits for that answer: delivered says `phone`, and an answer
    /// that lost to the laptop's (`already_resolved`) says `laptop`.
    @Test(arguments: [PromptAnswerOutcome.delivered, .alreadyResolved])
    func aPhoneAnswerStillRunningIsWaitedFor(outcome: PromptAnswerOutcome) async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let terminalID = try await h.seedTerminal().id
        let gate = PhoneTestGate()
        h.actions.hold(.answerPrompt, on: gate)
        h.actions.respond(to: .answerPrompt, with: try Self.answered(outcome))
        await h.pendingPrompts.open(
            terminalID: terminalID, sessionID: nil, toolUseID: "toolu-1", toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        let outbox = try await Self.liveConnection(h)
        await h.service.openPrompts(.local(terminalID: terminalID), for: deviceID)
        _ = try await Self.promptEvent(0, in: outbox)

        // The reply and the event race once the gate opens, so the request
        // is handed in directly and its reply found by its ID.
        let body = try PhoneTestRequests.body(.promptAnswer, id: "answer-1", params: Self.local(terminalID, "toolu-1"))
        await h.service.handleAppMessage(body, from: h.peer)
        try await waitUntil("the answer to reach the core") { h.actions.answers.count == 1 }
        await h.pendingPrompts.receipt(terminalID: terminalID, toolUseID: "toolu-1")
        await h.subscriptions.broadcastPendingPrompts(terminalID: terminalID, from: h.pendingPrompts)
        try await waitUntil("the feed to wait for the phone's answer") {
            await h.service.phoneAnswerWaiterCount() > 0
        }
        #expect(try Self.promptEvents(in: outbox).count == 1, "nothing is sent while the answer runs")
        gate.open()

        let closed = try await Self.promptEvent(1, in: outbox)
        let expected = outcome == .delivered
            ? PhonePromptResolution(promptID: "toolu-1", answeredBy: .phone, deviceID: deviceID)
            : PhonePromptResolution(promptID: "toolu-1", answeredBy: .laptop, deviceID: nil)
        #expect(closed.data.prompts.isEmpty)
        #expect(closed.data.resolved == [expected])
        let replyBytes = try await Self.reply("answer-1", in: outbox)
        #expect(try Self.outcome(replyBytes) == outcome)
        #expect(await h.service.phoneAnswerWaiterCount() == 0)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A remote prompt that closes while the provider still holds the
    /// phone's answer to it waits for that answer only
    /// `answerAttributionWait`: the `prompt.changed` carrying the next prompt
    /// goes out once that much time passes on the clock, with the closed
    /// prompt said to be this phone's, and the answer's own reply still
    /// comes when the provider returns.
    @Test func aHeldRemoteAnswerDelaysPromptChangedOnlyToTheBound() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let session = Self.remoteSession
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.answer])
        let gate = PhoneTestGate()
        h.actions.hold(.answerRemotePrompt, on: gate)
        h.actions.respond(to: .answerRemotePrompt, with: try Self.answered(.delivered))
        let answered = RemotePendingPrompt(
            id: "rp-1", kind: .permission, toolName: "Bash", toolInputJSON: #"{"command":"make"}"#)
        let next = RemotePendingPrompt(
            id: "rp-2", kind: .permission, toolName: "Bash", toolInputJSON: #"{"command":"make test"}"#)
        try Self.listRemoteSessions(h, open: answered, elsewhere: nil)
        let outbox = try await Self.liveConnection(h)
        await h.service.openPrompts(session, for: deviceID)
        _ = try await Self.promptEvent(0, in: outbox)

        let body = try PhoneTestRequests.body(
            .promptAnswer, id: "answer-1",
            params: PhonePromptAnswerParams(session: session, promptID: "rp-1", answer: Self.allow))
        await h.service.handleAppMessage(body, from: h.peer)
        try await waitUntil("the answer to reach the provider") { h.actions.remoteAnswers.count == 1 }
        try Self.listRemoteSessions(h, open: next, elsewhere: nil)
        h.subscriptions.broadcast(delta: .remoteSessionsChanged)
        try await waitUntil("the feed to wait for the phone's answer") {
            await h.service.phoneAnswerWaiterCount() > 0
        }
        #expect(try Self.promptEvents(in: outbox).count == 1, "nothing is sent while the wait runs")

        // The sessions publisher's catch-up window, and the wait's bound.
        try await h.clock.requireSleepersArmed(count: 2, timeout: TestDeadlines.saturatedPass)
        await h.clock.advance(by: PhoneAppConstants.answerAttributionWait)

        let changed = try await Self.promptEvent(1, in: outbox)
        #expect(changed.data == PromptChangedData(
            session: session, prompts: [PhonePromptShaper.remote(next)],
            resolved: [PhonePromptResolution(promptID: "rp-1", answeredBy: .phone, deviceID: deviceID)]))
        #expect(await h.service.phoneAnswerWaiterCount() == 0)
        let answering = h.actions.remoteAnswers.count
        #expect(answering == 1)

        gate.open()
        let replyBytes = try await Self.reply("answer-1", in: outbox)
        #expect(try Self.outcome(replyBytes) == .delivered)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A remote session's set comes from the laptop's remote session list,
    /// read once the feed opens and again on every `.remoteSessionsChanged`
    /// (`PhoneRemotePromptSource`). Another session's prompt is not this
    /// feed's, and a closed remote prompt says `phone` when this phone
    /// answered it and `unknown` otherwise.
    @Test func aRemotePromptSaysPhoneOnlyWhenThePhoneAnsweredIt() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let session = Self.remoteSession
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.answer])
        h.actions.respond(to: .answerRemotePrompt, with: try Self.answered(.delivered))
        let answered = RemotePendingPrompt(
            id: "rp-1", kind: .permission, toolName: "Bash", toolInputJSON: #"{"command":"make"}"#)
        let unanswered = RemotePendingPrompt(
            id: "rp-2", kind: .permission, toolName: "Bash", toolInputJSON: #"{"command":"make test"}"#)
        let elsewhere = RemotePendingPrompt(
            id: "rp-3", kind: .permission, toolName: "Bash", toolInputJSON: #"{"command":"make lint"}"#)
        try Self.listRemoteSessions(h, open: answered, elsewhere: elsewhere)
        let outbox = try await Self.liveConnection(h)
        await h.service.openPrompts(session, for: deviceID)

        // `rs-2`'s prompt, open throughout, never reaches this feed.
        let first = try await Self.promptEvent(0, in: outbox)
        #expect(first.data == PromptChangedData(
            session: session, prompts: [PhonePromptShaper.remote(answered)], resolved: nil))

        let (reply, _) = try await h.request(
            .promptAnswer, params: PhonePromptAnswerParams(session: session, promptID: "rp-1", answer: Self.allow),
            on: outbox)
        #expect(reply.error == nil)
        try Self.listRemoteSessions(h, open: unanswered, elsewhere: elsewhere)
        h.subscriptions.broadcast(delta: .remoteSessionsChanged)
        let byPhone = try await Self.promptEvent(1, in: outbox)
        #expect(byPhone.data == PromptChangedData(
            session: session, prompts: [PhonePromptShaper.remote(unanswered)],
            resolved: [PhonePromptResolution(promptID: "rp-1", answeredBy: .phone, deviceID: deviceID)]))

        try Self.listRemoteSessions(h, open: nil, elsewhere: elsewhere)
        h.subscriptions.broadcast(delta: .remoteSessionsChanged)
        let unknown = try await Self.promptEvent(2, in: outbox)
        #expect(unknown.data == PromptChangedData(session: session, prompts: [], resolved: [
            PhonePromptResolution(promptID: "rp-2", answeredBy: .unknown, deviceID: nil),
        ]))
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// Every later `phoneRemoteSessions` lists `acme-cloud`'s sessions `rs-1`,
    /// with `open` open, and `rs-2`, with `elsewhere` open.
    private static func listRemoteSessions(
        _ h: PhoneServiceHarness, open: RemotePendingPrompt?, elsewhere: RemotePendingPrompt?
    ) throws {
        func info(_ sessionID: String, _ prompt: RemotePendingPrompt?) -> RemoteSessionInfo {
            RemoteSessionInfo(
                provider: "acme-cloud",
                payload: RemoteSessionPayload(id: sessionID, state: .running, pendingPrompt: prompt),
                gone: false, dismissed: false, lastSeen: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let result = RemoteSessionsResult(sessions: [info("rs-1", open), info("rs-2", elsewhere)])
        h.actions.respond(to: .remoteSessions, with: try RPCResponse(result: result))
    }

    /// Opening another session replaces the feed: the earlier terminal's
    /// changes send nothing, and closing the feed removes its subscriber.
    @Test func openingAnotherSessionReplacesTheFeed() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let earlier = UUID()
        let later = UUID()
        let outbox = try await Self.liveConnection(h)
        let publisherOnly = h.subscriptions.subscriberCount

        await h.service.openPrompts(.local(terminalID: earlier), for: deviceID)
        let first = try await Self.promptEvent(0, in: outbox)
        #expect(first.data.session == .local(terminalID: earlier))
        await h.service.openPrompts(.local(terminalID: later), for: deviceID)
        let second = try await Self.promptEvent(1, in: outbox)
        #expect(second.data == PromptChangedData(session: .local(terminalID: later), prompts: [], resolved: nil))
        #expect(await h.service.promptsSession(for: deviceID) == .local(terminalID: later))
        #expect(h.subscriptions.subscriberCount == publisherOnly + 1)

        await h.pendingPrompts.open(
            terminalID: earlier, sessionID: nil, toolUseID: "toolu-a", toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        await h.subscriptions.broadcastPendingPrompts(terminalID: earlier, from: h.pendingPrompts)
        await h.pendingPrompts.open(
            terminalID: later, sessionID: nil, toolUseID: "toolu-b", toolName: "Bash",
            toolInputJSON: Self.bashInput, suggestionsJSON: nil)
        await h.subscriptions.broadcastPendingPrompts(terminalID: later, from: h.pendingPrompts)
        let third = try await Self.promptEvent(2, in: outbox)
        #expect(third.data.session == .local(terminalID: later))
        let thirdIDs = third.data.prompts.map(\.id)
        #expect(thirdIDs == ["toolu-b"])
        let sessions = try Self.promptEvents(in: outbox).map(\.data.session)
        #expect(sessions == [.local(terminalID: earlier), .local(terminalID: later), .local(terminalID: later)])

        await h.service.closePrompts(for: deviceID)
        #expect(await h.service.promptsSession(for: deviceID) == nil)
        try await waitUntil("the feed's subscriber to go") {
            h.subscriptions.subscriberCount == publisherOnly
        }
        await h.service.phoneRevoked(deviceID: deviceID)
        #expect(h.subscriptions.subscriberCount == 0)
    }
}

/// `prompt.answer` through the real core, `RPCRouter.answerPrompt`, so the
/// phone is shown to obey `transcript_prompt_answer_enabled` the way the
/// laptop's prompt card does: by its own check, and by the core's when the
/// setting changes, or stops being readable, between the two.
///
/// Tier 2: in-memory GRDB, a dry-run tmux and an actuation log under the
/// run's fenced scratch dir.
@Suite("Phone prompt.answer through the router", .fastPassBounded)
struct PhonePromptAnswerRouterTests {
    private struct Fixture {
        let db: TBDDatabase
        let service: PhoneAppService
        let peer: PhonePeer
    }

    /// The remote provider `remoteProvider` stands for.
    private static let provider = "acme-cloud"

    /// `describe`, declaring `answer`.
    private static let describeDeclaringAnswer = providerOK(
        #"{"contract_versions": [1], "name": "\#(provider)", "capabilities": ["\#(RemoteCapability.answer)"]}"#)

    /// `list`, naming session `s-1` blocked on permission prompt `p-1`.
    private static let listingAPrompt = providerOK(#"""
        {"sessions": [{"id": "s-1", "state": "running", "agent_state": "\#(RemoteAgentState.waitingInput.rawValue)", \#
        "pending_prompt": {"id": "p-1", "kind": "permission", "tool_name": "Bash", \#
        "tool_input": {"command": "touch x"}}}]}
        """#)

    /// With `beforeTheCore`, the service reaches the router through
    /// `ChangingTheSettingBeforeTheCore`, which runs it on the database just
    /// before the core of an answer runs. With `remoteProvider`, remote
    /// backends are on and the router has a provider, `provider`, that runs
    /// through it, has described itself and has mirrored its sessions once.
    private func makeFixture(
        remoteProvider: FakeProviderInvoker? = nil,
        beforeTheCore: (@Sendable (TBDDatabase) async throws -> Void)? = nil
    ) async throws -> Fixture {
        let directory = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-prompt"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPhoneControlEnabled(true)
        let peer = PhonePeer(deviceID: UUID(), deviceName: "Acme Phone")
        try await db.phoneDevices.insert(PhoneDevice(
            id: peer.deviceID, name: peer.deviceName, publicKey: Data(repeating: 7, count: 32),
            roomID: UUID().uuidString, pairedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let subs = StateSubscriptionManager()
        var remoteManager: RemoteProviderManager?
        if let remoteProvider {
            try await db.config.setRemoteBackendsEnabled(true)
            let registryURL = directory.appendingPathComponent("agent-providers.json")
            try #"[{"name": "\#(Self.provider)", "exec": "/nonexistent"}]"#
                .write(to: registryURL, atomically: true, encoding: .utf8)
            let manager = RemoteProviderManager(
                db: db, subscriptions: subs, runner: remoteProvider, registryURL: registryURL,
                actuationLog: ActuationLog(path: directory.appendingPathComponent("provider-actuations.jsonl").path))
            await manager.loadRegistryAndDescribe()
            await manager.pollOnce(provider: RemoteProviderConfig(name: Self.provider, exec: "/nonexistent"))
            remoteManager = manager
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                subscriptions: subs),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            remoteManager: remoteManager,
            actuationLog: ActuationLog(path: directory.appendingPathComponent("actuations.jsonl").path))
        let actions: any PhoneSessionActions
        if let beforeTheCore {
            actions = ChangingTheSettingBeforeTheCore(router: router, db: db, change: beforeTheCore)
        } else {
            actions = router
        }
        let service = PhoneAppService(
            db: db, actions: actions, subscriptions: subs, pendingPrompts: router.pendingQuestions,
            locateTranscript: PhoneServiceHarness.locateTranscript,
            recorder: CapturingRecorder(), clock: EventDrivenTestClock())
        return Fixture(db: db, service: service, peer: peer)
    }

    /// Answers a permission prompt on a Claude terminal the phone can see,
    /// since the service answers no other, and returns the reply's bytes.
    private func answer(_ f: Fixture) async throws -> Data {
        let repo = try await f.db.repos.create(
            path: "/acme/widgets-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await f.db.worktrees.create(
            repoID: repo.id, name: "acme-one", branch: "acme-one",
            path: "/acme/widgets-one-\(UUID().uuidString)", tmuxServer: "tbd-acme")
        let terminal = try await f.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", claudeSessionID: "acme-session",
            kind: .claude)
        let outbox = CapturingOutbox()
        await f.service.phoneConnected(f.peer, outbox: outbox)
        let params = PhonePromptAnswerParams(
            session: .local(terminalID: terminal.id), promptID: "toolu-1",
            answer: .permission(decision: .allow, message: nil))

        await f.service.handleAppMessage(
            try PhoneTestRequests.body(.promptAnswer, id: "answer-1", params: params), from: f.peer)

        return try await outbox.body(at: 0)
    }

    /// Answers remote session `s-1`'s permission prompt `p-1` on `provider`,
    /// and returns the reply's bytes.
    private func answerRemote(_ f: Fixture) async throws -> Data {
        let outbox = CapturingOutbox()
        await f.service.phoneConnected(f.peer, outbox: outbox)
        let params = PhonePromptAnswerParams(
            session: .remote(provider: Self.provider, sessionID: "s-1"), promptID: "p-1",
            answer: .permission(decision: .allow, message: nil))

        await f.service.handleAppMessage(
            try PhoneTestRequests.body(.promptAnswer, id: "answer-1", params: params), from: f.peer)

        return try await outbox.body(at: 0)
    }

    /// Off, the phone's own check refuses `unsupported` with the reason the
    /// sessions list shows, so the core never sees the answer. On, the core
    /// looks, finds no such prompt, and says it was already answered.
    @Test(arguments: [false, true])
    func thePhoneObeysThePromptAnswerSetting(enabled: Bool) async throws {
        let f = try await makeFixture()
        try await f.db.config.setTranscriptPromptAnswerEnabled(enabled)

        let bytes = try await answer(f)

        let reply = try JSONDecoder().decode(PhoneTestReply.self, from: bytes)
        if enabled {
            #expect(reply.error == nil)
            let result = try JSONDecoder().decode(PhoneReplyEnvelope<PromptAnswerResult>.self, from: bytes).result
            #expect(result.outcome == .alreadyResolved)
        } else {
            #expect(reply.error == PhoneAppError(code: .unsupported, message: PhoneSessionStatus.answerTurnedOffReason))
        }
    }

    /// The setting turned off after the phone's own check read it on: the
    /// core reads it again and refuses before it looks for the prompt, and
    /// the phone gets that refusal in the words its sessions list shows for
    /// the setting, not the core's.
    @Test func theCoreRefusesWhenTheSettingIsTurnedOffAfterThePhonesCheck() async throws {
        let f = try await makeFixture(beforeTheCore: { db in
            try await db.config.setTranscriptPromptAnswerEnabled(false)
        })
        try await f.db.config.setTranscriptPromptAnswerEnabled(true)

        let bytes = try await answer(f)

        let reply = try JSONDecoder().decode(PhoneTestReply.self, from: bytes)
        #expect(reply.error == PhoneAppError(code: .refused, message: PhoneSessionStatus.answerTurnedOffReason))
        #expect(try await f.db.config.get().transcriptPromptAnswerEnabled == false)
    }

    /// The setting read on by the phone's own check, then unreadable when the
    /// core reads it again: the core refuses before it looks for the prompt,
    /// rather than failing the call, which the phone would have to take for
    /// an answer that may have gone out. The phone gets that refusal in the
    /// words its sessions list shows for a setting it cannot read.
    @Test func theCoreRefusesWhenTheSettingCannotBeReadAfterThePhonesCheck() async throws {
        let f = try await makeFixture(beforeTheCore: { db in
            try await db.makeConfigUnreadable()
        })
        try await f.db.config.setTranscriptPromptAnswerEnabled(true)

        let bytes = try await answer(f)

        let reply = try JSONDecoder().decode(PhoneTestReply.self, from: bytes)
        #expect(reply.error == PhoneAppError(code: .refused, message: PhoneSessionStatus.answerSettingUnreadReason))
    }

    /// A remote answer whose provider declares `answer` and whose setting is
    /// on passes the phone's own check, then the config row is unreadable
    /// when the core of `remote.answer` reads it once for its remote
    /// backends gate, its cloud gate and the setting. The core refuses
    /// before it calls the provider, and the phone gets that refusal in the
    /// words its sessions list shows for a setting it cannot read.
    @Test func theRemoteCoreRefusesWhenTheConfigCannotBeReadAfterThePhonesCheck() async throws {
        let invoker = FakeProviderInvoker(script: [Self.describeDeclaringAnswer, Self.listingAPrompt])
        let f = try await makeFixture(remoteProvider: invoker, beforeTheCore: { db in
            try await db.makeConfigUnreadable()
        })
        try await f.db.config.setTranscriptPromptAnswerEnabled(true)

        let bytes = try await answerRemote(f)

        let reply = try JSONDecoder().decode(PhoneTestReply.self, from: bytes)
        #expect(reply.error == PhoneAppError(code: .refused, message: PhoneSessionStatus.answerSettingUnreadReason))
        let answers = invoker.callsSnapshot().filter { $0.first == "answer" }
        #expect(answers.isEmpty, "the provider is never asked to answer")
    }
}

/// The router as the phone's session actions, except that an answer, local
/// or remote, first runs `change` on the database, as a user who turns the
/// setting for answering prompts off between the phone's own check and the
/// core's call does, or a read of the config row that starts failing there.
/// Every other method goes straight to the router.
private struct ChangingTheSettingBeforeTheCore: PhoneSessionActions {
    let router: RPCRouter
    let db: TBDDatabase
    let change: @Sendable (TBDDatabase) async throws -> Void

    func phoneAnswerPrompt(_ p: PromptAnswerParams, deviceID: UUID) async throws -> RPCResponse {
        try await change(db)
        return try await router.phoneAnswerPrompt(p, deviceID: deviceID)
    }

    func phoneSessionStates() async throws -> RPCResponse {
        try await router.phoneSessionStates()
    }

    func phoneAnswerRemotePrompt(_ p: RemoteAnswerParams, deviceID: UUID) async throws -> RPCResponse {
        try await change(db)
        return try await router.phoneAnswerRemotePrompt(p, deviceID: deviceID)
    }

    func phoneSend(_ p: TerminalSendParams, deviceID: UUID) async throws -> RPCResponse {
        try await router.phoneSend(p, deviceID: deviceID)
    }

    func phoneWake(_ p: TerminalWakeParams, deviceID: UUID) async throws -> RPCResponse {
        try await router.phoneWake(p, deviceID: deviceID)
    }

    func phoneSwapProfile(_ p: TerminalSwapProfileParams, deviceID: UUID) async throws -> RPCResponse {
        try await router.phoneSwapProfile(p, deviceID: deviceID)
    }

    func phoneCreateWorktree(_ p: WorktreeCreateParams, deviceID: UUID) async throws -> RPCResponse {
        try await router.phoneCreateWorktree(p, deviceID: deviceID)
    }

    func phoneRemoteProviders() async throws -> RPCResponse {
        try await router.phoneRemoteProviders()
    }

    func phoneCachedRemoteProviders() async throws -> RPCResponse {
        try await router.phoneCachedRemoteProviders()
    }

    func phoneRemoteSessions() async throws -> RPCResponse {
        try await router.phoneRemoteSessions()
    }

    func phoneRemoteCreate(_ p: RemoteCreateParams, deviceID: UUID) async throws -> RPCResponse {
        try await router.phoneRemoteCreate(p, deviceID: deviceID)
    }

    func phoneRemoteSendMessage(_ p: RemoteSendMessageParams, deviceID: UUID) async throws -> RPCResponse {
        try await router.phoneRemoteSendMessage(p, deviceID: deviceID)
    }

    func phoneRemoteTranscriptSync(_ p: RemoteTranscriptSyncParams) async throws -> RPCResponse {
        try await router.phoneRemoteTranscriptSync(p)
    }

    func phoneRemoteTranscriptLoadEarlier(_ p: RemoteTranscriptLoadEarlierParams) async throws -> RPCResponse {
        try await router.phoneRemoteTranscriptLoadEarlier(p)
    }
}
