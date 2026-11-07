import CryptoKit
import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

private let relayURL = URL(string: "https://acme-relay.acme.workers.dev")!
private let loaderURL = URL(string: "https://acme.github.io/tbd-phone/")!

/// `count` bytes from the system's random generator.
private func randomBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
}

/// IKpsk2 message 1 for `link`, from a phone with `key` that names itself
/// `deviceName`: the first frame a pairing phone sends. Built here rather
/// than through ``TestPhone/pair(link:deviceName:sendHello:)``, which waits
/// for a message 2 that a refused or interrupted handshake never gets.
private func pairingMessage1(link: PairingLink, key: Curve25519.KeyAgreement.PrivateKey = .init(),
                             deviceName: String) throws -> Data {
    let keyBytes = try #require(Base64URL.decode(link.key))
    let secret = try #require(Base64URL.decode(link.secret))
    let room = try #require(PhoneRoom.roomBytes(link.room))
    var initiator = try NoiseInitiator(
        pattern: .ikpsk2, staticKey: key, remoteStatic: Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyBytes),
        psk: SymmetricKey(data: secret), prologue: PhoneChannelPrologue.make(roomID: room))
    return try initiator.writeMessage1(payload: JSONSerialization.data(withJSONObject: ["deviceName": deviceName]))
}

private extension PairingLink {
    /// The same link with a freshly minted secret: what a phone holding a
    /// stale or forged QR code would use.
    func withAnotherSecret() throws -> PairingLink {
        var copy = self
        copy.secret = try PhoneRoom.newToken()
        return copy
    }
}

/// The pairing state `status` showed each time the service called
/// `onChange`, read just after the call.
private actor PairingStateLog {
    private var service: PairingService?
    private(set) var seen: [PhonePairingState?] = []

    func attach(_ service: PairingService) {
        self.service = service
    }

    func capture() async {
        let status = await service?.status
        seen.append(status?.state)
    }
}

/// One pairing service under test, with everything it talks to.
private struct PairingHarness {
    let db: TBDDatabase
    let laptopKey: Curve25519.KeyAgreement.PrivateKey
    let relay: FakeRelay
    let clock: EventDrivenTestClock
    let dates: TestDateSource
    let states: PairingStateLog
    /// Every device `onPaired` was called with.
    let paired: FireRecorder<PhoneDevice>
    let service: PairingService

    /// Starts an offer, parses its link, and waits until the laptop's socket
    /// is in the offer's room.
    func startOffer() async throws -> (status: PhonePairingStatus, link: PairingLink) {
        let status = try await service.start(loaderURL: loaderURL)
        let text = try #require(status.link)
        let url = try #require(URL(string: text))
        let link = try PairingLink.parse(url, now: dates.now)
        try await waitUntil("the laptop to join the pairing room") { relay.laptopPresent(room: link.room) }
        return (status, link)
    }

    /// A phone in the offer's room, with the relay's `peer-joined` read.
    func joinedPhone(_ link: PairingLink) async throws -> TestPhone {
        let phone = try TestPhone(relay: relay, room: link.room)
        let signal = try await phone.nextSignal()
        try #require(signal == "peer-joined")
        return phone
    }

    /// Waits until `condition` holds, or throws naming `what` and the
    /// pairing state as it stands.
    func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = TestDeadlines.saturatedPass
        switch await pollUntilTrue(timeout: deadline, condition) {
        case .satisfied:
            return
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            let state = await service.status?.state
            throw BoundedWaitTimeout(what: what, observed: "pairing state \(String(describing: state))",
                                     deadline: deadline)
        }
    }

    func waitForState(_ state: PhonePairingState) async throws {
        try await waitUntil("the pairing state \(state)") { await service.status?.state == state }
    }

    /// A phone that has paired with `link`, sent `hello`, and reached the
    /// Allow prompt. Returns the phone and the code it computed.
    func phoneAwaitingApproval(_ link: PairingLink) async throws -> (phone: TestPhone, code: String) {
        let phone = try await joinedPhone(link)
        let (code, _) = try await phone.pair(link: link, deviceName: "iPhone")
        try await waitForState(.awaitingApproval)
        return (phone, code)
    }
}

