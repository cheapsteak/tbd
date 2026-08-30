import Foundation

// MARK: - The `messages` stream's line kinds
//
// Wire format for the peer link (docs/specs/2026-08-29-remote-peer-messaging-design.md
// § "Contract change", normatively specified in docs/remote-provider-contract.md):
// one duplex NDJSON stream per provider, TBD on stdin, provider on stdout.
// These types are the `messages` sibling of `RemoteEvent`, and they follow that
// stream's rules deliberately: one flat JSON object per line discriminated by a
// string, unknown fields ignored, unknown kinds ignored forward-compatibly
// rather than treated as errors.
//
// The discriminator is `kind` rather than `events`' `event` because this stream
// carries lines that are not events — an inventory and a delivery among them.

/// One line of the `messages` NDJSON stream, in either direction unless the
/// case says otherwise.
///
/// `peer` and `peer-gone` make this a registry-sync protocol rather than only a
/// message pipe: they are how each side learns what the other can address, and
/// a `message` naming a handle the receiver was never told about is dropped by
/// the *caller* (that check needs roster state this type does not have).
///
/// Every wire field name in this contract lives in exactly one place — this
/// type's `CodingKeys` — which both halves of the coding read. The payload
/// structs below are deliberately plain values with no `Codable` conformance of
/// their own, so there is no second encoding of the same line to drift from
/// this one.
public enum PeerBridgeFrame: Equatable, Sendable, Codable {
    /// First line each side writes, declaring the origin it speaks for and the
    /// peer protocol it speaks.
    case hello(origin: String, peerProtocol: Int)
    /// Announces or updates one addressable session on the sender's side.
    /// Idempotent and **complete** — never a partial diff — which is why every
    /// field on `PeerBridgePeer` that the sender's direction defines is
    /// required.
    case peer(PeerBridgePeer)
    /// That handle is no longer addressable.
    case peerGone(handle: String)
    /// One frame for delivery, addressed by handle.
    case message(PeerBridgeMessage)
    /// The handles the sender currently publishes on its side. Provider → TBD
    /// only: TBD diffs it against what it asked for, which is what makes the
    /// far half's hygiene observable. Named for the contract's existing word
    /// for a provider's full session set, not for TBD's internal "shadow".
    case peerInventory(handles: [String])
    /// Keepalive, as on `events`.
    case ping

    /// The wire discriminator. `CaseIterable` so a test can assert the set of
    /// kinds this build speaks is exactly the set the contract defines.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case hello
        case peer
        case peerGone = "peer-gone"
        case message
        case peerInventory = "peer-inventory"
        case ping
    }

    public var kind: Kind {
        switch self {
        case .hello: return .hello
        case .peer: return .peer
        case .peerGone: return .peerGone
        case .message: return .message
        case .peerInventory: return .peerInventory
        case .ping: return .ping
        }
    }

    /// True for the one kind the contract sends in a single direction. A
    /// property rather than a comment so the link can enforce it at the point
    /// it reads a line, instead of every reader remembering to.
    public var isProviderToTBDOnly: Bool {
        kind == .peerInventory
    }

    /// The peer protocol this line declares, for the lines that declare one.
    /// `nil` for the lines that do not — `message` deliberately among them: a
    /// message rides a link whose `hello` already matched and addresses a handle
    /// an already-matched `peer` line announced, so it carries no version of its
    /// own. (Claude Code's `msgV` stays inside `content`, where it belongs; it
    /// is that agent's frame internal and never a field of this contract.)
    public var declaredProtocol: Int? {
        switch self {
        case .hello(_, let peerProtocol): return peerProtocol
        case .peer(let peer): return peer.peerProtocol
        case .peerGone, .message, .peerInventory, .ping: return nil
        }
    }

    /// Every field name this contract puts on a `messages` line.
    private enum CodingKeys: String, CodingKey {
        case kind
        case origin
        case handle
        case handles
        case name
        case status
        case id
        /// `session` on the wire; `sessionID` in Swift.
        case session
        case to
        case from
        case content
        /// `protocol` on the wire; `peerProtocol` in Swift, where the former is
        /// a keyword.
        case peerProtocol = "protocol"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: raw) else {
            // NOT a `DecodingError`: a kind a newer peer speaks and this build
            // does not is forward compatibility working, not damage. The codec
            // recognises this case before it decodes; this throw covers a
            // direct `JSONDecoder().decode(PeerBridgeFrame.self, …)` caller.
            throw PeerBridgeFrameSkip.unrecognizedKind(raw)
        }
        switch kind {
        case .hello:
            let origin = try c.decode(String.self, forKey: .origin)
            let peerProtocol = try c.decode(Int.self, forKey: .peerProtocol)
            self = .hello(origin: origin, peerProtocol: peerProtocol)
        case .peer:
            let handle = try c.decode(String.self, forKey: .handle)
            let name = try c.decode(String.self, forKey: .name)
            let status = try c.decode(String.self, forKey: .status)
            let peerProtocol = try c.decode(Int.self, forKey: .peerProtocol)
            // Decoded permissively even though a provider MUST send it,
            // because the same coding serves both directions and TBD's own
            // `peer` lines carry no session id. A line that arrives without
            // one is not malformed — it is a peer that cannot be sited, which
            // is the receiver's judgement to make and to surface, not the
            // codec's.
            let sessionID = try c.decodeIfPresent(String.self, forKey: .session)
            self = .peer(PeerBridgePeer(
                handle: handle, name: name, status: status, peerProtocol: peerProtocol,
                sessionID: sessionID))
        case .peerGone:
            let handle = try c.decode(String.self, forKey: .handle)
            self = .peerGone(handle: handle)
        case .message:
            let id = try c.decode(String.self, forKey: .id)
            let to = try c.decode(String.self, forKey: .to)
            let from = try c.decode(String.self, forKey: .from)
            let content = try c.decode(String.self, forKey: .content)
            self = .message(PeerBridgeMessage(id: id, to: to, from: from, content: content))
        case .peerInventory:
            let handles = try c.decode([String].self, forKey: .handles)
            self = .peerInventory(handles: handles)
        case .ping:
            self = .ping
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .hello(let origin, let peerProtocol):
            try c.encode(origin, forKey: .origin)
            try c.encode(peerProtocol, forKey: .peerProtocol)
        case .peer(let peer):
            try c.encode(peer.handle, forKey: .handle)
            try c.encode(peer.name, forKey: .name)
            try c.encode(peer.status, forKey: .status)
            try c.encode(peer.peerProtocol, forKey: .peerProtocol)
            try c.encodeIfPresent(peer.sessionID, forKey: .session)
        case .peerGone(let handle):
            try c.encode(handle, forKey: .handle)
        case .message(let message):
            try c.encode(message.id, forKey: .id)
            try c.encode(message.to, forKey: .to)
            try c.encode(message.from, forKey: .from)
            try c.encode(message.content, forKey: .content)
        case .peerInventory(let handles):
            try c.encode(handles, forKey: .handles)
        case .ping:
            break
        }
    }
}

