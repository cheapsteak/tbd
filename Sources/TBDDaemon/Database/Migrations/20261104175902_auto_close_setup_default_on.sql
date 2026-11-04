-- Setup-tab auto-close is on by default, resolved as
-- auto_close_setup_enabled ?? Config.autoCloseSetupDefault.
--
-- The frozen v57_config_auto_close_setup migration added the column with
-- DEFAULT 0, so every row holds a 0 whether or not anyone chose it, and a
-- deliberate off cannot be told apart from that backfill. Resetting the column
-- to NULL turns the feature on for everyone, a deliberate off included, and
-- makes NULL mean "never chose" from here on: a 0 or 1 written after this
-- migration is an explicit choice that a later default change leaves alone.
UPDATE config SET auto_close_setup_enabled = NULL;
