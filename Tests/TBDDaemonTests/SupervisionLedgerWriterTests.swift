import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — real filesystem, no clocks, no subprocesses. The path is injected;
/// nothing here can reach `~/tbd/supervision`.
@Suite("Supervision ledger writer")
struct SupervisionLedgerWriterTests {

    private static func makePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ledger.jsonl").path
    }

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every project named by a line in the file, in order — enough to say
    /// which line landed where.
    private func projects(at path: String) throws -> [String?] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return try data.split(separator: 0x0A, omittingEmptySubsequences: true).map { raw in
            try JSONDecoder().decode(SupervisionLedgerLine.self, from: Data(raw)).project
        }
    }

    private static func line(_ project: String) -> SupervisionLedgerLine {
        .projectOn(project: project, mode: "attended", roster: [], at: epoch)
    }

    // MARK: - The file the handle points at

    @Test("A ledger removed between appends is noticed and recreated, not written into a ghost")
    func removedFileIsRecreated() async throws {
        let path = try Self.makePath()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let writer = SupervisionLedgerWriter(path: path)

        #expect(await writer.append(Self.line("acme-web")))
        // Someone moved the whole directory aside. The still-open `O_APPEND`
        // descriptor would happily accept writes into the unlinked inode —
        // into a file nobody will ever read — so the identity check has to
        // fail the append and let the reopen-retry recreate the path.
        try FileManager.default.removeItem(at: directory)

        #expect(await writer.append(Self.line("acme-api")),
                "the retry recreates the file rather than reporting the line lost")
        #expect(try projects(at: path) == ["acme-api"])
    }

    @Test("A ledger replaced between appends is followed, not written past")
    func replacedFileIsFollowed() async throws {
        let path = try Self.makePath()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let archived = directory.appendingPathComponent("archived.jsonl").path
        let writer = SupervisionLedgerWriter(path: path)

        #expect(await writer.append(Self.line("acme-web")))
        // An external rotation: the segment is moved aside and a fresh file
        // takes its place at the same path. The line must land in the file
        // that is at `path` *now*.
        try FileManager.default.moveItem(atPath: path, toPath: archived)
        FileManager.default.createFile(atPath: path, contents: Data())

        #expect(await writer.append(Self.line("acme-api")))
        #expect(try projects(at: path) == ["acme-api"], "the new line follows the path")
        #expect(try projects(at: archived) == ["acme-web"],
                "and the rotated segment keeps only what it already held")
    }

    @Test("Each append is one whole line, and a line survives the round trip")
    func appendsWholeLines() async throws {
        let path = try Self.makePath()
        let writer = SupervisionLedgerWriter(path: path)
        let line = SupervisionLedgerLine.projectOn(
            project: "acme-web", mode: "attended", roster: [], at: Self.epoch)

        #expect(await writer.append(line))
        #expect(await writer.append(SupervisionLedgerLine.brakeEngaged(at: Self.epoch)))

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let rows = contents.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(rows.count == 2)
        let first = try JSONDecoder().decode(SupervisionLedgerLine.self, from: Data(rows[0].utf8))
        #expect(first == line, "a line equals its reloaded self")
    }

    @Test("Span recovery reports the most recent open span and nothing closed")
    func spanRecoveryPairsOnWithOff() async throws {
        let path = try Self.makePath()
        let writer = SupervisionLedgerWriter(path: path)
        let opened = Self.epoch
        let closed = Self.epoch.addingTimeInterval(60)
        let reopened = Self.epoch.addingTimeInterval(120)

        await writer.append(.projectOn(project: "acme-web", mode: "attended", roster: [], at: opened))
        await writer.append(.projectOff(
            project: "acme-web", mode: "attended",
            coverage: SupervisionCoverageSummary(
                spanStartedAt: SupervisionInstant(opened),
                spanEndedAt: SupervisionInstant(closed),
                sweepContacts: 0, briefingsDelivered: 0),
            at: closed))
        await writer.append(.projectOn(project: "acme-web", mode: "attended", roster: [], at: reopened))
        await writer.append(.projectOn(project: "acme-api", mode: "attended", roster: [], at: opened))
        await writer.append(.projectOff(
            project: "acme-api", mode: "attended",
            coverage: SupervisionCoverageSummary(
                spanStartedAt: SupervisionInstant(opened),
                spanEndedAt: SupervisionInstant(closed),
                sweepContacts: 0, briefingsDelivered: 0),
            at: closed))

        let spans = await SupervisionLedgerWriter(path: path).spanStarts()
        #expect(spans == ["acme-web": SupervisionInstant(reopened)],
                "the most recent `on` with no `off` after it, and nothing for a closed span")
    }

    @Test("Fleet-wide lines open no span")
    func brakeLinesOpenNoSpan() async throws {
        let path = try Self.makePath()
        let writer = SupervisionLedgerWriter(path: path)
        await writer.append(.brakeReleased(at: Self.epoch))
        await writer.append(.brakeEngaged(at: Self.epoch))
        #expect(await SupervisionLedgerWriter(path: path).spanStarts().isEmpty)
    }

    @Test("A line nobody can read is skipped, not fatal")
    func unreadableLineDoesNotTakeTheRecordOffline() async throws {
        let path = try Self.makePath()
        try "{ this is not json\n".write(toFile: path, atomically: true, encoding: .utf8)
        let writer = SupervisionLedgerWriter(path: path)
        await writer.append(.projectOn(
            project: "acme-web", mode: "attended", roster: [], at: Self.epoch))

        let spans = await SupervisionLedgerWriter(path: path).spanStarts()
        #expect(spans == ["acme-web": SupervisionInstant(Self.epoch)],
                "a hand edit costs the edited line, never the record's memory")
    }

    @Test("A file ending mid-line does not fuse with the next append")
    func danglingFragmentIsIsolated() async throws {
        let path = try Self.makePath()
        try "{\"id\":\"abc\",\"ts\"".write(toFile: path, atomically: true, encoding: .utf8)
        let writer = SupervisionLedgerWriter(path: path)
        _ = await writer.spanStarts()  // notices the fragment
        await writer.append(.projectOn(
            project: "acme-web", mode: "attended", roster: [], at: Self.epoch))

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let rows = contents.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(rows.count == 2, "the fragment terminates as its own junk line")
        #expect(try JSONDecoder().decode(
            SupervisionLedgerLine.self, from: Data(rows[1].utf8)).project == "acme-web")
    }

    /// A `delivery` line, as a later slice will write it.
    ///
    /// Its timestamp is deliberately **not** `epoch`: a fixture whose
    /// unrecognized line shares a timestamp with the span it sits beside cannot
    /// tell "read past" from "opened a span at the same instant", and the whole
    /// point of this fixture is to tell those apart.
    private static func deliveryLine(project: String) -> String {
        // epoch + 300s = 2023-11-14T22:18:20Z. Built by concatenation rather
        // than a multiline literal: a `\` continuation inside `"""` is one
        // keystroke away from producing JSON that silently fails to parse, and
        // a fixture that does not decode makes every assertion below vacuous.
        "{\"id\":\"deadbeef\",\"ts\":\"2023-11-14T22:18:20.000Z\",\"mode\":\"attended\","
            + "\"project\":\"\(project)\",\"kind\":\"delivery\",\"hash\":\"abc123\"}\n"
    }

    private static func appendRaw(_ text: String, to path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try #require(FileHandle(forWritingAtPath: path))
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test("A line of a kind this build does not model opens and closes nothing")
    func unrecognizedKindsAreReadPast() async throws {
        let raw = Self.deliveryLine(project: "acme-web")

        // Pinned first, and on its own. Span recovery's read-past behavior is
        // defined against a line that actually *decodes* as `.unrecognized`; a
        // fixture that fails to decode is counted as corruption instead and
        // never reaches the arm under test, which would make both assertions
        // below pass for the wrong reason. If this fixture ever stops
        // decoding, the failure should say so by name.
        let decoded = try JSONDecoder().decode(SupervisionLedgerLine.self, from: Data(raw.utf8))
        #expect(decoded.payload == .unrecognized)
        #expect(decoded.project == "acme-web")

        // It must not close a span that stands …
        let beside = try Self.makePath()
        let writer = SupervisionLedgerWriter(path: beside)
        await writer.append(.projectOn(
            project: "acme-web", mode: "attended", roster: [], at: Self.epoch))
        try Self.appendRaw(raw, to: beside)
        #expect(await SupervisionLedgerWriter(path: beside).spanStarts()
            == ["acme-web": SupervisionInstant(Self.epoch)],
                "an unrecognized line neither closes the span nor restamps it")

        // … and must not open one where none does.
        let alone = try Self.makePath()
        try Self.appendRaw(raw, to: alone)
        #expect(await SupervisionLedgerWriter(path: alone).spanStarts().isEmpty,
                "coverage starts from a projectOn line and nothing else")
    }

    @Test("An empty or absent file recovers no spans")
    func absentFileRecoversNothing() async throws {
        let path = try Self.makePath()
        #expect(await SupervisionLedgerWriter(path: path).spanStarts().isEmpty)
    }
}
