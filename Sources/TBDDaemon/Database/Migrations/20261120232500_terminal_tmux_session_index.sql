-- The session ids of the terminal rows on tmux whose session may still run,
-- for the resume gate (docs/specs/2026-10-11-holder-transport-migration-design.md,
-- "Resuming a session a tmux row carries"). Every start of an existing session
-- on the pty holder looks its id up among these rows first, because the
-- session may still be running in the row's tmux server. A tmux row is one
-- whose transport is not 'holder', NULL included. Its session may still run
-- while the row is unparked, and while a park is in flight
-- (pendingSessionIncarnationID set), which is how an earlier build left a
-- hibernate whose respawn failed; a parked row with no park in flight ended
-- its session. So the partial index holds only the rows the gate can match.
-- An index changes no row and no behavior.
CREATE INDEX IF NOT EXISTS idx_terminal_live_tmux_session
    ON terminal(claudeSessionID)
    WHERE transport IS NOT 'holder'
    AND ((hibernatedAt IS NULL AND suspendedAt IS NULL) OR pendingSessionIncarnationID IS NOT NULL);
