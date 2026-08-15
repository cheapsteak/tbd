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

    @Test("A line of a kind this build does not model opens and closes nothing")
    func unrecognizedKindsAreReadPast() async throws {
        let path = try Self.makePath()
        let writer = SupervisionLedgerWriter(path: path)
        await writer.append(.projectOn(
            project: "acme-web", mode: "attended", roster: [], at: Self.epoch))

        // A `delivery` line, as a later slice will write it. It must not close
        // the span above, and it must not be counted as damage — a record that
        // reports itself corrupt the first time somebody adds a kind is an
        // alarm nobody will keep reading.
        let delivery = """
            {"id":"deadbeef","ts":"2023-11-14T22:13:20.000Z","mode":"attended",\
            "project":"acme-web","kind":"delivery","hash":"abc123"}

            """
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(delivery.utf8))
        try handle.close()

        let spans = await SupervisionLedgerWriter(path: path).spanStarts()
        #expect(spans == ["acme-web": SupervisionInstant(Self.epoch)])
    }

    @Test("An empty or absent file recovers no spans")
    func absentFileRecoversNothing() async throws {
        let path = try Self.makePath()
        #expect(await SupervisionLedgerWriter(path: path).spanStarts().isEmpty)
    }
}