/// Builds a pairing service on a fake relay, runs `body`, and cancels the
/// service whatever happens, so no task outlives the test.
private func withPairing(laptopName: String = "acme-laptop",
                         _ body: (PairingHarness) async throws -> Void) async throws {
    let db = try TBDDatabase(inMemory: true)
    let dates = TestDateSource()
    let laptopKey = Curve25519.KeyAgreement.PrivateKey()
    let relay = FakeRelay()
    let clock = EventDrivenTestClock()
    let states = PairingStateLog()
    let paired = FireRecorder<PhoneDevice>()
    let service = PairingService(
        relayURL: relayURL, transport: relay, laptopKey: laptopKey, laptopName: laptopName,
        devices: db.phoneDevices, preflight: { .proceed },
        onChange: { Task { await states.capture() } },
        onPaired: { paired.record($0) }, now: dates.provider,
        backoff: PhoneBackoff(jitter: { $0 }), clock: clock)
    await states.attach(service)
    let harness = PairingHarness(db: db, laptopKey: laptopKey, relay: relay, clock: clock, dates: dates,
                                 states: states, paired: paired, service: service)
    do {
        try await body(harness)
    } catch {
        await service.cancel()
        throw error
    }
    await service.cancel()
}

@Suite("PairingService", .clockDriven)
struct PairingServiceTests {
    // MARK: Offers

