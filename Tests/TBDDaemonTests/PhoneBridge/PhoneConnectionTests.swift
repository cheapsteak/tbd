import CryptoKit
import Foundation
import GRDB
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

private let relayURL = URL(string: "https://acme-relay.acme.workers.dev")!

/// IK message 1 for `room`, to the laptop whose public key is `laptopKey`,
/// from a phone with `key`. Built here rather than through ``TestPhone``,
/// whose socket would join the room and end the channel under test.
private func ikMessage1(room: String, laptopKey: Curve25519.KeyAgreement.PublicKey,
                        key: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
    let roomBytes = try #require(PhoneRoom.roomBytes(room))
    var initiator = try NoiseInitiator(pattern: .ik, staticKey: key, remoteStatic: laptopKey, psk: nil,
                                       prologue: PhoneChannelPrologue.make(roomID: roomBytes))
    return try initiator.writeMessage1(payload: Data("{}".utf8))
}

/// Holds `writer` inside one write until `release` is signalled, so every
/// other access to it waits, and records on `holding` once it holds.
/// Synchronous, so the hold blocks the calling thread; the caller keeps that
/// thread off the cooperative pool with `gateHoldingTask`.
private func holdWrites(_ writer: any DatabaseWriter, until release: DispatchSemaphore,
                        holding: FireRecorder<Void>) {
    _ = try? writer.write { _ -> Void in
        holding.record(())
        release.waitForGate("the phone_device write hold")
    }
}

/// One connection under test, with everything it talks to.
private struct ConnectionHarness: Sendable {
    let db: TBDDatabase
    /// The paired phone's row; the connection serves its room.
    let device: PhoneDevice
    /// The paired phone's key, the one `device` holds.
    let phoneKey: Curve25519.KeyAgreement.PrivateKey
    let laptopKey: Curve25519.KeyAgreement.PrivateKey
    let relay: FakeRelay
    let clock: EventDrivenTestClock
    let dates: TestDateSource
    let app: RecordingPhoneApp
    /// Every event the connection emitted, in order.
    let events: FireRecorder<PhoneConnection.Event>
    let connection: PhoneConnection

    var room: String {
        device.roomID
    }

    /// A phone in the device room with `key` (the paired one by default),
    /// with the relay's `peer-joined` read.
    func joinedPhone(key: Curve25519.KeyAgreement.PrivateKey? = nil) async throws -> TestPhone {
        try await TestPhone.joined(relay: relay, room: room, key: key ?? phoneKey)
    }

    /// A phone with the paired key that has handshaken, sent `hello` and
    /// read `welcome`, so its channel is established.
    func connectedPhone() async throws -> TestPhone {
        try await TestPhone.connected(relay: relay, room: room, key: phoneKey, laptopKey: laptopKey.publicKey)
    }

    /// Waits until `condition` holds, or throws naming `what` and the app's
    /// log and the connection's events as they stand.
    func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = TestDeadlines.saturatedPass
        switch await pollUntilTrue(timeout: deadline, condition) {
        case .satisfied:
            return
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            let log = await app.log
            throw BoundedWaitTimeout(what: what, observed: "app log \(log), events \(events.values)", deadline: deadline)
        }
    }

    /// Waits until the connection has emitted `event`.
    func waitForEvent(_ event: PhoneConnection.Event) async throws {
        try await waitUntil("the event \(event)") { events.values.contains(event) }
    }

    /// A frame the laptop could not decrypt in order: the channel ended once,
    /// and the room socket closed and, after one backoff, opened again.
    func expectTheRoomReopened(for phone: TestPhone) async throws {
        let left = try await phone.nextSignal()
        #expect(left == "peer-left")
        let log = await app.log
        #expect(log.filter { $0 == "disconnected" }.count == 1)
        try await clock.advanceUntil("the laptop rejoined", by: .seconds(1)) { relay.laptopPresent(room: room) }
        let joined = try await phone.nextSignal()
        #expect(joined == "peer-joined")
        #expect(relay.connectAttempts.count == 2)
    }
}