/// One addressable session on the sender's side, as announced by a `peer` line.
///
/// Every field the sender's direction defines is required, and that is the
/// contract rather than strictness for its own sake: a `peer` line is a
/// complete, idempotent statement of one session's state, so a line missing one
/// of them is not a smaller truth, it is a partial diff the receiver cannot
/// apply. `sessionID` is the one field only one direction defines, and its own
/// documentation says which.
public struct PeerBridgePeer: Sendable, Equatable {
    /// Opaque handle minted by the sender. **Never a socket path** — a wire
    /// that carried paths would let the far side name any socket in
    /// `/tmp/cc-socks`, including a session TBD never chose to mirror.
    public let handle: String
    /// The name this session is addressed by on the sender's side, already
    /// namespaced by the sender's origin.
    public let name: String
    /// The session's status, verbatim from the agent registry row it was read
    /// from. Deliberately a `String` rather than a tolerant enum with an
    /// `.unknown` fallback: this value is written back into a registry record
    /// on the receiving side, and collapsing a value this contract does not
    /// enumerate would destroy a fact the far side needs. The vocabulary
    /// belongs to the agent, not to this contract.
    public let status: String
    /// The peer protocol this session speaks, sourced from its own registry row
    /// rather than asserted.
    public let peerProtocol: Int
    /// Which of the sender's own sessions this line announces: the `id` on the
    /// Session object `list` and `events` already return for it, reused rather
    /// than a second identity minted for this stream.
    ///
    /// **Required provider → TBD, and the whole of what makes a peer sitable.**
    /// A handle addresses a session; this says *which* session, and TBD needs
    /// that to join the announcement to the worktree row it adopted for it —
    /// the row is what supplies the display name a shadow is published under
    /// and a `cwd` that exists on this machine. Nothing else on the line can
    /// stand in: a name the far side asserted is not the name the naming rule
    /// specifies, and a remote path resolves to nothing here.
    ///
    /// Nil is therefore "this peer cannot be sited" rather than "site it some
    /// other way": absent, or naming a session TBD adopted no row for, the
    /// receiver surfaces it as unmirrored and publishes nothing. It is not
    /// malformed — see the decoding note above.
    ///
    /// **Not required TBD → provider**, and defaulted to nil for exactly that
    /// direction: a provider publishes the name TBD composed and needs no
    /// session id to do it, and the handle is its stable key for the peer.
    public let sessionID: String?

    public init(
        handle: String, name: String, status: String, peerProtocol: Int,
        sessionID: String? = nil
    ) {
        self.handle = handle
        self.name = name
        self.status = status
        self.peerProtocol = peerProtocol
        self.sessionID = sessionID
    }
}

