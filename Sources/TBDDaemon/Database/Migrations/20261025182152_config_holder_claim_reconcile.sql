-- Holder viewer-claim reconcile (docs/specs/2026-10-25-holder-claim-reconcile-design.md).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean someone
-- did. The shipped default lives only in Config.holderClaimReconcileEnabledDefault.
ALTER TABLE config ADD COLUMN holder_claim_reconcile_enabled INTEGER;
