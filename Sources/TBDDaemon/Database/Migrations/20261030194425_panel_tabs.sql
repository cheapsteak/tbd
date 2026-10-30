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
