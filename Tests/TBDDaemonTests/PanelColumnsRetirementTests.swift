import Foundation
import GRDB
import TBDShared
import Testing
@testable import TBDDaemonLib

/// The panel model's four columns are retired (docs/specs/2026-10-30-panel-tabs-design.md,
/// "Rollout"). At schema epoch 5: the store's master switch
/// `config.daemon_panel_surface_enabled`, the agent gate
/// `config.agent_panel_control_enabled`, and the legacy-import stamp
/// `worktree.panel_surface_imported_at`. At epoch 6: the soak flag
/// `config.panel_tabs_enabled`. Nothing reads or writes them, and
/// `RetiredColumnReconciler` drops them once the kept rollback bundle no
/// longer uses them. See "Retiring a column" in
/// `Sources/TBDDaemon/Database/CLAUDE.md`.
@Suite struct PanelColumnsRetirementTests {

    private static let retired = [
        RetiredColumn(table: "config", column: "daemon_panel_surface_enabled", epoch: 5),
        RetiredColumn(table: "config", column: "agent_panel_control_enabled", epoch: 5),
        RetiredColumn(table: "worktree", column: "panel_surface_imported_at", epoch: 5),
        RetiredColumn(table: "config", column: "panel_tabs_enabled", epoch: 6),
    ]