/// Builds a connection for one paired phone on a fake relay, starts it,
/// waits for its socket to open, runs `body`, and stops the connection
/// whatever happens, so no task outlives the test. The connection opens its
/// sockets through `transport`, `relay` itself when nil. `onNow` runs on
/// every read of the connection's date seam, which it reads only to stamp
/// the phone's last-seen time, just before it writes it.
private func withConnection(relay: FakeRelay = FakeRelay(), transport: (any RelayTransport)? = nil,
                            onNow: (@Sendable () -> Void)? = nil,
                            _ body: (ConnectionHarness) async throws -> Void) async throws {
    let db = try TBDDatabase(inMemory: true)
    let dates = TestDateSource()
    let now: @Sendable () -> Date = { [dates] in
        onNow?()
        return dates.now
    }
    let phoneKey = Curve25519.KeyAgreement.PrivateKey()
    let laptopKey = Curve25519.KeyAgreement.PrivateKey()
    let room = try PhoneRoom.newToken()
    let device = PhoneDevice(id: UUID(), name: "iPhone", publicKey: phoneKey.publicKey.rawRepresentation,
                             roomID: room, pairedAt: dates.now.addingTimeInterval(-3_600))
    try await db.phoneDevices.insert(device)
    let bundle = try PhoneAppBundle.loadShipped()
    let sockets: any RelayTransport = transport ?? (relay as any RelayTransport)
    let clock = EventDrivenTestClock()
    let app = RecordingPhoneApp()
    let events = FireRecorder<PhoneConnection.Event>()
    let connection = PhoneConnection(
        device: device, relayURL: relayURL, transport: sockets, laptopKey: laptopKey, laptopName: "acme-laptop",
        devices: db.phoneDevices, bundle: bundle, appSlot: PhoneAppHandlerSlot(app),
        preflight: { .proceed }, onEvent: { events.record($0) }, now: now,
        backoff: PhoneBackoff(jitter: { $0 }), clock: clock)
    let harness = ConnectionHarness(db: db, device: device, phoneKey: phoneKey, laptopKey: laptopKey, relay: relay,
                                    clock: clock, dates: dates, app: app, events: events, connection: connection)
    await connection.start()
    do {
        let opened = await events.next()
        try #require(opened == .linkOpened)
        try await body(harness)
    } catch {
        await connection.stop()
        throw error
    }
    await connection.stop()
}

@Suite("PhoneConnection", .clockDriven)
struct PhoneConnectionTests {
    // MARK: Handshakes

