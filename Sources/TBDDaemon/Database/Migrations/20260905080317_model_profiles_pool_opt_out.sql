-- Per-profile opt-out from the balancing pool. NULL and 0 both mean "in the pool"
-- (when otherwise eligible), 1 means "never choose this one for me". Not a feature
-- flag, nothing to graduate — a standing user preference that sits in the database.
--
-- No DEFAULT clause. A profile without an explicit choice has NULL (or gets NULL
-- if inserted before this migration runs), not 0.
ALTER TABLE model_profiles ADD COLUMN pool_opt_out INTEGER;
