-- Gate for the per-session pty-holder transport.
--
-- No DEFAULT clause, deliberately. ADD COLUMN ... DEFAULT would backfill every
-- existing row, destroying the distinction between "nobody has chosen" (NULL)
-- and "chose off" (0) — which is what made auto_hibernate_enabled impossible to
-- graduate without a forcing UPDATE that also reset deliberate opt-ins.
-- The shipped default lives in exactly one place: Config.ptyHolderDefault.
ALTER TABLE config ADD COLUMN pty_holder_enabled INTEGER;
