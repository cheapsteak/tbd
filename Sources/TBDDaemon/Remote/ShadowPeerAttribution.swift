import Darwin
import Foundation
import os

private let shadowPeerLogger = Logger(subsystem: "com.tbd.daemon", category: "shadowPeer")

// MARK: - Attribution

/// Composes the `<cross-session-message …>` wrapper TBD stamps on every frame
/// arriving from a remote peer, and the agent frame that carries it into a
/// local session's socket.
///
/// **Attribution is stamped locally and never forwarded.** Claude Code's
/// wrapper is composed by the *sender's* client and travels inside the message
/// content, so a remote peer otherwise controls `from-name` and `from-mode`
/// outright: it could name itself as one of your local sessions and claim
/// `bypass` to satisfy an inbound policy. So the whole opening tag is replaced,
/// unconditionally, on every inbound frame — never inspected and patched, never
/// trusted when it "looks right"
/// (`docs/specs/2026-08-29-remote-peer-messaging-design.md` § "Trust").
///
/// **Everything after the opening tag survives byte for byte.** The design's
/// rule is that message content passes verbatim and *only* attribution is
/// rewritten, so this type replaces exactly the span from the content's first
/// character through the `>` that closes the opening tag, and copies the rest
/// of the string unexamined. It does not re-wrap, re-indent, trim, or normalise
/// anything, and it never searches the interior — a body that quotes a
/// `</cross-session-message>` of its own keeps it.
///
/// The stamp is not a claim that the content is safe. Remote message content
/// stays untrusted teammate input exactly as local peer content already is;
/// what the stamp buys is that it cannot *impersonate* a local teammate.
public enum ShadowPeerAttribution {
    /// The wrapper's element name, without its closing angle bracket.
    public static let openTagName = "<cross-session-message"
    /// The wrapper's closing tag, written only when the far side sent content
    /// with no wrapper of its own.
    public static let closeTag = "</cross-session-message>"

    /// The permission class TBD grants a remote peer, written as `from-mode`.
    ///
    /// **`default`, deliberately the least of the classes.** The attribute
    /// tells the receiving session what the sender was permitted to do, and a
    /// remote peer is granted nothing beyond being able to speak: TBD confers
    /// no elevated permission on the far side, so claiming one here would be
    /// the exact misstatement the stamp exists to prevent. The observed value
    /// on a real local send is `bypass`, which is what a locally-running
    /// session in bypass mode reports about *itself* — it is not a value TBD
    /// may pass on for somebody else.
    public static let grantedMode = "default"

    /// Replace the content's attribution with TBD's own.
    ///
    /// - Parameters:
    ///   - content: what arrived on the wire, byte-verbatim.
    ///   - senderAddress: the `uds:` address of the **shadow peer's own
    ///     socket** — the local stand-in for the remote sender. This is the
    ///     reply path: a session that answers writes to this address, reaches
    ///     the helper, and the frame goes back out over the link. It is a local
    ///     path and stays local; nothing derived from the wire appears here.
    ///   - senderName: the shadow peer's namespaced name.
    ///   - mode: the permission class TBD grants, `grantedMode` unless a caller
    ///     has a reason.
    public static func stamp(
        content: String, senderAddress: String, senderName: String,
        mode: String = ShadowPeerAttribution.grantedMode
    ) -> String {
        let tag = openTag(senderAddress: senderAddress, senderName: senderName, mode: mode)
        guard let end = openTagEnd(in: content) else {
            // No wrapper of its own: wrap it. The newlines match the shape a
            // real Claude Code send composes, and are the only bytes added.
            return tag + "\n" + content + "\n" + closeTag
        }
        return tag + String(content[content.index(after: end)...])
    }

    /// The opening tag TBD writes. Separate from `stamp` so a test can assert
    /// the composed tag in one place rather than re-deriving it.
    public static func openTag(
        senderAddress: String, senderName: String,
        mode: String = ShadowPeerAttribution.grantedMode
    ) -> String {
        "\(openTagName) from=\"\(escaped(senderAddress))\""
            + " from-name=\"\(escaped(senderName))\""
            + " from-mode=\"\(escaped(mode))\">"
    }

