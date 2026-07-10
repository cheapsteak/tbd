# Design: Pending-typed-input detection without TUI scraping

*2026-07-09. Grounded in a read of the live hibernation stack on `upstream/main`
(`HibernationSafetyChecks.swift`, `HibernationGate.swift`,
`HibernationCoordinator.swift`, the v39/v50 migrations), the Claude-hook overlay
(`ClaudeHookOverlay.swift`), and the tmux input pipeline
(`ControlModeInputRouter.swift`). Addresses gap #1 of issue #421.*

## Problem

Auto-idle-hibernate is the lever that keeps a 40-worktree fleet out of swap
(live Claude session ≈ 70 MB RSS → parked ≈ 0). It was **forced off by default**
in migration `v50_auto_hibernate_idle_sweep_off_by_default` for one reason,
spelled out in that migration's own comment:

> The idle sweep drives `HibernationSafetyChecks.hasPendingInput`, a sanctioned
> TUI screen-scrape whose failure direction is asymmetric: if Claude Code
> changes its `>` composer rendering, typed-but-unsent input goes unrecognized
> and gets EATEN by the park.

Today the *sole* guard against eating half-typed input is
`HibernationSafetyChecks.hasPendingInput(paneCapture:)` — a `capture-pane`
snapshot scanned bottom-up for a `>` prompt line with non-placeholder content.
It is a good heuristic, but it is coupled 1:1 to Claude Code's TUI. The moment
Anthropic reshapes the composer (a different prompt glyph, a full-width box, a
status line below the input, a theme that recolors the gutter), the scraper
silently returns `false` ("no pending input") and the sweep parks a pane with a
half-composed prompt. That is the single worst failure this feature can have —
the Chrome "discarding lost my typed text" backlash the code comments already
cite — and it is why the default is off.

**Goal:** add a pending-input signal that does **not** depend on parsing the
Claude TUI, so a Claude Code UI change fails *safe* (blocks the park) instead of
silently eating input. Once that signal exists and has soaked, the `v50`
default-off can be reverted in a later change. This design delivers the
detector, flag-gated and default-off; **it deliberately does not flip the
sweep's master default back on** (that is the post-soak follow-up, and keeps
this diff scoped to the detection layer while another session lands the
`HibernationCoordinator` wake-path changes for the same issue).

