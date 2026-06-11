import Testing
import Foundation
@testable import TBDShared

@Suite struct NewlineFrameScannerTests {

    // MARK: - Newline in first chunk

    @Test("newline in first chunk records correct index and trims frame")
    func newlineInFirstChunk() {
        var scanner = NewlineFrameScanner()
        let data = Data("hello\nworld".utf8)
        let found = scanner.append(data: data)
        #expect(found)
        #expect(scanner.hasNewline)
        #expect(scanner.newlineIndex == 5)
        #expect(scanner.frameData == Data("hello".utf8))
    }

    @Test("newline at very start of first chunk yields empty frame")
    func newlineAtStart() {
        var scanner = NewlineFrameScanner()
        scanner.append(data: Data([0x0A, 0x61, 0x62]))  // "\nab"
        #expect(scanner.hasNewline)
        #expect(scanner.newlineIndex == 0)
        #expect(scanner.frameData.isEmpty)
    }

    // MARK: - Newline split across multiple chunks

    @Test("newline arrives in chunk N — absolute index is correct")
    func newlineAcrossChunks() {
        var scanner = NewlineFrameScanner()
        // Chunk 1: "abc" — no newline
        let r1 = scanner.append(data: Data("abc".utf8))
        #expect(!r1)
        #expect(!scanner.hasNewline)
        // Chunk 2: "def" — no newline
        let r2 = scanner.append(data: Data("def".utf8))
        #expect(!r2)
        #expect(!scanner.hasNewline)
        // Chunk 3: "ghi\n" — newline at absolute offset 9
        let r3 = scanner.append(data: Data("ghi\n".utf8))
        #expect(r3)
        #expect(scanner.hasNewline)
        #expect(scanner.newlineIndex == 9)
        #expect(scanner.frameData == Data("abcdefghi".utf8))
    }

    @Test("many chunks before newline — correct index and frame content")
    func manyChunksBeforeNewline() {
        var scanner = NewlineFrameScanner()
        let chunkCount = 10
        let chunkSize = 8
        for i in 0..<chunkCount {
            let chunk = Data(repeating: UInt8(65 + i), count: chunkSize)  // 'A', 'B', ...
            let found = scanner.append(data: chunk)
            #expect(!found, "chunk \(i) should not contain newline")
        }
        // Final chunk: two payload bytes then newline, then trailing bytes
        let finalChunk = Data([0x58, 0x59, 0x0A, 0x5A, 0x5A])  // "XY\nZZ"
        scanner.append(data: finalChunk)
        #expect(scanner.hasNewline)
        #expect(scanner.newlineIndex == chunkCount * chunkSize + 2)
        // frameData must equal all prior chunks + "XY"
        var expected = Data()
        for i in 0..<chunkCount {
            expected.append(contentsOf: Array(repeating: UInt8(65 + i), count: chunkSize))
        }
        expected.append(contentsOf: [0x58, 0x59])  // "XY"
        #expect(scanner.frameData == expected)
    }

    // MARK: - Newline mid-chunk with trailing bytes

    @Test("newline mid-chunk — trailing bytes after newline are not included in frameData")
    func newlineMidChunkTrailingBytes() {
        var scanner = NewlineFrameScanner()
        // "hello\nworld\nmore" — first newline at offset 5
        scanner.append(data: Data("hello\nworld\nmore".utf8))
        #expect(scanner.hasNewline)
        #expect(scanner.newlineIndex == 5)
        #expect(scanner.frameData == Data("hello".utf8))
    }

    @Test("appending after newline is found does not change newlineIndex")
    func appendAfterNewlineDoesNotMove() {
        var scanner = NewlineFrameScanner()
        scanner.append(data: Data("abc\n".utf8))
        #expect(scanner.newlineIndex == 3)
        // Extra append — index must not shift
        scanner.append(data: Data("more\nbytes".utf8))
        #expect(scanner.newlineIndex == 3)
        #expect(scanner.frameData == Data("abc".utf8))
    }

    // MARK: - No newline (connection-closed semantics)

    @Test("no newline — frameData returns entire accumulated buffer")
    func noNewline() {
        var scanner = NewlineFrameScanner()
        let data = Data("hello world".utf8)
        let found = scanner.append(data: data)
        #expect(!found)
        #expect(!scanner.hasNewline)
        #expect(scanner.frameData == data)
    }

    @Test("empty scanner has no newline and empty frameData")
    func emptyScanner() {
        let scanner = NewlineFrameScanner()
        #expect(!scanner.hasNewline)
        #expect(scanner.newlineIndex == nil)
        #expect(scanner.frameData.isEmpty)
    }

    @Test("multiple chunks with no newline — full payload returned")
    func multipleChunksNoNewline() {
        var scanner = NewlineFrameScanner()
        let chunks = ["foo", "bar", "baz"].map { Data($0.utf8) }
        for chunk in chunks { scanner.append(data: chunk) }
        #expect(!scanner.hasNewline)
        #expect(scanner.frameData == Data("foobarbaz".utf8))
    }

    // MARK: - Multi-byte payload integrity

    @Test("multi-byte JSON payload roundtrip")
    func multiBytePayloadIntegrity() {
        var scanner = NewlineFrameScanner()
        let json = Data(#"{"success":true,"result":"{\"id\":\"abc\"}"}"#.utf8)
        scanner.append(data: json)
        scanner.append(data: Data([0x0A]))  // delimiter
        #expect(scanner.hasNewline)
        #expect(scanner.newlineIndex == json.count)
        #expect(scanner.frameData == json)
    }

    @Test("payload split at every byte boundary — frame always correct")
    func payloadSplitAtEveryByte() {
        let payload = Data("ABCDEFGHIJ\nKLMN".utf8)
        let expectedFrame = Data("ABCDEFGHIJ".utf8)
        // Try splitting the payload at each possible byte boundary
        for splitAt in 1..<payload.count {
            var scanner = NewlineFrameScanner()
            scanner.append(data: payload[..<splitAt])
            scanner.append(data: payload[splitAt...])
            #expect(scanner.hasNewline,
                    "split at \(splitAt): expected newline")
            #expect(scanner.frameData == expectedFrame,
                    "split at \(splitAt): wrong frame")
        }
    }
}