    /// Escapes a value for an attribute position.
    ///
    /// Load-bearing rather than cosmetic: a worktree display name is
    /// user-authored, so an unescaped `"` in one would close the attribute and
    /// let the rest of the name write attributes of its own — a display name of
    /// `x" from-mode="bypass` would otherwise forge the very field this type
    /// exists to control. `&` is replaced first so the escapes it introduces
    /// are not themselves re-escaped.
    public static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The index of the `>` that closes a leading opening tag, or nil when the
    /// content does not begin with one.
    ///
    /// Quote-aware on purpose: an attribute value may legally contain `>`, and
    /// a naive `firstIndex(of: ">")` would split inside one and spill the tail
    /// of the far side's tag into the message body. It is not a security hole —
    /// attribution is replaced either way — but it would corrupt a body this
    /// type promises to leave alone.
    static func openTagEnd(in content: String) -> String.Index? {
        guard content.hasPrefix(openTagName) else { return nil }
        var index = content.index(content.startIndex, offsetBy: openTagName.count)
        // `<cross-session-messageX` is a different element, not this one.
        guard index < content.endIndex else { return nil }
        let following = content[index]
        guard following == ">" || following.isWhitespace else { return nil }
        var quoted = false
        while index < content.endIndex {
            let character = content[index]
            if character == "\"" {
                quoted.toggle()
            } else if character == ">" && !quoted {
                return index
            }
            index = content.index(after: index)
        }
        return nil
    }
}

// MARK: - The agent frame

/// Claude Code's own message frame, composed locally around content that
/// arrived over the bridge.
///
/// **The far side sends none of this.** `PeerBridgeMessage` deliberately
/// carries no agent frame internals: putting one agent's frame shape into a
/// provider-facing contract would let the far side choose fields the receiving
/// side is answerable for. So `msgV`, the message id, the type and the priority
/// are all stamped here, and the only thing that crosses from the wire is
/// `content` — after `ShadowPeerAttribution.stamp` has replaced its
/// attribution.
public struct ShadowPeerAgentFrame: Encodable, Sendable, Equatable {
    /// Claude Code's own frame version, captured from a live `SendMessage`
    /// (`docs/research/2026-08-29-cross-machine-messaging/findings.md` § T1).
    ///
    /// **Not the peer-bridge protocol number**, even though both are currently
    /// `1`. `PeerBridgeFrameCodec.peerProtocol` versions the contract between
    /// TBD and a provider; this versions a frame belonging to the agent, whose
    /// interior neither side of that contract reaches into. They are free to
    /// move independently and one day will.
    public static let messageVersion = 1
    /// `type` on every peer send observed.
    public static let userType = "user"
    /// `priority` on every peer send observed. The vocabulary is Claude Code's
    /// and this is the only value the capture showed, so it is stamped rather
    /// than chosen.
    public static let nextPriority = "next"
    /// `message.role` on every peer send observed.
    public static let userRole = "user"

    /// The reply path: a `uds:` address naming the shadow peer's own socket.
    public let from: String
    /// The stamped content, wrapper included.
    public let content: String
    /// Claude Code's own message id, minted here. Unrelated to the bridge
    /// frame's correlation id, which names the wire hop and nothing inside it.
    public let messageID: String

    public init(from: String, content: String, messageID: String) {
        self.from = from
        self.content = content
        self.messageID = messageID
    }

    enum CodingKeys: String, CodingKey {
        case messageVersion = "msgV"
        case messageID = "msg_id"
        case type
        case priority
        case from
        case message
    }

    enum MessageKeys: String, CodingKey {
        case role
        case content
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.messageVersion, forKey: .messageVersion)
        try c.encode(messageID, forKey: .messageID)
        try c.encode(Self.userType, forKey: .type)
        try c.encode(Self.nextPriority, forKey: .priority)
        try c.encode(from, forKey: .from)
        var message = c.nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
        try message.encode(Self.userRole, forKey: .role)
        try message.encode(content, forKey: .content)
    }

    /// The bytes to write into a local session's socket. Deterministic key
    /// order so a test can assert the whole composed payload rather than
    /// spot-checking fields out of it.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - Delivery into a local session

