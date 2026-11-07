import Foundation
import Testing
import TestSupport

@testable import TBDDaemonLib

private let relayURL = URL(string: "https://acme-relay.acme.workers.dev")!

/// One link under test, with its fake relay, its clock and its events.
private struct LinkHarness: Sendable {
    let room: String
    let relay: FakeRelay
    let clock: EventDrivenTestClock
    let link: RelayLink
    /// Every event the link emitted, in order.
    let events: FireRecorder<RelayLinkEvent>
    /// Records `true` once `events` has finished.
    let ended: FireRecorder<Bool>

    /// Steps virtual time a second at a time until `condition` holds, and
    /// returns how long that took: the length of the backoff sleep the link
    /// was in. Advancing by the expected delay alone would also pass a
    /// shorter sleep; the measured length fails a sleep of the wrong length
    /// in either direction.
    func backoff(until what: String,
                 sourceLocation: SourceLocation = #_sourceLocation,
                 _ condition: @escaping @Sendable () async -> Bool) async throws -> Duration {
        let start = clock.now
        try await clock.advanceUntil(what, by: .seconds(1), maxSteps: 10, sourceLocation: sourceLocation, condition)
        return start.duration(to: clock.now)
    }

    /// How many `ping` texts the laptop has sent in the room.
    var pingsSeen: Int {
        relay.laptopTexts(room: room).filter { $0 == "ping" }.count
    }

    /// Waits until the relay has seen `count` pings from the laptop.
    func requirePings(_ count: Int) async throws {
        let deadline = TestDeadlines.saturatedPass
        switch await pollUntilTrue(timeout: deadline, { self.pingsSeen == count }) {
        case .satisfied:
            return
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw BoundedWaitTimeout(what: "the relay to see \(count) pings",
                                     observed: "texts \(relay.laptopTexts(room: room))", deadline: deadline)
        }
    }
}

/// Builds a link to a fresh room on `relay`, records its events, runs
/// `body`, and stops the link whatever happens, so no loop outlives the test.
private func withLink(
    relay: FakeRelay = FakeRelay(),
    backoff: PhoneBackoff = PhoneBackoff(jitter: { $0 }),
    preflight: @escaping @Sendable () async -> RelayPreflight = { .proceed },
    _ body: (LinkHarness) async throws -> Void
) async throws {
    let room = try PhoneRoom.newToken()
    let clock = EventDrivenTestClock()
    let link = RelayLink(url: PhoneRoom.socketURL(relay: relayURL, roomID: room), transport: relay,
                         backoff: backoff, preflight: preflight, clock: clock)
    let events = FireRecorder<RelayLinkEvent>()
    let ended = FireRecorder<Bool>()
    let pump = Task {
        for await event in link.events {
            events.record(event)
        }
        ended.record(true)
    }
    let harness = LinkHarness(room: room, relay: relay, clock: clock, link: link, events: events, ended: ended)
    do {
        try await body(harness)
    } catch {
        await link.stop()
        await pump.value
        throw error
    }
    await link.stop()
    await pump.value
}

/// A relay check that answers from a script, then `.proceed`, and records
/// how many connect attempts the relay had seen at each call.
private actor PreflightScript {
    private let relay: FakeRelay
    private var answers: [RelayPreflight]
    private(set) var attemptsSeenAtEachCall: [Int] = []

    init(relay: FakeRelay, answers: [RelayPreflight] = []) {
        self.relay = relay
        self.answers = answers
    }

    var calls: Int {
        attemptsSeenAtEachCall.count
    }

    func answer() -> RelayPreflight {
        attemptsSeenAtEachCall.append(relay.connectAttempts.count)
        return answers.isEmpty ? .proceed : answers.removeFirst()
    }
}

private let injectedFailure = FakeRelayError.injectedConnectFailure.localizedDescription

@Suite("RelayLink", .clockDriven)
struct RelayLinkTests {
    // MARK: Rooms and URLs

