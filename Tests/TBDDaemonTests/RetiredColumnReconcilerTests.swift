import Foundation
import GRDB
import TBDShared
import Testing
@testable import TBDDaemonLib

/// `RetiredColumnReconciler` drops a retired column only once the app bundle
/// kept for rollback no longer uses it
/// (`docs/specs/2026-10-24-column-retirement-design.md`). Every database,
/// snapshot and kept bundle here lives in a scratch directory, and the kept
/// bundle's path comes from an explicit `TBD_HOME` environment dictionary, so
/// nothing reads or writes the real `~/tbd`.
@Suite struct RetiredColumnReconcilerTests {

    // MARK: - The retired list

    @Test func theFirstRetirementsAreListedAtEpochOne() {
        #expect(RetiredColumns.all.contains(
            RetiredColumn(table: "config", column: "nightwatch_mode", epoch: 1)))
        #expect(RetiredColumns.all.contains(
            RetiredColumn(table: "terminal", column: "watch_desk_role", epoch: 1)))
    }

    // MARK: - The decision

    private static let entryAtTwo = RetiredColumn(table: "t", column: "c", epoch: 2)

    @Test func noKeptBundleDrops() {
        #expect(RetiredColumnReconciler.decision(for: Self.entryAtTwo, keptBundle: nil) == .drop)
    }

    @Test func aKeptBundleWithoutAnEpochHolds() {
        let kept = KeptBundle(path: "/kept/TBD.app", schemaEpoch: nil)
        #expect(RetiredColumnReconciler.decision(for: Self.entryAtTwo, keptBundle: kept) == .hold)
    }

    @Test(arguments: [0, 1])
    func aKeptBundleBelowTheEntryHolds(epoch: Int) {
        let kept = KeptBundle(path: "/kept/TBD.app", schemaEpoch: epoch)
        #expect(RetiredColumnReconciler.decision(for: Self.entryAtTwo, keptBundle: kept) == .hold)
    }

    @Test(arguments: [2, 3])
    func aKeptBundleAtOrAboveTheEntryDrops(epoch: Int) {
        let kept = KeptBundle(path: "/kept/TBD.app", schemaEpoch: epoch)
        #expect(RetiredColumnReconciler.decision(for: Self.entryAtTwo, keptBundle: kept) == .drop)
    }

    // MARK: - Reading the kept bundle

    @Test func nothingAtThePathIsNoKeptBundle() throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = TBDConstants.keptAppBundle(environment: Self.home(in: scratch))

        #expect(KeptBundle.read(atPath: bundle.path) == nil)
    }

    @Test func aKeptBundleWithNoIdentityFileHasNoEpoch() throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try Self.makeKeptBundle(in: scratch, identity: nil)

        #expect(KeptBundle.read(atPath: bundle.path) == KeptBundle(path: bundle.path, schemaEpoch: nil))
    }

    @Test func anIdentityWithoutSchemaEpochHasNoEpoch() throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try Self.makeKeptBundle(in: scratch, identity: Self.identity(schemaEpoch: nil))

        #expect(KeptBundle.read(atPath: bundle.path) == KeptBundle(path: bundle.path, schemaEpoch: nil))
    }

    /// A file that does not decode reads as no epoch, so it holds every drop.
    @Test func aMalformedIdentityHasNoEpochAndHolds() throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try Self.makeKeptBundle(in: scratch, identity: #"{"schemaEpoch": 5"#)

        let kept = KeptBundle.read(atPath: bundle.path)
        #expect(kept == KeptBundle(path: bundle.path, schemaEpoch: nil))
        #expect(RetiredColumnReconciler.decision(
            for: RetiredColumn(table: "t", column: "c", epoch: 1), keptBundle: kept) == .hold)
    }

    @Test func aWellFormedIdentityCarriesItsEpoch() throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try Self.makeKeptBundle(in: scratch, identity: Self.identity(schemaEpoch: 4))

        #expect(KeptBundle.read(atPath: bundle.path) == KeptBundle(path: bundle.path, schemaEpoch: 4))
    }

    // MARK: - The reconciler, against a database migrated to head

    @Test func bothColumnsDropWithNoKeptBundle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try await fixture.columns(of: "config").contains("nightwatch_mode"))
        #expect(try await fixture.columns(of: "terminal").contains("watch_desk_role"))

        let report = await fixture.db.reconcileRetiredColumns(fixture.reconciler(), at: Self.firstRun)

        #expect(report.outcomes[Self.nightwatchMode] == .dropped)
        #expect(report.outcomes[Self.watchDeskRole] == .dropped)
        #expect(try await fixture.columns(of: "config").contains("nightwatch_mode") == false)
        #expect(try await fixture.columns(of: "terminal").contains("watch_desk_role") == false)
    }

    @Test func neitherColumnDropsBehindAnEpochZeroKeptBundle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try Self.makeKeptBundle(in: fixture.scratch, identity: Self.identity(schemaEpoch: nil))

        let report = await fixture.db.reconcileRetiredColumns(fixture.reconciler(), at: Self.firstRun)

        #expect(report.outcomes[Self.nightwatchMode] == .held(keptEpoch: 0))
        #expect(report.outcomes[Self.watchDeskRole] == .held(keptEpoch: 0))
        #expect(report.snapshotPath == nil)
        #expect(fixture.snapshots().isEmpty)
        #expect(try await fixture.columns(of: "config").contains("nightwatch_mode"))
        #expect(try await fixture.columns(of: "terminal").contains("watch_desk_role"))
    }

    @Test func aKeptBundleAtTheRetirementEpochLetsTheDropsThrough() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try Self.makeKeptBundle(in: fixture.scratch, identity: Self.identity(schemaEpoch: 1))

        let report = await fixture.db.reconcileRetiredColumns(fixture.reconciler(), at: Self.firstRun)

        #expect(report.outcomes[Self.nightwatchMode] == .dropped)
        #expect(report.outcomes[Self.watchDeskRole] == .dropped)
    }

    @Test func aSecondRunIsANoOpThatWritesNoSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = await fixture.db.reconcileRetiredColumns(fixture.reconciler(), at: Self.firstRun)
        #expect(first.snapshotPath != nil)
        #expect(fixture.snapshots().count == 1)

        let second = await fixture.db.reconcileRetiredColumns(fixture.reconciler(), at: Self.secondRun)

        #expect(second.outcomes[Self.nightwatchMode] == .absent)
        #expect(second.outcomes[Self.watchDeskRole] == .absent)
        #expect(second.snapshotPath == nil)
        #expect(fixture.snapshots().count == 1)
    }

    /// SQLite refuses to drop an indexed column. The refusal is reported, the
    /// run does not throw, and the entries after it still drop.
    @Test func aFailingDropIsReportedAndTheRunCarriesOn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.db.writerForTests.write { db in
            try db.execute(sql: "CREATE TABLE retirement_probe (id INTEGER PRIMARY KEY, indexed TEXT)")
            try db.execute(sql: "CREATE INDEX retirement_probe_indexed ON retirement_probe(indexed)")
        }
        let indexed = RetiredColumn(table: "retirement_probe", column: "indexed", epoch: 1)

        let report = await fixture.db.reconcileRetiredColumns(
            fixture.reconciler(columns: [indexed, Self.nightwatchMode]), at: Self.firstRun)

        guard case .failed(_)? = report.outcomes[indexed] else {
            Issue.record("expected the indexed column's drop to fail, got \(String(describing: report.outcomes[indexed]))")
            return
        }
        #expect(report.outcomes[Self.nightwatchMode] == .dropped)
        #expect(try await fixture.columns(of: "retirement_probe").contains("indexed"))
        #expect(try await fixture.columns(of: "config").contains("nightwatch_mode") == false)
    }

    /// The snapshot is taken before the first drop, so it still holds the
    /// columns the run went on to drop, and it is named for the run's date.
    @Test func theSnapshotIsWrittenBeforeTheFirstDrop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let report = await fixture.db.reconcileRetiredColumns(fixture.reconciler(), at: Self.firstRun)

        let expectedPath = fixture.databasePath + ".pre-column-drop.20261024T123456Z"
        #expect(report.snapshotPath == expectedPath)
        #expect(fixture.snapshots() == ["state.db.pre-column-drop.20261024T123456Z"])
        let snapshot = try DatabaseQueue(path: expectedPath)
        let configColumns = try await snapshot.read { db in try Self.columnNames(of: "config", in: db) }
        let terminalColumns = try await snapshot.read { db in try Self.columnNames(of: "terminal", in: db) }
        #expect(configColumns.contains("nightwatch_mode"))
        #expect(terminalColumns.contains("watch_desk_role"))
    }

    /// Without the copy there is no way back for data someone still needed,
    /// so a run whose snapshot fails drops nothing.
    @Test func aFailedSnapshotDropsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let unwritable = fixture.scratch
            .appendingPathComponent("missing-directory")
            .appendingPathComponent("state.db").path

        let report = await fixture.db.reconcileRetiredColumns(
            fixture.reconciler(databasePath: unwritable), at: Self.firstRun)

        #expect(report.outcomes[Self.nightwatchMode] == .snapshotFailed)
        #expect(report.outcomes[Self.watchDeskRole] == .snapshotFailed)
        #expect(report.snapshotPath == nil)
        #expect(try await fixture.columns(of: "config").contains("nightwatch_mode"))
        #expect(try await fixture.columns(of: "terminal").contains("watch_desk_role"))
    }

    // MARK: - The stores after the drop

    /// `ConfigStore` writes the singleton row with raw `UPDATE`s and reads it
    /// through `ConfigRecord`, so the row is re-inserted through the record
    /// the store reads with, then written and read through the store.
    @Test func aConfigRowRoundTripsAfterTheDrop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = await fixture.db.reconcileRetiredColumns(fixture.reconciler(), at: Self.firstRun)
        #expect(report.outcomes[Self.nightwatchMode] == .dropped)

        let seeded = try await fixture.db.writerForTests.read { db in
            try ConfigRecord.fetchOne(db, key: ConfigStore.singletonID)
        }
        let record = try #require(seeded)
        try await fixture.db.writerForTests.write { db in
            _ = try ConfigRecord.deleteOne(db, key: ConfigStore.singletonID)
            try record.insert(db)
        }
        try await fixture.db.config.setGCEnabled(false)

        let config = try await fixture.db.config.get()
        #expect(config.gcEnabled == false)
    }

    @Test func aTerminalRowRoundTripsAfterTheDrop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = await fixture.db.reconcileRetiredColumns(fixture.reconciler(), at: Self.firstRun)
        #expect(report.outcomes[Self.watchDeskRole] == .dropped)

        let repo = try await fixture.db.repos.create(
            path: fixture.scratch.appendingPathComponent("acme").path,
            displayName: "acme", defaultBranch: "main")
        let worktree = try await fixture.db.worktrees.create(
            repoID: repo.id, name: "retire", branch: "retire",
            path: fixture.scratch.appendingPathComponent("acme-retire").path,
            tmuxServer: "tbd-retire")
        let created = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", label: "shell")
        try await fixture.db.terminals.setPin(id: created.id, pinned: true, at: Self.firstRun)

        let fetched = try #require(try await fixture.db.terminals.get(id: created.id))
        #expect(fetched.worktreeID == worktree.id)
        #expect(fetched.label == "shell")
        #expect(fetched.pinnedAt != nil)
    }

    // MARK: - Fixtures

    private static let nightwatchMode = RetiredColumn(table: "config", column: "nightwatch_mode", epoch: 1)
    private static let watchDeskRole = RetiredColumn(table: "terminal", column: "watch_desk_role", epoch: 1)

    /// 2026-10-24T12:34:56Z and the next morning.
    private static let firstRun = Date(timeIntervalSince1970: 1_792_845_296)
    private static let secondRun = Date(timeIntervalSince1970: 1_792_915_200)

    /// A file-backed database migrated to head, in its own scratch directory,
    /// with a scratch `TBD_HOME` for the kept bundle.
    private struct Fixture {
        let scratch: URL
        let db: TBDDatabase

        var databasePath: String { scratch.appendingPathComponent("state.db").path }

        init() throws {
            scratch = try RetiredColumnReconcilerTests.makeScratchDirectory()
            db = try TBDDatabase(
                path: scratch.appendingPathComponent("state.db").path,
                notesDir: scratch.appendingPathComponent("notes").path,
                terminalHistoryDir: scratch.appendingPathComponent("terminal-history").path)
        }

        func reconciler(
            columns: [RetiredColumn] = RetiredColumns.all,
            databasePath: String? = nil
        ) -> RetiredColumnReconciler {
            RetiredColumnReconciler(
                databasePath: databasePath ?? self.databasePath,
                keptBundlePath: TBDConstants.keptAppBundle(
                    environment: RetiredColumnReconcilerTests.home(in: scratch)).path,
                columns: columns)
        }

        func columns(of table: String) async throws -> Set<String> {
            try await db.writerForTests.read { conn in
                try RetiredColumnReconcilerTests.columnNames(of: table, in: conn)
            }
        }

        /// The pre-column-drop snapshots beside the database, by name.
        func snapshots() -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
            return names.filter { $0.contains(".pre-column-drop.") }.sorted()
        }

        func remove() {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    /// A scratch directory under the process temp dir — never `~/tbd`.
    private static func makeScratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-retired-columns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The environment that puts `TBD_HOME`, and so the updates directory,
    /// inside `scratch`.
    private static func home(in scratch: URL) -> [String: String] {
        ["TBD_HOME": scratch.appendingPathComponent("home").path]
    }

    /// Lay out the kept bundle the way `tbd update` leaves it, with `identity`
    /// as its build identity sidecar, or no sidecar at all when nil.
    private static func makeKeptBundle(in scratch: URL, identity: String?) throws -> URL {
        let env = home(in: scratch)
        let bundle = TBDConstants.keptAppBundle(environment: env)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents").appendingPathComponent("MacOS"),
            withIntermediateDirectories: true)
        if let identity {
            try Data(identity.utf8).write(to: TBDConstants.keptAppBundleIdentityFile(environment: env))
        }
        return bundle
    }

    /// A sidecar as the build wrapper writes it, with `schemaEpoch` when given.
    private static func identity(schemaEpoch: Int?) -> String {
        let epoch = schemaEpoch.map { #", "schemaEpoch": \#($0)"# } ?? ""
        return #"{"commit": "0123456789abcdef0123456789abcdef01234567", "shortCommit": "0123456", "branch": "HEAD", "dirty": false\#(epoch)}"#
    }

    private static func columnNames(of table: String, in db: Database) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").compactMap { $0["name"] as String? })
    }
}
