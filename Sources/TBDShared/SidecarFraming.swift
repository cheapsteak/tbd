import Foundation

/// Frame discriminator for the bidirectional sidecar data channel (M2.1).
/// daemon → app carries `.fdVend` (a JSON `FDVendHeader` alongside an
/// `SCM_RIGHTS` fd); app → daemon carries `.input` (keystroke bytes) and
/// `.paste` (bulk paste bytes), both tagged with a `SidecarInputHeader`.
///
/// `.input` and `.paste` share ONE payload sub-format and ride the SAME
/// ordered channel: a paste and a following keystroke are FIFO-ordered
/// end-to-end (the M2 paste ruling — the daemon runs the paste through the
/// correlator so a keystroke enqueued after it lands strictly after).
///
/// `.injection` (daemon → app) and `.injectionAck` (app → daemon) carry a
/// daemon-originated write for a holder-backed session whose pty a viewer
/// owns, and the app's answer about whether it wrote it. They ride the same
/// ordered channel and reuse the same tagged sub-format, with their own
/// header type.
///
/// **Adding a case here is cheap in both directions.** Both receive loops
/// return an unrecognized type byte rather than desyncing (see
/// `SidecarFrameScanner.append` and the `SidecarFrameType(rawValue:)` guards
/// in `FDSidecarClient.receiveLoop` / `FDVendingServer.startReceiveThread`),
/// so a peer built before a case existed skips the frame and logs it. That
/// forward-compat seam is why the injection path could be a new frame type
/// rather than a new socket.
public enum SidecarFrameType: UInt8, Sendable {
    case fdVend = 1
    case input = 2
    case paste = 3
    case injection = 4
    case injectionAck = 5
}

/// Header prefixing every app → daemon input frame: identifies which pane the
/// keystroke bytes belong to. `paneID` is only unique within one tmux server,
/// so the daemon resolves `worktreeID` → server before issuing `send-keys`.
public struct SidecarInputHeader: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let paneID: String
    public init(worktreeID: UUID, paneID: String) {
        self.worktreeID = worktreeID
        self.paneID = paneID
    }
}

/// Header prefixing every daemon → app injection frame.
///
/// `terminalID` names the session the bytes belong to, and it is the frame's
/// own address: the app verifies it against the panel it is about to write
/// to rather than inferring the destination from panel state. `injectionID`
/// is the correlation token the answering `SidecarInjectionAck` carries back,
/// so an ack that arrives after its injection's deadline can be recognized as
/// late instead of mistaken for another injection's.
public struct SidecarInjectionHeader: Codable, Sendable, Equatable {
    public let terminalID: UUID
    public let injectionID: UUID
    public init(terminalID: UUID, injectionID: UUID) {
        self.terminalID = terminalID
        self.injectionID = injectionID
    }
}

/// The app's answer to one injection.
///
/// `written` is a report, not a receipt: `false` means the app knows nothing
/// took the bytes and the daemon must write them itself, while `true` means
/// the app handed them to a transport. Neither value proves the child read
/// them, and the daemon's fail-open deadline — not this flag — is what covers
/// an ack that never comes.
public struct SidecarInjectionAck: Codable, Sendable, Equatable {
    public let injectionID: UUID
    public let written: Bool
    public init(injectionID: UUID, written: Bool) {
        self.injectionID = injectionID
        self.written = written
    }
}

/// Errors from decoding an input frame payload.
public enum SidecarFramingError: LocalizedError, Equatable {
    case truncatedPayload      // payload ended before the declared header/bytes
    case undecodableHeader     // header sub-region wasn't valid JSON

    public var errorDescription: String? {
        switch self {
        case .truncatedPayload:
            return "sidecar frame payload was truncated: it ended before the declared header length or byte count"
        case .undecodableHeader:
            return "sidecar frame header sub-region was not valid JSON"
        }
    }
}

