-- Clone-backed worktree checkout (docs/specs/2026-10-09-clone-backed-worktree-checkout-design.md).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean someone
-- did. The shipped default lives only in Config.cloneCheckoutDefault.
ALTER TABLE config ADD COLUMN clone_checkout_enabled INTEGER;
