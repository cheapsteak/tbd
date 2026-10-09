-- Schedule-based PR polling (docs/specs/2026-10-01-pr-polling-schedule-design.md).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean someone
-- did. The shipped default lives only in Config.prPollScheduleDefault.
ALTER TABLE config ADD COLUMN pr_poll_schedule_enabled INTEGER;
