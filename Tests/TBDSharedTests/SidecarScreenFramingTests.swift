import Foundation
import Testing

@testable import TBDShared

/// The screen pull's two frame types, their payloads, and the one rule the
/// request type enforces rather than documents.
///
/// Nothing sends these frames yet. What is testable now is the contract they
/// carry: that a request and a reply survive the wire unchanged, that a refusal
/// is distinguishable from an answer, that the depth cap cannot be bypassed by
/// a call site, and that the two new type bytes did not land on a value the
/// forward-compat seam depends on being unknown.
@Suite("Sidecar screen frames")
struct SidecarScreenFramingTests {

    private static func payload(
        lines: [String] = ["first", "second"],
        ageMilliseconds: Int = 12
    ) -> ViewerScreenPayload {
        ViewerScreenPayload(
            lines: lines,
            viewportStart: 1,
            cursorRow: 3,
            cursorColumn: 7,
            cursorVisible: true,
            cursorVisibleObserved: false,
            columns: 80,
            rows: 24,
            bracketedPaste: true,
            applicationCursor: false,
            alternateScreen: true,
            ageMilliseconds: ageMilliseconds)
    }

    // MARK: - Type bytes

    /// The seam the injection path relied on when it added a frame type:
    /// both receive loops return an unrecognized type byte instead of
    /// desyncing, and three suites drive that with byte 99. Two new cases must
    /// not claim a byte somebody is already using as "unknown", and must not
    /// collide with each other or with the five that existed.
    @Test("the new type bytes are distinct and leave the unknown-byte seam intact")
    func typeBytesAreDistinctAndLeaveRoom() {
        let claimed: [SidecarFrameType] = [
            .fdVend, .input, .paste, .injection, .injectionAck, .screenRequest, .screenReply,
        ]
        #expect(Set(claimed.map(\.rawValue)).count == claimed.count)
        #expect(SidecarFrameType.screenRequest.rawValue == 6)
        #expect(SidecarFrameType.screenReply.rawValue == 7)
        #expect(SidecarFrameType(rawValue: 99) == nil)
    }

    // MARK: - The request

    @Test("a screen request round-trips through the codec")
    func requestRoundTrips() throws {
        let request = SidecarScreenRequest(
            terminalID: UUID(),
            requestID: UUID(),
            requestedLines: 50,
            retainedScrollbackLines: 5_000,
            wantStyledCapture: true)
        let wire = try SidecarFrameCodec.encodeScreenRequest(request)

        let frames = SidecarFrameScanner().append(wire)
        #expect(frames.count == 1)
        #expect(frames[0].type == SidecarFrameType.screenRequest.rawValue)
        #expect(try SidecarFrameCodec.decodeScreenRequest(payload: frames[0].payload) == request)
    }

    /// The depth cap is the contract's "it must not vary by who is looking":
    /// a viewer's SwiftTerm retains more scrollback than the daemon's emulator,
    /// so a request that forwarded `--lines 10000` verbatim would answer the
    /// same question differently depending on whether anybody had the session
    /// open. Enforced in the initializer so no minting site can forget it.
    @Test("a requested depth is clamped to the daemon's retained depth")
    func requestedDepthIsClampedToRetained() {
        let request = SidecarScreenRequest(
            terminalID: UUID(), requestID: UUID(),
            requestedLines: 10_000, retainedScrollbackLines: 5_000,
            wantStyledCapture: false)
        #expect(request.lines == 5_000)
        #expect(request.styledScrollbackLines == 5_000)
    }

    @Test("a depth under the retained depth is forwarded as asked")
    func depthUnderTheCapIsUntouched() {
        let request = SidecarScreenRequest(
            terminalID: UUID(), requestID: UUID(),
            requestedLines: 50, retainedScrollbackLines: 5_000,
            wantStyledCapture: false)
        #expect(request.lines == 50)
    }

    /// Zero is the modes-only reading, and it has to survive the clamp: the
    /// projection's `maxLines <= 0` arm is what makes an oracle consultation a
    /// few hundred bytes instead of a scrollback walk.
    @Test("a zero depth stays zero, and a negative one floors there")
    func zeroAndNegativeDepths() {
        let modesOnly = SidecarScreenRequest(
            terminalID: UUID(), requestID: UUID(),
            requestedLines: 0, retainedScrollbackLines: 5_000, wantStyledCapture: false)
        #expect(modesOnly.lines == 0)

        let negative = SidecarScreenRequest(
            terminalID: UUID(), requestID: UUID(),
            requestedLines: -7, retainedScrollbackLines: 5_000, wantStyledCapture: false)
        #expect(negative.lines == 0)
    }

    @Test("a negative retained depth cannot produce a negative cap")
    func negativeRetainedDepthFloorsAtZero() {
        let request = SidecarScreenRequest(
            terminalID: UUID(), requestID: UUID(),
            requestedLines: 50, retainedScrollbackLines: -1, wantStyledCapture: true)
        #expect(request.lines == 0)
        #expect(request.styledScrollbackLines == 0)
    }

