import Foundation
import Testing
@testable import TBDShared

/// Unit tests for the length-prefixed sidecar wire framing (M2.1). Covers the
/// scanner's partial-frame buffering (the split-header regression the old
/// unframed sidecar could not survive) and the input codec round-trip.
@Suite("SidecarFraming")
struct SidecarFramingTests {

    // Build the outer frame bytes for a given type + payload without going
    // through the codec, so scanner tests are independent of encode().
    private func frame(type: UInt8, payload: Data) -> Data {
        var out = Data()
        let len = UInt32(1 + payload.count)
        out.append(UInt8(len & 0xff))
        out.append(UInt8((len >> 8) & 0xff))
        out.append(UInt8((len >> 16) & 0xff))
        out.append(UInt8((len >> 24) & 0xff))
        out.append(type)
        out.append(payload)
        return out
    }

    // MARK: Scanner

    @Test("one exact frame yields one frame")
    func oneExactFrame() {
        let scanner = SidecarFrameScanner()
        let frames = scanner.append(frame(type: 1, payload: Data("hello".utf8)))
        #expect(frames.count == 1)
        #expect(frames[0].type == 1)
        #expect(frames[0].payload == Data("hello".utf8))
        #expect(!scanner.isDesynced)
    }

    @Test("a frame delivered byte-by-byte still assembles (split-frame regression)")
    func byteByByte() {
        let scanner = SidecarFrameScanner()
        let full = frame(type: 2, payload: Data("keystroke".utf8))
        var collected: [(type: UInt8, payload: Data)] = []
        for byte in full {
            collected.append(contentsOf: scanner.append(Data([byte])))
        }
        #expect(collected.count == 1)
        #expect(collected[0].type == 2)
        #expect(collected[0].payload == Data("keystroke".utf8))
        #expect(!scanner.isDesynced)
    }

    @Test("three frames in one append arrive in order")
    func threeFramesOneAppend() {
        let scanner = SidecarFrameScanner()
        var blob = Data()
        blob.append(frame(type: 1, payload: Data("a".utf8)))
        blob.append(frame(type: 2, payload: Data("bb".utf8)))
        blob.append(frame(type: 1, payload: Data("ccc".utf8)))
        let frames = scanner.append(blob)
        #expect(frames.count == 3)
        #expect(frames[0].payload == Data("a".utf8))
        #expect(frames[1].payload == Data("bb".utf8))
        #expect(frames[2].payload == Data("ccc".utf8))
    }

    @Test("frame split across appends at every boundary (incl. mid-length-field)")
    func splitAtEveryBoundary() {
        let full = frame(type: 2, payload: Data("payload-bytes".utf8))
        for cut in 1..<full.count {
            let scanner = SidecarFrameScanner()
            var collected: [(type: UInt8, payload: Data)] = []
            collected.append(contentsOf: scanner.append(full.prefix(cut)))
            collected.append(contentsOf: scanner.append(full.suffix(from: full.startIndex + cut)))
            #expect(collected.count == 1, "cut at \(cut) lost the frame")
            #expect(collected.first?.payload == Data("payload-bytes".utf8), "cut at \(cut) corrupted payload")
        }
    }

    @Test("unknown type bytes are passed through, not dropped")
    func unknownTypePassthrough() {
        let scanner = SidecarFrameScanner()
        let frames = scanner.append(frame(type: 99, payload: Data("x".utf8)))
        #expect(frames.count == 1)
        #expect(frames[0].type == 99)
        #expect(!scanner.isDesynced)
    }

    @Test("frameLength exactly AT the 4 MiB cap is a valid frame, not a desync")
    func frameLengthAtCapPasses() {
        let scanner = SidecarFrameScanner()
        // frameLength covers the type byte: cap-sized frame = type + (cap-1)
        // payload bytes. The cap is INCLUSIVE — `> cap` desyncs, `== cap`
        // must scan cleanly (exact-boundary regression test).
        let cap = 4 * 1024 * 1024
        var blob = Data()
        let declared = UInt32(cap)
        blob.append(UInt8(declared & 0xff))
        blob.append(UInt8((declared >> 8) & 0xff))
        blob.append(UInt8((declared >> 16) & 0xff))
        blob.append(UInt8((declared >> 24) & 0xff))
        blob.append(7)   // type byte
        blob.append(Data(count: cap - 1))
        let frames = scanner.append(blob)
        #expect(frames.count == 1)
        #expect(frames.first?.type == 7)
        #expect(frames.first?.payload.count == cap - 1)
        #expect(!scanner.isDesynced)
    }

