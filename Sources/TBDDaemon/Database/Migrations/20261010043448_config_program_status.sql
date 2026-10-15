-- Gate for the Program Status Protocol (OSC 7501) on holder sessions
-- (docs/specs/2026-10-10-program-status-protocol-design.md).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean
-- someone did. The shipped default lives only in
-- Config.programStatusEnabledDefault.
ALTER TABLE config ADD COLUMN program_status_enabled INTEGER;
