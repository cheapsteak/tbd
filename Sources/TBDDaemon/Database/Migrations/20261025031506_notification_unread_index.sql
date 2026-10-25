-- Indexes the unread notifications by worktree. The app polls the per-worktree
-- unread summary every 2 seconds and mark-read runs per worktree; without an
-- index each walked the whole `notification` table, read rows included. The
-- index holds only unread rows, so both cost about the number of unread rows.
--
-- Changes no behavior and no row: an index is invisible to every reader, and
-- the previous build `tbd update` keeps for rollback runs unchanged against it.
CREATE INDEX IF NOT EXISTS idx_notification_unread_worktree ON notification(worktreeID) WHERE read = 0;