    @Test func roomAndInfoURLs() throws {
        let room = try PhoneRoom.newToken()
        #expect(PhoneRoom.socketURL(relay: relayURL, roomID: room).absoluteString
            == "wss://acme-relay.acme.workers.dev/v1/rooms/\(room)?role=laptop")
        #expect(PhoneRoom.socketURL(relay: URL(string: "https://acme.example/relay")!, roomID: room).path
            == "/relay/v1/rooms/\(room)")
        #expect(PhoneRoom.infoURL(relay: URL(string: "http://localhost:8787")!).absoluteString
            == "http://localhost:8787/v1/info")
    }

    @Test func trailingSlashesNeverDoubleTheSlashBeforeV1() throws {
        let room = try PhoneRoom.newToken()
        let withSlash = URL(string: "https://acme.example/relay/")!
        #expect(PhoneRoom.socketURL(relay: withSlash, roomID: room).absoluteString
            == "wss://acme.example/relay/v1/rooms/\(room)?role=laptop")
        #expect(PhoneRoom.infoURL(relay: withSlash).absoluteString == "https://acme.example/relay/v1/info")
        #expect(PhoneRoom.infoURL(relay: URL(string: "https://acme.example/")!).absoluteString
            == "https://acme.example/v1/info")
    }

    @Test func aLoopbackRelayGetsAPlainSocketOnItsPort() throws {
        let room = try PhoneRoom.newToken()
        #expect(PhoneRoom.socketURL(relay: URL(string: "http://127.0.0.1:8787")!, roomID: room).absoluteString
            == "ws://127.0.0.1:8787/v1/rooms/\(room)?role=laptop")
    }

    @Test func tokensAre32Bytes() throws {
        let token = try PhoneRoom.newToken()
        #expect(token.count == 43 && PhoneRoom.roomBytes(token)?.count == 32)
        #expect(try PhoneRoom.newToken() != token)
        #expect(FakeRelay.isValidRoomID(token))
        #expect(PhoneRoom.roomBytes("short") == nil)
        #expect(PhoneRoom.roomBytes(Base64URL.encode(Data(count: 16))) == nil)
    }

    // MARK: Backoff

    @Test func productionBackoffDoublesToSixty() {
        let backoff = PhoneBackoff(jitter: { $0 })
        let delays = (1...8).map { backoff.delay(afterFailures: $0) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) })
        #expect(backoff.delay(afterFailures: 1_000) == .seconds(60))
    }

    @Test func equalJitterStaysBetweenHalfAndFull() {
        #expect(PhoneBackoff.equalJitter(.seconds(8), unit: 0) == .seconds(4))
        #expect(PhoneBackoff.equalJitter(.seconds(8), unit: 1) == .seconds(8))
        #expect(PhoneBackoff.equalJitter(.seconds(8), unit: 0.5) == .seconds(6))
        // The default jitter is equal jitter.
        for failures in 1...8 {
            let capped = PhoneBackoff(jitter: { $0 }).delay(afterFailures: failures)
            let drawn = PhoneBackoff().delay(afterFailures: failures)
            #expect(drawn >= capped / 2 && drawn <= capped)
        }
    }

    // MARK: Connecting

    @Test func connectsWithTheUserAgent() async throws {
        try await withLink { h in
            await h.link.start()
            #expect(await h.events.next() == .opened)
            #expect(h.relay.connectAttempts.first?.userAgent == PhoneBridgeConstants.userAgent)
            #expect(h.relay.connectAttempts.first?.url == PhoneRoom.socketURL(relay: relayURL, roomID: h.room))
            #expect(await h.link.isOpen)
            #expect(h.relay.laptopPresent(room: h.room))
        }
    }

    @Test func preflightRunsBeforeEveryConnect() async throws {
        let relay = FakeRelay()
        let script = PreflightScript(relay: relay)
        try await withLink(relay: relay, preflight: { await script.answer() }) { h in
            await h.link.start()
            #expect(await h.events.next() == .opened)
            relay.closeLaptop(room: h.room, code: 1006)
            #expect(await h.events.next() == .closed)
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(1))
            #expect(await h.events.next() == .opened)
            let calls = await script.calls
            #expect(calls == 2 && relay.connectAttempts.count == 2)
            // Each check ran before its own connect.
            #expect(await script.attemptsSeenAtEachCall == [0, 1])
        }
    }

    @Test func aRefusingPreflightStopsTheLinkForGood() async throws {
        try await withLink(preflight: { .refuse("API [2]") }) { h in
            await h.link.start()
            #expect(await h.events.next() == .refused("API [2]") && h.relay.connectAttempts.isEmpty)
            #expect(await h.ended.next() == true)
            #expect(await watchForSleeper(on: h.clock, upTo: .milliseconds(200)) == false)
            #expect(await h.link.isOpen == false)
            // A refused link stays refused.
            await h.link.start()
            #expect(h.relay.connectAttempts.isEmpty)
        }
    }

    @Test func aRetryLaterPreflightBacksOff() async throws {
        let relay = FakeRelay()
        let script = PreflightScript(relay: relay,
                                     answers: [.retryLater("relay unreachable"), .retryLater("relay unreachable")])
        try await withLink(relay: relay, preflight: { await script.answer() }) { h in
            await h.link.start()
            #expect(await h.events.next() == .connectFailed("relay unreachable"))
            let first = try await h.backoff(until: "the second relay check") { await script.calls == 2 }
            #expect(first == .seconds(1))
            #expect(await h.events.next() == .connectFailed("relay unreachable"))
            let second = try await h.backoff(until: "the third relay check") { await script.calls == 3 }
            #expect(second == .seconds(2))
            #expect(await h.events.next() == .opened)
            #expect(relay.connectAttempts.count == 1)
        }
    }

    @Test func failedConnectsBackOffAndCap() async throws {
        let relay = FakeRelay()
        relay.failNextConnects(4)
        let backoff = PhoneBackoff(initial: .seconds(1), maximum: .seconds(4), jitter: { $0 })
        try await withLink(relay: relay, backoff: backoff) { h in
            await h.link.start()
            #expect(await h.events.next() == .connectFailed(injectedFailure))
            for (attempt, seconds) in [(2, 1), (3, 2), (4, 4), (5, 4)] {
                let waited = try await h.backoff(until: "connect attempt \(attempt)") {
                    relay.connectAttempts.count == attempt
                }
                #expect(waited == .seconds(seconds), "the wait before connect attempt \(attempt)")
                let expected: RelayLinkEvent = attempt < 5 ? .connectFailed(injectedFailure) : .opened
                #expect(await h.events.next() == expected)
            }
            #expect(relay.connectAttempts.count == 5 && relay.laptopPresent(room: h.room))
        }
    }

    // MARK: Backoff after a drop

    @Test func anUnstableConnectionKeepsGrowing() async throws {
        try await withLink { h in
            let relay = h.relay
            await h.link.start()
            #expect(await h.events.next() == .opened)
            relay.closeLaptop(room: h.room, code: 1006)
            #expect(await h.events.next() == .closed)
            let first = try await h.backoff(until: "the first reconnect") { relay.connectAttempts.count == 2 }
            #expect(first == .seconds(1))
            #expect(await h.events.next() == .opened)
            relay.closeLaptop(room: h.room, code: 1006)
            #expect(await h.events.next() == .closed)
            let second = try await h.backoff(until: "the second reconnect") { relay.connectAttempts.count == 3 }
            #expect(second == .seconds(2))
        }
    }

    @Test func backoffResetsAfterAStableConnection() async throws {
        let relay = FakeRelay()
        relay.failNextConnects(2)
        try await withLink(relay: relay) { h in
            await h.link.start()
            #expect(await h.events.next() == .connectFailed(injectedFailure))
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(1))
            #expect(await h.events.next() == .connectFailed(injectedFailure))
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(2))
            #expect(await h.events.next() == .opened)
            // A keepalive tick: the ping goes out and the relay answers it.
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(30))
            try await h.requirePings(1)
            relay.closeLaptop(room: h.room, code: 1006)
            #expect(await h.events.next() == .closed)
            // Counting on from the two failures would make this 4 s.
            let waited = try await h.backoff(until: "the reconnect") { relay.connectAttempts.count == 4 }
            #expect(waited == .seconds(1))
        }
    }

    @Test func replacedByAnotherLaptopBacksOff() async throws {
        try await withLink { h in
            let relay = h.relay
            await h.link.start()
            #expect(await h.events.next() == .opened)
            relay.closeLaptop(room: h.room, code: 4000)
            #expect(await h.events.next() == .closed)
            try await h.clock.requireSleeperArmed()
            #expect(relay.connectAttempts.count == 1)
            let waited = try await h.backoff(until: "the reconnect") { relay.connectAttempts.count == 2 }
            #expect(waited == .seconds(1))
        }
    }

    // MARK: Keepalive

    @Test func keepaliveSendsPing() async throws {
        try await withLink { h in
            await h.link.start()
            #expect(await h.events.next() == .opened)
            #expect(h.relay.laptopTexts(room: h.room).isEmpty)
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(30))
            try await h.requirePings(1)
            // The relay answered, so the next tick pings again instead of
            // closing the socket.
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(30))
            try await h.requirePings(2)
            #expect(await h.link.isOpen && h.relay.laptopPresent(room: h.room))
        }
    }

    @Test func aSilentSocketIsClosedAfterAMissedPong() async throws {
        try await withLink { h in
            h.relay.answersPings = false
            await h.link.start()
            #expect(await h.events.next() == .opened)
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(30))
            try await h.requirePings(1)
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(30))
            #expect(await h.events.next() == .closed)
            #expect(!h.relay.laptopPresent(room: h.room))
            #expect(h.relay.laptopCloseCodes(room: h.room) == [1000])
            #expect(h.relay.laptopTexts(room: h.room) == ["ping"])
            // A reconnect is armed.
            try await h.clock.requireSleeperArmed()
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    // MARK: Frames and signals

    @Test func signalsAndFramesBecomeEvents() async throws {
        try await withLink { h in
            await h.link.start()
            #expect(await h.events.next() == .opened)
            let phone = try h.relay.joinAsPhone(room: h.room)
            #expect(await h.events.next() == .peerJoined)
            let awaited1 = try await phone.next()
            #expect(awaited1 == .text("peer-joined"))
            try phone.send(.binary(Data([1, 2, 3])))
            #expect(await h.events.next() == .frame(Data([1, 2, 3])))
            phone.close()
            #expect(await h.events.next() == .peerLeft)
            #expect(await h.link.isOpen)
        }
    }

    @Test func pongAndUnknownRelayTextMakeNoEvent() async throws {
        try await withLink { h in
            await h.link.start()
            #expect(await h.events.next() == .opened)
            h.relay.sendToLaptop(room: h.room, .text("peer-absent"))
            h.relay.sendToLaptop(room: h.room, .text("pong"))
            h.relay.sendToLaptop(room: h.room, .text("relay-news"))
            h.relay.sendToLaptop(room: h.room, .binary(Data([4])))
            #expect(await h.events.next() == .peerAbsent)
            // The frame comes next: the two texts before it made no event.
            #expect(await h.events.next() == .frame(Data([4])))
            #expect(await h.link.isOpen)
        }
    }

    @Test func sendWhileDownThrows() async throws {
        try await withLink { h in
            await #expect(throws: RelayLinkError.notOpen) { try await h.link.send(Data([1])) }
            await h.link.start()
            #expect(await h.events.next() == .opened)
            let phone = try h.relay.joinAsPhone(room: h.room)
            #expect(await h.events.next() == .peerJoined)
            let awaited2 = try await phone.next()
            #expect(awaited2 == .text("peer-joined"))
            try await h.link.send(Data([9]))
            let awaited3 = try await phone.next()
            #expect(awaited3 == .binary(Data([9])))
            await h.link.restart()
            await #expect(throws: RelayLinkError.notOpen) { try await h.link.send(Data([2])) }
        }
    }

    // MARK: Restart and stop

    @Test func restartClosesNowAndReconnectsThroughTheBackoff() async throws {
        try await withLink { h in
            let relay = h.relay
            await h.link.start()
            #expect(await h.events.next() == .opened)
            let phone = try relay.joinAsPhone(room: h.room)
            #expect(await h.events.next() == .peerJoined)
            let awaited4 = try await phone.next()
            #expect(awaited4 == .text("peer-joined"))
            await h.link.restart()
            #expect(await h.link.isOpen == false)
            let awaited5 = try await phone.next()
            #expect(awaited5 == .text("peer-left"))
            #expect(relay.laptopCloseCodes(room: h.room) == [1000])
            #expect(await h.events.next() == .closed)
            let waited = try await h.backoff(until: "the reconnect") { relay.connectAttempts.count == 2 }
            #expect(waited == .seconds(1))
            #expect(await h.events.next() == .opened)
            #expect(await h.events.next() == .peerJoined)
            let awaited6 = try await phone.next()
            #expect(awaited6 == .text("peer-joined"))
        }
    }

    @Test func stopClosesAndNeverReconnects() async throws {
        try await withLink { h in
            await h.link.start()
            #expect(await h.events.next() == .opened)
            await h.link.stop()
            #expect(!h.relay.laptopPresent(room: h.room))
            #expect(h.relay.laptopCloseCodes(room: h.room) == [1000])
            #expect(await h.events.next() == .closed)
            #expect(await h.ended.next() == true)
            #expect(await watchForSleeper(on: h.clock, upTo: .milliseconds(200)) == false)
            // A stopped link stays stopped.
            await h.link.start()
            #expect(h.relay.connectAttempts.count == 1)
            #expect(await h.link.isOpen == false)
        }
    }

    @Test func stopDuringABackoffEndsTheWait() async throws {
        let relay = FakeRelay()
        relay.failNextConnects(1)
        try await withLink(relay: relay) { h in
            await h.link.start()
            #expect(await h.events.next() == .connectFailed(injectedFailure))
            try await h.clock.requireSleeperArmed()
            await h.link.stop()
            // `stop()` waited for the loop, whose sleep it cancelled.
            #expect(!h.clock.hasSleeper)
            #expect(await h.ended.next() == true)
            #expect(relay.connectAttempts.count == 1)
        }
    }
}