/// Writes one composed agent frame into a local session's messaging socket.
///
/// A protocol rather than a free function because it is the one step in the
/// inbound path that touches the machine: a test drives every routing, handle
/// and attribution decision through a fake and never binds a socket in the
/// `/tmp/cc-socks` every real session on this machine reads.
public protocol LocalPeerDelivering: Sendable {
    /// Connect, write every byte, close. Throws when the socket refuses,
    /// is gone, or will not take the write — which the caller counts as a
    /// drop, because the channel has no reply path to report it on.
    func deliver(_ payload: Data, toSocketPath path: String) async throws
}

/// The production `LocalPeerDelivering`: connect-write-close on an `AF_UNIX`
/// `SOCK_STREAM`, which is the whole of Claude Code's local transport — one
/// connection per message, no handshake, no ack
/// (`docs/research/2026-08-29-cross-machine-messaging/findings.md` § T1).
///
/// The syscalls run on a dedicated serial queue rather than on the caller's
/// actor. A `connect(2)` to a Unix socket whose listener has a full backlog
/// blocks, and blocking an actor's executor is the starvation class
/// `ProviderEventsSupervisor` documents at length; hopping costs one context
/// switch per message on a channel whose traffic is, by design, aggregate and
/// small.
public struct UnixSocketLocalPeerDelivery: LocalPeerDelivering {
    /// How long a write may take before the frame is abandoned.
    ///
    /// A **socket option** (`SO_SNDTIMEO`), not a scheduled delay, so it is a
    /// plain `TimeInterval` rather than something an injected `Clock` could
    /// drive — the same shape, and for the same reason, as
    /// `PeerHelper.connectionReadTimeout` on the other half of this feature.
    /// A healthy receiver takes a frame in microseconds.
    public let writeTimeout: TimeInterval

    private let queue = DispatchQueue(label: "com.tbd.daemon.shadowPeerDelivery")

    public init(writeTimeout: TimeInterval = 2) {
        self.writeTimeout = writeTimeout
    }

    public func deliver(_ payload: Data, toSocketPath path: String) async throws {
        let timeout = writeTimeout
        try await withCheckedThrowingContinuation { (continuation: WriteContinuation) in
            queue.async {
                do {
                    try Self.write(payload, to: path, timeout: timeout)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Named so the continuation's type can sit on the closure's opening line.
    private typealias WriteContinuation = CheckedContinuation<Void, any Error>

    private static func write(_ payload: Data, to path: String, timeout: TimeInterval) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < sunPathSize else {
            throw LocalPeerDeliveryError.pathTooLong(path: path, limit: sunPathSize - 1)
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { chars in
                    _ = strlcpy(chars, source, sunPathSize)
                }
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalPeerDeliveryError.socketUnavailable(path: path, errno: errno)
        }
        defer { Darwin.close(fd) }

        var sendTimeout = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                   socklen_t(MemoryLayout<timeval>.size))

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, length)
            }
        }
        guard connected == 0 else {
            // ECONNREFUSED here is the *designed* signal that a peer is gone:
            // a listener that has been closed and unlinked is what makes a
            // sender see the same failure as a session that exited.
            throw LocalPeerDeliveryError.connectFailed(path: path, errno: errno)
        }

        var offset = 0
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                throw LocalPeerDeliveryError.writeFailed(path: path, errno: errno)
            }
        }
    }
}

/// Failures writing into a local session's socket. Every one is a frame the
/// sender is never told about, so every one is counted by the caller.
public enum LocalPeerDeliveryError: LocalizedError, Equatable, Sendable {
    case pathTooLong(path: String, limit: Int)
    case socketUnavailable(path: String, errno: Int32)
    case connectFailed(path: String, errno: Int32)
    case writeFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path, let limit):
            return "peer socket path \(path) is longer than sun_path allows (\(limit) bytes)"
        case .socketUnavailable(let path, let code):
            return "could not create a socket to reach \(path): \(Self.describe(code))"
        case .connectFailed(let path, let code):
            return "could not connect to \(path): \(Self.describe(code))"
        case .writeFailed(let path, let code):
            return "could not write to \(path): \(Self.describe(code))"
        }
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
