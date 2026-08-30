-- The durable whitelist `ShadowPeerReconciler` reclaims against
-- (`docs/specs/2026-08-29-remote-peer-messaging-design.md`, "Reclamation and
-- detection").
--
-- Why a table and not an in-memory dictionary: a shadow peer's record carries
-- no field Claude Code does not itself define — one unknown key was measured to
-- make a record silently absent from every listing while surviving on disk — so
-- TBD cannot mark its own records from the inside, and cannot recognise them by
-- inspecting a path either. Its own bookkeeping is the only recognition it has,
-- and a shadow whose row is lost is a shadow nothing can recognise: its helper,
-- its socket and its record then outlive every daemon forever. The bookkeeping
-- therefore has to survive a daemon restart.
--
-- One row per helper process, keyed by its pid, because the two file artifacts
-- are named after that pid (`<pid>.json`, `<pid>.sock`) and at most one process
-- can hold a pid at a time. A pid TBD spawns a new helper under is by
-- construction one whose previous occupant is gone, so replacing the row on
-- conflict is correct rather than lossy.
--
-- `proc_start` is the kernel's start time for that pid at publication, and it is
-- the whole recycled-pid discriminator: Claude Code's reaper checks pid liveness
-- and nothing else (measured), so a record whose pid has been reused by an
-- unrelated process survives that reaper forever. It is nullable because the
-- kernel can refuse the read, and a NULL means "cannot prove this pid is still
-- ours" — which the sweep treats as a reason never to signal it, not as a
-- licence to.
--
-- `session_id` is the id inside the record the helper published. It is what
-- lets the sweep prove a file at a recorded path is still TBD's own before
-- unlinking it, rather than deleting a live session's record that a recycled
-- pid wrote over the same path.
--
-- `daemon_generation` names one daemon lifetime, so records published by a
-- previous generation are recognisable as such — the fourth thing the design
-- requires reclaiming.
--
-- No feature flag lives here: this is the reclaimer's ledger, not the feature.
-- Rows only ever exist when the bridge published something, and gating the
-- sweep on `remote_peer_messaging_enabled` would strand every artifact the
-- moment somebody turned the feature off.
CREATE TABLE IF NOT EXISTS shadow_peer_artifact (
    pid INTEGER PRIMARY KEY NOT NULL,
    provider TEXT NOT NULL,
    handle TEXT NOT NULL,
    name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    proc_start TEXT,
    socket_path TEXT NOT NULL,
    record_path TEXT NOT NULL,
    daemon_generation TEXT NOT NULL,
    published_at DATETIME NOT NULL
);
