-- A wake the user's start-admission command held
-- (docs/specs/2026-10-21-agent-start-admission-design.md).
--
-- Why the last automatic wake of a parked tab was held, and when. The parked
-- pane's notice shows both. A held wake sets them together and the next
-- successful wake clears them together. NULL means no hold has touched the row.
ALTER TABLE terminal ADD COLUMN start_held_reason TEXT;
ALTER TABLE terminal ADD COLUMN start_held_at DATETIME;
