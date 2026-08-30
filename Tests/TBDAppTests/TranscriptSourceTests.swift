import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

@Suite("TranscriptSource")
struct TranscriptSourceTests {

    private func tempFile(_ contents: String) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func append(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private let lineA = #"{"type":"user","uuid":"a","timestamp":"2026-08-26T10:00:00.000Z","message":{"role":"user","content":"hello"}}"#
    private let lineB = #"{"type":"user","uuid":"b","timestamp":"2026-08-26T10:00:01.000Z","message":{"role":"user","content":"second"}}"#

    @Test("a growing file yields only the appended items")
    func appendOnlyReadsTheDelta() async throws {
        let path = try tempFile(lineA + "\n")
        let source = TranscriptSource()
        let first = await source.refresh(sessionID: "s1", path: path)
        #expect(first?.appended.count == 1)

        try append(lineB + "\n", to: path)
        let second = await source.refresh(sessionID: "s1", path: path)
        #expect(second?.appended.count == 1, "second refresh must parse only the new line")
        #expect(await source.items(sessionID: "s1").count == 2)
    }

    @Test("a half-written trailing line is withheld, then delivered whole")
    func partialTrailingLineIsWithheld() async throws {
        let path = try tempFile(lineA + "\n")
        let source = TranscriptSource()
        _ = await source.refresh(sessionID: "s1", path: path)

        try append(String(lineB.prefix(20)), to: path)   // no newline yet
        _ = await source.refresh(sessionID: "s1", path: path)
        #expect(await source.items(sessionID: "s1").count == 1, "a partial line must not be parsed")

        try append(String(lineB.dropFirst(20)) + "\n", to: path)
        _ = await source.refresh(sessionID: "s1", path: path)
        #expect(await source.items(sessionID: "s1").count == 2, "the completed line must arrive whole")
    }

    @Test("a shrunken file triggers a full re-parse")
    func shrinkResetsState() async throws {
        let path = try tempFile(lineA + "\n" + lineB + "\n")
        let source = TranscriptSource()
        _ = await source.refresh(sessionID: "s1", path: path)
        #expect(await source.items(sessionID: "s1").count == 2)

        try (lineA + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        _ = await source.refresh(sessionID: "s1", path: path)
        #expect(await source.items(sessionID: "s1").count == 1, "shrink must reset, not append")
    }

    @Test("a changed path resets state")
    func changedPathResets() async throws {
        let pathA = try tempFile(lineA + "\n" + lineB + "\n")
        let pathB = try tempFile(lineA + "\n")
        let source = TranscriptSource()
        _ = await source.refresh(sessionID: "s1", path: pathA)
        _ = await source.refresh(sessionID: "s1", path: pathB)
        #expect(await source.items(sessionID: "s1").count == 1)
    }

    @Test("a read failure retains the previous items rather than blanking")
    func readFailureRetainsItems() async throws {
        let path = try tempFile(lineA + "\n")
        let source = TranscriptSource()
        _ = await source.refresh(sessionID: "s1", path: path)
        #expect(await source.items(sessionID: "s1").count == 1)

        try FileManager.default.removeItem(atPath: path)
        let change = await source.refresh(sessionID: "s1", path: path)
        #expect(change == nil, "a vanished file reports no change")
        #expect(await source.items(sessionID: "s1").count == 1,
                "a vanished file must NOT blank an already-loaded transcript")
    }

    @Test("an unchanged file does no work")
    func unchangedFileIsANoOp() async throws {
        let path = try tempFile(lineA + "\n")
        let source = TranscriptSource()
        _ = await source.refresh(sessionID: "s1", path: path)
        #expect(await source.refresh(sessionID: "s1", path: path)?.isEmpty ?? true)
    }

    /// Same byte length as `lineA`, different uuid and different text — the
    /// shape a rewrite-in-place produces (an edited or regenerated transcript
    /// whose replacement happens to weigh the same).
    private let lineASameSize = #"{"type":"user","uuid":"c","timestamp":"2026-08-26T10:00:00.000Z","message":{"role":"user","content":"world"}}"#

    /// `write(to:atomically:)` can land on the same whole-second mtime as the
    /// first write, which would make the two indistinguishable to the source
    /// and let this test pass for the wrong reason. Stamp the future time
    /// explicitly instead.
    private func setModified(_ path: String, secondsFromNow: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(secondsFromNow)],
            ofItemAtPath: path)
    }

    private func promptTexts(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { item -> String? in
            if case .userPrompt(_, let text, _) = item { return text }
            return nil
        }
    }

    @Test("a same-size rewrite with a newer mtime is re-read, not skipped")
    func sameSizeReplacementResets() async throws {
        #expect(lineASameSize.utf8.count == lineA.utf8.count,
                "the fixture only exercises the bug if both lines weigh the same")
        let path = try tempFile(lineA + "\n")
        let source = TranscriptSource()
        _ = await source.refresh(sessionID: "s1", path: path)
        #expect(promptTexts(await source.items(sessionID: "s1")) == ["hello"])

        try (lineASameSize + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        try setModified(path, secondsFromNow: 5)
        _ = await source.refresh(sessionID: "s1", path: path)
        #expect(promptTexts(await source.items(sessionID: "s1")) == ["world"],
                "a same-size rewrite must be re-read from the beginning")
    }

    @Test("a same-size rewrite that later grows does not splice stale rows")
    func sameSizeReplacementThenGrowth() async throws {
        let path = try tempFile(lineA + "\n")
        let source = TranscriptSource()
        _ = await source.refresh(sessionID: "s1", path: path)

        try (lineASameSize + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        try setModified(path, secondsFromNow: 5)
        _ = await source.refresh(sessionID: "s1", path: path)

        try append(lineB + "\n", to: path)
        try setModified(path, secondsFromNow: 10)
        _ = await source.refresh(sessionID: "s1", path: path)
        #expect(promptTexts(await source.items(sessionID: "s1")) == ["world", "second"],
                "the transcript must be the new file's content, with no row from the old one")
    }

    @Test("forget drops retained state")
    func forgetDropsState() async throws {
        let path = try tempFile(lineA + "\n")
        let source = TranscriptSource()
        _ = await source.refresh(sessionID: "s1", path: path)
        await source.forget(sessionID: "s1")
        #expect(await source.items(sessionID: "s1").isEmpty)
    }
}
