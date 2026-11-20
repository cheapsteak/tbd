-- The session ids of the unparked terminal rows on tmux, for the resume gate
-- (docs/specs/2026-10-11-holder-transport-migration-design.md, "Resuming a
-- session a tmux row carries"). Every start of an existing session on the pty
-- holder looks its id up among these rows first, because the session may
-- still be running in the row's tmux server. A tmux row is one whose transport
-- is not 'holder', NULL included, and a parked row's session ended when it was
-- parked, so the partial index holds only the rows the gate can match. An
-- index changes no row and no behavior.
CREATE INDEX IF NOT EXISTS idx_terminal_live_tmux_session
    ON terminal(claudeSessionID)
    WHERE transport IS NOT 'holder' AND hibernatedAt IS NULL AND suspendedAt IS NULL;
