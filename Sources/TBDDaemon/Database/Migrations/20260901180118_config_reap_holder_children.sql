-- Gate for the AgentReaper leg that kills a holder session's surviving child
-- process — the backstop for holder deaths the daemon was down for.
--
-- No DEFAULT clause, deliberately. ADD COLUMN ... DEFAULT would backfill every
-- existing row, destroying the distinction between "nobody has chosen" (NULL)
-- and "chose off" (0) — which is what made auto_hibernate_enabled impossible to
-- graduate without a forcing UPDATE that also reset deliberate opt-ins.
-- The shipped default lives in exactly one place:
-- Config.reapHolderChildrenEnabledDefault.
ALTER TABLE config ADD COLUMN reap_holder_children_enabled INTEGER;
