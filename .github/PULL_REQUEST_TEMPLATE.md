<!--
Pick the variant that matches this PR and delete the other, including these
instructions. Refactors, DX, and ops changes use the FEATURE skeleton, with
Summary carrying the motivation. Replace each section's guidance comment with
prose. Sections whose guidance marks them optional may be deleted outright
when they don't apply. This repo is public: no org, ticket, or host names —
see CLAUDE.md.
-->

<!-- ═══════════════════════ BUG FIX ═══════════════════════ -->

## What's broken

<!-- The symptom, as experienced. What you saw, what should have happened, who
hits it and how often. The reader should be able to picture the failure before
any code is mentioned. -->

## Why it happens

<!-- The mechanism, in plain language — pragmatics and semantics, minimal
syntax and jargon. Someone who has never opened these files should understand
the bug after this section; name files or functions only where they anchor the
story. If the root cause is confirmed, state it as fact. If not, open with
"Hypothesis:" and say what evidence supports it and what would refute it. -->

## When it broke

<!-- Optional — delete unless it's a regression. The PR or commit that
introduced it, and why it slipped through (untested branch, unmodeled
interaction, …). -->

## What this PR does

<!-- The fix, and why this approach over the alternatives considered. -->

## Assumptions

<!-- Optional — delete if none worth recording. Things this change takes to be
true but does not enforce or verify: environment invariants, other components'
behavior, usage patterns, scale. State each so a future reader debugging a
misbehavior can check whether it still holds — "assumes X; if X stops being
true, Y breaks". -->

## Evidence & verification

<!-- How we know the fix works — not just that nothing else broke:
- The repro: how the bug was reproduced before the fix.
- Discriminating evidence: a test that fails without the fix, or a concrete
  before/after observation. "Tests pass" alone is not evidence.
- Live verification when the change is user-visible: what you did in the
  running app and what you saw. -->

<!-- ═══════════════════════ FEATURE ═══════════════════════ -->

## Summary

<!-- The job to be done: who this is for, what they can do now that they
couldn't, and why it matters. Pragmatics and semantics, minimal syntax and
jargon — explain it the way you'd explain it to a user, not a compiler. -->

## Why this shape

<!-- Design rationale: the key decisions, rejected alternatives worth naming,
and a link to the spec (docs/specs/<date>-<topic>-design.md). If this change
shipped without a spec, say here why it didn't need one. -->

## What this PR does

<!-- The implementation at survey altitude: what got added or changed, where.
Bullets are fine. -->

## Flag & rollout

<!-- Required when the feature is gated; delete otherwise. Flag name, default
(should be OFF), how to enable it for the soak, and the graduation plan. -->

## Assumptions

<!-- Optional — delete if none worth recording. Things this change takes to be
true but does not enforce or verify: environment invariants, other components'
behavior, usage patterns, scale. State each so a future reader debugging a
misbehavior can check whether it still holds — "assumes X; if X stops being
true, Y breaks". -->

## Evidence & verification

<!-- How we know it works: a test per branch of any new flag or conditional,
live verification for anything user-visible, and what you did in the running
app to confirm it. -->