This is also exactly the direction the CLAUDE.md **"No TUI screen-scraping"**
rule now mandates: get agent state from machine interfaces — Claude Code hooks,
transcript JSONL, **tmux control-mode events** — not rendered screen text.
`HibernationSafetyChecks.hasPendingInput` is one of three *sanctioned legacy
scrapers* the rule explicitly excludes "with refactor-later intent … [it] should
eventually migrate off screen text." This design is that migration: the
control-mode input pipeline becomes the primary machine-interface signal, and
the scrape is demoted to a soak-window backup on a path to removal (see Future
work #1).

## Investigation findings (verified against `upstream/main`, not assumed)

1. **Every user keystroke already flows through the daemon.** The app does not
   write to the PTY directly. `TBDTerminalView` → `FDSidecarClient.sendInput`
   → the daemon's `ControlModeInputRouter`, whose `deliverInput` /
   `deliverPaste` emit `send-keys -H` on the pane. There is a single daemon-side
   chokepoint through which *all* typed input passes — a place to stamp "last
   input at" that owes nothing to how the TUI looks.

2. **Claude Code emits no composer-level event.** The hook overlay
   (`ClaudeHookOverlay`) registers `SessionStart`, `Stop`, `StopFailure`,
   `UserPromptSubmit`, and `PreToolUse/PostToolUse:AskUserQuestion`. These are
   **turn-boundary** events: `UserPromptSubmit`→`working`, `Stop`→`idle`, etc.
   The finest-grained "user did something" signal Claude Code exposes is
   *prompt submitted* — i.e. after the user pressed Enter. Nothing fires while
   the user is *typing* into the composer. So "composer state via session
   instrumentation" (option b below) cannot be built on today's hook surface.

3. **`activityState` already gates the coarse states.** `HibernationGate.blockingRail`
   already blocks `.working` and `.waitingForUser`. The residual danger is
   exactly the state hooks *can't* distinguish: **idle, but with unsent text in
   the composer.** That is the gap this design fills.

4. **The idle marker is in-memory and resets on restart.** `idleSince` is a
   `[UUID: Date]` map on the coordinator, seeded during the sweep and cleared on
   any activity transition; it is not persisted. After a daemon restart every
   terminal re-seeds `idleSince = now`, so nothing is "idle long enough" for a
   full `hibernateIdleMinutes` window post-restart. That existing behavior gives
   any in-memory input tracker a natural grace period to repopulate before the
   sweep can act (relevant to fail-safe below).

## Options evaluated

### (a) Keystroke tracking at the input pipeline — **chosen as primary**

Stamp a per-pane `lastInputAt` timestamp at the daemon-side input chokepoint
(`deliverInput` / `deliverPaste`), then veto the park if input arrived **at or
after** the moment the session went idle (`lastInputAt >= idleSince`).

- **TUI-independent.** It observes bytes entering the pane, not pixels leaving
  it. A Claude Code composer redesign cannot break it.
- **Conservative by construction.** *Any* input byte since idle vetoes — a bare
  Enter, Ctrl-C, an arrow key, or real text. All false positives are in the
  safe direction (skip one park this sweep; the issue explicitly accepts that
  cost). The only *permanent* veto is type-then-never-send-never-clear, which is
  precisely the case we must protect.
- **Self-clearing.** When the user finally sends (`Enter`→`working`→`Stop`→a
  new, later `idleSince`), `idleSince` advances past `lastInputAt` and the veto
  releases with no extra bookkeeping.
- **Cheap.** One dictionary write per input frame (already the granularity of
  `InputLatencyRecorder`), one comparison per sweep. No pane capture.

Weakness: in-memory, so a daemon restart forgets pre-restart typing. Covered by
(c) below and by finding #4's post-restart grace window.

### (b) Composer state via Claude Code session instrumentation — **rejected**

Finding #2 is decisive: Claude Code exposes no composer/keystroke hook. The only
session signal is turn-boundary state, which TBD already consumes and which by
definition cannot see "idle with half-typed text." Building (b) would require an
upstream Claude Code change (a new hook or a queryable composer-dirty bit) that
does not exist today. Recorded as a future possibility, not a current option.

### (c) Keep the scrape as a second, independent veto — **retained for the soak window only**

`hasPendingInput(paneCapture:)` stays exactly where it is, in
`performHibernate`, as a second veto re-checked at the kill instant. It covers
(a)'s one weakness — after a daemon restart the in-memory `lastInputAt` is empty,
but the scrape still reads the live pane. The two vetoes are independent (one
reads the input pipeline, one reads the rendered pane) and a park proceeds only
when **both** agree there is no pending input. Neither is load-bearing alone.

This is a *transitional* retention, not a permanent backup. The "No
TUI screen-scraping" rule wants this sanctioned scraper gone; keeping it while
the input veto soaks is the safe way to get there (two independent vetoes during
the risky window), and removing it once the input veto is trusted is tracked as
Future work #1 — that removal is what actually discharges the rule's
migrate-off-screen-text intent and deletes the `HibernationSafetyChecks.swift`
lint exclusion.

## Recommendation

**(a) as the new primary veto + (c) retained as the second veto; (b) rejected as
infeasible on today's hook surface.** This is the layered defense the issue asks
for: the primary signal is now TUI-independent, and the scrape degrades from
"sole guard" to "backup." A Claude Code UI change now costs *at most* the loss of
the backup veto, with the primary still blocking the park — the failure mode is
"we skip an eligible park," never "we eat typed input."

## Design

### Component A: `InputActivityTracker` (new, `Sources/TBDDaemon/Tmux/`)

A small `Sendable` actor (or lock-guarded final class, mirroring
`InputLatencyRecorder`) keyed by tmux `paneID`:

```swift
func recordInput(paneID: String, at: ContinuousClock.Instant /* + wall Date */)
func lastInput(paneID: String) -> Date?
func forget(paneID: String)   // called when a pane is respawned/closed
```

- Written from `ControlModeInputRouter.deliverInput` **and** `deliverPaste`
  (paste into the composer is pending input too) — the single chokepoint.
- Read by `HibernationCoordinator` during the sweep, translating
  `terminal.tmuxPaneID` → `lastInput(paneID:)`.
- In-memory only, matching `idleSince`. Keyed by paneID (not terminal UUID)
  because the router speaks paneIDs; a paneID reused after respawn can only
  *add* a stale veto, never drop a real one — the safe direction. Pruned
  alongside the coordinator's existing `idleSince` prune, plus a `forget` on
  respawn.

Storing a wall-clock `Date` (comparable to `idleSince`) as well as the
`ContinuousClock.Instant` the latency path uses; the sweep compares against
`idleSince`, which is a `Date`.

### Component B: the veto in `HibernationGate.decide` (pure, unit-testable)

Add two parameters and one `Decision` case, consistent with how
`autoHibernateEnabled` is already threaded into the gate:

```swift
public enum Decision {
    ...
    case pendingTypedInput   // idle, but input arrived after it went to rest
}

public static func decide(
    terminal: Terminal,
    autoHibernateEnabled: Bool,
    inputVetoEnabled: Bool,        // NEW — the soak flag
    idleTimeout: TimeInterval,
    idleSince: Date?,
    lastInputAt: Date?,            // NEW — from InputActivityTracker
    now: Date
) -> Decision {
    guard autoHibernateEnabled else { return .featureDisabled }
    if let blocked = blockingRail(terminal: terminal) { return blocked }
    guard let idleSince, now.timeIntervalSince(idleSince) >= idleTimeout else {
        return .notIdleLongEnough
    }
    if inputVetoEnabled, let lastInputAt, lastInputAt >= idleSince {
        return .pendingTypedInput
    }
    return .eligible
}
```

Placed *after* the idle-duration check: we only consult the input veto for an
otherwise-eligible terminal. The gate stays pure and actor-free — both flag
branches and the veto boundary are testable with plain values. `sweep()` treats
`.pendingTypedInput` like the other non-go cases (reset `pendingKillSince`, keep
the `idleSince` marker so the clock isn't punished, log the precise reason).

`decideForMerge` is left untouched: merge-park is a distinct trigger and keeps
its own rails; adding the input veto there is a possible follow-up but out of
scope here.

### Component C: scrape unchanged

`performHibernate` keeps its `hasPendingInput(paneCapture:)` re-check verbatim.
No change — it is now the *second* veto rather than the only one.

### Component D: the soak flag

A new config column, `hibernate_input_veto_enabled`, added in the next migration
(`v51_…`), **default `false`** — following the CLAUDE.md migration rules (add
column with a default, update the GRDB record, update the `Config` model in
`TBDShared/Models.swift`, all in one commit; new field optional/defaulted so
existing rows decode). The coordinator reads it and passes `inputVetoEnabled`
into the gate.

Flag semantics:
- **OFF (default, today's behavior):** the input veto is never consulted; the
  scrape alone guards, exactly as on `main`. The `v50` sweep default also stays
  off, so nothing changes for users until they opt in.
- **ON (soak):** the input veto is the primary guard; the scrape is the backup.
  Dogfooded on the author's fleet to measure veto rate (how often real input is
  correctly caught vs. how often benign input needlessly skips a park) before
  proposing the `v50` revert.

Deliberately **not in this change:** flipping `autoHibernateEnabled`'s default
back on. That is the payoff, but it waits until the detector has soaked — and it
touches the same master-switch surface the concurrent `HibernationCoordinator`
work is on.

### Data flow

```
user types  ─▶ TBDTerminalView ─▶ FDSidecarClient.sendInput
            ─▶ ControlModeInputRouter.deliverInput/deliverPaste
                   ├─ send-keys -H  (unchanged)
                   └─ InputActivityTracker.recordInput(paneID, now)   ← NEW

sweep()  ─▶ for each Claude terminal:
             lastInputAt = InputActivityTracker.lastInput(terminal.tmuxPaneID)
             HibernationGate.decide(..., inputVetoEnabled, lastInputAt, ...)
               ├─ .pendingTypedInput ─▶ skip (primary veto)          ← NEW
               └─ .eligible ─▶ performHibernate
                                 └─ hasPendingInput(capture) ─▶ skip (backup veto)
```

## Testing

Both flag branches and the fail-safe path get explicit coverage (per CLAUDE.md's
"add a test for each branch of a gating conditional"):

**`HibernationGate` unit tests (pure):**
- Flag ON + `lastInputAt >= idleSince` + idle long enough → `.pendingTypedInput`.
- Flag OFF + same inputs → `.eligible` (proves the veto is truly gated;
  regression-guards today's behavior).
- Flag ON + `lastInputAt < idleSince` (input was consumed by the last turn) →
  `.eligible`.
- Flag ON + `lastInputAt == nil` (no input recorded, e.g. post-restart) →
  `.eligible` from the gate — the scrape is what covers this branch (below).
- Precedence: `.running` / `.waitingForUser` / `.notIdleLongEnough` still win
  over the input veto where they should.

**`InputActivityTracker` unit tests:**
- `recordInput` then `lastInput` returns the stamp; `forget` clears it; unknown
  pane returns `nil`.

**Fail-safe / belt-and-suspenders (the headline guarantee):**
- **TUI-break simulation:** feed `performHibernate`'s path a `paneCapture` the
  scraper does *not* recognize (`hasPendingInput` returns `false`, mimicking a
  composer redesign) **while** `lastInputAt > idleSince`. Assert the overall
  decision blocks via `.pendingTypedInput` — i.e. the input veto catches what
  the scrape misses. This is the test that proves "a Claude Code UI change fails
  safe."
- **Restart simulation:** `lastInputAt == nil` but the live pane shows composer
  text → the scrape veto in `performHibernate` still blocks. Proves the backup
  covers (a)'s one gap.

**Integration (coordinator sweep):**
- With the flag ON, a terminal that receives an input frame after going idle is
  not parked on the next sweep; after it "sends" (idle marker advances past the
  input), it becomes eligible again.

## Future work (fast-follow, tracked after soak)

1. **Remove the scrape + revert `v50`.** The payoff, in one post-soak PR: once
   the input veto's veto rate is acceptable, delete `hasPendingInput` and its
   `HibernationSafetyChecks.swift` lint exclusion (discharging the "No TUI
   screen-scraping" migrate-off intent), and flip the sweep's master default
   back on. Coordinated with the wake-path work.
2. **Reduce benign false positives.** If the soak shows the veto skipping too
   many parks, refine "any input" → "any input that isn't a lone submit/cancel"
   (reset the marker on a bare Enter or Ctrl-C, which submit or clear the
   composer). Kept out of v1 to stay maximally conservative.
3. **Upstream composer-dirty signal (option b).** If Claude Code ever adds a
   hook or queryable "composer non-empty" bit, promote it to the primary — an
   even cleaner machine interface than the input pipeline.
4. **Extend the veto to `decideForMerge`** if merge-park ever eats input in
   practice.

## Success criteria

- A simulated Claude Code composer redesign (scraper blind) **cannot** cause a
  park that eats typed input, as long as the input arrived after the session
  went idle — proven by the TUI-break test.
- Flag OFF reproduces today's behavior byte-for-byte (regression test green).
- The detector is purely additive to safety: it can only *add* vetoes, never
  remove an existing one.
- Diff is scoped to the detection layer (input router, tracker, gate, config
  flag, migration) — no changes to the wake path or the master default that the
  concurrent `HibernationCoordinator` work owns.
