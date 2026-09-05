# Remote snapshot ordering — design

**Date:** 2026-08-26
**Status:** Implemented.
**Scope:** TBD-side only. No contract change: the field this reads,
`agent_state_at`, has been in the provider contract since v1 and was simply
never read.

## The question this answers

TBD's remote-session mirror is fed by three channels that nothing serializes
against each other: the periodic `list` poll, the `events` stream, and the
session objects that verb responses (`create`, `stop`, `rename`, `archive`)
return. Each writes through the same upsert, which was last-writer-wins.

So arrival order is not observation order. A `list` response that spent four
seconds in flight lands after an `events` line that observed the same session
later, and the mirror ends up holding the older reading. On the agent axis
that is not cosmetic: it restores a `waiting_input` a human already dealt
with, and the sidebar puts the attention hand back on a session that has been
working for minutes — where, the state having already transitioned once,
nothing short of the *next* genuine transition can clear it again.

The contract already carries the fact that distinguishes the two orderings:
`agent_state_at`, the instant the agent state was determined. This design is
what TBD does with it.

## The rule

For each session in a sighting, compare the incoming `agent_state_at` against
the one in the mirrored payload:

- **Both parse, and incoming is strictly older** → the sighting's **agent
  axis** is withheld; the mirrored `agent_state`, `agent_state_reason` and
  `agent_state_at` are kept.
- **Anything else** → apply, exactly as before.

Three deliberate conservatisms, all in the same direction: the cost of
wrongly *rejecting* a sighting is a row frozen at a state the provider has
moved on from — precisely the bug being fixed, arrived at from the other
side — while the cost of wrongly *accepting* one is the pre-existing
behavior. So every ambiguity resolves toward applying.

- **No stamp on either side applies.** `agent_state_at` is optional and most
  providers will never send it. A provider that sends none must see byte-for-
  byte the previous behavior.
- **Equal stamps apply.** A provider stamping at second granularity would
  otherwise have every update after the first within one second dropped, and
  re-applying an identical state costs nothing.
- **A future-dated *stored* stamp disables the check.** A provider whose
  clock ran ahead, or that stamped a state before observing it, would
  otherwise make every later sighting "older" forever. That freezes the row
  permanently, with no path back — strictly worse than the bug. The
  allowance is a clock-skew tolerance of one minute: far more skew than an
  NTP-synced machine shows, far less than a genuinely wrong clock. It is
  deliberately not derived from the 60-second poll interval it happens to
  match; the two answer unrelated questions, and coupling them would make a
  change in poll cadence silently redefine what counts as a broken clock.

## Why only the agent axis

`agent_state_at` timestamps the agent state. It says nothing about when the
title, the terminal state, `meta`, or `archived` were determined, so
withholding those on its evidence would be inventing a claim the provider
never made — and would have a concrete cost: a `rename` response echoes the
session object with a new title and whatever agent stamp it happens to hold,
so rejecting the whole payload would silently drop renames.

Both halves of the agent axis move together or neither does. A mirrored
payload whose `agent_state` and `agent_state_at` disagreed would make the
*next* ordering decision meaningless, so the merge takes state, reason and
stamp from the same side.

## What a withheld sighting still does

- **Presence is never withheld.** The session was there to be reported,
  whenever the report was taken, so `lastSeen`, `missingCount` and `gone` are
  refreshed exactly as they would be. The contract's two-absence rule is
  untouched, and a session cannot drift toward `gone` because its state was
  stale.
- **No attention edge fires.** The daemon raises a notification on an
  observed transition into `waiting_input` or `exited`. An edge TBD did not
  observe going forward is not one to notify about.
- **`changed` reports honestly.** A sighting whose merged payload equals the
  stored one is not a change, so it costs no UI broadcast; one that also
  cleared a pending absence is.

## Rejected alternatives

- **Serializing the channels.** The push stream exists precisely so state
  arrives without waiting for the next poll; funnelling both through one
  queue would give back the latency the stream buys, and would still not
  order a response against a poll that was already in flight.
- **A monotonic sequence number added to the contract.** Stronger, and not
  free: every provider would have to implement it before any of them
  benefited, whereas `agent_state_at` is already specified, already emitted
  by providers that have it, and degrades to today's behavior for the rest.
  Worth revisiting only if a provider is found whose stamps are unusable.
- **Storing the stamp in its own column.** The mirrored payload is already
  the record of what the provider last said; a column would be a second copy
  of one fact, which some future write path would forget to keep in step. The
  common path decodes one field out of the stored JSON, and the full decode
  is paid only on the rare sighting that actually is out of order.
- **Trusting the local clock instead of the stamps.** Arrival time is what
  produced the bug; ordering by it is the bug.
