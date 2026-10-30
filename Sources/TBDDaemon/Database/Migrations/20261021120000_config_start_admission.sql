-- Agent start admission (docs/specs/2026-10-21-agent-start-admission-design.md).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean someone
-- did. The shipped default lives only in Config.startAdmissionDefault.
ALTER TABLE config ADD COLUMN start_admission_enabled INTEGER;
