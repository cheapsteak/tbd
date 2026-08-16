import Foundation
import Testing
@testable import TBDShared

/// The two desk lifecycle lines: `deskSpawned` and `deskReplaced`.
///
/// Tier 1 — pure encode/decode, no filesystem, no clocks.
@Suite("Supervision desk lifecycle lines")
struct SupervisionDeskLedgerTests {

    private static let at = Date(timeIntervalSince1970: 1_800_000_000)

    private static func encode(_ line: SupervisionLedgerLine) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(with: try encoder.encode(line))
        return object as? [String: Any] ?? [:]
    }

    @Test("A spawn line carries the desk by id and the conduct it stands on")
    func spawnShape() throws {
        let terminal = UUID()
        let worktree = UUID()
        let line = SupervisionLedgerLine.deskSpawned(
            project: "acme-web", mode: "attended",
            desk: SupervisionDeskRef(terminal: terminal, worktree: worktree),
            conductHash: "feed01", at: Self.at, id: "line1")
        let json = try Self.encode(line)

        #expect(json["kind"] as? String == "lifecycle")
        #expect(json["event"] as? String == "deskSpawned")
        #expect(json["project"] as? String == "acme-web")
        #expect(json["mode"] as? String == "attended")
        #expect(json["conductHash"] as? String == "feed01")
        let desk = try #require(json["desk"] as? [String: Any])
        #expect(desk["terminal"] as? String == terminal.uuidString)
        #expect(desk["worktree"] as? String == worktree.uuidString)
        #expect(json["predecessor"] == nil)
    }

    @Test("A replacement line links successor to predecessor")
    func replacementLinksPredecessor() throws {
        let successor = SupervisionDeskRef(terminal: UUID(), worktree: UUID())
        let predecessor = SupervisionDeskRef(terminal: UUID(), worktree: UUID())
        let line = SupervisionLedgerLine.deskReplaced(
            project: "acme-web", mode: "autonomous", desk: successor,
            predecessor: predecessor, conductHash: "feed02", at: Self.at, id: "line2")
        let json = try Self.encode(line)

        #expect(json["event"] as? String == "deskReplaced")
        let recorded = try #require(json["predecessor"] as? [String: Any])
        #expect(recorded["terminal"] as? String == predecessor.terminal.uuidString)
        // Successor and predecessor are distinguishable, which is the whole
        // reason the line exists rather than a second spawn line.
        let desk = try #require(json["desk"] as? [String: Any])
        #expect(desk["terminal"] as? String == successor.terminal.uuidString)
    }

    @Test("Both lines survive a round trip through the record's own coding")
    func roundTrip() throws {
        let lines = [
            SupervisionLedgerLine.deskSpawned(
                project: "acme-web", mode: "attended",
                desk: SupervisionDeskRef(terminal: UUID(), worktree: UUID()),
                conductHash: "aa", at: Self.at),
            SupervisionLedgerLine.deskReplaced(
                project: "acme-web", mode: "attended",
                desk: SupervisionDeskRef(terminal: UUID(), worktree: UUID()),
                predecessor: SupervisionDeskRef(terminal: UUID(), worktree: UUID()),
                conductHash: "bb", at: Self.at),
        ]
        for line in lines {
            let decoded = try JSONDecoder().decode(
                SupervisionLedgerLine.self, from: try JSONEncoder().encode(line))
            #expect(decoded == line)
            #expect(decoded.payload.event == line.payload.event)
        }
    }

    @Test("A desk event a later build writes decodes as unrecognized, not as damage")
    func unknownDeskEventIsReadPast() throws {
        let raw = Data("""
            {"id":"x","ts":"2027-01-01T00:00:00.000Z","mode":"attended","project":"acme-web",\
            "kind":"lifecycle","event":"deskRetired"}
            """.utf8)
        let line = try JSONDecoder().decode(SupervisionLedgerLine.self, from: raw)
        #expect(line.payload == .unrecognized)
        #expect(line.project == "acme-web")
    }
}
