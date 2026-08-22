-- Remote create-param defaults, one map per level: the repo's own and the
-- machine-wide fall-through beneath it. JSON text keyed by the PROVIDER's
-- `create_params` field names, stored and replayed without interpretation — a
-- column named for one provider's concept (say `permission_mode`) would
-- hardcode that vocabulary into TBD's schema, and the next provider would need
-- another column.
--
-- Data, not a feature gate, so no SQL default is needed for the three-state
-- reason CLAUDE.md gives: NULL and `'{}'` mean the same thing here ("no
-- opinion at this level, defer to the next"), and TEXT columns arrive NULL
-- anyway.
ALTER TABLE config ADD COLUMN remote_create_defaults TEXT;
ALTER TABLE repo ADD COLUMN remote_create_defaults TEXT;
