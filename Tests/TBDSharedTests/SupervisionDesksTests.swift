import Foundation
import Testing
@testable import TBDShared

/// `~/tbd/supervision/desks.json`: the wire shape a hosted desk is recorded in,
/// and the store that writes it durably.
///
/// Tier 2 — real filesystem, no clocks, no subprocesses. Every path is a temp
/// directory handed to the store, so nothing here touches `~/tbd`.
@Suite("Supervision desks file")
struct SupervisionDesksTests {

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-desks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func entry(
        terminal: UUID = UUID(), worktree: UUID = UUID(),
        at seconds: TimeInterval = 1_800_000_000, hash: String = "abc123"
    ) -> SupervisionDeskEntry {
        SupervisionDeskEntry(
            terminal: terminal, worktree: worktree,
            spawnedAt: SupervisionInstant(Date(timeIntervalSince1970: seconds)),
            conductHash: hash)
    }

    // MARK: - Shape

    @Test("A desk entry carries exactly the four fields, keyed by id")
    func entryShape() throws {
        let terminal = UUID()
        let worktree = UUID()
        let file = SupervisionDesksFile(desks: [
            "acme-web": Self.entry(terminal: terminal, worktree: worktree, hash: "deadbeef")
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try JSONSerialization.jsonObject(with: encoder.encode(file))

        let root = try #require(json as? [String: Any])
        #expect(root["version"] as? Int == 1)
        let desks = try #require(root["desks"] as? [String: Any])
        let acme = try #require(desks["acme-web"] as? [String: Any])
        #expect(Set(acme.keys) == ["terminal", "worktree", "spawnedAt", "conductHash"])
        #expect(acme["terminal"] as? String == terminal.uuidString)
        #expect(acme["worktree"] as? String == worktree.uuidString)
        #expect(acme["conductHash"] as? String == "deadbeef")
        // No display string anywhere: a rename must never orphan a desk.
        #expect(acme["name"] == nil)
        #expect(acme["displayName"] == nil)
    }

    @Test("An empty record is one line, not empty scaffolding")
    func emptyRecordOmitsTheMap() throws {
        let data = try JSONEncoder().encode(SupervisionDesksFile())
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["version"] as? Int == 1)
        #expect(root["desks"] == nil)
    }

    @Test("An entry survives a round trip unchanged")
    func roundTrip() throws {
        let file = SupervisionDesksFile(desks: ["acme-web": Self.entry()])
        let decoded = try JSONDecoder().decode(
            SupervisionDesksFile.self, from: try JSONEncoder().encode(file))
        #expect(decoded == file)
    }

    @Test("A version this build does not read is refused")
    func futureVersionRefused() throws {
        let data = Data(#"{"version": 2}"#.utf8)
        let file = try JSONDecoder().decode(SupervisionDesksFile.self, from: data)
        #expect(throws: SupervisionDesksError.self) { try file.validate() }
    }

    // MARK: - Mutation

    @Test("Recording and forgetting are value transforms; forgetting nothing is a no-op")
    func mutations() {
        let entry = Self.entry()
        let empty = SupervisionDesksFile()
        let recorded = empty.recording(entry, for: "acme-web")
        #expect(recorded.desk(for: "acme-web") == entry)
        #expect(empty.desk(for: "acme-web") == nil)

        // A no-op returns an equal value, which is what lets the collector
        // decline to write.
        #expect(empty.forgetting("acme-web") == empty)
        #expect(recorded.forgetting("acme-web") == empty)
    }

    // MARK: - Store

    @Test("An absent file loads as the empty record, not an error")
    func absentFileIsEmpty() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SupervisionDesksStore(
            fileURL: directory.appendingPathComponent("desks.json"))
        #expect(try store.load() == SupervisionDesksFile())
    }

    @Test("Save then load returns the same record")
    func saveLoadRoundTrip() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SupervisionDesksStore(
            fileURL: directory.appendingPathComponent("desks.json"))
        let file = SupervisionDesksFile(desks: [
            "acme-web": Self.entry(), "acme-hooks": Self.entry()
        ])
        try store.save(file)
        #expect(try store.load() == file)
    }

    @Test("The write leaves no temp file behind, and the temp is in the target's directory")
    func saveIsAtomicInPlace() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SupervisionDesksStore(
            fileURL: directory.appendingPathComponent("desks.json"))
        // `rename(2)` is atomic only within a filesystem, so the temp has to be
        // a sibling of the target rather than under `/tmp`.
        #expect(store.temporaryURL().deletingLastPathComponent().path == directory.path)

        try store.save(SupervisionDesksFile(desks: ["acme-web": Self.entry()]))
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left == ["desks.json"])
    }

    @Test("A malformed record is refused by path, naming the file")
    func malformedIsNamed() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("desks.json")
        try Data("{ not json".utf8).write(to: url)
        let store = SupervisionDesksStore(fileURL: url)
        #expect(throws: SupervisionDesksError.self) { _ = try store.load() }
    }

    @Test("The desks path is TBD_HOME-relative, and beside the operator's file")
    func pathHonorsTBDHome() {
        let environment = ["TBD_HOME": "/tmp/x-tbd-home"]
        let desks = TBDConstants.supervisionDesksPath(environment: environment)
        #expect(desks == "/tmp/x-tbd-home/supervision/desks.json")
        // Beside `supervision.json`, never inside it: derived state and
        // operator selections share a directory, not a file.
        #expect(
            (desks as NSString).deletingLastPathComponent
                == (TBDConstants.supervisionFilePath(environment: environment) as NSString)
                    .deletingLastPathComponent)
    }
}
