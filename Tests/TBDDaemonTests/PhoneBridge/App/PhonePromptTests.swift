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

    /// Waits until `condition` holds, or throws naming `what`.
    private static func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = TestDeadlines.saturatedPass
        switch await pollUntilTrue(timeout: deadline, condition) {
        case .satisfied:
            return
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw BoundedWaitTimeout(what: what, observed: nil, deadline: deadline)
        }
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

    /// The core refuses while `transcript_prompt_answer_enabled` is off, and
    /// the phone gets that refusal as it is. `PhonePromptAnswerRouterTests`
    /// runs the same through the real core.
    @Test func theSettingsRefusalReachesThePhone() async throws {
        let h = try await PhoneServiceHarness.make()
        h.actions.respond(to: .answerPrompt, with: RPCResponse(error: RPCRouter.promptAnswerDisabledRefusal))
        let outbox = await h.connect()

        let terminalID = try await h.seedTerminal().id
        let (reply, _) = try await h.request(.promptAnswer, params: Self.local(terminalID, "toolu-1"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: RPCRouter.promptAnswerDisabledRefusal))
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
        #expect(h.actions.calls == [FakeSessionActions.Call(method: .remoteProviders, deviceID: nil)])
    }

    @Test func aRemoteAnswerGoesToItsProvider() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.answer])
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
            FakeSessionActions.Call(method: .remoteProviders, deviceID: nil),
            FakeSessionActions.Call(method: .answerRemotePrompt, deviceID: h.peer.deviceID),
        ])
        #expect(h.recorder.records == [PhoneActionRecord(
            deviceName: "Acme Phone", action: "prompt.answer", target: "remote:acme-cloud/rs-1")])
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
            #expect(answers == (kept ? ["toolu-1": h.peer.deviceID] : [:]), "response: \(response)")
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
        _ = ledger.finish(key, token: 2, keep: false, now: now)
        #expect(ledger.isAnswering(key), "the winner's call still runs")
        #expect(ledger.answeredBy(key) == nil)
        _ = ledger.finish(key, token: 1, keep: true, now: now)

        #expect(!ledger.isAnswering(key))
        #expect(ledger.answeredBy(key) == winner)
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
        _ = aged.finish(key("old"), token: 1, keep: true, now: now)
        aged.begin(key("new"), token: 2, deviceID: device, now: now.addingTimeInterval(PhonePromptAnswerLedger.lifetime + 1))
        #expect(aged.answeredBy(key("old")) == nil)

        var full = PhonePromptAnswerLedger()
        let count = PhonePromptAnswerLedger.settledLimit + 1
        for index in 0..<count {
            full.begin(key("p-\(index)"), token: UInt64(index + 1), deviceID: device, now: now)
            _ = full.finish(key("p-\(index)"), token: UInt64(index + 1), keep: true, now: now)
        }
        #expect(full.answeredBy(key("p-0")) == nil)
        #expect(full.answeredBy(key("p-1")) == device)
        #expect(full.answeredBy(key("p-\(count - 1)")) == device)
    }

    /// A prompt opened again under the same ID: an answer that settled
    /// before its latest opening answered an earlier one and does not count.
    @Test func anAnswerToAnEarlierOpeningOfAPromptDoesNotCount() {
        var ledger = PhonePromptAnswerLedger()
        let key = PhonePromptAnswerLedger.Key(session: .local(terminalID: UUID()), promptID: "toolu-1")
        let device = UUID()
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.begin(key, token: 1, deviceID: device, now: opened.addingTimeInterval(5))
        _ = ledger.finish(key, token: 1, keep: true, now: opened.addingTimeInterval(6))

        #expect(ledger.answeredBy(key) == device)
        #expect(ledger.answeredBy(key, openedAt: opened) == device)
        #expect(ledger.answeredBy(key, openedAt: opened.addingTimeInterval(60)) == nil)
    }

    // MARK: - Who answered

    @Test func aLocalPromptsResolutionSaysWhoAnswered() {
        let phone = UUID()
        let attribution = PhonePromptAttribution(
            phoneAnswers: ["by-phone": phone, "phone-then-terminal": phone, "phone-unrecorded": phone, "phone-gone": phone],
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
        let attribution = PhonePromptAttribution(phoneAnswers: ["by-phone": phone], localResolutions: nil)

        #expect(attribution.resolution(of: "by-phone") == PhonePromptResolution(
            promptID: "by-phone", answeredBy: .phone, deviceID: phone))
        #expect(attribution.resolution(of: "elsewhere") == PhonePromptResolution(
            promptID: "elsewhere", answeredBy: .unknown, deviceID: nil))
    }

    /// The store keeps how each recently closed prompt ended, at most
    /// `recentResolutionLimit` of them, and forgets a prompt's ending when it
    /// opens again.
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
        let first = try #require(set.advance(to: [huge, small], attribution: PhonePromptAttribution()))
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
        try await Self.waitUntil("the answer to reach the core") { h.actions.answers.count == 1 }
        await h.pendingPrompts.receipt(terminalID: terminalID, toolUseID: "toolu-1")
        await h.subscriptions.broadcastPendingPrompts(terminalID: terminalID, from: h.pendingPrompts)
        try await Self.waitUntil("the feed to wait for the phone's answer") {
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

    /// A remote session's set arrives through `remotePromptsRead`; a closed
    /// remote prompt says `phone` when this phone answered it, and
    /// `unknown` otherwise.
    @Test func aRemotePromptSaysPhoneOnlyWhenThePhoneAnsweredIt() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let session = Self.remoteSession
        try h.actions.registerProvider("acme-cloud", capabilities: [RemoteCapability.answer])
        h.actions.respond(to: .answerRemotePrompt, with: try Self.answered(.delivered))
        let answered = RemotePendingPrompt(
            id: "rp-1", kind: .permission, toolName: "Bash", toolInputJSON: #"{"command":"make"}"#)
        let other = RemotePendingPrompt(
            id: "rp-2", kind: .permission, toolName: "Bash", toolInputJSON: #"{"command":"make test"}"#)
        let outbox = try await Self.liveConnection(h)
        await h.service.openPrompts(session, for: deviceID)

        // Another session's prompts are not this feed's.
        await h.service.remotePromptsRead(
            [other], session: .remote(provider: "acme-cloud", sessionID: "rs-2"), deviceID: deviceID)
        await h.service.remotePromptsRead([answered, other], session: session, deviceID: deviceID)
        let first = try await Self.promptEvent(0, in: outbox)
        #expect(first.data == PromptChangedData(
            session: session, prompts: [PhonePromptShaper.remote(answered), PhonePromptShaper.remote(other)],
            resolved: nil))

        let (reply, _) = try await h.request(
            .promptAnswer, params: PhonePromptAnswerParams(session: session, promptID: "rp-1", answer: Self.allow),
            on: outbox)
        #expect(reply.error == nil)
        await h.service.remotePromptsRead([], session: session, deviceID: deviceID)

        let closed = try await Self.promptEvent(1, in: outbox)
        #expect(closed.data == PromptChangedData(session: session, prompts: [], resolved: [
            PhonePromptResolution(promptID: "rp-1", answeredBy: .phone, deviceID: deviceID),
            PhonePromptResolution(promptID: "rp-2", answeredBy: .unknown, deviceID: nil),
        ]))
        await h.service.phoneRevoked(deviceID: deviceID)
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
        try await Self.waitUntil("the feed's subscriber to go") {
            h.subscriptions.subscriberCount == publisherOnly
        }
        await h.service.phoneRevoked(deviceID: deviceID)
        #expect(h.subscriptions.subscriberCount == 0)
    }
}