/// One message frame for delivery, addressed by handle. Four fields, and the
/// absences are as load-bearing as the fields.
///
/// **No attribution.** The `<cross-session-message>` wrapper's `from-name` and
/// `from-mode` never travel: they are composed by the sender's own client, so a
/// remote peer that could set them could name itself as one of your local
/// sessions. The receiving side stamps attribution from `from` — the handle it
/// minted itself — and passes `content` byte-verbatim.
///
/// **No agent frame internals.** The delivering side composes the agent's own
/// frame (its message id, type and priority, and its `msgV`) locally around
/// `content`. Carrying them would put one agent's frame shape into a
/// provider-facing contract, and would let the far side choose fields the
/// receiver is answerable for.
public struct PeerBridgeMessage: Sendable, Equatable {
    /// Opaque id minted by the sending side, unique for the life of one
    /// connection. **Diagnostic only, and never an acknowledgement.**
    ///
    /// Nothing on this stream is acked, so the channel's main failure mode is a
    /// frame that is dropped somewhere and never mentioned again. Both sides log
    /// this id, which is what lets one frame be named identically in both logs
    /// and a drop be attributed to a side. It confers nothing else: no receipt
    /// travels back, no side reports what it did with a frame, nothing is
    /// retried, and a repeated id is not a replay to suppress. A receiver never
    /// parses it or derives anything from it.
    ///
    /// It names this hop and nothing inside `content`: the agent's own frame
    /// internals, its message id among them, are composed around `content` by
    /// the delivering side and are never fields of this contract.
    public let id: String
    /// Opaque handle of the addressee. A handle the receiver cannot look up
    /// resolves to nothing — it can never reach a session that was not mirrored.
    public let to: String
    /// Opaque handle of the sender. Required: it is the only attribution the
    /// receiver trusts, and a frame it cannot attribute is one it cannot stamp.
    public let from: String
    /// The message content, byte-verbatim. Never rewritten in transit.
    public let content: String

    public init(id: String, to: String, from: String, content: String) {
        self.id = id
        self.to = to
        self.from = from
        self.content = content
    }
}

// MARK: - Outcomes

/// A line that carried nothing wrong and nothing this build can act on.
/// Skipping is the contract's forward-compatibility rule, not a failure, so
/// these are deliberately not `PeerBridgeFrameRejection` cases: a caller counts
/// them separately or not at all, and never reports them as loss.
public enum PeerBridgeFrameSkip: LocalizedError, Equatable, Sendable {
    /// A blank keepalive line.
    case blankLine
    /// A line kind a newer peer speaks and this build does not.
    case unrecognizedKind(String)

    public var errorDescription: String? {
        switch self {
        case .blankLine:
            return "peer bridge line was blank; skipped"
        case .unrecognizedKind(let kind):
            return "peer bridge line kind '\(kind)' is not one this build speaks; skipped"
        }
    }
}

/// A frame that is dropped rather than delivered. Every case is loss the sender
/// is never told about — the channel has no reply path — so every one is
/// something the caller logs and counts (the counts surface in `tbd peer list`).
public enum PeerBridgeFrameRejection: LocalizedError, Equatable, Sendable {
    /// Encoded size exceeded `PeerBridgeFrameCodec.maxFrameBytes`. Dropped
    /// whole and counted, never truncated: a truncated frame is a frame that
    /// arrives looking valid while saying something the sender did not.
    case oversized(bytes: Int)
    /// Not JSON, or JSON that is not a frame of the kind it claims to be
    /// (a `peer` line missing its handle, a `hello` with no protocol number).
    case malformed
    /// The line declares a peer protocol that differs from the negotiated one.
    case protocolMismatch(frame: Int, negotiated: Int)

    public var errorDescription: String? {
        switch self {
        case .oversized(let bytes):
            return "peer bridge frame is \(bytes) bytes, over the \(PeerBridgeFrameCodec.maxFrameBytes)-byte cap; dropped rather than truncated"
        case .malformed:
            return "peer bridge frame was not decodable as any known line kind"
        case .protocolMismatch(let frame, let negotiated):
            return "peer bridge frame declares peer protocol \(frame), negotiated \(negotiated); dropped"
        }
    }
}

/// What one line of the stream turned out to be. Three outcomes rather than an
/// optional, because "nothing was wrong" and "a frame was lost" are different
/// facts and only one of them is worth counting.
public enum PeerBridgeFrameDecoding: Equatable, Sendable {
    case frame(PeerBridgeFrame)
    case skipped(PeerBridgeFrameSkip)
    case rejected(PeerBridgeFrameRejection)
}

// MARK: - Codec

