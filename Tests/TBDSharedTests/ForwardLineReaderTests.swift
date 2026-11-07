import Foundation
import Testing

@testable import TBDShared

/// `ForwardLineReader`, the chunked line reader behind
/// `TranscriptParser.lookupDetail(filePath:itemID:startingAt:)`. Tier 1 apart
/// from the fixture file, which each test writes to a temp directory of its
/// own.
@Suite("ForwardLineReader")
struct ForwardLineReaderTests {
    /// From one byte per read, where every refill carries a partial line, to
    /// one read for the whole file.
    @Test(arguments: [1, 7, 64, 1 << 20])
    func aLineSpanningSeveralChunksComesOutWholeAndTheNextLineFollows(chunkSize: Int) throws {
        let long = String(repeating: "x", count: 10_000)
        let file = try LineFile("first\n\(long)\nnext\n\n\nlast")
        defer { file.remove() }

        let lines = try readLines(path: file.path, from: 0, chunkSize: chunkSize)

        #expect(lines == ["first", long, "next", "last"])
    }

    @Test func manyShortLinesComeOutInOrder() throws {
        let expected = (1...500).map { "line \($0)" }
        let file = try LineFile(expected.joined(separator: "\n") + "\n")
        defer { file.remove() }

        let lines = try readLines(path: file.path, from: 0, chunkSize: 16)

        #expect(lines == expected)
    }

    @Test func aReadStartsAtItsOffset() throws {
        let file = try LineFile("first\nsecond\nthird")
        defer { file.remove() }

        let lines = try readLines(path: file.path, from: 6, chunkSize: 4)

        #expect(lines == ["second", "third"])
    }
}

// MARK: - fixtures

private func readLines(path: String, from offset: UInt64, chunkSize: Int) throws -> [String] {
    let handle = try #require(FileHandle(forReadingAtPath: path))
    defer { try? handle.close() }
    var reader = try #require(ForwardLineReader(handle: handle, from: offset, chunkSize: chunkSize))
    var lines: [String] = []
    while let line = reader.next() {
        let text = try #require(String(data: line, encoding: .utf8))
        lines.append(text)
    }
    return lines
}

/// A file in a temp directory of its own.
private struct LineFile {
    let directory: URL
    let path: String

    init(_ contents: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forward-line-reader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("lines.jsonl").path
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        self.directory = directory
        self.path = path
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