    @Test("frameLength of cap + 1 desyncs (exact boundary of the corruption check)")
    func frameLengthJustOverCapDesyncs() {
        let scanner = SidecarFrameScanner()
        let cap = 4 * 1024 * 1024
        var blob = Data()
        let declared = UInt32(cap + 1)
        blob.append(UInt8(declared & 0xff))
        blob.append(UInt8((declared >> 8) & 0xff))
        blob.append(UInt8((declared >> 16) & 0xff))
        blob.append(UInt8((declared >> 24) & 0xff))
        blob.append(contentsOf: [0x01, 0x02])   // a few bytes; length alone must trip it
        let frames = scanner.append(blob)
        #expect(frames.isEmpty)
        #expect(scanner.isDesynced)
        // Terminal: nothing ever comes back after the corrupt length.
        #expect(scanner.append(Data([0x00])).isEmpty)
    }

    @Test("an oversized declared length flags desync without allocating or crashing")
    func oversizedLengthDesyncs() {
        let scanner = SidecarFrameScanner()
        // Declare a 100 MiB frame — far past the 4 MiB cap.
        var blob = Data()
        let bogus = UInt32(100 * 1024 * 1024)
        blob.append(UInt8(bogus & 0xff))
        blob.append(UInt8((bogus >> 8) & 0xff))
        blob.append(UInt8((bogus >> 16) & 0xff))
        blob.append(UInt8((bogus >> 24) & 0xff))
        blob.append(contentsOf: [0x01, 0x02, 0x03])   // a few payload bytes, nowhere near declared size
        let frames = scanner.append(blob)
        #expect(frames.isEmpty)
        #expect(scanner.isDesynced)
        // Further appends yield nothing once desynced.
        #expect(scanner.append(Data([0x00, 0x00])).isEmpty)
    }

    // MARK: Codec

    @Test("encodeInput/decodeInput round-trips header and bytes")
    func inputRoundTrip() throws {
        let header = SidecarInputHeader(worktreeID: UUID(), paneID: "%42")
        let bytes = Data("echo hi\r".utf8)
        let frameBytes = try SidecarFrameCodec.encodeInput(header: header, bytes: bytes)

        // The outer frame decodes to type .input; its payload decodes back.
        let scanner = SidecarFrameScanner()
        let frames = scanner.append(frameBytes)
        #expect(frames.count == 1)
        #expect(frames[0].type == SidecarFrameType.input.rawValue)
        let (decodedHeader, decodedBytes) = try SidecarFrameCodec.decodeInput(payload: frames[0].payload)
        #expect(decodedHeader == header)
        #expect(decodedBytes == bytes)
    }

    @Test("encodeInput round-trips empty bytes and multibyte pane strings")
    func inputRoundTripEdgeCases() throws {
        let header = SidecarInputHeader(worktreeID: UUID(), paneID: "%窓-🚀")
        let frameBytes = try SidecarFrameCodec.encodeInput(header: header, bytes: Data())
        let scanner = SidecarFrameScanner()
        let frames = scanner.append(frameBytes)
        #expect(frames.count == 1)
        let (decodedHeader, decodedBytes) = try SidecarFrameCodec.decodeInput(payload: frames[0].payload)
        #expect(decodedHeader == header)
        #expect(decodedBytes.isEmpty)
    }

