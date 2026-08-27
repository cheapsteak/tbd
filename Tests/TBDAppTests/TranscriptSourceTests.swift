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

    @Test("forget drops retained state")
    func forgetDropsState() async throws {
        let path = try tempFile(lineA + "\n")
        let source = TranscriptSource()
        _ = await source.refresh(sessionID: "s1", path: path)
        await source.forget(sessionID: "s1")
        #expect(await source.items(sessionID: "s1").isEmpty)
    }
}
