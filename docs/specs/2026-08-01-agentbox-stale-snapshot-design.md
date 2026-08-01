# Agent Box stale-snapshot visibility

## Problem

TBD persists the last successful remote-session inventory so users can still
inspect and attach to known sessions after a provider error. Before this
change, a failed full-list refresh left those cached rows looking live and
kept inventory-dependent mutations enabled. An AWS/SSM output truncation could
therefore make a healthy Agent Box feel broken while TBD presented stale state
with false confidence.

## Decision

The provider manager owns one inventory-health boundary. Every successful full
snapshot records its time. After a later full-list failure, persisted active
rows are projected as unknown and the provider status includes the last
successful snapshot time. A daemon restart recovers that time from the newest
persisted `lastSeen` value before publishing degraded health.

While a previously successful inventory is stale, TBD keeps read-only and
recovery actions available: Attach, Log, Copy, and Pin. It blocks Create, Stop,
Send, and Rename in both the app and daemon RPC layer because each mutation
depends on inventory state that TBD can no longer verify. A first-ever provider
failure has no cached snapshot to misrepresent and retains the prior behavior.

Successful non-list verbs do not clear inventory degradation; only a complete
full-list refresh can re-establish authoritative state. Provider errors shown
in the UI are bounded and redact the known oversized/truncated payload shape.

## Boundaries

- No provider protocol, credential, or Agent Box host changes.
- No automatic retry, restart, stop, or other remote mutation.
- No TUI screen scraping.
- Cached rows remain attachable because provider session IDs are still useful
  even when their liveness is unknown.
- The daemon gate is authoritative; app disabling is explanatory defense in
  depth.

## Verification

- A healthy snapshot followed by a list failure demotes cached active rows and
  records snapshot age.
- Restart recovery reconstructs the last successful timestamp.
- Full-list recovery restores authoritative status.
- Non-list successes cannot clear stale inventory health.
- Create, Stop, Send, and Rename fail closed at the RPC boundary while Attach
  and Log remain usable.
- First-ever malformed output says that no successful snapshot exists rather
  than claiming that one is displayed.
