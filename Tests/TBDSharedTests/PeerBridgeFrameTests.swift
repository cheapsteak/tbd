import Testing
import Foundation
@testable import TBDShared

/// Wire-format tests for the `messages` stream
/// (docs/specs/2026-08-29-remote-peer-messaging-design.md § "Contract change"
/// and § "Failure semantics").
///
/// Assertions here are on whole composed values — a decoded frame compared in
/// full, a complete key set, a whole list of stream outcomes — rather than a
/// field at a time, so a field that appears, vanishes or is renamed on the wire
/// fails a test rather than slipping past a spot check.
@Suite("Peer bridge frames")
struct PeerBridgeFrameTests {

    /// One frame of every kind the contract defines. The `allCases` assertion
    /// below is what keeps this list honest when a kind is added.
    static let everyKind: [PeerBridgeFrame] = [
        .hello(origin: "acme-laptop", peerProtocol: 1),
        .peer(PeerBridgePeer(
            handle: "h-9f3a", name: "acme-cloud:useful-swallow",
            status: "busy", peerProtocol: 1)),
        .peerGone(handle: "h-9f3a"),
        .message(PeerBridgeMessage(
            id: "m-6d40", to: "h-9f3a", from: "h-1b2c",
            content: "rebase landed, please re-run CI")),
        .peerInventory(handles: ["h-9f3a", "h-1b2c"]),
        .ping,
    ]

    // MARK: - Round trip

