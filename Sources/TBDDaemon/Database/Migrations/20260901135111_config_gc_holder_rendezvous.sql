-- Gate for the orphan-GC phase that unlinks holder rendezvous files — the
-- socket a SIGKILLed holder could not unlink, plus its sibling lock and log.
--
-- No DEFAULT clause, deliberately. ADD COLUMN ... DEFAULT would backfill every
-- existing row, destroying the distinction between "nobody has chosen" (NULL)
-- and "chose off" (0) — which is what made auto_hibernate_enabled impossible to
-- graduate without a forcing UPDATE that also reset deliberate opt-ins.
-- The shipped default lives in exactly one place:
-- Config.gcHolderRendezvousEnabledDefault.
ALTER TABLE config ADD COLUMN gc_holder_rendezvous_enabled INTEGER;