// MARK: - The fake relay itself

private func connectLaptop(_ relay: FakeRelay, room: String) async throws -> any RelaySocket {
    try await relay.connect(url: PhoneRoom.socketURL(relay: relayURL, roomID: room), userAgent: "fake-relay-test")
}

/// A laptop and a phone in one room, with both `peer-joined` signals read.
private func pairedRoom(_ relay: FakeRelay) async throws -> (room: String, laptop: any RelaySocket, phone: FakePhoneSocket) {
    let room = try PhoneRoom.newToken()
    let laptop = try await connectLaptop(relay, room: room)
    let phone = try relay.joinAsPhone(room: room)
    #expect(try await laptop.receive() == .text("peer-joined"))
    #expect(try await phone.next() == .text("peer-joined"))
    return (room, laptop, phone)
}

/// The fake follows relay API v1 and its signal routing (spec section 3);
/// the bridge's tests depend on it doing so.
@Suite("FakeRelay", .fastPassBounded)
struct FakeRelayTests {
    @Test func aPhoneAloneGetsPeerAbsentThenPeerJoined() async throws {
        let relay = FakeRelay()
        let room = try PhoneRoom.newToken()
        let phone = try relay.joinAsPhone(room: room)
        #expect(try await phone.next() == .text("peer-absent"))
        let laptop = try await connectLaptop(relay, room: room)
        #expect(try await phone.next() == .text("peer-joined"))
        #expect(try await laptop.receive() == .text("peer-joined"))
    }