    // MARK: - The reply

    @Test("an answering reply round-trips, screen and styled capture intact")
    func answeringReplyRoundTrips() throws {
        let reply = SidecarScreenReply(
            requestID: UUID(),
            terminalID: UUID(),
            screen: Self.payload(),
            styledCapture: "\u{1b}[31mred\u{1b}[0m\n")
        let frames = SidecarFrameScanner().append(try SidecarFrameCodec.encodeScreenReply(reply))

        #expect(frames[0].type == SidecarFrameType.screenReply.rawValue)
        let decoded = try SidecarFrameCodec.decodeScreenReply(payload: frames[0].payload)
        #expect(decoded == reply)
        #expect(decoded.screen?.lines == ["first", "second"])
        #expect(decoded.styledCapture == "\u{1b}[31mred\u{1b}[0m\n")
        #expect(decoded.unavailable == nil)
    }

    /// A refusal must be distinguishable from an answer on the wire, because
    /// that is what lets the daemon fall back immediately instead of burning
    /// its bound on an answer that was never coming.
    @Test("a refusing reply carries its reason and no screen")
    func refusingReplyRoundTrips() throws {
        for reason in SidecarScreenReply.Unavailable.allCases {
            let reply = SidecarScreenReply(
                requestID: UUID(), terminalID: UUID(), unavailable: reason)
            let frames = SidecarFrameScanner().append(
                try SidecarFrameCodec.encodeScreenReply(reply))
            let decoded = try SidecarFrameCodec.decodeScreenReply(payload: frames[0].payload)
            #expect(decoded.unavailable == reason)
            #expect(decoded.screen == nil)
            #expect(decoded.styledCapture == nil)
        }
    }

    @Test("an answer with no styled capture decodes with none")
    func answerWithoutStyledCapture() throws {
        let reply = SidecarScreenReply(
            requestID: UUID(), terminalID: UUID(), screen: Self.payload())
        let decoded = try SidecarFrameCodec.decodeScreenReply(
            payload: SidecarFrameScanner().append(
                try SidecarFrameCodec.encodeScreenReply(reply))[0].payload)
        #expect(decoded.styledCapture == nil)
        #expect(decoded.screen != nil)
    }

    // MARK: - Undecodable payloads

    @Test("an undecodable request payload throws the documented error")
    func undecodableRequest() {
        #expect(throws: SidecarFramingError.undecodableHeader) {
            try SidecarFrameCodec.decodeScreenRequest(payload: Data("not json".utf8))
        }
    }

    @Test("an undecodable reply payload throws the documented error")
    func undecodableReply() {
        #expect(throws: SidecarFramingError.undecodableHeader) {
            try SidecarFrameCodec.decodeScreenReply(payload: Data([0x00, 0x01, 0x02]))
        }
    }

    /// A truncation inside the JSON is a decode failure, not a silently
    /// half-filled value — the same guarantee `.injectionAck` has, reached the
    /// same way.
    @Test("a reply truncated mid-JSON throws rather than decoding partially")
    func truncatedReply() throws {
        let reply = SidecarScreenReply(
            requestID: UUID(), terminalID: UUID(), screen: Self.payload())
        let json = try JSONEncoder().encode(reply)
        #expect(throws: SidecarFramingError.undecodableHeader) {
            try SidecarFrameCodec.decodeScreenReply(payload: json.prefix(json.count / 2))
        }
    }

    // MARK: - What the payload says, and what it refuses to say

    /// The payload carries the viewer's half of a screen and deliberately not
    /// the daemon's: no `source`, no `modesObserved`, no `contentObserved`.
    /// A field appearing on the wire would mean the app had started inventing
    /// provenance it cannot have.
    @Test("the payload's wire form carries no provenance the app cannot know")
    func payloadCarriesNoDaemonProvenance() throws {
        let encoded = try JSONEncoder().encode(Self.payload())
        let object = try JSONSerialization.jsonObject(with: encoded)
        let fields = try #require(object as? [String: Any])
        let keys = Set(fields.keys)
        #expect(keys.isDisjoint(with: ["source", "modesObserved", "contentObserved"]))
        #expect(keys.contains("cursorVisibleObserved"))
        #expect(keys.contains("ageMilliseconds"))
    }

    /// The composed accessors are what the daemon stamps a `TerminalScreen`
    /// from, so they have to agree with the flat fields they are built out of.
    @Test("the payload composes the modes, size and cursor it was built with")
    func payloadComposesItsOwnFields() {
        let payload = Self.payload()
        #expect(payload.modes.bracketedPaste)
        #expect(!payload.modes.applicationCursor)
        #expect(payload.modes.alternateScreen)
        #expect(payload.size == TerminalScreen.Size(columns: 80, rows: 24))
        #expect(payload.cursor.row == 3)
        #expect(payload.cursor.column == 7)
        #expect(payload.cursor.visible)
    }
}
