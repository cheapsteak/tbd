-- The two thresholds profile balancing routes on (design 2026-09-05 §5):
-- the usage ceiling, in percent, at or above which an account counts as full,
-- and the maximum age, in seconds, of a usage reading it will route on.
--
-- No DEFAULT clause, deliberately. NULL means "never set" and resolves to the
-- shipped values in one place, ProfilePoolPolicy: an 85% ceiling, and each
-- credential kind's own cadence-relative reading age. A backfilled literal
-- would pin every existing install to today's numbers.
ALTER TABLE config ADD COLUMN profile_balancing_usage_ceiling_percent INTEGER;
ALTER TABLE config ADD COLUMN profile_balancing_max_reading_age_seconds INTEGER;