    @Test func aPairedPhoneHandshakesAndGetsWelcome() async throws {
        try await withConnection { h in
            let phone = try await h.joinedPhone()
            let laptopName = try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            #expect(laptopName == "acme-laptop")
            try await phone.sendHello()
            let welcome = try await phone.next()
            #expect(welcome["type"] as? String == "welcome")
            #expect(welcome["protocol"] as? Int == 1)
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func connectedOnlyAfterTheFirstTransportMessage() async throws {
        try await withConnection { h in
            let phone = try await h.joinedPhone()
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            // Message 2 is out, and nothing has decrypted yet.
            let connectedEarly = await h.connection.isConnected
            #expect(connectedEarly == false)
            let seenEarly = try await h.db.phoneDevices.device(id: h.device.id)?.lastSeenAt
            #expect(seenEarly == nil)
            #expect(!h.events.values.contains(.connected(deviceID: h.device.id)))
            let logEarly = await h.app.log
            #expect(logEarly.isEmpty)

            try await phone.sendHello()
            let welcome = try await phone.next()
            #expect(welcome["type"] as? String == "welcome")
            #expect(h.events.values.contains(.connected(deviceID: h.device.id)))
            let seen = try await h.db.phoneDevices.device(id: h.device.id)?.lastSeenAt
            #expect(seen == h.dates.now)
            let log = await h.app.log
            #expect(log == ["connected"])
            let peers = await h.app.peers
            #expect(peers.first == PhonePeer(deviceID: h.device.id, deviceName: h.device.name))
            let connected = await h.connection.isConnected
            #expect(connected)
        }
    }

    @Test func aReplayedMessage1NeverConnects() async throws {
        try await withConnection { h in
            let phone = try await h.joinedPhone()
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            let message1 = try #require(phone.lastMessage1)
            phone.close()

            let replayer = try h.relay.joinAsPhone(room: h.room)
            let joined = try await replayer.next()
            #expect(joined == .text("peer-joined"))
            try replayer.send(.binary(message1))
            let answer = try await replayer.next()
            // The laptop answered both copies of message 1 with a message 2.
            let frames = h.relay.laptopFrames(room: h.room)
            #expect(frames.count == 2)
            let secondMessage2 = frames.last.map { RelayFrame.binary($0) }
            #expect(answer == secondMessage2)

            // The replayer cannot produce a transport message, so the channel
            // never becomes established, and the timer drops it.
            try await h.clock.requireSleepersArmed(count: 2)
            await h.clock.advance(by: PhoneBridgeConstants.handshakeTimeout)
            try await h.waitForEvent(.handshakeRefused("handshake timed out"))
            let connected = await h.connection.isConnected
            #expect(connected == false)
            #expect(!h.events.values.contains(.connected(deviceID: h.device.id)))
            let log = await h.app.log
            #expect(log.isEmpty)
            let seen = try await h.db.phoneDevices.device(id: h.device.id)?.lastSeenAt
            #expect(seen == nil)
        }
    }

    @Test func anUnknownKeyIsRefused() async throws {
        try await withConnection { h in
            let stranger = try await h.joinedPhone(key: Curve25519.KeyAgreement.PrivateKey())
            try await stranger.startIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            let refused = await h.events.next()
            #expect(refused == .handshakeRefused("unknown key"))
            #expect(h.relay.laptopFrames(room: h.room).isEmpty)

            // The socket stayed open: the paired phone connects on it.
            _ = try await h.connectedPhone()
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func aRevokedKeyIsRefused() async throws {
        try await withConnection { h in
            let deleted = try await h.db.phoneDevices.delete(id: h.device.id)
            #expect(deleted)
            let phone = try await h.joinedPhone()
            try await phone.startIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            let refused = await h.events.next()
            #expect(refused == .handshakeRefused("no paired device for this room"))
            #expect(h.relay.laptopFrames(room: h.room).isEmpty)
            let log = await h.app.log
            #expect(log.isEmpty)
        }
    }

    @Test func anotherPairedPhonesKeyIsRefusedInThisRoom() async throws {
        try await withConnection { h in
            // A second phone, paired with this laptop in a room of its own.
            let otherKey = Curve25519.KeyAgreement.PrivateKey()
            let otherRoom = try PhoneRoom.newToken()
            let other = PhoneDevice(id: UUID(), name: "iPad", publicKey: otherKey.publicKey.rawRepresentation,
                                    roomID: otherRoom, pairedAt: h.dates.now)
            try await h.db.phoneDevices.insert(other)

            let intruder = try await h.joinedPhone(key: otherKey)
            try await intruder.startIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            let refused = await h.events.next()
            #expect(refused == .handshakeRefused("unknown key"))
            #expect(h.relay.laptopFrames(room: h.room).isEmpty)
            let log = await h.app.log
            #expect(log.isEmpty)
        }
    }

    @Test func aRowDeletedAfterAConnectionIsHonouredOnTheNextHandshake() async throws {
        try await withConnection { h in
            let first = try await h.connectedPhone()
            first.close()
            try await h.waitUntil("the channel to end") { await h.app.log.contains("disconnected") }
            let deleted = try await h.db.phoneDevices.delete(id: h.device.id)
            #expect(deleted)
            // Message 2 and `welcome`, from the first connection.
            let framesBefore = h.relay.laptopFrames(room: h.room).count
            #expect(framesBefore == 2)

            // The same key comes back, on a new socket.
            let again = try await h.joinedPhone()
            try await again.startIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            try await h.waitForEvent(.handshakeRefused("no paired device for this room"))
            #expect(h.relay.laptopFrames(room: h.room).count == framesBefore)
            let log = await h.app.log
            #expect(log == ["connected", "disconnected"])
            let connected = await h.connection.isConnected
            #expect(connected == false)
        }
    }

    @Test func aJunkFrameBeforeMessage1IsDroppedAndIKStillConnects() async throws {
        try await withConnection { h in
            let phone = try await h.joinedPhone()
            try await phone.sendRaw(PhoneTestVectors.randomBytes(100))
            let refused = await h.events.next()
            #expect(refused == .handshakeRefused("unreadable handshake message"))
            #expect(h.relay.laptopFrames(room: h.room).isEmpty)

            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            try await phone.sendHello()
            let welcome = try await phone.next()
            #expect(welcome["type"] as? String == "welcome")
            #expect(h.events.values.contains(.connected(deviceID: h.device.id)))
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func aHandshakeWithNoTransportMessageTimesOutBackToWaiting() async throws {
        try await withConnection { h in
            let phone = try await h.joinedPhone()
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            // The keepalive and the handshake timer.
            try await h.clock.requireSleepersArmed(count: 2)
            await h.clock.advance(by: .seconds(9))
            await settle()
            #expect(!h.events.values.contains(.handshakeRefused("handshake timed out")))
            await h.clock.advance(by: .seconds(1))
            try await h.waitForEvent(.handshakeRefused("handshake timed out"))
            let connected = await h.connection.isConnected
            #expect(connected == false)
            #expect(!h.events.values.contains(.connected(deviceID: h.device.id)))
            let log = await h.app.log
            #expect(log.isEmpty)
            // The channel was dropped silently: nothing went out after message 2.
            #expect(h.relay.laptopFrames(room: h.room).count == 1)

            // The same socket handshakes again.
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            try await phone.sendHello()
            let welcome = try await phone.next()
            #expect(welcome["type"] as? String == "welcome")
            #expect(phone.closeCode == nil)
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func aJunkFrameAfterMessage2IsDroppedAndHelloStillConnects() async throws {
        try await withConnection { h in
            let phone = try await h.joinedPhone()
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            // Nothing has decrypted yet, so the junk is tried as a message 1,
            // refused, and dropped; the handshaken channel stays.
            try await phone.sendRaw(PhoneTestVectors.randomBytes(100))
            try await h.waitForEvent(.handshakeRefused("unreadable handshake message"))
            try await phone.sendHello()
            let welcome = try await phone.next()
            #expect(welcome["type"] as? String == "welcome")
            #expect(h.events.values.contains(.connected(deviceID: h.device.id)))
            let log = await h.app.log
            #expect(log == ["connected"])
            // Message 2 and `welcome`: nothing answered the junk.
            #expect(h.relay.laptopFrames(room: h.room).count == 2)
            // The room socket never reopened.
            #expect(phone.closeCode == nil)
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func thePhonesRealMessage1ReplacesAValidReplayThatArrivedFirst() async throws {
        try await withConnection { h in
            let phone = try await h.joinedPhone()
            // An earlier attempt by the phone, whose message 1 a replayer
            // captured. The page then reloads: its new socket ends that
            // handshaken channel.
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            let replayed = try #require(phone.lastMessage1)
            try await phone.rejoin(room: h.room)

            // The replay reaches the laptop first, on the phone's new socket.
            // The laptop reads it as a message 1, accepts it, and answers
            // with a message 2 the phone cannot use.
            try await phone.sendRaw(replayed)
            try await h.waitUntil("the laptop to answer the replay") {
                h.relay.laptopFrames(room: h.room).count == 2
            }
            let replayAnswer = try await phone.nextRawFrame()
            #expect(replayAnswer == h.relay.laptopFrames(room: h.room).last)

            // Then the phone's real message 1: it fails to decrypt on the
            // replay's channel, is read as a message 1, and replaces it.
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            try await phone.sendHello()
            let welcome = try await phone.next()
            #expect(welcome["type"] as? String == "welcome")
            #expect(h.events.values.contains(.connected(deviceID: h.device.id)))
            let log = await h.app.log
            #expect(log == ["connected"])
            let refusals = h.events.values.filter { event in
                if case .handshakeRefused = event { return true }
                return false
            }
            #expect(refusals.isEmpty)
            // Three message 2s and `welcome`.
            #expect(h.relay.laptopFrames(room: h.room).count == 4)
            // The room socket never reopened.
            #expect(phone.closeCode == nil)
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func aMessage1TheRelayDeliversTwiceIsAnsweredOnce() async throws {
        try await withConnection { h in
            let phone = try await h.joinedPhone()
            // The laptop gets the phone's message 1 twice. Answering the copy
            // would replace the channel with one the phone, which reads the
            // first message 2, cannot complete, and its `hello` would be
            // dropped.
            h.relay.duplicateNextPhoneFrame(room: h.room)
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            try await phone.sendHello()
            // The phone's next frame is `welcome`. A second message 2 would
            // come first and fail to decrypt here.
            let welcome = try await phone.next()
            #expect(welcome["type"] as? String == "welcome")
            #expect(h.events.values.contains(.handshakeRefused("repeated handshake message")))
            #expect(h.events.values.contains(.connected(deviceID: h.device.id)))
            let log = await h.app.log
            #expect(log == ["connected"])
            // One message 2 and `welcome`: the copy got no answer.
            #expect(h.relay.laptopFrames(room: h.room).count == 2)
            #expect(phone.closeCode == nil)
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func refusedHandshakesKeepAHandshakenChannelThatStillConnects() async throws {
        try await withConnection { h in
            // A phone paired with this laptop in a room of its own, then
            // revoked.
            let revokedKey = Curve25519.KeyAgreement.PrivateKey()
            let revokedRoom = try PhoneRoom.newToken()
            let revoked = PhoneDevice(id: UUID(), name: "iPad", publicKey: revokedKey.publicKey.rawRepresentation,
                                      roomID: revokedRoom, pairedAt: h.dates.now)
            try await h.db.phoneDevices.insert(revoked)
            let deleted = try await h.db.phoneDevices.delete(id: revoked.id)
            #expect(deleted)

            let phone = try await h.joinedPhone()
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            // While the channel waits for its first transport message, two
            // message 1s arrive on the phone's socket: one from a key never
            // paired, then one from the revoked phone's key. Each fails to
            // decrypt, is read as a message 1, and is refused.
            try await phone.sendRaw(ikMessage1(room: h.room, laptopKey: h.laptopKey.publicKey,
                                               key: Curve25519.KeyAgreement.PrivateKey()))
            try await phone.sendRaw(ikMessage1(room: h.room, laptopKey: h.laptopKey.publicKey, key: revokedKey))

            // The handshaken channel was kept: the phone's `hello`, sealed for
            // it, decrypts. Frames are handled in order, so both refusals came
            // first.
            try await phone.sendHello()
            let welcome = try await phone.next()
            #expect(welcome["type"] as? String == "welcome")
            let refusals = h.events.values.filter { $0 == .handshakeRefused("unknown key") }
            #expect(refusals.count == 2)
            #expect(h.events.values.contains(.connected(deviceID: h.device.id)))
            let log = await h.app.log
            #expect(log == ["connected"])
            // One message 2 and `welcome`: neither refused handshake was
            // answered.
            #expect(h.relay.laptopFrames(room: h.room).count == 2)
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    // MARK: App messages

    @Test func appMessagesAreHandledOneAtATimeInOrder() async throws {
        try await withConnection { h in
            let phone = try await h.connectedPhone()
            await h.app.closeGate(on: "r1")
            for requestID in ["r1", "r2", "r3"] {
                try await phone.sendRequest(requestID)
            }
            try await h.waitUntil("r1 to reach the app") { await h.app.log.contains("message:r1") }
            // r2 and r3 have reached the laptop's socket; neither starts
            // while r1 is held.
            await settle()
            let held = await h.app.log
            #expect(held == ["connected", "message:r1"])
            await h.app.openGate()
            phone.close()
            try await h.waitUntil("the channel to end") { await h.app.log.contains("disconnected") }
            let log = await h.app.log
            #expect(log == ["connected", "message:r1", "message:r2", "message:r3", "disconnected"])
        }
    }

    @Test func anIncompatibleLoaderHearsWhyBeforeTheSocketCloses() async throws {
        try await withConnection { h in
            let phone = try await h.joinedPhone()
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            try await phone.send(json: ["type": "hello", "loaderVersion": "9.0.0", "protocols": [99]])
            let answer = try await phone.next()
            #expect(answer["type"] as? String == "incompatible")
            #expect(answer["tooOld"] as? String == "laptop")
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            let log = await h.app.log
            #expect(log == ["connected", "disconnected"])
        }
    }

    // MARK: Frames out of order

    @Test func aDuplicatedFrameEndsTheConnection() async throws {
        try await withConnection { h in
            let phone = try await h.connectedPhone()
            h.relay.duplicateNextPhoneFrame(room: h.room)
            try await phone.send(json: ["type": "app", "body": ["kind": "event"]])
            try await h.expectTheRoomReopened(for: phone)
        }
    }

    @Test func aReorderedFrameEndsTheConnection() async throws {
        try await withConnection { h in
            let phone = try await h.connectedPhone()
            h.relay.swapNextTwoPhoneFrames(room: h.room)
            try await phone.send(json: ["type": "app", "body": ["kind": "event"]])
            try await phone.send(json: ["type": "app", "body": ["kind": "event"]])
            try await h.expectTheRoomReopened(for: phone)
        }
    }

    @Test func aReplayedMessage1OnAnEstablishedChannelEndsIt() async throws {
        try await withConnection { h in
            let phone = try await h.connectedPhone()
            let message1 = try #require(phone.lastMessage1)
            // The relay itself injects the phone's own valid message 1 on the
            // phone's open socket, so no `peer-joined` precedes it. On an
            // established channel it is no new handshake: it fails to
            // decrypt, which is fatal.
            h.relay.sendToLaptop(room: h.room, .binary(message1))
            try await h.expectTheRoomReopened(for: phone)
            // It was not answered as a handshake: the laptop's frames are
            // still message 2 and `welcome`.
            #expect(h.relay.laptopFrames(room: h.room).count == 2)
            let refusals = h.events.values.filter { event in
                if case .handshakeRefused = event { return true }
                return false
            }
            #expect(refusals.isEmpty)
            let log = await h.app.log
            #expect(log == ["connected", "disconnected"])
        }
    }

    // MARK: Reloads

    @Test func aReloadedPageGetsAFreshChannel() async throws {
        try await withConnection { h in
            let first = try await h.connectedPhone()
            // A second socket with the same key replaces the first; the relay
            // sends the laptop `peer-joined` and no `peer-left`.
            let reloaded = try await h.joinedPhone()
            #expect(first.closeCode == 4000)
            try await reloaded.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)
            try await reloaded.sendHello()
            let welcome = try await reloaded.next()
            #expect(welcome["type"] as? String == "welcome")
            let log = await h.app.log
            #expect(log == ["connected", "disconnected", "connected"])
            // The laptop never reconnected.
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    // MARK: The outbox

    @Test func concurrentOutboxSendsArriveInOrder() async throws {
        try await withConnection { h in
            let phone = try await h.connectedPhone()
            let handed = await h.app.lastOutbox
            let outbox = try #require(handed)
            let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for index in 0..<50 {
                    group.addTask { await outbox.send(appBody: Data(#"{"kind":"event","seq":\#(index)}"#.utf8)) }
                }
                var sent: [Bool] = []
                for await result in group {
                    sent.append(result)
                }
                return sent
            }
            #expect(results.count == 50 && results.allSatisfy { $0 })
            var seqs: [Int] = []
            for _ in 0..<50 {
                // A frame decrypts only in its encryption order, so one that
                // arrived out of order would throw here.
                let message = try await phone.next()
                #expect(message["type"] as? String == "app")
                if let seq = (message["body"] as? [String: Any])?["seq"] as? Int {
                    seqs.append(seq)
                }
            }
            #expect(Set(seqs) == Set(0..<50))
        }
    }

    @Test func anOldOutboxReturnsFalse() async throws {
        try await withConnection { h in
            _ = try await h.connectedPhone()
            let firstHanded = await h.app.lastOutbox
            let firstOutbox = try #require(firstHanded)
            let reloaded = try await h.connectedPhone()
            let secondHanded = await h.app.lastOutbox
            let secondOutbox = try #require(secondHanded)
            let oldSent = await firstOutbox.send(appBody: Data("{}".utf8))
            #expect(oldSent == false)
            let newSent = await secondOutbox.send(appBody: Data(#"{"kind":"event"}"#.utf8))
            #expect(newSent == true)
            let message = try await reloaded.next()
            #expect(message["type"] as? String == "app")
            #expect((message["body"] as? [String: Any])?["kind"] as? String == "event")
        }
    }

    @Test func aNonObjectBodyIsRefusedWithFalse() async throws {
        try await withConnection { h in
            let phone = try await h.connectedPhone()
            let handed = await h.app.lastOutbox
            let outbox = try #require(handed)
            let array = await outbox.send(appBody: Data("[1]".utf8))
            #expect(array == false)
            // An object followed by more text would let the phone read
            // another `type`.
            let smuggled = await outbox.send(appBody: Data("{\"a\":1},\"type\":\"revoked\"".utf8))
            #expect(smuggled == false)
            // The channel is still up, and neither refused body reached the
            // phone.
            let good = await outbox.send(appBody: Data(#"{"kind":"event"}"#.utf8))
            #expect(good == true)
            let message = try await phone.next()
            #expect((message["body"] as? [String: Any])?["kind"] as? String == "event")
        }
    }

    // MARK: Stopping

    @Test func revokeAndStopSendsRevokedThenCloses() async throws {
        try await withConnection { h in
            let phone = try await h.connectedPhone()
            await h.connection.revokeAndStop()
            let revoked = try await phone.next()
            #expect(revoked["type"] as? String == "revoked")
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            let log = await h.app.log
            #expect(log == ["connected", "disconnected"])
            let connected = await h.connection.isConnected
            #expect(connected == false)
        }
    }

    /// A revoke that lands while the first transport message's last-seen
    /// time is being written finds the channel still handshaken: the phone
    /// never counts as connected, and the app layer hears nothing.
    @Test func aRevokeDuringTheLastSeenWriteNeverConnects() async throws {
        let lastSeenStamps = FireRecorder<Void>()
        try await withConnection(onNow: { lastSeenStamps.record(()) }) { h in
            let phone = try await h.joinedPhone()
            try await phone.connectIK(room: h.room, laptopKey: h.laptopKey.publicKey)

            // From here the database waits, so the last-seen write that
            // `hello` starts cannot finish until the test releases it.
            let release = DispatchSemaphore(value: 0)
            // However the test ends, the database is let go.
            defer { release.signal() }
            let holding = FireRecorder<Void>()
            let writer = h.db.writerForTests
            let hold = gateHoldingTask { holdWrites(writer, until: release, holding: holding) }
            let held = await holding.next()
            try #require(held != nil)

            try await phone.sendHello()
            let stamped = await lastSeenStamps.next()
            try #require(stamped != nil)
            let connection = h.connection
            let revoking = Task { await connection.revokeAndStop() }
            // The socket closes once the revoke has begun stopping.
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")

            release.signal()
            await hold.value
            await revoking.value
            #expect(!h.events.values.contains(.connected(deviceID: h.device.id)))
            let log = await h.app.log
            #expect(log.isEmpty)
            let connected = await h.connection.isConnected
            #expect(connected == false)
        }
    }

    @Test func stopWaitsForTheHeldMessageThenDisconnectsOnce() async throws {
        try await withConnection { h in
            let phone = try await h.connectedPhone()
            await h.app.closeGate(on: "r1")
            try await phone.sendRequest("r1")
            try await h.waitUntil("r1 to reach the app") { await h.app.log.contains("message:r1") }
            let stopping = Task { await h.connection.stop() }
            // The socket closes at once.
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            // The channel does not end while the app still holds a message.
            await settle()
            let held = await h.app.log
            #expect(held == ["connected", "message:r1"])
            await h.app.openGate()
            await stopping.value
            let log = await h.app.log
            #expect(log == ["connected", "message:r1", "disconnected"])
            #expect(h.events.values.filter { $0 == .disconnected(deviceID: h.device.id) }.count == 1)
            // Stopping sent nothing: the laptop's frames are message 2 and
            // `welcome`.
            #expect(h.relay.laptopFrames(room: h.room).count == 2)
            #expect(!h.clock.hasSleeper)
        }
    }

    @Test func stopRecordsWhenThePhoneWasLastSeen() async throws {
        try await withConnection { h in
            _ = try await h.connectedPhone()
            let connectedAt = h.dates.now
            let seenAtConnect = try await h.db.phoneDevices.device(id: h.device.id)?.lastSeenAt
            #expect(seenAtConnect == connectedAt)
            h.dates.advance(by: 600)

            // The link's last `.closed` reaches the inbound task after
            // `stop()` cancelled it; the channel still ends in a task that
            // can write.
            await h.connection.stop()
            let seen = try await h.db.phoneDevices.device(id: h.device.id)?.lastSeenAt
            #expect(seen == connectedAt.addingTimeInterval(600))
            let log = await h.app.log
            #expect(log == ["connected", "disconnected"])
            let disconnects = h.events.values.filter { $0 == .disconnected(deviceID: h.device.id) }
            #expect(disconnects.count == 1)
        }
    }

    @Test func aRevokedPhoneIsNotHeardWhileRevokedLeaves() async throws {
        let relay = FakeRelay()
        let transport = HoldingTransport(relay: relay)
        try await withConnection(relay: relay, transport: transport) { h in
            // However the test ends, nothing stays held for `stop()` to wait on.
            defer { transport.release() }
            let phone = try await h.connectedPhone()
            let handed = await h.app.lastOutbox
            let outbox = try #require(handed)

            // `revoked` cannot leave, so `revokeAndStop()` waits up to the
            // flush limit, which the test clock never reaches, before it
            // stops the connection.
            transport.hold()
            let revoking = Task { await h.connection.revokeAndStop() }
            try await h.waitUntil("`revoked` to reach the socket") { transport.heldSends == 1 }

            // Nothing more goes to the revoked phone.
            let sent = await outbox.send(appBody: Data(#"{"kind":"event"}"#.utf8))
            #expect(sent == false)

            // The phone acts after `revoked` was queued, then leaves. The
            // laptop handles its events in order, so once the channel has
            // ended, the phone's request has been handled too.
            try await phone.sendRequest("r9")
            phone.close()
            try await h.waitUntil("the channel to end") { await h.app.log.contains("disconnected") }
            let log = await h.app.log
            #expect(log == ["connected", "disconnected"])

            transport.release()
            await revoking.value
            let after = await h.app.log
            #expect(after == ["connected", "disconnected"])
            let connected = await h.connection.isConnected
            #expect(connected == false)
        }
    }
}