/// `prompt.answer` through the real core, `RPCRouter.answerPrompt`, so the
/// phone is shown to obey `transcript_prompt_answer_enabled` the way the
/// laptop's prompt card does, by the core's own check.
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

    private func makeFixture() async throws -> Fixture {
        let directory = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-prompt"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPhoneControlEnabled(true)
        let peer = PhonePeer(deviceID: UUID(), deviceName: "Acme Phone")
        try await db.phoneDevices.insert(PhoneDevice(
            id: peer.deviceID, name: peer.deviceName, publicKey: Data(repeating: 7, count: 32),
            roomID: UUID().uuidString, pairedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let subs = StateSubscriptionManager()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                subscriptions: subs),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            actuationLog: ActuationLog(path: directory.appendingPathComponent("actuations.jsonl").path))
        let service = PhoneAppService(
            db: db, actions: router, subscriptions: subs, pendingPrompts: router.pendingQuestions,
            locateTranscript: PhoneServiceHarness.locateTranscript,
            recorder: CapturingRecorder(), clock: EventDrivenTestClock())
        return Fixture(db: db, service: service, peer: peer)
    }

    /// Off, the core refuses before it looks for the prompt, and the phone
    /// gets that refusal. On, the core looks, finds no such prompt, and says
    /// it was already answered.
    @Test(arguments: [false, true])
    func thePhoneObeysThePromptAnswerSetting(enabled: Bool) async throws {
        let f = try await makeFixture()
        try await f.db.config.setTranscriptPromptAnswerEnabled(enabled)
        // A terminal the phone can see, since the service answers no other.
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

        let bytes = try await outbox.body(at: 0)
        let reply = try JSONDecoder().decode(PhoneTestReply.self, from: bytes)
        if enabled {
            #expect(reply.error == nil)
            let result = try JSONDecoder().decode(PhoneReplyEnvelope<PromptAnswerResult>.self, from: bytes).result
            #expect(result.outcome == .alreadyResolved)
        } else {
            #expect(reply.error == PhoneAppError(code: .refused, message: RPCRouter.promptAnswerDisabledRefusal))
        }
    }
}
