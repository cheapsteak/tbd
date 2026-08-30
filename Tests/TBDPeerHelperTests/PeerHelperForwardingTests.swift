import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDPeerHelper

/// What the helper puts on its stdout when a local session sends to a shadow.
///
/// **Why these are integration tests against the real binary.** The leak they
/// exist to catch — the whole agent frame going out as `content` — is invisible
/// to a hand-built fixture. `ShadowPeerManagerTests` already carries the right
/// assertion ("no `/tmp/`, no `.sock`") and passed the entire time the leak was
/// live, because the frame it asserts on comes from a fake helper handed
/// `content: "ack"`. So the frame under inspection here is produced by the
/// shipped helper, from bytes written into the socket it really bound.
@Suite(.serialized)
struct PeerHelperForwardingTests {

    /// **The regression test for the whole-frame leak.**
    ///
    /// `forward` set `content` to the entire agent frame read off the socket.
    /// That frame carries `"from":"uds:/tmp/cc-socks/<pid>.sock"` at top level
    /// *and* again inside the sender's `<cross-session-message …>` wrapper,
    /// along with the sender's self-chosen name and permission class — so the
    /// path the daemon carefully rewrites `from` to hide rode across the wire
    /// inside the message body anyway
    /// (`docs/specs/2026-08-29-remote-peer-messaging-design.md` § "Trust":
    /// raw socket paths never travel, in either direction).
    ///
    /// It broke the contract's other half at the same time. `PeerBridgeMessage`
    /// defines `content` as the thing the delivering side composes an agent
    /// frame *around*, and `ShadowPeerManager.deliverInbound` implements exactly
    /// that — so a conforming provider mirroring TBD's inbound behavior would
    /// have handed its session a `<cross-session-message>` whose body was raw
    /// JSON.
    @Test func forwardsTheBodyWithNoSocketPathAnywhereInIt() async throws {
        let helper = try SpawnedPeerHelper(name: "acme:forwarding-shadow")
        defer { helper.tearDown() }

        #expect(await helper.waitForPublication(), "the helper never published")

        let body = "bridge probe: is anyone home?"
        try helper.deliverToSocket(CapturedAgentFrame.payload(body: body))

        let emitted = await helper.nextLine()
        let line = try #require(emitted, "the helper forwarded nothing")

        let decoded = PeerBridgeFrameCodec.decode(
            line: line, negotiatedProtocol: PeerBridgeFrameCodec.peerProtocol)
        guard case .frame(let frame) = decoded, case .message(let message) = frame else {
            Issue.record("the helper emitted something other than a message frame: \(line)")
            return
        }

        // `content` is the BODY, not the frame. Both halves matter: the equality
        // says the body survived byte-verbatim, and the absences say nothing of
        // the sender's own framing came with it.
        #expect(message.content == body)
        #expect(!message.content.contains("msgV"), "content is still a JSON agent frame")
        #expect(!message.content.contains("cross-session-message"))
        #expect(!message.content.contains("from-name"))
        #expect(
            !message.content.contains(CapturedAgentFrame.senderMode),
            "the sender's self-claimed permission class must not travel")
        #expect(
            !message.content.contains(CapturedAgentFrame.senderName),
            "the sender's self-chosen name must not travel")
        #expect(!message.content.contains("/tmp/"))
        #expect(!message.content.contains(".sock"))
        #expect(!message.content.contains("cc-socks"))
        #expect(!message.content.contains("46403"), "the sender's local pid must not travel")

        #expect(message.to == helper.handle)
        #expect(!message.to.contains("/"), "a handle is never a path")

        // `from` is the ONE field on THIS hop that may carry a path, and it must:
        // the helper-to-daemon pipe is inside the trust boundary, and the daemon
        // looks the local sender up by this address in the handle table it keeps
        // privately, rewriting it to a handle before anything leaves the machine
        // (`ShadowPeerManager.forwardOutbound`). So the "no paths" assertion is
        // made on the line with that member excised — asserting it on the whole
        // line would be asserting something the design does not say, and could
        // only be satisfied by breaking outbound routing.
        #expect(message.from == CapturedAgentFrame.senderAddress)
        let fromMember = "\"from\":\"\(CapturedAgentFrame.senderAddress)\""
        #expect(line.contains(fromMember), "expected the sender address verbatim in: \(line)")
        let rest = line.replacingOccurrences(of: fromMember, with: "")
        #expect(!rest.contains("/tmp/"), "a socket path escaped outside `from`: \(rest)")
        #expect(!rest.contains(".sock"), "a socket path escaped outside `from`: \(rest)")
        #expect(!rest.contains("cc-socks"), "a socket path escaped outside `from`: \(rest)")
    }

    /// A body carrying no wrapper of its own is forwarded untouched. Guards the
    /// stripper against over-reaching: it removes attribution, never content.
    @Test func aBodyWithNoWrapperIsForwardedUnchanged() async throws {
        let helper = try SpawnedPeerHelper(name: "acme:bare-body-shadow")
        defer { helper.tearDown() }

        #expect(await helper.waitForPublication(), "the helper never published")

        let body = "no wrapper here — just <angle> brackets and a \"quote\""
        try helper.deliverToSocket(CapturedAgentFrame.payload(rawContent: body))

        let emitted = await helper.nextLine()
        let line = try #require(emitted, "the helper forwarded nothing")
        let decoded = PeerBridgeFrameCodec.decode(
            line: line, negotiatedProtocol: PeerBridgeFrameCodec.peerProtocol)
        guard case .frame(let frame) = decoded, case .message(let message) = frame else {
            Issue.record("the helper emitted something other than a message frame: \(line)")
            return
        }
        #expect(message.content == body)
    }

    /// `ListAgents` probes liveness by connecting and dropping. That probe is
    /// the whole reason the listener exists, so it must cost nothing: no frame,
    /// no drop count, and a helper still running afterwards.
    @Test func aLivenessProbeForwardsNothingAndLeavesTheHelperRunning() async throws {
        let helper = try SpawnedPeerHelper(name: "acme:probed-shadow")
        defer { helper.tearDown() }

        #expect(await helper.waitForPublication(), "the helper never published")

        try helper.probeSocket()
        try helper.probeSocket()

        #expect(await helper.lineEmitted(during: 0.5) == nil, "a probe must forward nothing")
        #expect(helper.isRunning)
        #expect(helper.socketExists)
        #expect(helper.recordExists)
    }
}

