-- Notes and the Changes list as worktree-wide side-panel tabs
-- (docs/specs/2026-11-01-side-panel-notes-and-changes-design.md). One row per
-- worktree panel, ordered within its worktree by position; content is the JSON
-- of its WorktreePanelContent. Deleting the worktree row deletes its panels.
CREATE TABLE IF NOT EXISTS worktree_panel (id TEXT PRIMARY KEY NOT NULL, worktreeID TEXT NOT NULL REFERENCES worktree(id) ON DELETE CASCADE, position INTEGER NOT NULL, content TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS worktree_panel_on_worktreeID ON worktree_panel(worktreeID, position);
