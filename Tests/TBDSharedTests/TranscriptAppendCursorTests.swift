import Foundation
import Testing
import TBDShared

/// `TranscriptAppendCursor` — the append-versus-reset decision a transcript
/// reader makes on each refresh, and the rebase after a known prepend. Tier 2:
/// each test writes a real file in a temp directory of its own. Every write is
/// followed by an explicit modification date, so no decision depends on the
/// file system's timestamp resolution or the wall clock.
@Suite("TranscriptAppendCursor")
struct TranscriptAppendCursorTests {

    /// A fixed instant every test stamps its writes relative to.
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private let diskTail: @Sendable (String, UInt64) -> Data? = { path, offset in
        TranscriptAppendCursor.diskTailWindow(path: path, endingAt: offset)
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-append-cursor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Replaces the file's contents and stamps it `seconds` after `base`.
    private func write(_ text: String, to path: String, at seconds: TimeInterval) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try stamp(path, at: seconds)
    }

    /// Appends to the file and stamps it `seconds` after `base`.
    private func append(_ text: String, to path: String, at seconds: TimeInterval) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        try stamp(path, at: seconds)
    }

    private func stamp(_ path: String, at seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(seconds)], ofItemAtPath: path)
    }

    private let lineA = #"{"type":"user","uuid":"a","message":"the first prompt of the session"}"#
    private let lineB = #"{"type":"user","uuid":"b","message":"the second prompt of the session"}"#
    private let lineC = #"{"type":"user","uuid":"c","message":"the third prompt of the session"}"#

    @Test func appendedLinesArriveOnce() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.jsonl").path
        try write(lineA + "\n" + lineB + "\n", to: path, at: 0)
        var cursor = TranscriptAppendCursor(path: path, offset: 0, captureTail: diskTail)

        let first = cursor.step(path: path)
        #expect(first == .appended(lines: [lineA, lineB]))

        try append(lineC + "\n", to: path, at: 5)
        let second = cursor.step(path: path)
        #expect(second == .appended(lines: [lineC]), "only the appended line arrives")

        let third = cursor.step(path: path)
        #expect(third == .unchanged)
        #expect(cursor.offset == UInt64((lineA + "\n" + lineB + "\n" + lineC + "\n").utf8.count))
    }

    @Test func aShrinkResets() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.jsonl").path
        try write(lineA + "\n" + lineB + "\n", to: path, at: 0)
        var cursor = TranscriptAppendCursor(path: path, offset: 0, captureTail: diskTail)
        _ = cursor.step(path: path)

        try write(lineA + "\n", to: path, at: 5)
        let step = cursor.step(path: path)
        #expect(step == .reset)
    }

    @Test func aSameSizeRewriteResets() throws {
        let replacement = #"{"type":"user","uuid":"z","message":"the first prompt of the session"}"#
        #expect(replacement.utf8.count == lineA.utf8.count,
                "the fixture only exercises the rule if both lines weigh the same")
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.jsonl").path
        try write(lineA + "\n", to: path, at: 0)
        var cursor = TranscriptAppendCursor(path: path, offset: 0, captureTail: diskTail)
        _ = cursor.step(path: path)

        try write(replacement + "\n", to: path, at: 5)
        let step = cursor.step(path: path)
        #expect(step == .reset, "the same byte count with a new modification date is a different file")
    }

    @Test func aLargerRewriteWithChangedTailResets() throws {
        let original = lineA + "\n"
        let replacement = lineC + "\n" + lineB + "\n"
        #expect(replacement.utf8.count > original.utf8.count,
                "the fixture only exercises the tail check if the rewrite is larger")
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.jsonl").path
        try write(original, to: path, at: 0)
        var cursor = TranscriptAppendCursor(path: path, offset: 0, captureTail: diskTail)
        _ = cursor.step(path: path)

        // Larger, with a newer modification date: the stat reads exactly like
        // an append, and only the re-read window tells them apart.
        try write(replacement, to: path, at: 5)
        let step = cursor.step(path: path)
        #expect(step == .reset)
        #expect(cursor.offset == UInt64(original.utf8.count), "a reset leaves the cursor where it was")
    }

    @Test func rebaseFindsTheTailAfterAPrepend() throws {
        let original = lineA + "\n" + lineB + "\n"
        // Fewer bytes than the window the cursor captured, so the window's new
        // position starts before the old offset.
        let prepended = "p1\np2\np3\n"
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.jsonl").path
        try write(original, to: path, at: 0)
        var cursor = TranscriptAppendCursor(path: path, offset: 0, captureTail: diskTail)
        _ = cursor.step(path: path)

        try write(prepended + original, to: path, at: 5)
        let rebased = cursor.rebaseAfterPrepend(limit: 1 << 20)
        #expect(rebased)
        #expect(cursor.offset == UInt64((prepended + original).utf8.count))

        try append(lineC + "\n", to: path, at: 10)
        let step = cursor.step(path: path)
        #expect(step == .appended(lines: [lineC]), "only the line written after the prepend arrives")
    }

    @Test func rebaseFailsAfterARewrite() throws {
        let original = lineA + "\n" + lineB + "\n"
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.jsonl").path
        try write(original, to: path, at: 0)
        var cursor = TranscriptAppendCursor(path: path, offset: 0, captureTail: diskTail)
        _ = cursor.step(path: path)

        try write("p1\np2\n" + lineC + "\n" + lineB + "\n", to: path, at: 5)
        let rebased = cursor.rebaseAfterPrepend(limit: 1 << 20)
        #expect(!rebased)
        #expect(cursor.offset == UInt64(original.utf8.count), "a failed rebase leaves the cursor where it was")
    }
}
