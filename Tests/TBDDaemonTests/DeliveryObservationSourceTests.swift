import Foundation
import Testing
@testable import TBDDaemonLib

/// Tier 2 — real files in a temp directory, no database.
///
/// `DatabaseDeliveryObservationSource.transcriptTail` is the only production
/// implementation of the observation's file read, and every verifier test
/// supplies its own `Data?` instead — so nothing exercised it. What it returns
/// is not a detail: empty `Data` means *readable, and the envelope is genuinely
/// not there*, which is the positive evidence that licenses a re-paste, while
/// `nil` means no observation could be made. The two must never be confusable,
/// least of all by a swallowed I/O error.
@Suite("the observation's transcript read")
struct DeliveryObservationSourceTests {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func source() throws -> DatabaseDeliveryObservationSource {
        DatabaseDeliveryObservationSource(db: try TBDDatabase(inMemory: true))
    }

    /// Unreadable is not absent. A path that cannot be opened must answer `nil`,
    /// so the mapping reaches `undetermined` rather than claiming the envelope
    /// is missing from a file it never read.
    @Test("a transcript that cannot be opened answers nil, never empty")
    func missingFileAnswersNil() async throws {
        let directory = try makeDirectory()
        let absent = directory.appendingPathComponent("never-written.jsonl").path

        let reader = try source()
        #expect(await reader.transcriptTail(atPath: absent, maxBytes: 64 * 1024) == nil)
    }

    /// A real, readable, empty file is the one case that legitimately answers
    /// empty — readable-and-absent, which is evidence.
    @Test("an empty transcript answers empty data, which is evidence")
    func emptyFileAnswersEmptyData() async throws {
        let directory = try makeDirectory()
        let path = directory.appendingPathComponent("session.jsonl").path
        FileManager.default.createFile(atPath: path, contents: Data())

        let reader = try source()
        let tail = await reader.transcriptTail(atPath: path, maxBytes: 64 * 1024)
        #expect(tail == Data())
    }

    /// Shorter than the window: the whole file comes back, which is what makes
    /// `count < maxBytes` a sound proof that nothing was missed.
    @Test("a transcript shorter than the window returns all of it")
    func shortFileReturnsWholeContent() async throws {
        let directory = try makeDirectory()
        let path = directory.appendingPathComponent("session.jsonl").path
        let body = Data("{\"type\":\"user\",\"content\":\"hello\"}\n".utf8)
        try body.write(to: URL(fileURLWithPath: path))

        let reader = try source()
        let tail = await reader.transcriptTail(atPath: path, maxBytes: 64 * 1024)
        #expect(tail == body)
        #expect((tail?.count ?? 0) < 64 * 1024)
    }

    /// Longer than the window: exactly the last `maxBytes`, and — the property
    /// the escalation's whole-file proof rests on — a result whose length is the
    /// window it asked for, never more.
    @Test("a transcript longer than the window returns exactly its last maxBytes")
    func longFileReturnsExactlyTheWindow() async throws {
        let directory = try makeDirectory()
        let path = directory.appendingPathComponent("session.jsonl").path
        var body = Data(repeating: 0x41, count: 4096)
        body.append(Data(repeating: 0x42, count: 1024))
        try body.write(to: URL(fileURLWithPath: path))

        let reader = try source()
        let tail = try #require(await reader.transcriptTail(atPath: path, maxBytes: 1024))
        #expect(tail.count == 1024)
        #expect(tail == Data(repeating: 0x42, count: 1024))
    }

    /// A directory is not a transcript, and must not read as an empty one.
    ///
    /// **This does not exercise the `do`/`catch` around `seek`/`read`** — it was
    /// written believing it did, and a mutation check proved otherwise: reverting
    /// that block to `try?`/`?? Data()` left this test green, because
    /// `FileHandle(forReadingAtPath:)` refuses a directory outright and the
    /// first guard answers `nil` without ever seeking. The catch branch is
    /// correct by inspection and unproven by test; forcing a `seek` or `read` to
    /// throw on a local regular file needs a seam this type does not have, and
    /// inventing one to test a two-line guard is a worse trade than saying so.
    @Test("a path that is not a readable file answers nil, not empty")
    func nonFilePathAnswersNil() async throws {
        let directory = try makeDirectory()

        let reader = try source()
        #expect(await reader.transcriptTail(
            atPath: directory.path, maxBytes: 64 * 1024) == nil)
    }
}