/// Encodes and decodes `messages` lines, applying the size cap and the protocol
/// gate. It never logs and never throws out of a parse loop: decoding returns an
/// outcome the caller logs and counts, so one bad line costs one line — the same
/// rule `RemoteEventParser` follows on the `events` stream.
public enum PeerBridgeFrameCodec {
    /// The peer protocol this build speaks, and so the number TBD declares in
    /// its own `hello`.
    public static let peerProtocol = 1

    /// Keepalive cadence, and the silence after which the link is dead. The
    /// same 1:3 ratio the `events` stream uses at 30/90, tightened because the
    /// cost of staleness here is a session sending into a void rather than a
    /// stale badge. Stated here so both halves of the link read one number.
    public static let keepaliveInterval: TimeInterval = 10
    public static let silenceLimit: TimeInterval = 30

    /// Largest encoded frame, newline excluded.
    ///
    /// The number is set by the reader on the other end of the pipe, not by
    /// anything about a message: `PipeLineReader` in `ProviderEventsSupervisor`
    /// caps its un-newlined buffer at 1 MB (`maxPendingBytes = 1 << 20`) and
    /// **discards the whole buffer** once past it, logging only the *first*
    /// overflow per reader — so every subsequent loss there is invisible. The
    /// cap therefore sits at half that, well below the size at which loss stops
    /// being reportable, and an oversized frame is refused *here*, once, with a
    /// reason the caller can count.
    public static let maxFrameBytes = 512 * 1024

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Deterministic key order so an encoded line is comparable, and no
        // escaped slashes so a URL-bearing message does not pay for them.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Encode one frame as a single NDJSON line's worth of bytes, with no
    /// trailing newline.
    ///
    /// Throws `PeerBridgeFrameRejection.oversized` rather than truncating. JSON
    /// string escaping guarantees the result contains no raw newline, so the
    /// caller may frame it by appending one.
    public static func encode(_ frame: PeerBridgeFrame) throws -> Data {
        let data = try encoder.encode(frame)
        guard data.count <= maxFrameBytes else {
            throw PeerBridgeFrameRejection.oversized(bytes: data.count)
        }
        return data
    }

    /// `encode(_:)` plus the newline that frames it on the wire. The cap applies
    /// to the JSON, not to this string.
    public static func encodeLine(_ frame: PeerBridgeFrame) throws -> String {
        let data = try encode(frame)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PeerBridgeFrameRejection.malformed
        }
        return json + "\n"
    }

    /// Read just far enough to name the line kind, the way `RemoteEventParser`
    /// reads `event` — so an unknown kind is recognised as forward
    /// compatibility before any of the rest of the line is interpreted.
    private struct KindEnvelope: Decodable {
        let kind: String
    }

    /// Decode one line of the stream.
    ///
    /// `negotiatedProtocol` is the peer protocol the link agreed on, and it has
    /// no default on purpose: the gate it drives is the difference between
    /// delivering a frame and dropping it, so every call site states it. Both
    /// lines that declare a protocol are gated — a `hello` answering with a
    /// different number never negotiated, and a `peer` announcing a session that
    /// speaks a different number announced one this side cannot address. Those
    /// two are the whole gate, because a `message` declares no protocol: it
    /// rides a link whose `hello` matched, addressed to a handle a matching
    /// `peer` line announced.
    public static func decode(line: String, negotiatedProtocol: Int) -> PeerBridgeFrameDecoding {
        // `.whitespacesAndNewlines`, not `.whitespaces`: a line may still carry
        // the newline that framed it, or a `\r\n` pair from a provider that
        // terminates its NDJSON that way. Neither reduces to empty under
        // `.whitespaces`, so a blank keepalive would decode as `.malformed` and
        // be counted against the peer as a dropped frame.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skipped(.blankLine) }
        guard let data = trimmed.data(using: .utf8) else { return .rejected(.malformed) }
        // Checked before parsing: an oversized line is refused on its size, not
        // on whether it happens to be well-formed.
        guard data.count <= maxFrameBytes else {
            return .rejected(.oversized(bytes: data.count))
        }
        guard let envelope = try? JSONDecoder().decode(KindEnvelope.self, from: data) else {
            return .rejected(.malformed)
        }
        guard PeerBridgeFrame.Kind(rawValue: envelope.kind) != nil else {
            return .skipped(.unrecognizedKind(envelope.kind))
        }
        let frame: PeerBridgeFrame
        do {
            frame = try JSONDecoder().decode(PeerBridgeFrame.self, from: data)
        } catch let skip as PeerBridgeFrameSkip {
            return .skipped(skip)
        } catch {
            return .rejected(.malformed)
        }
        if let declared = frame.declaredProtocol, declared != negotiatedProtocol {
            return .rejected(
                .protocolMismatch(frame: declared, negotiated: negotiatedProtocol))
        }
        return .frame(frame)
    }
}