/// The attribution stripper and the frame reader, exercised directly.
///
/// The integration tests above prove the shipped binary does the right thing on
/// the ordinary frame; these cover the shapes that are awkward to drive through
/// a socket and are exactly where a naive implementation leaks.
@Suite
struct CrossSessionWrapperStrippingTests {

    @Test func stripsTheWholeWrapperAndLeavesTheBody() {
        let wrapped = CapturedAgentFrame.wrapped("hello there")
        #expect(PeerHelper.strippedOfSenderAttribution(wrapped) == "hello there")
    }

    @Test func leavesABareBodyAlone() {
        #expect(PeerHelper.strippedOfSenderAttribution("hello there") == "hello there")
        #expect(PeerHelper.strippedOfSenderAttribution("") == "")
    }

    /// The wrapper's own closing tag is removed because it is *paired* with the
    /// opening tag that was removed — never because the string ends with one.
    /// A body quoting a closing tag of its own keeps it.
    @Test func keepsAClosingTagThatBelongsToTheBody() {
        let body = "quoting </cross-session-message> at you"
        let stripped = PeerHelper.strippedOfSenderAttribution(
            CapturedAgentFrame.wrapped(body))
        #expect(stripped == body)
    }

    /// **The quote-awareness discriminator.** An attribute value may legally
    /// contain `>`, and a naive `firstIndex(of: ">")` splits inside it — leaving
    /// the tail of the sender's tag, socket path and all, in the body that is
    /// about to go on the wire.
    @Test func doesNotSplitInsideAQuotedAngleBracket() {
        let content = "<cross-session-message from=\"uds:/tmp/cc-socks/a>b.sock\" from-name=\"x\" from-mode=\"bypass\">\nthe body\n</cross-session-message>"
        let stripped = PeerHelper.strippedOfSenderAttribution(content)
        #expect(stripped == "the body")
        #expect(!stripped.contains(".sock"))
        #expect(!stripped.contains("/tmp/"))
    }

    /// `<cross-session-messageX …>` is a different element. Treating it as the
    /// wrapper would delete a span of somebody's message.
    @Test func aDifferentElementIsNotTheWrapper() {
        let content = "<cross-session-messageboard>hi</cross-session-messageboard>"
        #expect(PeerHelper.strippedOfSenderAttribution(content) == content)
    }

    /// An opening tag with no closing tag keeps whatever follows it: the
    /// closing tag is removed only as the pair of an opening one, and the
    /// interior is never searched.
    @Test func anUnclosedWrapperKeepsItsRemainder() {
        let content = "<cross-session-message from=\"uds:/x\">\nbody with no close"
        #expect(PeerHelper.strippedOfSenderAttribution(content) == "body with no close")
    }

    @Test func readsTheSenderAndTheBodyOutOfARealFrame() throws {
        let payload = CapturedAgentFrame.payload(body: "hello")
        let parsed = try #require(PeerHelper.readAgentFrame(payload))
        #expect(parsed.sender == CapturedAgentFrame.senderAddress)
        #expect(parsed.body == CapturedAgentFrame.wrapped("hello"))
    }

    /// Nil, not a fallback. A payload this build cannot read a body out of is
    /// dropped and counted: forwarding the raw bytes instead is precisely the
    /// leak the stripper exists to close, so there is deliberately no path that
    /// puts unparsed bytes on the wire.
    @Test(arguments: [
        "not json at all",
        "[1, 2, 3]",
        "{\"from\":\"uds:/tmp/cc-socks/46403.sock\"}",
        "{\"from\":\"uds:/x\",\"message\":{\"role\":\"user\"}}",
        "{\"from\":\"uds:/x\",\"message\":{\"role\":\"user\",\"content\":[]}}",
    ])
    func returnsNilForAPayloadWithNoReadableBody(_ raw: String) {
        #expect(PeerHelper.readAgentFrame(Data(raw.utf8)) == nil)
    }

    /// A frame with a body but no `from` is still forwardable — unattributed,
    /// which the helper logs. Losing the message would be worse than losing the
    /// attribution, and the daemon drops what it cannot route anyway.
    @Test func readsABodyEvenWithNoSenderAddress() throws {
        let raw = "{\"msgV\":1,\"message\":{\"role\":\"user\",\"content\":\"orphaned\"}}"
        let parsed = try #require(PeerHelper.readAgentFrame(Data(raw.utf8)))
        #expect(parsed.sender.isEmpty)
        #expect(parsed.body == "orphaned")
    }
}
