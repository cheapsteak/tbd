-- Composer draft save-and-restore (docs/specs/2026-10-19-tbd-session-mod-design.md).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean someone
-- did. The shipped default lives only in Config.composerDraftDefault.
ALTER TABLE config ADD COLUMN composer_draft_enabled INTEGER;