    @Test func aLaptopAloneGetsNothingUntilAPhoneJoins() async throws {
        let relay = FakeRelay()
        let room = try PhoneRoom.newToken()
        let laptop = try await connectLaptop(relay, room: room)
        _ = try relay.joinAsPhone(room: room)
        // The first frame the laptop ever gets is the phone's arrival.
        #expect(try await laptop.receive() == .text("peer-joined"))
    }

    @Test func aReplacedPhoneIsClosedWith4000AndTheLaptopHearsNoPeerLeft() async throws {
        let relay = FakeRelay()
        let (room, laptop, first) = try await pairedRoom(relay)
        let second = try relay.joinAsPhone(room: room)
        await #expect(throws: RelaySocketClosed(code: 4000)) { try await first.next() }
        #expect(try await second.next() == .text("peer-joined"))
        #expect(try await laptop.receive() == .text("peer-joined"))
        try second.send(.binary(Data([5])))
        #expect(try await laptop.receive() == .binary(Data([5])))
    }

    @Test func aReplacedLaptopIsClosedWith4000() async throws {
        let relay = FakeRelay()
        let room = try PhoneRoom.newToken()
        let phone = try relay.joinAsPhone(room: room)
        let first = try await connectLaptop(relay, room: room)
        let second = try await connectLaptop(relay, room: room)
        #expect(try await first.receive() == .text("peer-joined"))
        await #expect(throws: RelaySocketClosed(code: 4000)) { try await first.receive() }
        #expect(try await second.receive() == .text("peer-joined"))
        #expect(try await phone.next() == .text("peer-absent"))
        #expect(try await phone.next() == .text("peer-joined"))
        #expect(try await phone.next() == .text("peer-joined"))
        #expect(relay.openLaptopRooms() == [room])
    }

