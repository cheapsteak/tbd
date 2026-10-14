-- The dev server this terminal tab runs, by declared name, or NULL for every
-- other tab (docs/specs/2026-10-11-dev-servers-design.md, "Starting").
--
-- Recorded at spawn. Links a tab to its server so state derivation can tell
-- "TBD's tab for web is still running" from "web's tab exited (code N)", and
-- so a restart reuses that tab instead of piling up new ones. No DEFAULT:
-- every row written before this column is not a server tab, which is NULL.
ALTER TABLE terminal ADD COLUMN server_name TEXT;

-- A holder-backed server's saved final output (the spec's "Exited servers
-- keep their last output"): the server a Closed Terminals entry speaks for,
-- and the exit code it recorded. On terminal_history rather than terminal
-- because reconcile deletes an ended holder session's terminal row, and the
-- exit has to survive that and a daemon restart. NULL for every other entry,
-- and again once a start or stop detaches the entry from its server. An
-- entry whose server is set and whose exitCode is NULL is an exit whose
-- status the transport could not observe. No DEFAULT on either column.
ALTER TABLE terminal_history ADD COLUMN serverName TEXT;
ALTER TABLE terminal_history ADD COLUMN exitCode INTEGER;
