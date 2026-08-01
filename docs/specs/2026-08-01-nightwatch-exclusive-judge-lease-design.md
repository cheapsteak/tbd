# Nightwatch exclusive judge lease

**Status:** approved in issue #567; materialized for implementation on 2026-08-01.

## Problem and invariant

A Watch Desk may have several live terminals, but exactly one may hold mutable judge authority. Agent kind, tab label, creation time, and pane liveness are discovery signals, not authority. A second live terminal must remain an observer until ownership transfers atomically.

## Chosen design

The daemon owns a durable, generation-fenced lease per Watch Desk. A new SQLite table stores the desk worktree, holder terminal, opaque token, monotonically increasing generation, and expiry. Acquisition, renewal, transfer, release, and validation execute in one database transaction. An expired lease can be acquired by a successor; an unexpired lease can only be renewed or transferred by its current token and generation. Every transfer increments the generation and replaces the token, so a predecessor is fenced immediately.

Terminal rows gain an explicit `watchRole`: `judge`, `readOnlyCoordinator`, or no role. This is persisted and returned over RPC so the app can label Judge and Read-only tabs without inferring authority. Lease state is authoritative if a stale role marker disagrees with it.

The production desk manager acquires a lease for the live configured-agent terminal before sending a judge nudge. If another unexpired holder exists, it fails closed: no prompt is sent and one notification identifies the conflict. If a holder's pane or process disappears, the manager revokes it before selecting a successor. Normal observer terminals remain untouched, including their transcripts and independently spawned children.

The CLI exposes `tbd nightwatch lease status|validate|renew|transfer|release`. Judge instructions carry the terminal, token, and generation and require validation immediately before merge, apply, archive, wake/nudge, or worker-spawn actions. Handoff uses atomic transfer after the successor terminal exists; the successor may not act until it receives the returned token and generation. Direct external commands cannot be intercepted by TBD, so this version combines a daemon-enforced single nudge target with an explicit fail-closed validation command at each mutation boundary.

## Recovery and timing

The default lease lifetime is two minutes. A valid holder renews on every nudge and through explicit CLI renewal while working. A crash therefore becomes recoverable after at most two minutes without killing the terminal row or transcript. An operator may transfer an unexpired lease only with the current credentials. Turning watch mode off releases the lease after posting the shift wrap-up.

All expiry comparisons use an injected `now` closure. Generation is never reset or reused for a desk, including after expiry or release.

## Observability

Lease status reports desk, terminal, role, generation, acquisition/renewal/expiry timestamps, and whether it is currently valid. Contention produces one deduplicated task notification per conflicting lease generation and an OS log entry. Tabs display a compact `Judge` or `Read-only` suffix.

## Failure behavior

- Two acquisition attempts serialize in SQLite; only one receives the lease.
- Renewal with an old token or generation fails without extending the lease.
- Transfer commits the successor and fences the predecessor in the same transaction.
- A missing/dead owner is revoked by the desk manager; a stale database row is never sufficient.
- If lease persistence or validation fails, the desk does not nudge or mutate.
- Read-only observers can inspect status but cannot validate mutable authority.

## Tests

Store tests cover contention, renewal, expiry takeover, stale-token rejection, atomic transfer, release, and observer denial. Desk tests cover two live candidates, dead-owner recovery, Claude-to-Codex and Codex-to-Claude transfer semantics, stale rows, exactly one nudge target, and deduplicated conflict notification. Shared-model and CLI tests cover backward-compatible role decoding and machine-readable status/validation output.

## Scope

This change does not enable a second Watch Desk, alter live desk state, merge or apply anything, or broaden Nightwatch's existing protected-PR rules. It establishes ownership and fencing for the existing single-desk architecture from #562.
