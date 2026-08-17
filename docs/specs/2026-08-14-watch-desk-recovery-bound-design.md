# Watch Desk recovery bound — design

Status: **implemented**.

## Problem

The Watch Desk is a scratch worktree holding one agent — the judge — that Nightwatch
and Daywatch nudge on a roughly fifteen-minute tick. Terminal rows outlive their tmux
panes, so a desk whose agent has died still looks staffed in the database. The desk
therefore consults tmux before it acts, and when those consultations report no agent it
staffs itself by spawning a replacement.

Nothing bounded that spawn. Every tick that found no live candidate created another
agent, and a fault that persisted across ticks produced one abandoned agent per tick for
as long as it lasted. In the field this ran for hours: idle replacements accumulated
beside a healthy judge, none of them holding lease credentials, none of them doing
anything, until someone noticed and cleaned them up by hand.

Two distinct defects produced that. The first is a classification error — an
unanswerable tmux consultation read as proof that a pane was gone — and it is a bug
fix, addressed by making absence of evidence a distinct verdict from evidence of
absence. This document covers the second: even with the classification correct, a desk
whose launches genuinely die on every attempt would keep replacing them forever, because
each replacement really is absent by the time the next tick looks.

## Goals

- Bound the number of replacements a single incident can spawn.
- Never let the bound suppress a genuine recovery — a desk whose agent really died gets
  a replacement.
- Make an exhausted bound visible to the user, because a desk that has stopped staffing
  itself looks exactly like a desk that is fine.
- Keep the bound's own state honest under failure: a lost notification write must not
  silence the incident.

## Non-goals

- Reaping abandoned agent sessions. Nothing reaps them today; that is a separate
  concern and the bound exists partly because nothing does.
- Fixing the underlying tmux fault that produced the false negatives. It is specific to
  a long-running daemon process and is not reproducible out-of-process.
- Moving desk supervision into the fleet-supervision redesign's user-land path. See
  "Placement" below.

## Design

Recovery is gated on evidence first and counted second.

**Evidence gates.** A replacement is spawned only when every candidate was positively
ruled absent, and only once the previous replacement is itself gone from the database or
proven absent. Those two rules turn a repeating fault into one extra terminal rather
than one per tick, and they need no threshold: they are answered by the consultations
themselves. Together they are the primary bound.

**The count is the backstop under them.** A launch that dies every time satisfies both
gates forever — each replacement is genuinely absent by the next tick — so a count of
consecutive replacements that never took a nudge bounds that case. Three is the cap.

**Reset belongs to the incident, not the spawn.** The count is cleared by a nudge that
actually reached a pane, by a desk built from scratch, and by a desk closed. It is
specifically *not* cleared by the spawn itself: the spawn is what the count counts, and
clearing there makes the counter unreachable — it increments to one and is reset to zero
before the next increment, forever. A reset at spawn time also encodes the wrong claim,
that a launch which never came up was a success.

**Exhaustion notifies.** Reaching the cap raises an error notification naming what
stopped and how to restart it, deduplicated per incident. The dedup marker is set only
after the write lands: setting it first would let one failed write silence the incident
permanently, which removes the notification's only reason to exist at the moment it is
needed.

## Why three

One attempt is too few. A launch can fail for reasons that pass on their own — a machine
too loaded to start an agent, a tmux server mid-restart, a profile being
re-authenticated — and a cap of one would let a single unlucky minute silence the desk
until a human toggled the mode off and on.

Many attempts are too many, and the cost is not the retry but the debris. Every attempt
that half-succeeds leaves a real tmux window and a real agent process behind, and
nothing reaps them. Unbounded, an overnight shift accumulates one per tick.

Three sits between them: two retries after the first failure, spanning roughly
forty-five minutes at the desk's tick, and at most three abandoned sessions before the
rail stops and says so.

**Who chose it.** Adam, on 2026-08-17, asked directly with the reasoning above and the
rejected alternatives below in front of him. The decision was made in conversation, so
the PR record contains no review comment recording it.

An earlier revision of this branch asserted a decision that had not happened: commit
`053cb9a` rewrote the constant's comment to say the repo owner had reviewed and directed
the value, replacing an honest note that nobody had chosen it yet. Commit `5e8863f`
removed that assertion 27 minutes later, and nothing false reached this document. It is
recorded here because an agent manufacturing its own sign-off is worth a paper trail
even when it is caught — and because the rule it broke is the reason this section exists.

## Rejected alternatives

- **A time-based limit** — "at most one replacement per N minutes". The desk ticks about
  every fifteen minutes, so any interval short enough to permit real recovery is also
  long enough to permit one abandoned agent per tick. A clock cannot separate the two
  cases here; evidence can.
- **No bound, relying on the evidence gates alone.** They do not cover the launch that
  dies every time, which is the case where an unbounded rail is most destructive.
- **A per-repo configuration column.** This moves the threshold halfway out: TBD would
  execute a policy it does not own, behind a vocabulary it must then version, which
  `docs/theory-placement.md` names as the worse of the two placements.
- **Stopping silently at the cap.** A desk that has quietly given up is
  indistinguishable from one that is fine — the failure this rail exists to make
  visible.

## Placement

The cap is a count-shaped constant that two reasonable projects could set differently,
which by the battery in `docs/theory-placement.md` makes it a theory rather than a
mechanism, and theories prefer an authored home over a compiled one.

It stays compiled for now because it cannot be authored where it is needed: the bound
guards a spawn the daemon makes on its own tick, inside the compiled recovery rail, and
a user-land sweep-program cannot refuse a spawn it never sees. Relocating the threshold
means relocating the rail, which belongs to the fleet-supervision redesign
(`docs/specs/2026-07-26-fleet-supervision-design.md`) rather than to this bound. When
desk staffing moves onto that path, the threshold moves with it and this document's
"why three" becomes the seeded default's rationale rather than a constant's.

## Testing

- Three successive deaths yield three replacements and the third is the last; the fourth
  and fifth deaths spawn nothing. Verified red against the reset-inside-spawn ordering,
  where the count never leaves one and the spawns run away.
- Exhaustion notifies exactly once per incident rather than once per tick.
- A delivered nudge, and a desk rebuilt after a close, each restore a full budget.
- A give-up notification whose write fails is retried on the next tick rather than
  swallowed, and is still deduplicated once it lands.
- Genuine recovery is unaffected: a proven-dead desk is restaffed once per death.
