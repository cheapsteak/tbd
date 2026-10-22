-- Agent background priority (docs/specs/2026-10-21-agent-start-admission-design.md).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean someone
-- did. The shipped default lives only in Config.agentBackgroundDefault.
ALTER TABLE config ADD COLUMN agent_background_enabled INTEGER;