    @Test func framesReachOnlyAPresentPeer() async throws {
        let relay = FakeRelay()
        let room = try PhoneRoom.newToken()
        let laptop = try await connectLaptop(relay, room: room)
        try await laptop.send(.binary(Data([9])))
        let phone = try relay.joinAsPhone(room: room)
        #expect(try await phone.next() == .text("peer-joined"))
        try await laptop.send(.binary(Data([7])))
        // The frame sent before the phone joined was dropped, not queued.
        #expect(try await phone.next() == .binary(Data([7])))
        #expect(relay.laptopFrames(room: room) == [Data([9]), Data([7])])
    }

    @Test func clientTextIsNeverForwardedAndOnlyPingIsAnswered() async throws {
        let relay = FakeRelay()
        let (room, laptop, phone) = try await pairedRoom(relay)
        try phone.send(.text("peer-left"))
        try phone.send(.text("hello"))
        try phone.send(.text("ping"))
        #expect(try await phone.next() == .text("pong"))
        try phone.send(.binary(Data([1])))
        #expect(try await laptop.receive() == .binary(Data([1])))
        relay.answersPings = false
        try await laptop.send(.text("ping"))
        try await laptop.send(.binary(Data([2])))
        #expect(try await phone.next() == .binary(Data([2])))
        try phone.send(.binary(Data([3])))
        // No pong reached the laptop ahead of the frame.
        #expect(try await laptop.receive() == .binary(Data([3])))
        #expect(relay.laptopTexts(room: room) == ["ping"])
    }

