import Foundation
import TBDShared
import Testing

@testable import TBDDaemonLib

/// `count` bytes from the system's random generator, which DEFLATE cannot
/// shrink, so the compressed stream is about as long as the input.
private func randomBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
}

/// A small bundle, for the tests that do not care about its size.
private func smallBundle() throws -> PhoneAppBundle {
    try PhoneAppBundle(source: Data("globalThis.app = 1;\n".utf8))
}

/// A `hello` offering `protocols`.
private func hello(_ protocols: [Int]) -> Data {
    Data(#"{"type":"hello","loaderVersion":"1.0.0","protocols":\#(protocols)}"#.utf8)
}

/// A `bundle.get` for `sha256`.
private func bundleGet(_ sha256: String) -> Data {
    Data(#"{"type":"bundle.get","sha256":"\#(sha256)"}"#.utf8)
}

/// A handler that has answered `hello` with `welcome`.
private func welcomed(_ bundle: PhoneAppBundle) throws -> LoaderHandler {
    var handler = LoaderHandler(bundle: bundle)
    let answer = handler.handle(hello([1]))
    try #require(answer.count == 1)
    return handler
}

/// The payload of every `.send` in `actions`, in order.
private func sent(_ actions: [LoaderHandler.Action]) -> [Data] {
    var messages: [Data] = []
    for action in actions {
        if case .send(let message) = action {
            messages.append(message)
        }
    }
    return messages
}

/// The JSON object `data` holds.
private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The JSON object `data` holds, for comparing whole objects.
private func dictionary(_ data: Data) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

/// A `PhoneAppOutbox` that keeps every body it is given and reports success.
private actor OutboxRecorder: PhoneAppOutbox {
    private(set) var bodies: [Data] = []

    func send(appBody: Data) -> Bool {
        bodies.append(appBody)
        return true
    }
}

@Suite("LoaderHandler")
struct LoaderHandlerTests {
    // MARK: hello

    @Test func helloGetsWelcome() throws {
        let b = try smallBundle()
        var handler = LoaderHandler(bundle: b)
        let actions = handler.handle(hello([1]))
        try #require(actions.count == 1)
        let welcome = try #require(sent(actions).first)
        let expected: NSDictionary = [
            "type": "welcome",
            "protocol": 1,
            "minProtocol": 1,
            "tbdVersion": TBDConstants.version,
            "bundle": ["sha256": b.sha256Hex, "size": b.compressed.count] as [String: Any],
        ]
        #expect(try dictionary(welcome) == expected)
    }

    @Test func helloPicksTheHighestCommonVersion() throws {
        var handler = LoaderHandler(bundle: try smallBundle())
        let actions = handler.handle(hello([3, 1, 0, 2]))
        let welcome = try #require(sent(actions).first)
        #expect(try object(welcome)["protocol"] as? Int == 1)
    }

    @Test func aNewerOnlyLoaderIsToldTheLaptopIsTooOld() throws {
        var handler = LoaderHandler(bundle: try smallBundle())
        let actions = handler.handle(hello([2]))
        try #require(actions.count == 2)
        let incompatible = try #require(sent(actions).first)
        let expected: NSDictionary = ["type": "incompatible", "tooOld": "laptop"]
        #expect(try dictionary(incompatible) == expected)
        #expect(actions.last == LoaderHandler.Action.end("no common loader protocol"))
        // The connection is over: nothing later is answered.
        let later = handler.handle(hello([1]))
        #expect(later == [.end("no common loader protocol")])
    }

    @Test func anOlderOrEmptyLoaderIsToldItIsTooOld() throws {
        for protocols in [[], [0]] as [[Int]] {
            var handler = LoaderHandler(bundle: try smallBundle())
            let actions = handler.handle(hello(protocols))
            try #require(actions.count == 2)
            let incompatible = try #require(sent(actions).first)
            let expected: NSDictionary = ["type": "incompatible", "tooOld": "loader"]
            #expect(try dictionary(incompatible) == expected)
            #expect(actions.last == LoaderHandler.Action.end("no common loader protocol"))
        }
    }

    @Test func aHelloWithoutAListOfIntegersEnds() throws {
        let bodies = [
            #"{"type":"hello","loaderVersion":"1.0.0"}"#,
            #"{"type":"hello","protocols":"1"}"#,
            #"{"type":"hello","protocols":{"1":1}}"#,
            #"{"type":"hello","protocols":[true]}"#,
            #"{"type":"hello","protocols":[1.5]}"#,
            #"{"type":"hello","protocols":["1"]}"#,
            #"{"type":"hello","protocols":[1,null]}"#,
            #"{"type":"hello","protocols":[-1e400]}"#,
            #"{"type":"hello","protocols":[99999999999999999999]}"#,
        ]
        for body in bodies {
            var handler = LoaderHandler(bundle: try smallBundle())
            let actions = handler.handle(Data(body.utf8))
            #expect(actions == [.end("malformed message")], "\(body)")
        }
    }

    @Test func aSecondHelloIsIgnored() throws {
        var handler = try welcomed(try smallBundle())
        let actions = handler.handle(hello([1]))
        #expect(actions.isEmpty)
    }

    @Test func anythingBeforeHelloEnds() throws {
        let b = try smallBundle()
        let early = [
            #"{"type":"app","body":{}}"#,
            #"{"type":"bundle.get","sha256":"\#(b.sha256Hex)"}"#,
            #"{"type":"future.thing"}"#,
        ]
        for body in early {
            var handler = LoaderHandler(bundle: b)
            let actions = handler.handle(Data(body.utf8))
            #expect(actions == [.end("message before hello")], "\(body)")
            // Ended for good: even a hello gets no welcome now.
            let later = handler.handle(hello([1]))
            #expect(later == [.end("message before hello")])
        }
    }

    // MARK: bundle.get

    @Test func bundleGetSendsEveryChunkInOrder() throws {
        // Random bytes do not compress, so 120,000 of them need three chunks.
        let b = try PhoneAppBundle(source: randomBytes(120_000))
        try #require(b.chunks.count >= 2)
        var handler = try welcomed(b)
        let actions = handler.handle(bundleGet(b.sha256Hex))
        let messages = sent(actions)
        #expect(messages.count == actions.count)
        let chunks = try messages.map { try object($0) }
        let types = chunks.compactMap { $0["type"] as? String }
        #expect(types == Array(repeating: "bundle.chunk", count: b.chunks.count))
        let indices = chunks.compactMap { $0["index"] as? Int }
        #expect(indices == Array(0..<b.chunks.count))
        #expect(chunks.allSatisfy { $0["count"] as? Int == b.chunks.count && $0["sha256"] as? String == b.sha256Hex })
        var joined = Data()
        for chunk in chunks {
            let text = try #require(chunk["data"] as? String)
            joined += try #require(Data(base64Encoded: text))
        }
        #expect(joined == b.compressed)
    }

    @Test func aFullChunkFitsTheFrameBudget() throws {
        // An incompressible source, so the first chunk holds the full 45,000 bytes.
        let b = try PhoneAppBundle(source: randomBytes(100_000))
        try #require(b.chunks.count >= 2)
        #expect(b.chunks[0].count == 45_000)
        var handler = try welcomed(b)
        let messages = sent(handler.handle(bundleGet(b.sha256Hex)))
        #expect(messages.count == b.chunks.count)
        // About 60,130 bytes each once base64 and the envelope are added.
        #expect(messages.allSatisfy { $0.count <= NoiseTransport.maxPlaintextLength })
        #expect((messages.first?.count ?? 0) > 60_000)
    }

    @Test func bundleGetForAnotherHashEnds() throws {
        let b = try smallBundle()
        let other = try PhoneAppBundle(source: Data("other".utf8))
        let unknown = [other.sha256Hex, b.sha256Hex.uppercased(), b.sha256Hex + " ", " " + b.sha256Hex, "", String(b.sha256Hex.dropLast())]
        for hash in unknown {
            var handler = try welcomed(b)
            let actions = handler.handle(bundleGet(hash))
            #expect(actions == [.end("unknown bundle")], "\(hash)")
            // Ended for good: the right hash gets no chunks now.
            let later = handler.handle(bundleGet(b.sha256Hex))
            #expect(later == [.end("unknown bundle")])
        }
        for body in [#"{"type":"bundle.get"}"#, #"{"type":"bundle.get","sha256":1}"#] {
            var handler = try welcomed(b)
            let actions = handler.handle(Data(body.utf8))
            #expect(actions == [.end("malformed message")], "\(body)")
        }
    }

    // MARK: app

    @Test func appAfterWelcomeIsDelivered() throws {
        var handler = try welcomed(try smallBundle())
        let actions = handler.handle(Data(#"{"type":"app","body":{"kind":"request","requestID":"r1"}}"#.utf8))
        try #require(actions.count == 1)
        guard case .deliverApp(let delivered) = actions[0] else {
            Issue.record("expected .deliverApp, got \(actions)")
            return
        }
        let expected: NSDictionary = ["kind": "request", "requestID": "r1"]
        #expect(try dictionary(delivered) == expected)
    }

    @Test func anAppBodyThatIsNotAnObjectEnds() throws {
        let bodies = [
            #"{"type":"app"}"#,
            #"{"type":"app","body":[1]}"#,
            #"{"type":"app","body":"x"}"#,
            #"{"type":"app","body":null}"#,
            // Parses, but to an infinity no JSON writer accepts.
            #"{"type":"app","body":{"n":-1e400}}"#,
        ]
        for body in bodies {
            var handler = try welcomed(try smallBundle())
            let actions = handler.handle(Data(body.utf8))
            #expect(actions == [.end("app body is not a JSON object")], "\(body)")
            // Ended for good: a good app message is not delivered now.
            let later = handler.handle(Data(#"{"type":"app","body":{}}"#.utf8))
            #expect(later == [.end("app body is not a JSON object")])
        }
    }

    // MARK: Other messages

    @Test func unknownTypeIsIgnoredAndMalformedEnds() throws {
        var handler = try welcomed(try smallBundle())
        let unknown = handler.handle(Data(#"{"type":"future.thing","x":1}"#.utf8))
        #expect(unknown.isEmpty)
        let laptopOnly = handler.handle(Data(#"{"type":"welcome"}"#.utf8))
        #expect(laptopOnly.isEmpty)
        // Still open after an ignored message.
        let app = handler.handle(Data(#"{"type":"app","body":{}}"#.utf8))
        #expect(app.count == 1)

        let utf16 = try #require(#"{"type":"future.thing"}"#.data(using: .utf16LittleEndian))
        let malformed: [Data] = [
            Data(),
            Data("not json".utf8),
            Data("[1]".utf8),
            Data(#""hello""#.utf8),
            Data(#"{"protocols":[1]}"#.utf8),
            Data(#"{"type":5}"#.utf8),
            Data(#"{"type":"future.thing"} trailing"#.utf8),
            Data(#"{"type":"future.thing"}{"type":"app","body":{}}"#.utf8),
            Data(#"{"type":"future.thing","x":"a"#.utf8) + Data([0x01]) + Data(#""}"#.utf8),
            Data(#"{"type":"future.thing","x":""#.utf8) + Data([0xFF, 0xFE]) + Data(#""}"#.utf8),
            utf16,
            // Deeper than the parser goes; it must refuse, not overflow the stack.
            Data(String(repeating: "[", count: 30_000).utf8),
        ]
        for message in malformed {
            var fresh = try welcomed(try smallBundle())
            let actions = fresh.handle(message)
            #expect(actions == [.end("malformed message")], "\(message.count) bytes")
        }
    }

    @Test func aMessageLargerThanAFrameEnds() throws {
        var handler = try welcomed(try smallBundle())
        let tooLarge = Data(repeating: 0x20, count: NoiseTransport.maxPlaintextLength + 1)
        let actions = handler.handle(tooLarge)
        #expect(actions == [.end("message too large")])
    }

    @Test func aMessageTooLargeToSendEndsInstead() throws {
        let version = String(repeating: "x", count: NoiseTransport.maxPlaintextLength)
        var handler = LoaderHandler(bundle: try smallBundle(), tbdVersion: version)
        let actions = handler.handle(hello([1]))
        #expect(actions == [.end("outgoing message too large")])
    }

    @Test func stringsInMessagesAreEscaped() throws {
        let version = "1.0 \"beta\" \\ / \n\r\t\u{1}\u{1f}\u{7f} é ✓ \u{2028}"
        var handler = LoaderHandler(bundle: try smallBundle(), tbdVersion: version)
        let actions = handler.handle(hello([1]))
        let welcome = try #require(sent(actions).first)
        #expect(try object(welcome)["tbdVersion"] as? String == version)
        let room = "a\"b\\c\n"
        let expected: NSDictionary = ["type": "paired", "room": room]
        #expect(try dictionary(LoaderHandler.paired(room: room)) == expected)
    }

    // MARK: Messages the bridge builds

    @Test func pairedCarriesTheRoom() throws {
        let room = try PhoneRoom.newToken()
        let paired: NSDictionary = ["type": "paired", "room": room]
        #expect(try dictionary(LoaderHandler.paired(room: room)) == paired)
        let revoked: NSDictionary = ["type": "revoked"]
        #expect(try dictionary(LoaderHandler.revoked) == revoked)
        let denied: NSDictionary = ["type": "pairDenied", "reason": "denied"]
        #expect(try dictionary(LoaderHandler.pairDenied(.denied)) == denied)
        let expired: NSDictionary = ["type": "pairDenied", "reason": "expired"]
        #expect(try dictionary(LoaderHandler.pairDenied(.expired)) == expired)
    }

    @Test func appMessageSplicesTheBody() throws {
        let body = Data(" \n{\"kind\":\"event\",\"event\":\"x\",\"seq\":1,\"data\":{}}\t".utf8)
        let message = try LoaderHandler.appMessage(body: body)
        #expect(message == Data(#"{"type":"app","body":"#.utf8) + body + Data("}".utf8))
        let json = try object(message)
        #expect(json["type"] as? String == "app")
        #expect((json["body"] as? [String: Any])?["event"] as? String == "x")

        // A body that fills the frame exactly is still accepted.
        let fill = NoiseTransport.maxPlaintextLength - 22 - #"{"x":""}"#.utf8.count
        let fullBody = Data(#"{"x":""#.utf8) + Data(repeating: 0x61, count: fill) + Data(#""}"#.utf8)
        #expect(try LoaderHandler.appMessage(body: fullBody).count == NoiseTransport.maxPlaintextLength)
    }

    @Test func appMessageRefusesOversizeAndNonObjects() {
        #expect(throws: PhoneBridgeError.messageTooLarge) {
            try LoaderHandler.appMessage(body: Data(#"{"x":""#.utf8) + Data(repeating: 0x61, count: 65_519) + Data(#""}"#.utf8))
        }
        let notObjects = [
            "[1]",
            "",
            "   ",
            #""x""#,
            "{",
            #"{"a":1} trailing"#,
            #"{"a":1}{"b":2}"#,
            // Would put a second `type` in the envelope if spliced unchecked.
            #"{"a":1},"type":"revoked""#,
            #"{"a":"x"#,
        ]
        for body in notObjects {
            #expect(throws: PhoneBridgeError.notAJSONObject, "\(body)") {
                try LoaderHandler.appMessage(body: Data(body.utf8))
            }
        }
        #expect(throws: PhoneBridgeError.notAJSONObject) {
            try LoaderHandler.appMessage(body: Data(#"{"a":""#.utf8) + Data([0xFF]) + Data(#""}"#.utf8))
        }
        #expect(throws: PhoneBridgeError.notAJSONObject) {
            try LoaderHandler.appMessage(body: Data(#"{"a":""#.utf8) + Data([0x0A]) + Data(#""}"#.utf8))
        }
    }

    // MARK: The app seam

    @Test func theStubRepliesUnavailable() async throws {
        let stub = UnavailablePhoneApp()
        let outbox = OutboxRecorder()
        let peer = PhonePeer(deviceID: UUID(), deviceName: "iPhone")
        let request = Data(#"{"kind":"request","requestID":"r9","method":"sessions.subscribe","params":{}}"#.utf8)
        await stub.phoneConnected(peer, outbox: outbox)
        await stub.handleAppMessage(request, from: peer)
        let replies = await outbox.bodies
        try #require(replies.count == 1)
        let expected: NSDictionary = [
            "kind": "reply",
            "requestID": "r9",
            "error": ["code": "unavailable", "message": "This TBD build has no phone app service."],
        ]
        #expect(try dictionary(replies[0]) == expected)
        // The reply is one JSON object, so the real outbox can wrap it.
        let wrapped = try LoaderHandler.appMessage(body: replies[0])
        #expect(try object(wrapped)["type"] as? String == "app")

        // Nothing but a well-formed request gets a reply.
        let notRequests = [
            #"{"kind":"request","method":"sessions.subscribe","params":{}}"#,
            #"{"kind":"request","requestID":9}"#,
            #"{"kind":"event","event":"x","requestID":"r1"}"#,
            #"{"requestID":"r1"}"#,
            "not json",
            "[1]",
        ]
        for body in notRequests {
            await stub.handleAppMessage(Data(body.utf8), from: peer)
        }
        // Nor does a phone that never connected.
        await stub.handleAppMessage(request, from: PhonePeer(deviceID: UUID(), deviceName: "iPad"))
        let afterOthers = await outbox.bodies.count
        #expect(afterOthers == 1)

        // Nor does one that has disconnected.
        await stub.phoneDisconnected(peer)
        await stub.handleAppMessage(request, from: peer)
        let afterDisconnect = await outbox.bodies.count
        #expect(afterDisconnect == 1)
    }

    @Test func theStubForgetsARevokedPhone() async throws {
        let stub = UnavailablePhoneApp()
        let outbox = OutboxRecorder()
        let peer = PhonePeer(deviceID: UUID(), deviceName: "iPhone")
        await stub.phoneConnected(peer, outbox: outbox)
        await stub.phoneRevoked(deviceID: peer.deviceID)
        await stub.handleAppMessage(Data(#"{"kind":"request","requestID":"r1","method":"x","params":{}}"#.utf8), from: peer)
        let replies = await outbox.bodies
        #expect(replies.isEmpty)
    }

    @Test func theStubEchoesAnyRequestIDSafely() async throws {
        let stub = UnavailablePhoneApp()
        let outbox = OutboxRecorder()
        let peer = PhonePeer(deviceID: UUID(), deviceName: "iPhone")
        let requestID = "r\"1\\\n},\"kind\":\"event"
        let request = try JSONSerialization.data(withJSONObject: ["kind": "request", "requestID": requestID, "method": "x"])
        await stub.phoneConnected(peer, outbox: outbox)
        await stub.handleAppMessage(request, from: peer)
        let replies = await outbox.bodies
        let reply = try object(try #require(replies.first))
        #expect(reply["kind"] as? String == "reply")
        #expect(reply["requestID"] as? String == requestID)
    }

    @Test func theSlotKeepsTheLatestHandler() async {
        let slot = PhoneAppHandlerSlot()
        let recorder = RecordingPhoneApp()
        let initial = await slot.current()
        #expect(initial is UnavailablePhoneApp)
        await slot.set(recorder)
        let current = await slot.current()
        #expect((current as? RecordingPhoneApp) === recorder)
    }
}