/// Read a little-endian `UInt32` at `offset` bytes past `data.startIndex`.
/// Slice-safe: always indexes relative to `startIndex` so a `Data` sub-slice
/// (which keeps its parent's offsets) reads correctly.
private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    let i = data.startIndex + offset
    return UInt32(data[i])
        | (UInt32(data[i + 1]) << 8)
        | (UInt32(data[i + 2]) << 16)
        | (UInt32(data[i + 3]) << 24)
}

/// Append `value` as four little-endian bytes.
private func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}

/// Encoders/decoders for the sidecar wire format.
///
/// Outer frame: `[UInt32 LE frameLength][UInt8 type][payload]`, where
/// `frameLength = 1 + payload.count` (it covers the type byte).
///
/// Tagged payload sub-format (shared by `.input` and `.paste`):
/// `[UInt32 LE headerLength][JSON header][raw bytes]`.
public enum SidecarFrameCodec {

    /// Largest paste that rides a `.paste` frame. Sits under the scanner's 4 MiB
    /// hard cap with 64 KiB of headroom for the JSON header + outer framing, so
    /// even a max-size payload's encoded frame never trips `isDesynced`.
    ///
    /// Pastes LARGER than this are REFUSED at the app's view level — a
    /// user-visible error log, then the paste is dropped (the paste ruling v2).
    /// They are NOT split across frames (each `.paste` frame is its own
    /// `paste-buffer` call, which tmux would bracket as a separate paste), and
    /// they NEVER fall back to the keystroke path: SwiftTerm's bracketed-paste
    /// tracking can be stale after a re-attach, so tmux must remain the sole
    /// bracketing authority while attached.
    public static let maxPasteBytes = 4 * 1024 * 1024 - 64 * 1024