    @Test func theColumnsAreRetiredAtTheirEpochs() throws {
        #expect(SchemaEpoch.current >= 6)
        for column in Self.retired {
            let index = try #require(RetiredColumns.all.firstIndex(of: column),
                                     "\(column) is not listed in RetiredColumns.all")
            // Appended, never inserted: nothing before it was retired later.
            #expect(RetiredColumns.all[..<index].allSatisfy { $0.epoch <= column.epoch },
                    "a retirement is appended, never inserted")
        }
        #expect(RetiredColumns.all.allSatisfy { $0.epoch <= SchemaEpoch.current },
                "an entry names an epoch this tree has not reached")
    }

    /// The soak flag's column is dropped once the kept bundle was built from
    /// a tree that had retired it (epoch 6), and kept while the bundle still
    /// reads it (epoch 5, or no recorded epoch).
    @Test func theSoakFlagColumnDropsAtEpochSixAndHoldsBelow() {
        let entry = RetiredColumn(table: "config", column: "panel_tabs_enabled", epoch: 6)
        #expect(RetiredColumns.all.contains(entry))
        #expect(RetiredColumnReconciler.decision(
            for: entry, keptBundle: KeptBundle(path: "/kept/TBD.app", schemaEpoch: 6)) == .drop)
        #expect(RetiredColumnReconciler.decision(
            for: entry, keptBundle: KeptBundle(path: "/kept/TBD.app", schemaEpoch: 5)) == .hold)
        #expect(RetiredColumnReconciler.decision(
            for: entry, keptBundle: KeptBundle(path: "/kept/TBD.app", schemaEpoch: nil)) == .hold)
        #expect(RetiredColumnReconciler.decision(for: entry, keptBundle: nil) == .drop)
    }

    // MARK: - The record mirrors

    /// A GRDB record writes every property it declares, so a record that
    /// still declared a column would fail every write once it is dropped.
    /// `composer_draft_enabled` is the control: the reflection does see the
    /// record's columns.
    @Test func configRecordNoLongerDeclaresTheColumns() {
        let labels = Mirror(reflecting: ConfigRecord(id: "unstored")).children.compactMap(\.label)
        #expect(labels.contains("composer_draft_enabled"))
        #expect(!labels.contains("panel_tabs_enabled"))
        #expect(!labels.contains("daemon_panel_surface_enabled"))
        #expect(!labels.contains("agent_panel_control_enabled"))
    }

    /// Same guard for the worktree record. `foreign_head` is the control.
    @Test func worktreeRecordNoLongerDeclaresTheColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let id = try await makeWorktree(db).id
        let record = try await db.writerForTests.read { conn in
            try WorktreeRecord.fetchOne(conn, key: id.uuidString)
        }
        let fetched = try #require(record)
        let labels = Mirror(reflecting: fetched).children.compactMap(\.label)
        #expect(labels.contains("foreign_head"))
        #expect(!labels.contains("panel_surface_imported_at"))
    }

    /// The shared models lose the fields the columns fed.
    @Test func theSharedModelsNoLongerCarryTheFlags() {
        let configLabels = Mirror(reflecting: Config()).children.compactMap(\.label)
        #expect(!configLabels.contains("panelTabsEnabled"))
        #expect(!configLabels.contains("panelSurfaceEnabled"))
        #expect(!configLabels.contains("agentPanelControlEnabled"))

        let capsLabels = Mirror(reflecting: DaemonCapabilitiesResult(controlModeEnabled: false))
            .children.compactMap(\.label)
        #expect(!capsLabels.contains("panelTabsEnabled"))
        #expect(!capsLabels.contains("panelSurfaceEnabled"))
    }

    // MARK: - Round trips against a schema the columns are dropped from

    /// The config row is written through the record and read back, against a
    /// schema all three config columns have been dropped from.
    @Test func theConfigRowRoundTripsWithoutTheColumns() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try await db.writerForTests.write { conn -> ConfigRecord? in
            try conn.execute(sql: "ALTER TABLE config DROP COLUMN daemon_panel_surface_enabled")
            try conn.execute(sql: "ALTER TABLE config DROP COLUMN agent_panel_control_enabled")
            try conn.execute(sql: "ALTER TABLE config DROP COLUMN panel_tabs_enabled")
            return try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
        let seeded = try #require(record)
        try await db.writerForTests.write { conn in
            _ = try ConfigRecord.deleteOne(conn, key: ConfigStore.singletonID)
            try seeded.insert(conn)
        }
        try await db.config.setAutoCreateNotes(false)

        let config = try await db.config.get()
        #expect(!config.autoCreateNotesEnabled)
    }

    /// A worktree row is inserted, updated and read back through the store
    /// against a schema `panel_surface_imported_at` has been dropped from.
    @Test func theWorktreeRowRoundTripsWithoutTheColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "ALTER TABLE worktree DROP COLUMN panel_surface_imported_at")
        }
        let created = try await makeWorktree(db)
        try await db.worktrees.rename(id: created.id, displayName: "renamed")

        let fetched = try #require(try await db.worktrees.get(id: created.id))
        #expect(fetched.displayName == "renamed")
        #expect(fetched.branch == created.branch)
    }

    // MARK: - The wire

    /// A daemon built before the retirement still sends `panelSurfaceEnabled`,
    /// `agentPanelControlEnabled` and `panelTabsEnabled` in every `Config`. A newer client
    /// ignores the keys rather than failing the decode.
    @Test func aConfigThatStillCarriesTheFlagsDecodes() throws {
        let data = try JSONEncoder().encode(Config())
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["panelSurfaceEnabled"] = true
        object["agentPanelControlEnabled"] = true
        object["panelTabsEnabled"] = true
        let withFlags = try JSONSerialization.data(withJSONObject: object)

        let expected = try JSONDecoder().decode(Config.self, from: data)
        #expect(try JSONDecoder().decode(Config.self, from: withFlags) == expected)
    }

    /// The same for `daemon.capabilities`: an old daemon's panel flags are
    /// ignored rather than read.
    @Test func capabilitiesThatStillCarryTheFlagsDecode() throws {
        let json = #"{"controlModeEnabled":true,"panelSurfaceEnabled":true,"panelTabsEnabled":true}"#
        let caps = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.controlModeEnabled == true)
    }

    // MARK: - Helpers

    private func makeWorktree(_ db: TBDDatabase) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/panel-retire-\(UUID())", displayName: "panel-retire", defaultBranch: "main")
        return try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/panel-retire-wt-\(UUID())", tmuxServer: "srv")
    }
}