    @Test("decodeInput throws on a truncated payload")
    func decodeInputTruncated() {
        // A payload shorter than the 4-byte header-length prefix.
        #expect(throws: SidecarFramingError.self) {
            _ = try SidecarFrameCodec.decodeInput(payload: Data([0x00, 0x01]))
        }
        // A payload whose declared header length exceeds the bytes present.
        var truncated = Data()
        truncated.append(contentsOf: [0xff, 0x00, 0x00, 0x00])   // claims 255-byte header
        truncated.append(contentsOf: [0x7b, 0x7d])               // but only "{}" follows
        #expect(throws: SidecarFramingError.self) {
            _ = try SidecarFrameCodec.decodeInput(payload: truncated)
        }
    }

    @Test("encodePaste/decodeTagged round-trips header and bytes over a .paste frame")
    func pasteRoundTrip() throws {
        let header = SidecarInputHeader(worktreeID: UUID(), paneID: "%7")
        let bytes = Data("a large pasted blob".utf8)
        let frameBytes = try SidecarFrameCodec.encodePaste(header: header, bytes: bytes)

        let scanner = SidecarFrameScanner()
        let frames = scanner.append(frameBytes)
        #expect(frames.count == 1)
        #expect(frames[0].type == SidecarFrameType.paste.rawValue)
        let (decodedHeader, decodedBytes) = try SidecarFrameCodec.decodeTagged(payload: frames[0].payload)
        #expect(decodedHeader == header)
        #expect(decodedBytes == bytes)
    }

    @Test(".input and .paste share one sub-format: same sub-payload, only the outer type byte differs")
    func sharedSubFormatEquivalence() {
        // Wrap ONE shared sub-payload under both types via the public outer
        // encoder — this proves "same sub-format, different tag" without
        // depending on two independent JSONEncoder runs being byte-identical.
        let subPayload = Data("shared-sub-format-bytes".utf8)
        let inputFrame = SidecarFrameCodec.encode(type: .input, payload: subPayload)
        let pasteFrame = SidecarFrameCodec.encode(type: .paste, payload: subPayload)

        #expect(inputFrame.count == pasteFrame.count)
        #expect(inputFrame[4] == SidecarFrameType.input.rawValue)
        #expect(pasteFrame[4] == SidecarFrameType.paste.rawValue)
        // Everything before and after the type byte is byte-identical.
        #expect(inputFrame.prefix(4) == pasteFrame.prefix(4))
        #expect(inputFrame.suffix(from: inputFrame.startIndex + 5)
            == pasteFrame.suffix(from: pasteFrame.startIndex + 5))
    }

    @Test("encodeInput and encodePaste round-trip the same header+bytes through one decoder")
    func inputPasteDecodeEquivalence() throws {
        let header = SidecarInputHeader(worktreeID: UUID(), paneID: "%same")
        let bytes = Data("identical payload".utf8)
        let inputFrame = try SidecarFrameCodec.encodeInput(header: header, bytes: bytes)
        let pasteFrame = try SidecarFrameCodec.encodePaste(header: header, bytes: bytes)

        // decodeTagged decodes either frame's payload back to the same values.
        let scanner = SidecarFrameScanner()
        let inFrames = scanner.append(inputFrame)
        let paFrames = scanner.append(pasteFrame)
        let decodedIn = try SidecarFrameCodec.decodeTagged(payload: inFrames[0].payload)
        let decodedPa = try SidecarFrameCodec.decodeTagged(payload: paFrames[0].payload)
        #expect(decodedIn.header == header)
        #expect(decodedPa.header == header)
        #expect(decodedIn.bytes == bytes)
        #expect(decodedPa.bytes == bytes)
    }

    @Test("a maxPasteBytes payload's encoded frame stays under the 4 MiB scanner cap")
    func maxPasteBytesHeadroom() throws {
        // Construct the frame length arithmetic cheaply — no 4 MiB allocation.
        // Outer frameLength = 1 (type) + 4 (headerLen prefix) + headerJSON + payload.
        let header = SidecarInputHeader(worktreeID: UUID(), paneID: "%0")
        let headerJSONCount = try JSONEncoder().encode(header).count
        let encodedFrameOuterLength = 1 + 4 + headerJSONCount + SidecarFrameCodec.maxPasteBytes
        // The scanner rejects a declared frameLength > 4 MiB; our worst case must
        // sit strictly under it (the cap carries 64 KiB of headroom for exactly
        // this header + framing overhead).
        let scannerCap = 4 * 1024 * 1024
        #expect(encodedFrameOuterLength < scannerCap)
        // And the total wire frame (4-byte length prefix + outer) is also under cap.
        #expect(4 + encodedFrameOuterLength < scannerCap + 4)
    }

    @Test("encode produces the documented [len][type][payload] layout")
    func encodeLayout() {
        let payload = Data("hi".utf8)
        let encoded = SidecarFrameCodec.encode(type: .fdVend, payload: payload)
        #expect(encoded.count == 4 + 1 + payload.count)
        // frameLength covers the type byte: 1 + payload.count.
        let len = UInt32(encoded[0]) | (UInt32(encoded[1]) << 8)
            | (UInt32(encoded[2]) << 16) | (UInt32(encoded[3]) << 24)
        #expect(len == UInt32(1 + payload.count))
        #expect(encoded[4] == SidecarFrameType.fdVend.rawValue)
    }
}