    @Test func anOversizeFrameClosesItsSenderWith1009() async throws {
        let relay = FakeRelay()
        let (_, laptop, phone) = try await pairedRoom(relay)
        let largest = Data(repeating: 0xA5, count: FakeRelay.maxFrameBytes)
        try phone.send(.binary(largest))
        #expect(try await laptop.receive() == .binary(largest))
        try phone.send(.binary(Data(count: FakeRelay.maxFrameBytes + 1)))
        await #expect(throws: RelaySocketClosed(code: 1009)) { try await phone.next() }
        #expect(try await laptop.receive() == .text("peer-left"))
    }

    @Test func duplicateAndSwapReorderTheNextPhoneFrames() async throws {
        let relay = FakeRelay()
        let (room, laptop, phone) = try await pairedRoom(relay)
        relay.duplicateNextPhoneFrame(room: room)
        try phone.send(.binary(Data([1])))
        relay.swapNextTwoPhoneFrames(room: room)
        try phone.send(.binary(Data([2])))
        try phone.send(.binary(Data([3])))
        try phone.send(.binary(Data([4])))
        var received: [RelayFrame] = []
        for _ in 0..<5 {
            received.append(try await laptop.receive())
        }
        let order: [UInt8] = [1, 1, 3, 2, 4]
        #expect(received == order.map { RelayFrame.binary(Data([$0])) })
    }

