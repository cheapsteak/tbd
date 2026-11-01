/// A database column no current code reads or writes, waiting to be dropped.
///
/// `epoch` is the `SchemaEpoch.current` its retirement set. A build whose
/// recorded epoch is at least that was built from a tree that had already
/// retired the column, so it never names it.
struct RetiredColumn: Hashable, Sendable, CustomStringConvertible {
    let table: String
    let column: String
    let epoch: Int

    var description: String { "\(table).\(column)" }
}

/// Every column ever retired, in retirement order. `RetiredColumnReconciler`
/// drops each one at daemon startup once the kept rollback bundle's epoch
/// reaches the entry's.
///
/// The list is permanent, like migration history. A fresh install still
/// creates every retired column, through the frozen migration that added it,
/// and relies on the reconciler to drop it again, so removing an entry would
/// leave that column on every later fresh install. Append only; the checklist
/// is "Retiring a column" in `Sources/TBDDaemon/Database/CLAUDE.md`.
enum RetiredColumns {
    static let all: [RetiredColumn] = [
        // Nightwatch's mode switch, added by `v38_nightwatch_mode` as `TEXT DEFAULT 'off'`.
        RetiredColumn(table: "config", column: "nightwatch_mode", epoch: 1),
        // Nightwatch's watch-desk role, added by `v68_watch_desk_judge_lease` as `TEXT DEFAULT NULL`.
        RetiredColumn(table: "terminal", column: "watch_desk_role", epoch: 1),
        // The keystroke veto's soak flag, added by `v51_config_hibernate_input_veto`
        // as `BOOLEAN DEFAULT 0`. The session mod is the only park draft guard.
        RetiredColumn(table: "config", column: "hibernate_input_veto_enabled", epoch: 2),
        // Fleet supervision's brake, added by `v77_config_supervision_enabled` as `BOOLEAN`.
        RetiredColumn(table: "config", column: "supervision_enabled", epoch: 3),
        // The Program Status Protocol's soak flag, added by
        // `20261010043448_config_program_status` as `INTEGER` with no default.
        // OSC 7501 is always on.
        RetiredColumn(table: "config", column: "program_status_enabled", epoch: 4),
        // The v1 panel store's master switch, added by the frozen `v59_panel_surface`
        // as `BOOLEAN DEFAULT 0`. The panel store is always on.
        RetiredColumn(table: "config", column: "daemon_panel_surface_enabled", epoch: 5),
        // The v1 agent panel-control gate, added by the frozen `v59_panel_surface`
        // as `BOOLEAN DEFAULT 0`. Agent panel control is always on.
        RetiredColumn(table: "config", column: "agent_panel_control_enabled", epoch: 5),
        // The legacy-layout import stamp, added by the frozen `v59_panel_surface`
        // as `DATETIME`. The tab sync imports any tab without a surface instead.
        RetiredColumn(table: "worktree", column: "panel_surface_imported_at", epoch: 5),
        // The side panel with tabs' soak flag, added by `20261030194425_panel_tabs`
        // as `INTEGER` with no default. Panel tabs are always on.
        RetiredColumn(table: "config", column: "panel_tabs_enabled", epoch: 6),
    ]
}
