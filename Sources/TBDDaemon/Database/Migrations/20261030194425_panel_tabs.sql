-- Side panel with tabs (docs/specs/2026-10-30-panel-tabs-design.md).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean someone
-- did. The shipped default lives only in Config.panelTabsDefault.
ALTER TABLE config ADD COLUMN panel_tabs_enabled INTEGER;
-- The v1 panel rows hold a split-tree layout the v2 model cannot read. Tabs
-- get their surfaces again from the next panel.syncTabs. Receipts and
-- history go first: history references the surface rows.
DELETE FROM panel_operation_receipt;
DELETE FROM panel_history;
DELETE FROM workspace_tab_surface;
-- 1 while a surface awaits its tab's first listing in a panel.syncTabs: a
-- scratch promote moves surfaces to the main worktree before the app's tab
-- list names them, and a sync that omits such a surface must not prune it.
-- Not a feature flag, so the DEFAULT is deliberate: every existing row has
-- been listed, and the backfilled 0 is correct for it.
ALTER TABLE workspace_tab_surface ADD COLUMN awaitingListing INTEGER NOT NULL DEFAULT 0;
-- One daemon-wide counter every surface write takes its revision from, so a
-- tab's revisions keep rising across a delete and re-import. It never goes
-- down; the surface rows are all gone above, so it starts at zero.
CREATE TABLE IF NOT EXISTS panel_revision_counter (id INTEGER PRIMARY KEY CHECK (id = 1), value INTEGER NOT NULL);
INSERT OR IGNORE INTO panel_revision_counter (id, value) VALUES (1, 0);
