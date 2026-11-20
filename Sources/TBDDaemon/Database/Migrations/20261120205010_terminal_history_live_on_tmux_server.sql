-- The tmux server a closed terminal's session may still be running in: set on
-- the Closed Terminals entry of a live tmux row TBD deleted without running
-- tmux, NULL on every other entry
-- (docs/specs/2026-10-11-holder-transport-migration-design.md, "Resuming a
-- session a closed tmux row carried"). Every resume of a session id looks its
-- marks up before starting it on the pty holder, so the partial index holds
-- only the marked entries. No DEFAULT: every entry written before this column
-- carries no mark, which is NULL.
ALTER TABLE terminal_history ADD COLUMN liveOnTmuxServer TEXT;
CREATE INDEX IF NOT EXISTS idx_terminal_history_live_on_tmux_session
    ON terminal_history(claudeSessionID) WHERE liveOnTmuxServer IS NOT NULL;
