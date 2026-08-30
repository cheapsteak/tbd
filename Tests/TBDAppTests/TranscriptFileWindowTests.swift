import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

/// The window reader's byte-level contract: what it withholds, what it skips,
/// and that the offset always ends up somewhere the next read can resume from.
@Suite("TranscriptFileWindow")
struct TranscriptFileWindowTests {

    private static let newline: UInt8 = 0x0A

    /// Joins raw line bodies into a JSONL blob, newline-terminating each one.
    /// Takes `Data` rather than `String` so a deliberately undecodable line can
    /// sit among valid ones.
    private func jsonl(_ lines: [Data]) -> Data {
        var out = Data()
        for line in lines {
            out.append(line)
            out.append(Self.newline)
        }
        return out
    }

    private func tempFile(_ bytes: Data) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        try bytes.write(to: file)
        return file.path
    }

    private func append(_ bytes: Data, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
        try handle.close()
    }

    private func promptTexts(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { item -> String? in
            if case .userPrompt(_, let text, _) = item { return text }
            return nil
        }
    }

    private let lineA = #"{"type":"user","uuid":"a","timestamp":"2026-08-26T10:00:00.000Z","message":{"role":"user","content":"hello"}}"#
    private let lineB = #"{"type":"user","uuid":"b","timestamp":"2026-08-26T10:00:01.000Z","message":{"role":"user","content":"second"}}"#
    private let lineC = #"{"type":"user","uuid":"c","timestamp":"2026-08-26T10:00:02.000Z","message":{"role":"user","content":"third"}}"#

    /// A line with the right JSON shape whose content byte is `0xFF` — a byte
    /// that can never appear in valid UTF-8, so the sequence stays invalid no
    /// matter what follows it and no later tick can decode it. Synthetic; not
    /// captured from any real session.
    private var undecodableLine: Data {
        var line = Data(#"{"type":"user","uuid":"x","timestamp":"2026-08-26T10:00:03.000Z","message":{"role":"user","content":""#.utf8)
        line.append(UInt8(0xFF))
        line.append(contentsOf: Data(#""}}"#.utf8))
        return line
    }

    /// Fails against the current code: the whole window is decoded in one
    /// `String(data:encoding:.utf8)`, which returns nil for these bytes, so
    /// `read` returns nil — "no news" — and the offset never moves past the bad
    /// line. Every later tick re-reads the identical window and fails the same
    /// way, so `lineB` is never delivered and the session is wedged forever.
    @Test("an undecodable line is skipped and the offset advances past it")
    func undecodableLineIsSkipped() throws {
        let bytes = jsonl([Data(lineA.utf8), undecodableLine, Data(lineB.utf8)])
        let path = try tempFile(bytes)

        let read = try #require(TranscriptFileWindow.read(path: path, from: 0),
                                "an undecodable line must not be reported as 'no news'")
        #expect(read.lines == [lineA, lineB], "every decodable line survives, byte-accurate")
        #expect(read.newOffset == UInt64(bytes.count),
                "the offset must clear the whole window, or the next tick re-reads the same bad bytes")
    }

    /// Fails against the current code for the same reason, one layer up: the
    /// first `refresh` gets nil from the window reader, so nothing is stored,
    /// `items` stays empty, and the later append is never picked up either —
    /// the pane silently stops updating with no recovery path.
    @Test("a session with an undecodable line still advances on later appends")
    func sessionRecoversAndKeepsReading() async throws {
        let path = try tempFile(jsonl([Data(lineA.utf8), undecodableLine, Data(lineB.utf8)]))
        let source = TranscriptSource()

        let first = await source.refresh(sessionID: "s1", path: path)
        #expect(first != nil, "the bad line must not be reported as a read failure")
        #expect(promptTexts(await source.items(sessionID: "s1")) == ["hello", "second"])

        try append(jsonl([Data(lineC.utf8)]), to: path)
        let second = await source.refresh(sessionID: "s1", path: path)
        #expect(second?.appended.count == 1,
                "having skipped the bad line, the reader resumes reading only the delta")
        #expect(promptTexts(await source.items(sessionID: "s1")) == ["hello", "second", "third"])
    }

    /// A regression guard rather than a failing-first test: it passes against
    /// the current code, and pins the behaviour the recovery path must not
    /// cost. It fails against the two obvious wrong implementations — decoding
    /// the *untruncated* buffer lossily, which delivers a mangled half line now
    /// instead of the whole line later, and treating any decode failure as a
    /// skippable line, which drops the split line permanently.
    @Test("a line split mid-character is withheld, then delivered whole")
    func partialMultiByteTailIsWithheld() throws {
        let accented = #"{"type":"user","uuid":"e","timestamp":"2026-08-26T10:00:04.000Z","message":{"role":"user","content":"café"}}"#
        let accentedBytes = Data(accented.utf8)
        // Cut one byte into the two-byte "é" (0xC3 0xA9): the lead byte has
        // landed, its continuation byte has not.
        let lead = try #require(accentedBytes.firstIndex(of: UInt8(0xC3)))
        let cut = accentedBytes.index(after: lead)
        let head = Data(accentedBytes[accentedBytes.startIndex..<cut])
        var tail = Data(accentedBytes[cut...])

        let path = try tempFile(jsonl([Data(lineA.utf8)]))
        try append(head, to: path)

        let first = try #require(TranscriptFileWindow.read(path: path, from: 0))
        #expect(first.lines == [lineA], "a line cut mid-character must not be parsed")
        #expect(first.newOffset == UInt64(lineA.utf8.count + 1),
                "the offset stops at the last newline, so the split line is re-read whole")

        tail.append(Self.newline)
        try append(tail, to: path)
        let second = try #require(TranscriptFileWindow.read(path: path, from: first.newOffset))
        #expect(second.lines == [accented], "the completed line arrives whole and unmangled")
    }

    /// Fails against the current code: the undecodable line poisons the
    /// whole-window decode, so `read` returns nil and neither non-ASCII line is
    /// ever delivered. It also pins that the recovery splits on the newline
    /// BYTE and measures the offset in bytes — splitting or counting by
    /// `Character` would mangle these lines or leave the offset short.
    @Test("valid multi-byte content survives the skip path intact")
    func multiByteContentSurvivesRecovery() throws {
        let cjk = #"{"type":"user","uuid":"m1","timestamp":"2026-08-26T10:00:05.000Z","message":{"role":"user","content":"日本語のテスト"}}"#
        let mixed = #"{"type":"user","uuid":"m2","timestamp":"2026-08-26T10:00:06.000Z","message":{"role":"user","content":"café 🌊 ünïcode"}}"#
        #expect(cjk.utf8.count > cjk.count && mixed.utf8.count > mixed.count,
                "the fixture only exercises byte-vs-character counting if the lines are multi-byte")

        let bytes = jsonl([Data(cjk.utf8), undecodableLine, Data(mixed.utf8)])
        let path = try tempFile(bytes)

        let read = try #require(TranscriptFileWindow.read(path: path, from: 0))
        #expect(read.lines == [cjk, mixed], "non-ASCII lines must come back byte-accurate")
        #expect(read.newOffset == UInt64(bytes.count), "the offset is a byte count, not a character count")
    }
}
