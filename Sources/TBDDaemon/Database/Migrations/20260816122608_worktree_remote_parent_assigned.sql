-- Has adoption already given this row a parent?
--
-- `parentWorktreeID IS NULL` has two provenances a remote lane cannot tell
-- apart: nobody could name a parent when the row was minted, or the user took
-- the one it had away (`tbd worktree move <lane> --root`). Adoption must heal
-- the first and never touch the second, and the provider's
-- `tbd_parent_worktree_id` stamp cannot arbitrate — it is static from create
-- time, so it is present on every later poll and would re-nest the lane within
-- one poll interval. This column is the missing fact: adoption sets it the
-- moment it ASSIGNS a parent, and never offers one again.
--
-- Data, not a feature gate, so it carries an ordinary SQL default (the
-- three-state rule in CLAUDE.md is about flags whose default may need flipping
-- later; there is no third state here). The backfill covers rows adopted
-- before the column existed: a remote row that already has a parent got it
-- from adoption — nothing else mints those rows — so recording that is a
-- correction, not a guess, and it errs in the only safe direction, since the
-- marker can only ever WITHHOLD a parent adoption would otherwise impose.
ALTER TABLE worktree ADD COLUMN remote_parent_assigned BOOLEAN DEFAULT 0;

UPDATE worktree SET remote_parent_assigned = 1
WHERE location = 'remote' AND parentWorktreeID IS NOT NULL;
