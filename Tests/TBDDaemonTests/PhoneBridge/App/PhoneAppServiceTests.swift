import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// Tier 1: the service actor over an in-memory database, with fake session
/// actions, a capturing outbox and recorder, and a virtual clock. Nothing
/// touches the disk or the network.
@Suite("Phone app service", .clockDriven)
struct PhoneAppServiceTests {
    private let terminalID = UUID()

    private var sendParams: MessageSendParams {
        MessageSendParams(session: .local(terminalID: terminalID), text: "hi")
    }

    /// Waits until `condition` holds, or throws naming `what`.
    private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
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

    // MARK: - Stand-in handlers

    /// Stands in for `message.send`: one `phoneSend` of the message as a text
    /// part, under the request's device. With a gate, it waits for the gate
    /// first.
    private static func sendStub(_ actions: FakeSessionActions, gate: PhoneTestGate? = nil) -> PhoneMethodHandler {
        PhoneAppService.typed(MessageSendParams.self) { p, context -> ActionOutcomeResult in
            if let gate {
                await gate.wait()
            }
            guard case .local(let terminalID) = p.session else {
                throw PhoneAppError(code: .unsupported, message: "Local sessions only.")
            }
            _ = try await actions.phoneSend(
                TerminalSendParams(terminalID: terminalID, submit: true, parts: [.text(p.text)]),
                deviceID: context.peer.deviceID)
            return ActionOutcomeResult(outcome: "sent")
        }
    }

    /// Stands in for `transcript.close`: replies `PhoneEmpty`.
    private static let closeStub = PhoneAppService.typed(PhoneEmpty.self) { _, _ in PhoneEmpty() }

    /// Stands in for `sessions.subscribe`: replies with the device's stream ID.
    private static func subscribeStub(_ service: PhoneAppService) -> PhoneMethodHandler {
        PhoneAppService.typed(SessionsSubscribeParams.self) { _, context -> SessionsSubscribeResult in
            let stream = await service.streamID(for: context.peer.deviceID) ?? ""
            return SessionsSubscribeResult(
                stream: stream, seq: 0, replayed: false, layout: nil, rows: nil, omittedRows: 0, more: false)
        }
    }