    @Test func closingTheLastSocketOfARoleSendsPeerLeft() async throws {
        let relay = FakeRelay()
        let (room, laptop, phone) = try await pairedRoom(relay)
        await laptop.close(code: 1000)
        #expect(try await phone.next() == .text("peer-left"))
        #expect(!relay.laptopPresent(room: room) && relay.openLaptopRooms().isEmpty)
        #expect(relay.laptopCloseCodes(room: room) == [1000])
        await #expect(throws: RelaySocketClosed(code: 1000)) { try await laptop.receive() }
        await #expect(throws: RelaySocketClosed(code: 1000)) { try await laptop.send(.binary(Data([1]))) }
    }

    @Test func closeLaptopTellsThePhoneUnlessItStandsForAReplacement() async throws {
        let relay = FakeRelay()
        let (dropped, droppedLaptop, droppedPhone) = try await pairedRoom(relay)
        relay.closeLaptop(room: dropped, code: 1006)
        #expect(try await droppedPhone.next() == .text("peer-left"))
        await #expect(throws: RelaySocketClosed(code: 1006)) { try await droppedLaptop.receive() }

        let (replaced, replacedLaptop, replacedPhone) = try await pairedRoom(relay)
        relay.closeLaptop(room: replaced, code: 4000)
        await #expect(throws: RelaySocketClosed(code: 4000)) { try await replacedLaptop.receive() }
        await #expect(throws: FakePhoneSocketTimeout.self) { try await replacedPhone.next(timeout: .milliseconds(100)) }
        #expect(relay.laptopCloseCodes(room: dropped).isEmpty && relay.laptopCloseCodes(room: replaced).isEmpty)
    }

    @Test func connectRecordsEveryAttemptAndRefusesBadRooms() async throws {
        let relay = FakeRelay()
        let room = try PhoneRoom.newToken()
        await #expect(throws: FakeRelayError.httpStatus(404)) { try await connectLaptop(relay, room: "short") }
        await #expect(throws: FakeRelayError.httpStatus(404)) {
            try await relay.connect(url: URL(string: "wss://acme-relay.acme.workers.dev//v1/rooms/\(room)?role=laptop")!,
                                    userAgent: "fake-relay-test")
        }
        await #expect(throws: FakeRelayError.httpStatus(400)) {
            try await relay.connect(url: URL(string: "wss://acme-relay.acme.workers.dev/v1/rooms/\(room)?role=phone")!,
                                    userAgent: "fake-relay-test")
        }
        #expect(throws: FakeRelayError.httpStatus(404)) { try relay.joinAsPhone(room: "short") }
        relay.failNextConnects(1)
        await #expect(throws: FakeRelayError.injectedConnectFailure) { try await connectLaptop(relay, room: room) }
        _ = try await connectLaptop(relay, room: room)
        #expect(relay.connectAttempts.count == 5)
        #expect(relay.connectAttempts.allSatisfy { $0.userAgent == "fake-relay-test" })
        #expect(relay.openLaptopRooms() == [room])
    }

    @Test func aPhoneTimeoutNamesTheFramesItWasSent() async throws {
        let relay = FakeRelay()
        let room = try PhoneRoom.newToken()
        let phone = try relay.joinAsPhone(room: room)
        #expect(try await phone.next() == .text("peer-absent"))
        do {
            _ = try await phone.next(timeout: .milliseconds(50))
            Issue.record("next() returned a frame; expected a timeout")
        } catch let timeout as FakePhoneSocketTimeout {
            #expect(timeout.seen == [.text("peer-absent")])
            #expect(timeout.description.contains("text \"peer-absent\""))
        }
    }
}
