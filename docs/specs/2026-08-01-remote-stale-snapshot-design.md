# Remote provider stale-snapshot visibility

## Problem

TBD persists the last successful remote-session inventory so users can still
inspect and attach to known sessions after a provider error. Before this
change, a failed full-list refresh left those cached rows looking live and
kept inventory-dependent mutations enabled. A remote host can be healthy while
its unbounded `list` response is truncated by the transport, so a
provider-path failure was indistinguishable from real remote work: TBD
presented stale state with false confidence.

## Decision

The provider manager owns one inventory-health boundary. Every successful full
snapshot records its time in the same database transaction as the mirror update.
The timestamp is separate from per-session `lastSeen`, because the independent
events stream can update rows without proving that the full inventory works.
After a later full-list failure, persisted active
rows are projected as unknown and the provider status includes the last
successful snapshot time. A daemon restart recovers that time from the dedicated
persisted `tbd_meta` snapshot timestamp before publishing degraded health.

While a previously successful inventory is stale, TBD keeps read-only and
recovery actions available: Attach, Log, Copy, and Pin. It blocks Create, Stop,
Send, and Rename in both the app and daemon RPC layer because each mutation
depends on inventory state that TBD can no longer verify. A first-ever provider
failure has no cached snapshot to misrepresent and retains the prior behavior.

Successful non-list verbs do not clear inventory degradation; only a complete
full-list refresh can re-establish authoritative state. Provider errors shown
in the UI are bounded and redact the known oversized/truncated payload shape.

Fail direction is decided by what the daemon can prove, not by convenience.
"No successful snapshot was ever recorded" is positive knowledge — the mirror
was never authoritative, so there is nothing to misrepresent and mutations
stay enabled. A freshness read that *fails* proves nothing, so it gates
instead: it is recorded distinctly from a confirmed absence, reports its own
health text, and clears as soon as a read succeeds or a live snapshot lands.
Conflating the two would let a database error silently buy back the exact
false confidence this change removes.

## Boundaries

- No provider protocol, credential, or remote host changes.
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
- An unreadable persisted freshness row gates mutations and claims no age,
  and stops gating once a snapshot succeeds.