    /// Wrap `payload` in an outer frame with the given `type`.
    public static func encode(type: SidecarFrameType, payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        appendUInt32LE(&out, UInt32(1 + payload.count))
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    /// Build the shared sub-payload: JSON-encode `header`, prefix it with its
    /// length, append `bytes`. The single sub-format implementation behind both
    /// `.input` and `.paste`.
    private static func encodeSubPayload<Header: Encodable>(header: Header, bytes: Data) throws -> Data {
        let headerJSON = try JSONEncoder().encode(header)
        var payload = Data(capacity: 4 + headerJSON.count + bytes.count)
        appendUInt32LE(&payload, UInt32(headerJSON.count))
        payload.append(headerJSON)
        payload.append(bytes)
        return payload
    }

    /// Encode a tagged frame (`.input` or `.paste`) around the shared sub-format.
    public static func encodeTagged(
        type: SidecarFrameType, header: SidecarInputHeader, bytes: Data) throws -> Data {
        encode(type: type, payload: try encodeSubPayload(header: header, bytes: bytes))
    }

    /// Encode a keystroke `.input` frame.
    public static func encodeInput(header: SidecarInputHeader, bytes: Data) throws -> Data {
        try encodeTagged(type: .input, header: header, bytes: bytes)
    }

    /// Encode a bulk `.paste` frame (same sub-format as `.input`).
    public static func encodePaste(header: SidecarInputHeader, bytes: Data) throws -> Data {
        try encodeTagged(type: .paste, header: header, bytes: bytes)
    }

    /// Decode a tagged frame's payload back into its header and raw bytes.
    /// Throws `SidecarFramingError` on a truncated or undecodable payload. The
    /// sub-format is header-type-agnostic — one decoder serves `.input`,
    /// `.paste` and `.injection`.
    private static func decodeSubPayload<Header: Decodable>(
        _ headerType: Header.Type, payload: Data
    ) throws -> (header: Header, bytes: Data) {
        guard payload.count >= 4 else { throw SidecarFramingError.truncatedPayload }
        let headerLength = Int(readUInt32LE(payload, at: 0))
        guard payload.count >= 4 + headerLength else { throw SidecarFramingError.truncatedPayload }
        let headerStart = payload.startIndex + 4
        let headerEnd = headerStart + headerLength
        // Copy the slices so JSON decoding and the returned bytes are rebased
        // to zero, independent of the parent buffer's offsets.
        let headerData = Data(payload[headerStart..<headerEnd])
        guard let header = try? JSONDecoder().decode(headerType, from: headerData) else {
            throw SidecarFramingError.undecodableHeader
        }
        let bytes = Data(payload[headerEnd..<payload.endIndex])
        return (header, bytes)
    }

    /// Decode an `.input`/`.paste` frame's payload back into its header and raw
    /// bytes.
    public static func decodeTagged(payload: Data) throws -> (header: SidecarInputHeader, bytes: Data) {
        try decodeSubPayload(SidecarInputHeader.self, payload: payload)
    }

    /// Decode an `.input` frame's payload (alias of `decodeTagged`).
    public static func decodeInput(payload: Data) throws -> (header: SidecarInputHeader, bytes: Data) {
        try decodeTagged(payload: payload)
    }

    /// Encode a daemon → app `.injection` frame: the same tagged sub-format as
    /// `.input`, over an injection header.
    public static func encodeInjection(
        header: SidecarInjectionHeader, bytes: Data) throws -> Data {
        encode(type: .injection, payload: try encodeSubPayload(header: header, bytes: bytes))
    }

    /// Decode an `.injection` frame's payload.
    public static func decodeInjection(
        payload: Data) throws -> (header: SidecarInjectionHeader, bytes: Data) {
        try decodeSubPayload(SidecarInjectionHeader.self, payload: payload)
    }

    /// Encode an app → daemon `.injectionAck` frame. The payload is the JSON ack
    /// alone — there are no raw bytes to carry, so it does not use the tagged
    /// sub-format.
    public static func encodeInjectionAck(_ ack: SidecarInjectionAck) throws -> Data {
        encode(type: .injectionAck, payload: try JSONEncoder().encode(ack))
    }

    /// Decode an `.injectionAck` frame's payload.
    public static func decodeInjectionAck(payload: Data) throws -> SidecarInjectionAck {
        guard let ack = try? JSONDecoder().decode(SidecarInjectionAck.self, from: payload) else {
            throw SidecarFramingError.undecodableHeader
        }
        return ack
    }
}

/// Reassembles length-prefixed frames from an arbitrarily-chunked byte stream.
///
/// NOT thread-safe — owned by a single receive thread. `append` buffers partial
/// frames across calls and returns every frame that completed, in order. Unknown
/// type bytes are still returned (the caller decides to skip + log, so a new
/// frame type never desyncs an old peer). A declared `frameLength` past the
/// 4 MiB hard cap flags `isDesynced`, drops the buffer, and returns no further
/// frames — a corrupt length must never drive an unbounded allocation.
public final class SidecarFrameScanner {
    /// Maximum plausible frame; a larger declared length is treated as stream
    /// corruption rather than a real (huge) allocation.
    private static let maxFrameLength = 4 * 1024 * 1024

    private var buffer = Data()

    /// Set once a corrupt length is seen. Terminal: no further frames are
    /// returned and the owning receive loop should tear the connection down.
    public private(set) var isDesynced = false

    public init() {}

    /// Append `data` and return every frame completed by it, in order.
    public func append(_ data: Data) -> [(type: UInt8, payload: Data)] {
        if isDesynced { return [] }
        buffer.append(data)

        var frames: [(type: UInt8, payload: Data)] = []
        while buffer.count >= 4 {
            let frameLength = readUInt32LE(buffer, at: 0)
            // frameLength covers the type byte, so it must be ≥ 1; anything
            // past the cap (or an impossible zero) is corruption.
            if frameLength < 1 || frameLength > UInt32(SidecarFrameScanner.maxFrameLength) {
                isDesynced = true
                buffer.removeAll(keepingCapacity: false)
                return frames
            }
            let totalLength = 4 + Int(frameLength)
            guard buffer.count >= totalLength else { break }   // wait for the rest

            let typeIndex = buffer.startIndex + 4
            let payloadStart = typeIndex + 1
            let payloadEnd = buffer.startIndex + totalLength
            let type = buffer[typeIndex]
            let payload = Data(buffer[payloadStart..<payloadEnd])   // copy → rebased to zero
            frames.append((type: type, payload: payload))

            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }
        return frames
    }
}