    @Test func everyLineKindRoundTripsAsAWholeValue() throws {
        for frame in Self.everyKind {
            let line = try PeerBridgeFrameCodec.encodeLine(frame)
            let decoded = PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: 1)
            #expect(decoded == .frame(frame))
        }
    }

    /// The fixture list covers the contract, not just the cases someone
    /// remembered. Adding a kind without adding a fixture fails here.
    @Test func theRoundTripFixturesCoverEveryDefinedKind() {
        #expect(Set(Self.everyKind.map(\.kind)) == Set(PeerBridgeFrame.Kind.allCases))
    }

    @Test func kindsSpellThemselvesTheWayTheContractDoes() {
        #expect(Set(PeerBridgeFrame.Kind.allCases.map(\.rawValue))
            == ["hello", "peer", "peer-gone", "message", "peer-inventory", "ping"])
    }

    /// The complete key set each kind puts on the wire — an extra field, a
    /// missing one, or a renamed one all fail this.
    @Test func eachKindEncodesExactlyTheContractsFields() throws {
        let expected: [PeerBridgeFrame.Kind: Set<String>] = [
            .hello: ["kind", "origin", "protocol"],
            .peer: ["kind", "handle", "name", "status", "protocol"],
            .peerGone: ["kind", "handle"],
            .message: ["kind", "id", "to", "from", "content"],
            .peerInventory: ["kind", "handles"],
            .ping: ["kind"],
        ]
        var observed: [PeerBridgeFrame.Kind: Set<String>] = [:]
        for frame in Self.everyKind {
            let data = try PeerBridgeFrameCodec.encode(frame)
            let json = try JSONSerialization.jsonObject(with: data)
            let object = try #require(json as? [String: Any])
            observed[frame.kind] = Set(object.keys)
        }
        #expect(observed == expected)
    }

    /// A JSON object encodes to one physical line whatever the content holds,
    /// which is what makes NDJSON framing safe. Content itself is byte-verbatim.
    @Test func contentSurvivesVerbatimAndNeverBreaksTheLineFraming() throws {
        let awkward = "line one\nline two\ttabbed \"quoted\" ünïcode /slashes/ \\ backslash"
        let frame = PeerBridgeFrame.message(
            PeerBridgeMessage(id: "m-6d40", to: "h-1", from: "h-2", content: awkward))
        let line = try PeerBridgeFrameCodec.encodeLine(frame)
        #expect(line.hasSuffix("\n"))
        #expect(line.filter { $0 == "\n" }.count == 1)
        #expect(PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: 1) == .frame(frame))
    }

    /// The correlation id rides across verbatim and is what tells two otherwise
    /// identical frames apart, which is the whole of what it buys: on a stream
    /// with no acks it is how one frame is named the same way in both sides'
    /// logs. Nothing here asserts a receiver answers one, and nothing should
    /// grow to — an id is diagnostic, never a receipt.
    @Test func theIdIsCarriedVerbatimAndSeparatesOtherwiseIdenticalFrames() throws {
        let first = PeerBridgeFrame.message(PeerBridgeMessage(
            id: "m-6d40", to: "h-9f3a", from: "h-1b2c", content: "please re-run CI"))
        let second = PeerBridgeFrame.message(PeerBridgeMessage(
            id: "m-9b71", to: "h-9f3a", from: "h-1b2c", content: "please re-run CI"))
        #expect(first != second)
        for frame in [first, second] {
            let line = try PeerBridgeFrameCodec.encodeLine(frame)
            #expect(PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: 1) == .frame(frame))
        }
    }

    @Test func peerInventoryIsTheOnlyProviderToTBDOnlyKind() {
        let oneWay = Self.everyKind.filter(\.isProviderToTBDOnly).map(\.kind)
        #expect(Set(oneWay) == [.peerInventory])
    }

    // MARK: - Size cap

    /// The cap is a refusal, not a truncation: an oversized frame never becomes
    /// a smaller frame that looks valid and says something the sender did not.
    @Test func anOversizedFrameIsRefusedOnEncode() throws {
        let overhead = try PeerBridgeFrameCodec.encode(
            .message(PeerBridgeMessage(id: "m-1", to: "t", from: "f", content: ""))).count
        let oneTooLong = String(
            repeating: "a", count: PeerBridgeFrameCodec.maxFrameBytes - overhead + 1)
        let frame = PeerBridgeFrame.message(
            PeerBridgeMessage(id: "m-1", to: "t", from: "f", content: oneTooLong))
        do {
            _ = try PeerBridgeFrameCodec.encode(frame)
            Issue.record("a frame one byte over the cap was encoded rather than refused")
        } catch let rejection as PeerBridgeFrameRejection {
            #expect(rejection == .oversized(bytes: PeerBridgeFrameCodec.maxFrameBytes + 1))
        }
    }

    /// The boundary in the other direction — without this, a cap of zero would
    /// pass the refusal test above.
    @Test func aFrameExactlyAtTheCapEncodes() throws {
        let overhead = try PeerBridgeFrameCodec.encode(
            .message(PeerBridgeMessage(id: "m-1", to: "t", from: "f", content: ""))).count
        let exact = String(repeating: "a", count: PeerBridgeFrameCodec.maxFrameBytes - overhead)
        let frame = PeerBridgeFrame.message(
            PeerBridgeMessage(id: "m-1", to: "t", from: "f", content: exact))
        let data = try PeerBridgeFrameCodec.encode(frame)
        #expect(data.count == PeerBridgeFrameCodec.maxFrameBytes)
    }

    /// Inbound, the cap is checked on the line's size before anything parses
    /// it, so a huge line costs one rejection rather than a parse.
    @Test func anOversizedLineIsRejectedOnDecode() {
        let prefix = #"{"content":""#
        let suffix = #"","from":"h-2","id":"m-1","kind":"message","to":"h-1"}"#
        let padding = String(
            repeating: "a",
            count: PeerBridgeFrameCodec.maxFrameBytes - prefix.utf8.count - suffix.utf8.count + 1)
        let line = prefix + padding + suffix
        #expect(PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: 1)
            == .rejected(.oversized(bytes: PeerBridgeFrameCodec.maxFrameBytes + 1)))
    }

    /// The cap's whole reason for being where it is: it must sit below the size
    /// at which `PipeLineReader` (Sources/TBDDaemon/Remote/ProviderEventsSupervisor.swift)
    /// discards an un-newlined buffer, since that discard is reported only once
    /// per reader and is invisible after that.
    @Test func theCapSitsBelowThePipeReadersSilentDiscardThreshold() {
        #expect(PeerBridgeFrameCodec.maxFrameBytes < 1 << 20)
    }

    // MARK: - Forward compatibility

    @Test func anUnknownLineKindIsSkippedRatherThanTreatedAsDamage() {
        let line = #"{"kind":"peer-renamed","handle":"h-1","name":"whatever"}"#
        #expect(PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: 1)
            == .skipped(.unrecognizedKind("peer-renamed")))
    }

    @Test func unknownFieldsOnAKnownKindAreIgnored() {
        let line = #"{"kind":"hello","origin":"acme-laptop","protocol":1,"lease":"future"}"#
        #expect(PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: 1)
            == .frame(.hello(origin: "acme-laptop", peerProtocol: 1)))
    }

    @Test func blankAndWhitespaceOnlyLinesAreSkipped() {
        #expect(PeerBridgeFrameCodec.decode(line: "", negotiatedProtocol: 1)
            == .skipped(.blankLine))
        #expect(PeerBridgeFrameCodec.decode(line: "   ", negotiatedProtocol: 1)
            == .skipped(.blankLine))
    }

    // MARK: - Protocol gate

    @Test func aHelloDeclaringAnotherProtocolIsRejected() {
        let line = #"{"kind":"hello","origin":"acme-laptop","protocol":2}"#
        #expect(PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: 1)
            == .rejected(.protocolMismatch(frame: 2, negotiated: 1)))
    }

    @Test func aPeerDeclaringAnotherProtocolIsRejected() {
        let line = #"{"kind":"peer","handle":"h-1","name":"acme-cloud:swallow","status":"idle","protocol":2}"#
        #expect(PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: 1)
            == .rejected(.protocolMismatch(frame: 2, negotiated: 1)))
    }

    /// The gate is on the declared number, not on the reader's own constant: a
    /// link that negotiated 2 accepts 2 and rejects 1.
    @Test func theGateFollowsTheNegotiatedNumberNotThisBuildsConstant() {
        let line = #"{"kind":"hello","origin":"acme-laptop","protocol":2}"#
        #expect(PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: 2)
            == .frame(.hello(origin: "acme-laptop", peerProtocol: 2)))
        let ours = #"{"kind":"hello","origin":"acme-laptop","protocol":1}"#
        #expect(PeerBridgeFrameCodec.decode(line: ours, negotiatedProtocol: 2)
            == .rejected(.protocolMismatch(frame: 1, negotiated: 2)))
    }

    /// A `message` declares no protocol of its own — it rides a link whose
    /// `hello` already matched — so it is delivered whatever number the link
    /// settled on, and carries no agent frame internals to disagree about.
    @Test func aMessageCarriesNoProtocolOfItsOwn() {
        let line = #"{"kind":"message","id":"m-1","to":"h-1","from":"h-2","content":"hi","msgV":9}"#
        #expect(PeerBridgeFrameCodec.decode(line: line, negotiatedProtocol: 7)
            == .frame(.message(
                PeerBridgeMessage(id: "m-1", to: "h-1", from: "h-2", content: "hi"))))
    }

    // MARK: - Malformed input

    /// A stream of mixed lines, asserted as one whole list of outcomes: the bad
    /// lines are rejected in place and the good lines on either side of them
    /// still parse, which is what "rejected without throwing out of the parse
    /// loop" means in practice.
    @Test func malformedLinesCostOneLineEachAndNeverTheStream() {
        let lines = [
            #"{"kind":"ping"}"#,
            #"{"kind":"peer","name":"no handle","status":"idle","protocol":1}"#,
            "{not json at all",
            #"{"kind":"hello","origin":"acme-laptop"}"#,
            #"{"kind":"message","to":"h-1","from":"h-2","content":"no id"}"#,
            #"["kind","message"]"#,
            #"{"kind":42}"#,
            #"{"kind":"peer-gone","handle":"h-1"}"#,
        ]
        let outcomes = lines.map {
            PeerBridgeFrameCodec.decode(line: $0, negotiatedProtocol: 1)
        }
        #expect(outcomes == [
            .frame(.ping),
            .rejected(.malformed),
            .rejected(.malformed),
            .rejected(.malformed),
            .rejected(.malformed),
            .rejected(.malformed),
            .rejected(.malformed),
            .frame(.peerGone(handle: "h-1")),
        ])
    }
}
