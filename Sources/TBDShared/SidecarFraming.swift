import Foundation

/// Frame discriminator for the bidirectional sidecar data channel (M2.1).
/// daemon → app carries `.fdVend` (a JSON `FDVendHeader` alongside an
/// `SCM_RIGHTS` fd); app → daemon carries `.input` (keystroke/paste bytes
/// tagged with a `SidecarInputHeader`).
public enum SidecarFrameType: UInt8, Sendable {
    case fdVend = 1
    case input = 2
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
/// Input payload sub-format: `[UInt32 LE headerLength][JSON header][raw bytes]`.
public enum SidecarFrameCodec {

    /// Wrap `payload` in an outer frame with the given `type`.
    public static func encode(type: SidecarFrameType, payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        appendUInt32LE(&out, UInt32(1 + payload.count))
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    /// Encode an input frame: JSON-encode `header`, prefix it with its length,
    /// append `bytes`, then wrap the whole thing in a `.input` outer frame.
    public static func encodeInput(header: SidecarInputHeader, bytes: Data) throws -> Data {
        let headerJSON = try JSONEncoder().encode(header)
        var payload = Data(capacity: 4 + headerJSON.count + bytes.count)
        appendUInt32LE(&payload, UInt32(headerJSON.count))
        payload.append(headerJSON)
        payload.append(bytes)
        return encode(type: .input, payload: payload)
    }

    /// Decode an input frame's payload back into its header and raw bytes.
    /// Throws `SidecarFramingError` on a truncated or undecodable payload.
    public static func decodeInput(payload: Data) throws -> (header: SidecarInputHeader, bytes: Data) {
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