    @Test func startMakesAFiveMinuteOfferWithAParsableLink() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            #expect(link.v == 1)
            #expect(link.room.count == 43 && link.secret.count == 43 && link.room != link.secret)
            #expect(link.name == "acme-laptop")
            #expect(link.relay == "https://acme-relay.acme.workers.dev")
            #expect(Base64URL.decode(link.key) == h.laptopKey.publicKey.rawRepresentation)
            #expect(status.expiresAt == h.dates.now.addingTimeInterval(300))
            #expect(link.exp == Int(status.expiresAt.timeIntervalSince1970))
            #expect(status.state == .waitingForPhone)
            #expect(status.confirmationCode == nil && status.deviceName == nil && status.deviceID == nil)
            let current = await h.service.status
            #expect(current == status)
            #expect(h.relay.openLaptopRooms() == Set([link.room]))
        }
    }

    @Test func aLongLaptopNameIsCutTo256Bytes() async throws {
        try await withPairing(laptopName: String(repeating: "\u{E9}", count: 200)) { h in
            let (_, link) = try await h.startOffer()
            #expect(link.name.utf8.count == 256)
            #expect(link.name == String(repeating: "\u{E9}", count: 128))
            // Message 2 carries the same name.
            let phone = try await h.joinedPhone(link)
            let (_, laptopName) = try await phone.pair(link: link, deviceName: "iPhone", sendHello: false)
            #expect(laptopName == link.name)
        }
    }

    @Test func startReplacesALiveOffer() async throws {
        try await withPairing { h in
            let (first, firstLink) = try await h.startOffer()
            let (second, secondLink) = try await h.startOffer()
            #expect(!h.relay.laptopPresent(room: firstLink.room))
            #expect(h.relay.openLaptopRooms() == Set([secondLink.room]))
            #expect(second.offerID != first.offerID)
            #expect(secondLink.room != firstLink.room && secondLink.secret != firstLink.secret)
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await h.service.deny(offerID: first.offerID) }
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await h.service.allow(offerID: first.offerID) }
            let current = await h.service.status
            #expect(current == second)
        }
    }

    @Test func cancelClosesThePairingRoomAndEndsEveryTask() async throws {
        try await withPairing { h in
            let (_, link) = try await h.startOffer()
            let (phone, _) = try await h.phoneAwaitingApproval(link)
            await h.service.cancel()
            let after = await h.service.status
            #expect(after == nil)
            #expect(h.relay.openLaptopRooms().isEmpty)
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            // Cancelling sends nothing: the laptop's only frame is message 2.
            #expect(h.relay.laptopFrames(room: link.room).count == 1)
            // The keepalive, the expiry and the handshake timer are all gone.
            #expect(!h.clock.hasSleeper)
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
        }
    }

    // MARK: The Allow prompt

    @Test func theAllowPromptWaitsForHelloThenShowsTheNameAndCode() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let phone = try await h.joinedPhone(link)
            let (code, laptopName) = try await phone.pair(link: link, deviceName: "iPhone", sendHello: false)
            #expect(laptopName == "acme-laptop")
            // Message 2 is out, and nothing has decrypted: a replayed message 1
            // gets this far, so nothing is shown yet.
            let early = await h.service.status
            #expect(early?.state == .waitingForPhone)
            #expect(early?.confirmationCode == nil)
            #expect(early?.deviceName == nil)
            let pending = await h.service.hasPendingHandshake
            #expect(pending)

            try await phone.sendHello()
            try await h.waitForState(.awaitingApproval)
            let shown = await h.service.status
            #expect(shown?.confirmationCode == code)
            #expect(shown?.deviceName == "iPhone")
            #expect(shown?.offerID == status.offerID)
            #expect(shown?.link == status.link)
            // Shown, but not stored.
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
            #expect(h.paired.values.isEmpty)
        }
    }

    @Test(arguments: [("  iPhone \n", "iPhone"), (String(repeating: "a", count: 64), String(repeating: "a", count: 64)),
                      ("Pixel 9 \u{1F4F1}", "Pixel 9 \u{1F4F1}")])
    func goodDeviceNamesAreShownTrimmed(sent: String, shown: String) async throws {
        try await withPairing { h in
            let (_, link) = try await h.startOffer()
            let phone = try await h.joinedPhone(link)
            try await phone.pair(link: link, deviceName: sent)
            try await h.waitForState(.awaitingApproval)
            let status = await h.service.status
            #expect(status?.deviceName == shown)
        }
    }

    @Test(arguments: ["", "   ", String(repeating: "a", count: 65), "a\u{202E}b", "line\nbreak", "tab\there"])
    func badDeviceNamesAreRefused(name: String) async throws {
        try await withPairing { h in
            let (_, link) = try await h.startOffer()
            let phone = try await h.joinedPhone(link)
            try await phone.sendRaw(pairingMessage1(link: link, deviceName: name))
            // Frames are handled in order, so once a good message 1 on the
            // same socket is answered, the bad one has been handled.
            let (code, _) = try await phone.pair(link: link, deviceName: "iPhone", sendHello: false)
            #expect(h.relay.laptopFrames(room: link.room).count == 1)
            let waiting = await h.service.status
            #expect(waiting?.state == .waitingForPhone)
            try await phone.sendHello()
            try await h.waitForState(.awaitingApproval)
            let shown = await h.service.status
            #expect(shown?.deviceName == "iPhone")
            #expect(shown?.confirmationCode == code)
        }
    }

    // MARK: Allow and Deny

    @Test func allowMovesThePhoneToANewRoom() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let (phone, _) = try await h.phoneAwaitingApproval(link)
            let device = try await h.service.allow(offerID: status.offerID)
            let message = try await phone.next()
            let newRoom = try #require(message["room"] as? String)
            #expect(message["type"] as? String == "paired")
            #expect(newRoom.count == 43 && PhoneRoom.roomBytes(newRoom)?.count == 32 && newRoom != link.room)
            let rows = try await h.db.phoneDevices.list()
            #expect(rows == [device] && device.roomID == newRoom)
            #expect(device.name == "iPhone")
            #expect(device.publicKey == phone.key.publicKey.rawRepresentation)
            #expect(device.pairedAt == h.dates.now)
            // The laptop left the pairing room for good before `onPaired`.
            #expect(!h.relay.laptopPresent(room: link.room))
            #expect(h.paired.values == [device])
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            let after = await h.service.status
            #expect(after?.state == .paired)
            #expect(after?.deviceName == "iPhone")
            #expect(after?.deviceID == device.id)
            #expect(after?.link == nil)
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await h.service.allow(offerID: status.offerID) }
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func denySendsPairDeniedAndDiscardsTheOffer() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let (phone, _) = try await h.phoneAwaitingApproval(link)
            try await h.service.deny(offerID: status.offerID)
            let message = try await phone.next()
            #expect(message["type"] as? String == "pairDenied")
            #expect(message["reason"] as? String == "denied")
            #expect(message.count == 2)
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            let after = await h.service.status
            #expect(after?.state == .denied)
            #expect(after?.link == nil)
            #expect(after?.deviceName == nil && after?.confirmationCode == nil)
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await h.service.allow(offerID: status.offerID) }
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
            #expect(h.paired.values.isEmpty)
        }
    }

    @Test func denyWhileWaitingSendsNothing() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let phone = try await h.joinedPhone(link)
            try await h.service.deny(offerID: status.offerID)
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            #expect(h.relay.laptopFrames(room: link.room).isEmpty)
            let after = await h.service.status
            #expect(after?.state == .denied)
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await h.service.allow(offerID: status.offerID) }
        }
    }

    // MARK: Expiry

    @Test func theOfferExpiresAfterFiveMinutes() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let (phone, _) = try await h.phoneAwaitingApproval(link)
            // The pairing room's keepalive and the offer's expiry; the
            // handshake timer ended when `hello` decrypted.
            try await h.clock.requireSleepersArmed(count: 2)
            await h.clock.advance(by: .seconds(299))
            await settle()
            let early = await h.service.status
            #expect(early?.state == .awaitingApproval)

            await h.clock.advance(by: .seconds(1))
            let message = try await phone.next()
            #expect(message["type"] as? String == "pairDenied")
            #expect(message["reason"] as? String == "expired")
            try await h.waitForState(.expired)
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            await #expect(throws: PhoneBridgeError.offerExpired) { try await h.service.allow(offerID: status.offerID) }
            await #expect(throws: PhoneBridgeError.offerExpired) { try await h.service.deny(offerID: status.offerID) }
            let after = await h.service.status
            #expect(after?.link == nil)
            #expect(after?.deviceName == nil && after?.confirmationCode == nil)
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
        }
    }

    @Test func expiryWhileWaitingSendsNothing() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let phone = try await h.joinedPhone(link)
            // The pairing room's keepalive and the offer's expiry.
            try await h.clock.requireSleepersArmed(count: 2)
            await h.clock.advance(by: .seconds(300))
            try await h.waitForState(.expired)
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            #expect(h.relay.laptopFrames(room: link.room).isEmpty)
            await #expect(throws: PhoneBridgeError.offerExpired) { try await h.service.allow(offerID: status.offerID) }
        }
    }

    // MARK: Failed attempts keep the offer open

    @Test func aHandshakeWithNoTransportMessageNeverRaisesTheAllowPrompt() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let phone = try await h.joinedPhone(link)
            try await phone.pair(link: link, deviceName: "iPhone", sendHello: false)
            // The pairing room's keepalive, the offer's expiry and the
            // handshake timer.
            try await h.clock.requireSleepersArmed(count: 3)
            await h.clock.advance(by: .seconds(9))
            await settle()
            let stillPending = await h.service.hasPendingHandshake
            #expect(stillPending)
            await h.clock.advance(by: .seconds(1))
            try await h.waitUntil("the handshake timer to drop the attempt") {
                await h.service.hasPendingHandshake == false
            }
            let after = await h.service.status
            #expect(after?.state == .waitingForPhone)
            #expect(after?.confirmationCode == nil && after?.deviceName == nil)
            await #expect(throws: PhoneBridgeError.notAwaitingApproval) {
                try await h.service.allow(offerID: status.offerID)
            }
            let rowsAfterTimeout = try await h.db.phoneDevices.list()
            #expect(rowsAfterTimeout.isEmpty)

            // A `hello` on the dropped channel no longer raises the prompt.
            try await phone.sendHello()
            // A second, correct attempt on the same offer: once its message 2
            // is read, the stale `hello` has been handled.
            let (code, _) = try await phone.pair(link: link, deviceName: "iPhone", sendHello: false)
            let beforeHello = await h.service.status
            #expect(beforeHello?.state == .waitingForPhone)
            let seen = await h.states.seen
            #expect(!seen.contains(.awaitingApproval))
            try await phone.sendHello()
            try await h.waitForState(.awaitingApproval)
            let shown = await h.service.status
            #expect(shown?.confirmationCode == code)
            let device = try await h.service.allow(offerID: status.offerID)
            let rows = try await h.db.phoneDevices.list()
            #expect(rows == [device])
        }
    }

    @Test func aWrongSecretNeverRaisesTheAllowPrompt() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let wrong = try link.withAnotherSecret()
            let phone = try await h.joinedPhone(link)
            await #expect(throws: NoiseError.self) { try await phone.pair(link: wrong, deviceName: "iPhone") }
            // The laptop answered: IKpsk2 mixes the secret in only at message 2.
            #expect(h.relay.laptopFrames(room: link.room).count == 1)
            let after = await h.service.status
            #expect(after?.state == .waitingForPhone)
            #expect(after?.confirmationCode == nil && after?.deviceName == nil)
            await #expect(throws: PhoneBridgeError.notAwaitingApproval) {
                try await h.service.allow(offerID: status.offerID)
            }
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
            let seen = await h.states.seen
            #expect(!seen.contains(.awaitingApproval))
        }
    }

    @Test(arguments: [false, true])
    func aWrongSecretThenACorrectAttemptPairs(onANewSocket: Bool) async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let wrong = try link.withAnotherSecret()
            let phone = try await h.joinedPhone(link)
            await #expect(throws: NoiseError.self) { try await phone.pair(link: wrong, deviceName: "iPhone") }
            if onANewSocket {
                // The relay announces the new socket with `peer-joined`.
                try await phone.rejoin(room: link.room)
            }
            // On the same socket, the laptop still holds the failed attempt:
            // this message 1 fails to decrypt against it, is read as a new
            // message 1, and replaces it.
            let (code, _) = try await phone.pair(link: link, deviceName: "iPhone")
            try await h.waitForState(.awaitingApproval)
            let shown = await h.service.status
            #expect(shown?.confirmationCode == code)
            let device = try await h.service.allow(offerID: status.offerID)
            let message = try await phone.next()
            #expect(message["type"] as? String == "paired")
            #expect(message["room"] as? String == device.roomID)
            #expect(device.publicKey == phone.key.publicKey.rawRepresentation)
            let rows = try await h.db.phoneDevices.list()
            #expect(rows == [device])
        }
    }

    @Test func aJunkFrameAfterMessage2IsDroppedAndHelloStillRaisesThePrompt() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let phone = try await h.joinedPhone(link)
            let (code, _) = try await phone.pair(link: link, deviceName: "iPhone", sendHello: false)
            // Nothing has decrypted on the attempt, so the junk is tried as a
            // message 1, refused, and dropped; the attempt stays.
            try await phone.sendRaw(randomBytes(100))
            try await phone.sendHello()
            try await h.waitForState(.awaitingApproval)
            let shown = await h.service.status
            #expect(shown?.confirmationCode == code)
            #expect(shown?.deviceName == "iPhone")
            // Only message 2 went out: nothing answered the junk.
            #expect(h.relay.laptopFrames(room: link.room).count == 1)
            let seen = await h.states.seen
            #expect(!seen.contains(.interrupted))
            let device = try await h.service.allow(offerID: status.offerID)
            #expect(device.name == "iPhone")
            let message = try await phone.next()
            #expect(message["type"] as? String == "paired")
            // The pairing link never restarted.
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func thePhonesRealMessage1ReplacesAValidReplayThatArrivedFirst() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let phone = try await h.joinedPhone(link)
            // An earlier attempt by the phone, whose message 1 a replayer
            // captured.
            try await phone.pair(link: link, deviceName: "iPhone", sendHello: false)
            let replayed = try #require(phone.lastMessage1)

            // The replay reaches the laptop first, on the phone's socket.
            // Nothing has decrypted, so the laptop reads it as a message 1,
            // accepts it, and answers with a message 2 the phone cannot use.
            try await phone.sendRaw(replayed)
            try await h.waitUntil("the laptop to answer the replay") {
                h.relay.laptopFrames(room: link.room).count == 2
            }
            let replayAnswer = try await phone.nextRawFrame()
            #expect(replayAnswer == h.relay.laptopFrames(room: link.room).last)
            let waiting = await h.service.status
            #expect(waiting?.state == .waitingForPhone)

            // Then the phone's real attempt: its message 1 fails to decrypt
            // on the replay's attempt, is read as a message 1, and replaces
            // it, so its `hello` raises the prompt with its own code.
            let (code, _) = try await phone.pair(link: link, deviceName: "iPhone")
            try await h.waitForState(.awaitingApproval)
            let shown = await h.service.status
            #expect(shown?.confirmationCode == code)
            #expect(shown?.deviceName == "iPhone")
            // Three message 2s.
            #expect(h.relay.laptopFrames(room: link.room).count == 3)
            let device = try await h.service.allow(offerID: status.offerID)
            let message = try await phone.next()
            #expect(message["type"] as? String == "paired")
            #expect(message["room"] as? String == device.roomID)
            #expect(device.publicKey == phone.key.publicKey.rawRepresentation)
            // The pairing link never restarted.
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func aJunkFrameBeforeMessage1IsDroppedAndPairingStillSucceeds() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let phone = try await h.joinedPhone(link)
            try await phone.sendRaw(randomBytes(100))
            let (code, _) = try await phone.pair(link: link, deviceName: "iPhone")
            try await h.waitForState(.awaitingApproval)
            let shown = await h.service.status
            #expect(shown?.confirmationCode == code)
            #expect(h.relay.laptopFrames(room: link.room).count == 1)
            let device = try await h.service.allow(offerID: status.offerID)
            let message = try await phone.next()
            #expect(message["type"] as? String == "paired")
            #expect(message["room"] as? String == device.roomID)
            // The pairing link never restarted.
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func anIKHandshakeOnThePairingRoomIsRefused() async throws {
        try await withPairing { h in
            let (_, link) = try await h.startOffer()
            let phone = try await h.joinedPhone(link)
            try await phone.startIK(room: link.room, laptopKey: h.laptopKey.publicKey)
            // A pairing message 1 on the same socket: once it is answered,
            // the IK one has been handled.
            let (code, _) = try await phone.pair(link: link, deviceName: "iPhone", sendHello: false)
            #expect(h.relay.laptopFrames(room: link.room).count == 1)
            let waiting = await h.service.status
            #expect(waiting?.state == .waitingForPhone)
            try await phone.sendHello()
            try await h.waitForState(.awaitingApproval)
            let shown = await h.service.status
            #expect(shown?.confirmationCode == code)
        }
    }

    // MARK: Interruptions after the prompt

    @Test func aReplayedMessage1InterruptsTheOffer() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let (phone, _) = try await h.phoneAwaitingApproval(link)
            let message1 = try #require(phone.lastMessage1)
            // The replay comes from a new phone socket, which the relay
            // announces with `peer-joined`.
            let replayer = try h.relay.joinAsPhone(room: link.room)
            try replayer.send(.binary(message1))
            try await h.waitForState(.interrupted)
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await h.service.allow(offerID: status.offerID) }
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
            // The replay got no message 2.
            #expect(h.relay.laptopFrames(room: link.room).count == 1)
            let after = await h.service.status
            #expect(after?.link == nil && after?.deviceName == nil && after?.confirmationCode == nil)
            try await h.waitUntil("the laptop to leave the pairing room") { !h.relay.laptopPresent(room: link.room) }
        }
    }

    @Test func anUndecryptableFrameAfterHelloInterruptsTheOffer() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let (phone, _) = try await h.phoneAwaitingApproval(link)
            let message1 = try #require(phone.lastMessage1)
            // The relay itself injects the replay on the phone's open socket,
            // so no `peer-joined` precedes it: the frame alone must end it.
            h.relay.sendToLaptop(room: link.room, .binary(message1))
            try await h.waitForState(.interrupted)
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await h.service.allow(offerID: status.offerID) }
            #expect(h.relay.laptopFrames(room: link.room).count == 1)
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
        }
    }

    @Test func aFrameThatDecryptsAfterHelloIsIgnored() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let (phone, code) = try await h.phoneAwaitingApproval(link)
            // Each frame that decrypts moves the receive nonce on, so the
            // second one decrypts too. A laptop that kept the old nonce would
            // fail it and interrupt. One-sided: it holds up to the settle.
            try await phone.send(json: ["type": "ping"])
            try await phone.send(json: ["type": "ping"])
            await settle()
            let still = await h.service.status
            #expect(still?.state == .awaitingApproval)
            let device = try await h.service.allow(offerID: status.offerID)
            let message = try await phone.next()
            #expect(message["type"] as? String == "paired")
            #expect(message["room"] as? String == device.roomID)
            let after = await h.service.status
            #expect(after?.confirmationCode == code)
        }
    }

    @Test func aSecondHandshakeInterruptsTheOffer() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            _ = try await h.phoneAwaitingApproval(link)
            let second = try h.relay.joinAsPhone(room: link.room)
            try second.send(.binary(pairingMessage1(link: link, deviceName: "Other phone")))
            try await h.waitForState(.interrupted)
            #expect(h.relay.laptopFrames(room: link.room).count == 1)
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await h.service.allow(offerID: status.offerID) }
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
        }
    }

    @Test func aPhoneThatLeavesBeforeAllowInterruptsTheOffer() async throws {
        try await withPairing { h in
            let (status, link) = try await h.startOffer()
            let (phone, _) = try await h.phoneAwaitingApproval(link)
            phone.close()
            try await h.waitForState(.interrupted)
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await h.service.allow(offerID: status.offerID) }
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await h.service.deny(offerID: status.offerID) }
            try await h.waitUntil("the laptop to leave the pairing room") { !h.relay.laptopPresent(room: link.room) }
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
        }
    }
}