    /// The stream ID a fresh `sessions.subscribe` replies with.
    private func subscribedStream(_ h: PhoneServiceHarness, on outbox: CapturingOutbox) async throws -> String {
        let (_, bytes) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: nil, sinceSeq: nil), on: outbox)
        return try JSONDecoder().decode(PhoneReplyEnvelope<SessionsSubscribeResult>.self, from: bytes).result.stream
    }

    // MARK: - The flag

    @Test func flagOffRepliesPhoneControlOffAndCallsNothing() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.sendStub(h.actions), for: .messageSend)
        let outbox = await h.connect()
        try await h.db.config.setPhoneControlEnabled(false)

        let (reply, _) = try await h.request(.messageSend, id: "r1", params: sendParams, on: outbox)

        #expect(reply.error?.code == .phoneControlOff)
        #expect(reply.error?.message == "Phone control is off on this laptop.")
        #expect(h.actions.calls.isEmpty)
        #expect(h.recorder.records.isEmpty)
        #expect(await !h.service.memory.remembers(deviceID: h.peer.deviceID, requestID: "r1"))

        // The "off" reply was not remembered: once the flag is on, the same
        // request ID acts.
        try await h.db.config.setPhoneControlEnabled(true)
        let (again, _) = try await h.request(.messageSend, id: "r1", params: sendParams, on: outbox)
        #expect(again.error == nil)
        #expect(h.actions.sends.count == 1)
    }

    /// A `sessions.subscribe` made while the flag is off changes no device
    /// state: the connection's resume decision stays undecided.
    @Test func flagOffLeavesTheResumeDecisionAlone() async throws {
        let h = try await PhoneServiceHarness.make()
        let outbox = await h.connect()
        let subscribe = SessionsSubscribeParams(stream: nil, sinceSeq: nil)
        try await h.db.config.setPhoneControlEnabled(false)

        let (off, _) = try await h.request(.sessionsSubscribe, params: subscribe, on: outbox)
        #expect(off.error?.code == .phoneControlOff)
        #expect(await h.service.resumeDecision(for: h.peer.deviceID) == .undecided)

        try await h.db.config.setPhoneControlEnabled(true)
        _ = try await h.request(.sessionsSubscribe, params: subscribe, on: outbox)
        #expect(await h.service.resumeDecision(for: h.peer.deviceID) == .snapshot)
        // Stops the publisher the subscribe started.
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    @Test func flagOnRunsTheAction() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.sendStub(h.actions), for: .messageSend)
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(.messageSend, id: "r1", params: sendParams, on: outbox)

        let decoded = try JSONDecoder().decode(PhoneReplyEnvelope<ActionOutcomeResult>.self, from: bytes)
        #expect(reply.error == nil)
        #expect(decoded.requestID == "r1")
        #expect(decoded.result == ActionOutcomeResult(outcome: "sent"))
        #expect(h.actions.calls == [FakeSessionActions.Call(method: .send, deviceID: h.peer.deviceID)])
        let sent = h.actions.sends
        #expect(sent.count == 1)
        #expect(sent.first?.terminalID == terminalID)
        #expect(sent.first?.parts == [.text("hi")])

        // A resend gets the same bytes, acts no more and records nothing.
        let (_, again) = try await h.request(.messageSend, id: "r1", params: sendParams, on: outbox)
        #expect(again == bytes)
        #expect(h.actions.sends.count == 1)
        #expect(h.recorder.records.count == 1)
    }

    // MARK: - Dispatch

    @Test func anUnknownMethodRepliesUnknownMethod() async throws {
        let h = try await PhoneServiceHarness.make()
        let outbox = await h.connect()
        let body = Data(#"{"kind":"request","method":"acme.unknown","params":{},"requestID":"r1"}"#.utf8)

        let (reply, _) = try await h.send(body, on: outbox)

        #expect(reply.requestID == "r1")
        #expect(reply.error?.code == .unknownMethod)
        #expect(h.actions.calls.isEmpty)
        #expect(h.recorder.records.isEmpty)
    }

    @Test func badParamsReplyBadRequest() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.sendStub(h.actions), for: .messageSend)
        let outbox = await h.connect()
        let body = Data(#"{"kind":"request","method":"message.send","params":{"session":{"kind":"local"}},"requestID":"r1"}"#.utf8)

        let (reply, _) = try await h.send(body, on: outbox)

        #expect(reply.requestID == "r1")
        #expect(reply.error?.code == .badRequest)
        #expect(h.actions.calls.isEmpty)
        #expect(h.recorder.records.isEmpty)
    }

    @Test func aStandInHandlerRepliesWithItsResult() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.closeStub, for: .transcriptClose)
        let outbox = await h.connect()

        let (_, bytes) = try await h.request(.transcriptClose, id: "r1", params: PhoneEmpty(), on: outbox)

        let decoded = try JSONDecoder().decode(PhoneReplyEnvelope<PhoneEmpty>.self, from: bytes)
        #expect(decoded.requestID == "r1")
        #expect(decoded.result == PhoneEmpty())
        #expect(h.recorder.records == [PhoneActionRecord(deviceName: "Acme Phone", action: "transcript.close", target: "transcript")])
    }

    /// A known method no task serves yet replies `unavailable`, and is not
    /// recorded: nothing happened.
    @Test func aMethodWithNoHandlerRepliesUnavailable() async throws {
        let h = try await PhoneServiceHarness.make()
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .transcriptDetail,
            params: TranscriptDetailParams(session: .local(terminalID: terminalID), itemID: "x", part: .text, chunk: 0),
            on: outbox)

        #expect(reply.error?.code == .unavailable)
        #expect(h.actions.calls.isEmpty)
        #expect(h.recorder.records.isEmpty)
    }

    /// The window between a revoke's row delete and its `phoneRevoked`: a
    /// request that reaches its work then is refused and acts on nothing.
    @Test func aPhoneWhosePairingIsGoneIsRefused() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.sendStub(h.actions), for: .messageSend)
        let outbox = await h.connect()
        _ = try await h.db.phoneDevices.delete(id: h.peer.deviceID)

        let (reply, _) = try await h.request(.messageSend, params: sendParams, on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: "This phone is no longer paired."))
        #expect(h.actions.calls.isEmpty)
        #expect(h.recorder.records.isEmpty)
    }

    @Test func aRequestIDOverTheLimitIsRefusedBeforeTheMemory() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.sendStub(h.actions), for: .messageSend)
        let outbox = await h.connect()
        let tooLong = String(repeating: "x", count: PhoneAppConstants.requestIDMaxBytes + 1)

        let (refused, _) = try await h.request(.messageSend, id: tooLong, params: sendParams, on: outbox)
        #expect(refused.error?.code == .badRequest)
        #expect(h.actions.calls.isEmpty)
        #expect(await !h.service.memory.remembers(deviceID: h.peer.deviceID, requestID: tooLong))

        let longest = String(repeating: "y", count: PhoneAppConstants.requestIDMaxBytes)
        let (accepted, _) = try await h.request(.messageSend, id: longest, params: sendParams, on: outbox)
        #expect(accepted.error == nil)
        #expect(h.actions.sends.count == 1)
    }

    /// Only the methods that act on a session or create something go through
    /// the request memory. A pure read and a state request skip it.
    @Test func onlyActionsAreRemembered() async throws {
        let h = try await PhoneServiceHarness.make()
        let listStub = PhoneAppService.typed(PhoneEmpty.self) { _, _ in ProfilesListResult(profiles: []) }
        await h.service.setHandler(listStub, for: .profilesList)
        await h.service.setHandler(Self.closeStub, for: .transcriptClose)
        await h.service.setHandler(Self.sendStub(h.actions), for: .messageSend)
        let outbox = await h.connect()

        let (read, _) = try await h.request(.profilesList, id: "read", params: PhoneEmpty(), on: outbox)
        let (close, _) = try await h.request(.transcriptClose, id: "close", params: PhoneEmpty(), on: outbox)
        let (send, _) = try await h.request(.messageSend, id: "send", params: sendParams, on: outbox)

        #expect(read.error == nil)
        #expect(close.error == nil)
        #expect(send.error == nil)
        #expect(await !h.service.memory.remembers(deviceID: h.peer.deviceID, requestID: "read"))
        #expect(await !h.service.memory.remembers(deviceID: h.peer.deviceID, requestID: "close"))
        #expect(await h.service.memory.remembers(deviceID: h.peer.deviceID, requestID: "send"))
        let remembered = PhoneAppMethod.allCases.filter { PhoneAppService.remembersReplies(of: $0) }
        #expect(Set(remembered) == [
            .messageSend, .promptAnswer, .sessionSwitchProfile, .sessionFork, .sessionSetModel,
            .worktreeCreate, .remoteCreate,
        ])
    }

    /// A resend of a request still running, here after the device filled up
    /// to the in-flight limit, starts nothing, is not refused, and gets no
    /// reply of its own: the held request replies once.
    @Test func aResendOfARunningRequestStartsNothingAndRepliesOnce() async throws {
        let h = try await PhoneServiceHarness.make()
        let gate = PhoneTestGate()
        defer { gate.open() }
        await h.service.setHandler(Self.sendStub(h.actions, gate: gate), for: .messageSend)
        let pageStub = PhoneAppService.typed(TranscriptPageParams.self) { _, _ -> TranscriptPage in
            await gate.wait()
            return TranscriptPage(items: [], cursor: nil, reachedStart: true, omittedItems: 0)
        }
        await h.service.setHandler(pageStub, for: .transcriptPage)
        let outbox = await h.connect()
        let held = try PhoneTestRequests.body(.messageSend, id: "held", params: sendParams)
        let page = TranscriptPageParams(session: .local(terminalID: terminalID), cursor: "0")

        let limit = PhoneAppConstants.requestsInFlightPerDevice
        await h.service.handleAppMessage(held, from: h.peer)
        for index in 0..<(limit - 1) {
            let body = try PhoneTestRequests.body(.transcriptPage, id: "page-\(index)", params: page)
            await h.service.handleAppMessage(body, from: h.peer)
        }
        #expect(await h.service.requestsRunning(for: h.peer.deviceID) == limit)

        // The resend starts no task and queues nothing. The probe after it is
        // refused, and its refusal is the first body out, so the resend sent
        // nothing before it.
        await h.service.handleAppMessage(held, from: h.peer)
        #expect(await h.service.requestsRunning(for: h.peer.deviceID) == limit)
        let (probe, _) = try await h.request(.transcriptPage, id: "probe", params: page, on: outbox)
        #expect(probe.requestID == "probe")
        #expect(probe.error?.code == .refused)

        gate.open()
        try await waitUntil("the held requests to end") {
            await h.service.requestsRunning(for: h.peer.deviceID) == 0
        }
        // Every reply is queued by now, and the outbox sends in order: the
        // probe's refusal, the 32 replies, then this last request's reply.
        let flush = Data(#"{"kind":"request","method":"acme.unknown","params":{},"requestID":"flush"}"#.utf8)
        await h.service.handleAppMessage(flush, from: h.peer)
        let last = try await outbox.body(at: limit + 1)
        #expect(try JSONDecoder().decode(PhoneTestReply.self, from: last).requestID == "flush")

        let replies = try outbox.bodies.map { try JSONDecoder().decode(PhoneTestReply.self, from: $0) }
        let heldReplies = replies.filter { $0.requestID == "held" }
        #expect(heldReplies.count == 1)
        #expect(heldReplies.first?.error == nil)
        #expect(replies.count == limit + 2)
        #expect(h.actions.sends.count == 1)
        let sendRecords = h.recorder.records.filter { $0.action == "message.send" }
        #expect(sendRecords.count == 1)
    }

    /// A device with the most requests running is refused at once; the
    /// requests already running carry on.
    @Test func aDeviceWithTooManyRequestsRunningIsRefused() async throws {
        let h = try await PhoneServiceHarness.make()
        let gate = PhoneTestGate()
        defer { gate.open() }
        let pageStub = PhoneAppService.typed(TranscriptPageParams.self) { _, _ -> TranscriptPage in
            await gate.wait()
            return TranscriptPage(items: [], cursor: nil, reachedStart: true, omittedItems: 0)
        }
        await h.service.setHandler(pageStub, for: .transcriptPage)
        let outbox = await h.connect()
        let page = TranscriptPageParams(session: .local(terminalID: terminalID), cursor: "0")

        let limit = PhoneAppConstants.requestsInFlightPerDevice
        for index in 0..<limit {
            let body = try PhoneTestRequests.body(.transcriptPage, id: "held-\(index)", params: page)
            await h.service.handleAppMessage(body, from: h.peer)
        }
        #expect(await h.service.requestsRunning(for: h.peer.deviceID) == limit)

        let (refused, _) = try await h.request(.transcriptPage, id: "one-more", params: page, on: outbox)
        #expect(refused.requestID == "one-more")
        #expect(refused.error == PhoneAppError(
            code: .refused, message: "Too many requests are in progress. Try again in a moment."))

        gate.open()
        _ = try await outbox.body(at: limit)
        let replies = try outbox.bodies.map { try JSONDecoder().decode(PhoneTestReply.self, from: $0) }
        let repliedIDs = Set(replies.map(\.requestID))
        #expect(repliedIDs.count == limit + 1)
    }

    // MARK: - The record

    @Test func theRecordNeverCarriesMessageText() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.sendStub(h.actions), for: .messageSend)
        let outbox = await h.connect()
        let t = terminalID

        _ = try await h.request(
            .messageSend, params: MessageSendParams(session: .local(terminalID: t), text: "secret words"), on: outbox)

        #expect(h.recorder.records == [PhoneActionRecord(deviceName: "Acme Phone", action: "message.send", target: "local:\(t)")])
        #expect(!String(describing: h.recorder.records).contains("secret words"))
    }

    @Test func aTargetIsMadeSafeToLog() {
        let raw = "provider:acme\nforged line\u{7}" + String(repeating: "x", count: 300)
        let target = PhoneActionRecord.loggableTarget(raw)
        #expect(target.hasPrefix("provider:acme?forged line?"))
        #expect(target.unicodeScalars.count == PhoneActionRecord.targetLimit)
    }

    /// Format characters (a bidirectional override, a zero-width space) and
    /// the line and paragraph separators become `?` too; other text stays.
    @Test func aTargetLosesFormatCharactersAndSeparators() {
        let raw = "remote:acme/\u{202E}gpj.exe\u{200B}x\u{2028}y\u{2029}z-é"
        #expect(PhoneActionRecord.loggableTarget(raw) == "remote:acme/?gpj.exe?x?y?z-é")
    }

    // MARK: - Sessions the phone can see

    /// What takes a listed local session out of the phone's sight.
    enum OutOfSight: String, CaseIterable, Sendable {
        case terminalGone
        case worktreeArchived
        case repoHidden
    }

    /// A phone can keep a terminal ID from a list sent before its tab closed,
    /// its worktree was archived or its repo hidden. Every action on a local
    /// session answers such an ID `not_found`, and nothing reaches the
    /// daemon.
    @Test(arguments: OutOfSight.allCases)
    func everyLocalActionIsNotFoundOnASessionThePhoneCannotSee(_ outOfSight: OutOfSight) async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal()
        switch outOfSight {
        case .terminalGone:
            try await h.db.terminals.delete(id: terminal.id)
        case .worktreeArchived:
            try await h.db.worktrees.archive(id: terminal.worktreeID)
        case .repoHidden:
            let worktree = try await h.db.worktrees.get(id: terminal.worktreeID)
            let repoID = try #require(worktree?.repoID)
            try await h.db.repos.setHidden(id: repoID, hidden: true)
        }
        let outbox = await h.connect()
        let session = PhoneSessionRef.local(terminalID: terminal.id)

        let (sent, _) = try await h.request(
            .messageSend, params: MessageSendParams(session: session, text: "hi"), on: outbox)
        let (model, _) = try await h.request(
            .sessionSetModel, params: SessionSetModelParams(session: session, model: "opus"), on: outbox)
        let (answered, _) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(
                session: session, promptID: "toolu-1", answer: .permission(decision: .allow, message: nil)),
            on: outbox)
        let (switched, _) = try await h.request(
            .sessionSwitchProfile, params: SessionSwitchProfileParams(session: session, profileID: profile.id),
            on: outbox)
        let (forked, _) = try await h.request(
            .sessionFork, params: SessionForkParams(session: session, profileID: nil), on: outbox)

        let notFound = PhoneAppError(code: .notFound, message: PhoneAppService.noSuchSessionReason)
        let errors = [sent.error, model.error, answered.error, switched.error, forked.error]
        let expected: [PhoneAppError?] = Array(repeating: notFound, count: 5)
        #expect(errors == expected, "\(outOfSight.rawValue)")
        #expect(h.actions.calls.isEmpty)
    }

    /// The same session in sight acts, so the refusals above are about sight
    /// and nothing else.
    @Test func aLocalSessionInSightActs() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()

        let (sent, _) = try await h.request(
            .messageSend, params: MessageSendParams(session: .local(terminalID: terminal.id), text: "hi"),
            on: outbox)

        #expect(sent.error == nil)
        #expect(h.actions.calls == [FakeSessionActions.Call(method: .send, deviceID: h.peer.deviceID)])
    }

    // MARK: - Replies across a reconnect

    /// A disconnect in the middle of a send does not cut it short. Its reply
    /// goes through the connection the phone has when the reply is ready, and
    /// the resend after the reconnect gets the same reply and acts no more.
    @Test func aReplyGoesToTheConnectionCurrentWhenItIsReady() async throws {
        let h = try await PhoneServiceHarness.make()
        let gate = PhoneTestGate()
        defer { gate.open() }
        await h.service.setHandler(Self.sendStub(h.actions, gate: gate), for: .messageSend)
        let first = await h.connect()
        let body = try PhoneTestRequests.body(.messageSend, id: "r1", params: sendParams)

        await h.service.handleAppMessage(body, from: h.peer)
        await h.service.phoneDisconnected(h.peer)
        let second = await h.connect()
        gate.open()

        let replied = try await second.body(at: 0)
        let reply = try JSONDecoder().decode(PhoneTestReply.self, from: replied)
        #expect(reply.requestID == "r1")
        #expect(reply.error == nil)
        #expect(first.bodies.isEmpty)
        #expect(h.actions.sends.count == 1)

        let (_, again) = try await h.send(body, on: second)
        #expect(again == replied)
        #expect(h.actions.sends.count == 1)
        #expect(h.recorder.records.count == 1)
    }

    // MARK: - Device state and the grace

    @Test func stateSurvivesAShortDisconnect() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.subscribeStub(h.service), for: .sessionsSubscribe)
        let outbox = await h.connect()
        let stream = try await subscribedStream(h, on: outbox)

        await h.service.phoneDisconnected(h.peer)
        // The grace. A subscribe is not remembered, so it armed no retention
        // timer.
        try await h.clock.requireSleeperArmed()
        #expect(h.clock.sleeperCount == 1)
        await h.clock.advance(by: .seconds(60))
        let again = await h.connect()

        // Reconnecting cancelled the grace.
        #expect(h.clock.sleeperCount == 0)
        #expect(try await subscribedStream(h, on: again) == stream)
    }

    @Test func stateIsDroppedAfterTheGrace() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.subscribeStub(h.service), for: .sessionsSubscribe)
        let outbox = await h.connect()
        let stream = try await subscribedStream(h, on: outbox)

        await h.service.phoneDisconnected(h.peer)
        // The grace.
        try await h.clock.requireSleeperArmed()
        await h.clock.advance(by: .seconds(119))
        #expect(await h.service.streamID(for: h.peer.deviceID) == stream)
        await h.clock.advance(by: .seconds(1))
        try await waitUntil("the grace to drop the state") {
            await h.service.streamID(for: h.peer.deviceID) == nil
        }

        let again = await h.connect()
        #expect(try await subscribedStream(h, on: again) != stream)
    }

    /// Events go out only once the connection's `sessions.subscribe` reply
    /// is queued. One emitted before it is numbered and kept, and the reply's
    /// `seq` covers it; one emitted after it is sent. While the phone is away
    /// an event is kept, and a new connection holds events back until its
    /// own `sessions.subscribe`, which decides to replay exactly what the
    /// phone missed.
    @Test func eventsWaitForTheSubscribeReply() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let outbox = await h.connect()
        let early = SessionsChangedData(layout: nil, rows: [], removedRowIDs: ["acme-1"])
        let late = SessionsChangedData(layout: nil, rows: [], removedRowIDs: ["acme-2"])
        let away = SessionsChangedData(layout: nil, rows: [], removedRowIDs: ["acme-3"])

        await h.service.emit(.sessionsChanged, data: early, to: deviceID)
        let (reply, bytes) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: nil, sinceSeq: nil), on: outbox)
        #expect(reply.kind == "reply")
        let subscribed = try JSONDecoder().decode(PhoneReplyEnvelope<SessionsSubscribeResult>.self, from: bytes).result
        #expect(subscribed.seq == 1)

        await h.service.emit(.sessionsChanged, data: late, to: deviceID)
        let lateBytes = try PhoneAppCoding.event(.sessionsChanged, seq: 2, data: late)
        #expect(try await outbox.body(at: 1) == lateBytes)

        await h.service.phoneDisconnected(h.peer)
        await h.service.emit(.sessionsChanged, data: away, to: deviceID)
        let again = await h.connect()
        await h.service.emit(.sessionsChanged, data: early, to: deviceID)
        #expect(again.bodies.isEmpty)

        let (resumed, _) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: subscribed.stream, sinceSeq: 2), on: again)

        #expect(resumed.error == nil)
        let awayBytes = try PhoneAppCoding.event(.sessionsChanged, seq: 3, data: away)
        let heldBytes = try PhoneAppCoding.event(.sessionsChanged, seq: 4, data: early)
        #expect(await h.service.resumeDecision(for: deviceID) == .replay([awayBytes, heldBytes]))
        #expect(try await again.body(at: 1) == awayBytes)
        #expect(try await again.body(at: 2) == heldBytes)
        #expect(outbox.bodies.count == 2)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    // MARK: - Revoke

    @Test func revokeDropsStateAndRequestMemory() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.sendStub(h.actions), for: .messageSend)
        let outbox = await h.connect()
        _ = try await h.request(.messageSend, id: "r1", params: sendParams, on: outbox)
        #expect(await h.service.memory.remembers(deviceID: h.peer.deviceID, requestID: "r1"))

        // The bridge's order: the row goes, the connection ends, then the
        // revoke.
        _ = try await h.db.phoneDevices.delete(id: h.peer.deviceID)
        await h.service.phoneDisconnected(h.peer)
        // The send's retention timer and the grace.
        try await h.clock.requireSleepersArmed(count: 2)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)

        #expect(await h.service.streamID(for: h.peer.deviceID) == nil)
        #expect(await !h.service.memory.remembers(deviceID: h.peer.deviceID, requestID: "r1"))
        #expect(h.clock.sleeperCount == 0)
    }

    /// A revoke cancels the device's requests still running. The held send
    /// sees its cancellation, and its run sends no reply, even through a
    /// connection made after the revoke and before the run ended.
    @Test func revokeCancelsTheDevicesRunningRequests() async throws {
        let h = try await PhoneServiceHarness.make()
        let gate = PhoneTestGate()
        let afterCancel = PhoneTestGate()
        defer {
            gate.open()
            afterCancel.open()
        }
        let cancellations = FireRecorder<String>()
        let heldSend = PhoneAppService.typed(MessageSendParams.self) { _, _ -> ActionOutcomeResult in
            await gate.wait()
            if Task.isCancelled {
                cancellations.record("send")
                // Hold the cancelled run until the test has a new connection.
                // An unstructured task does not inherit the cancellation, so
                // this waits for the gate.
                await Task { await afterCancel.wait() }.value
                throw CancellationError()
            }
            return ActionOutcomeResult(outcome: "sent")
        }
        await h.service.setHandler(heldSend, for: .messageSend)
        _ = await h.connect()

        let body = try PhoneTestRequests.body(.messageSend, id: "r1", params: sendParams)
        await h.service.handleAppMessage(body, from: h.peer)
        try await waitUntil("the send to reach its handler") { h.recorder.records.count == 1 }
        _ = try await h.db.phoneDevices.delete(id: h.peer.deviceID)
        await h.service.phoneDisconnected(h.peer)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)

        #expect(await cancellations.next() == "send")
        // A connection current when the cancelled run ends.
        let fresh = await h.connect()
        afterCancel.open()
        try await waitUntil("the request to end") {
            await h.service.requestsRunning(for: h.peer.deviceID) == 0
        }
        // Anything the run had sent was queued before this probe's reply, so
        // the probe's reply being the only body proves the run sent nothing.
        let probe = Data(#"{"kind":"request","method":"acme.unknown","params":{},"requestID":"probe"}"#.utf8)
        await h.service.handleAppMessage(probe, from: h.peer)
        let first = try await fresh.body(at: 0)
        #expect(try JSONDecoder().decode(PhoneTestReply.self, from: first).requestID == "probe")
        #expect(fresh.bodies.count == 1)
    }
}
