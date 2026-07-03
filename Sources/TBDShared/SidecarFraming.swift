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
public enum SidecarFrameType: UInt8, Sendable {
    case fdVend = 1
    case input = 2
    case paste = 3
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

/// Errors from decoding an input frame payload.
public enum SidecarFramingError: Error, Equatable {
    case truncatedPayload      // payload ended before the declared header/bytes
    case undecodableHeader     // header sub-region wasn't valid JSON
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
    /// Pastes LARGER than this are NOT split across frames (the M2 ruling's
    /// rider 2): the app falls back to SwiftTerm's normal keystroke-path paste
    /// — correct, just slower — rather than fragmenting a paste across the
    /// ordered channel.
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
    private static func encodeSubPayload(header: SidecarInputHeader, bytes: Data) throws -> Data {
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

    /// Decode a tagged (`.input`/`.paste`) frame's payload back into its header
    /// and raw bytes. Throws `SidecarFramingError` on a truncated or undecodable
    /// payload. The sub-format is type-agnostic — one decoder serves both.
    public static func decodeTagged(payload: Data) throws -> (header: SidecarInputHeader, bytes: Data) {
        guard payload.count >= 4 else { throw SidecarFramingError.truncatedPayload }
        let headerLength = Int(readUInt32LE(payload, at: 0))
        guard payload.count >= 4 + headerLength else { throw SidecarFramingError.truncatedPayload }
        let headerStart = payload.startIndex + 4
        let headerEnd = headerStart + headerLength
        // Copy the slices so JSON decoding and the returned bytes are rebased
        // to zero, independent of the parent buffer's offsets.
        let headerData = Data(payload[headerStart..<headerEnd])
        guard let header = try? JSONDecoder().decode(SidecarInputHeader.self, from: headerData) else {
            throw SidecarFramingError.undecodableHeader
        }
        let bytes = Data(payload[headerEnd..<payload.endIndex])
        return (header, bytes)
    }

    /// Decode an `.input` frame's payload (alias of `decodeTagged`).
    public static func decodeInput(payload: Data) throws -> (header: SidecarInputHeader, bytes: Data) {
        try decodeTagged(payload: payload)
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
