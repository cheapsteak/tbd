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

        let (reply, _) = try await h.request(.messageSend, params: sendParams, on: outbox)

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

    /// The pure reads skip the request memory; everything else goes through it.
    @Test func pureReadsAreNotRemembered() async throws {
        let h = try await PhoneServiceHarness.make()
        let listStub = PhoneAppService.typed(PhoneEmpty.self) { _, _ in ProfilesListResult(profiles: []) }
        await h.service.setHandler(listStub, for: .profilesList)
        await h.service.setHandler(Self.closeStub, for: .transcriptClose)
        let outbox = await h.connect()

        let (read, _) = try await h.request(.profilesList, id: "read", params: PhoneEmpty(), on: outbox)
        let (close, _) = try await h.request(.transcriptClose, id: "close", params: PhoneEmpty(), on: outbox)

        #expect(read.error == nil)
        #expect(close.error == nil)
        #expect(await !h.service.memory.remembers(deviceID: h.peer.deviceID, requestID: "read"))
        #expect(await h.service.memory.remembers(deviceID: h.peer.deviceID, requestID: "close"))
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
        // The subscribe's retention timer and the grace.
        try await h.clock.requireSleepersArmed(count: 2)
        await h.clock.advance(by: .seconds(60))
        let again = await h.connect()

        // Reconnecting cancelled the grace; only the retention timer is left.
        #expect(h.clock.sleeperCount == 1)
        #expect(try await subscribedStream(h, on: again) == stream)
    }

    @Test func stateIsDroppedAfterTheGrace() async throws {
        let h = try await PhoneServiceHarness.make()
        await h.service.setHandler(Self.subscribeStub(h.service), for: .sessionsSubscribe)
        let outbox = await h.connect()
        let stream = try await subscribedStream(h, on: outbox)

        await h.service.phoneDisconnected(h.peer)
        // The subscribe's retention timer and the grace.
        try await h.clock.requireSleepersArmed(count: 2)
        await h.clock.advance(by: .seconds(119))
        #expect(await h.service.streamID(for: h.peer.deviceID) == stream)
        await h.clock.advance(by: .seconds(1))
        try await waitUntil("the grace to drop the state") {
            await h.service.streamID(for: h.peer.deviceID) == nil
        }

        let again = await h.connect()
        #expect(try await subscribedStream(h, on: again) != stream)
    }

    /// While the phone is away, an event is numbered and kept, not sent. A
    /// `sessions.subscribe` naming the stream and the last seq the phone saw
    /// decides to replay exactly what it missed, before the next message.
    @Test func anEventWhileDisconnectedIsKeptForTheResume() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let outbox = await h.connect()
        let seen = SessionsChangedData(layout: nil, rows: [], removedRowIDs: ["acme-1"])
        let missed = SessionsChangedData(layout: nil, rows: [], removedRowIDs: ["acme-2"])

        await h.service.emit(.sessionsChanged, data: seen, to: deviceID)
        let sent = try await outbox.body(at: 0)
        await h.service.phoneDisconnected(h.peer)
        await h.service.emit(.sessionsChanged, data: missed, to: deviceID)
        let again = await h.connect()
        let stream = try #require(await h.service.streamID(for: deviceID))

        // No handler serves `sessions.subscribe` yet; the decision is made all
        // the same.
        _ = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: stream, sinceSeq: 1), on: again)

        let seenBytes = try PhoneAppCoding.event(.sessionsChanged, seq: 1, data: seen)
        let missedBytes = try PhoneAppCoding.event(.sessionsChanged, seq: 2, data: missed)
        #expect(sent == seenBytes)
        #expect(await h.service.resumeDecision(for: deviceID) == .replay([missedBytes]))
        #expect(outbox.bodies.count == 1)
        #expect(again.bodies.count == 1)
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
    /// sees its cancellation, and no reply goes out.
    @Test func revokeCancelsTheDevicesRunningRequests() async throws {
        let h = try await PhoneServiceHarness.make()
        let gate = PhoneTestGate()
        defer { gate.open() }
        let cancellations = FireRecorder<String>()
        let heldSend = PhoneAppService.typed(MessageSendParams.self) { _, _ -> ActionOutcomeResult in
            await gate.wait()
            if Task.isCancelled {
                cancellations.record("send")
                throw CancellationError()
            }
            return ActionOutcomeResult(outcome: "sent")
        }
        await h.service.setHandler(heldSend, for: .messageSend)
        let outbox = await h.connect()

        let body = try PhoneTestRequests.body(.messageSend, id: "r1", params: sendParams)
        await h.service.handleAppMessage(body, from: h.peer)
        try await waitUntil("the send to reach its handler") { h.recorder.records.count == 1 }
        _ = try await h.db.phoneDevices.delete(id: h.peer.deviceID)
        await h.service.phoneDisconnected(h.peer)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)

        #expect(await cancellations.next() == "send")
        try await waitUntil("the request to end") {
            await h.service.requestsRunning(for: h.peer.deviceID) == 0
        }
        #expect(outbox.bodies.isEmpty)
    }
}
