-- Session usage recorded by the session mod
-- (docs/specs/2026-10-20-session-usage-mod-feature-design.md).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean someone
-- did. The shipped default lives only in Config.sessionModUsageDefault.
ALTER TABLE config ADD COLUMN session_mod_usage_enabled INTEGER;
