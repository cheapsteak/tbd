# In-place profile swap on holder rows

## Summary

"Switch account" on a terminal tab swaps the running Claude Code session to
another model profile while keeping the tab, the terminal row, and the session
id. On the tmux transport it is built on `tmux respawn-window -k`: the daemon
interrupts the pane's Claude and respawns `claude --resume <id>` under the new
profile in the same window, and the attached viewer keeps painting throughout.
A holder row has no window, so `terminal.swapProfile` in `.inPlace` mode
refuses it today (`holderInPlaceSwapRefusal`) and sends the user to "Fork
session", which lands the conversation in a new tab under a new session id.

This spec replaces that refusal with a holder arm composed of three verbs the
daemon already has and that already soak in the field: **park** the row
(the holder half of hibernation), **re-home** its profile (the cold swap a
parked row already takes), and **wake** it (the holder half of wake, which
spawns a fresh holder running the resume). One actuation, one tab, one row,
one session id. The tab shows the session's last frame under a "Switching
account to <profile>…" caption for the duration of the ladder, and then the
resumed session under the new profile.

The decisions a human made, in order:

- **Same tab with a visible blink, not a seamless replacement.** On a holder
  the pty dies with the child (`forkpty`), so no holder replacement can keep
  the viewer's existing attachment painting the way tmux's respawn does. A
  seamless variant would need a new holder verb, a protocol version bump that
  every holder born before it cannot answer, and a new hand-over seam through
  the viewer. The blink buys all of that back for no new binary.
- **The swap interrupts regardless, matching tmux.** The holder park has
  refusal rails the tmux swap does not: typed-but-unsent composer text, a
  transcript tail that is mid-write, and a screen that is not a trustworthy
  daemon-rendered projection. The swap bypasses all three. The tmux arm has
  never honoured any of them, and a "Switch account" that refuses after a
  daemon restart until the re-adopted screen is observed again was judged
  worse than a swap that drops typed text.
- **No new flag.** The holder transport is itself gated by
  `pty_holder_enabled`, the action needs a user gesture, and every failure
  point lands the row in a state an existing path owns (see "Failure
  outcomes"). The tmux arm has never been gated. CLAUDE.md's flag rule names
  process-killing behaviour; this PR says in its description why it adds
  none, as that rule allows.

## The flow

`handleTerminalSwapProfile` keeps everything it does before the transport
branch: resolve the destination profile, carry the session transcript into the
destination config dir, seed trust, build the spawn command from
`planTerminalSwap` (a resume, or a fresh spawn when the session is blank), and
open one `terminalSwapProfile` actuation naming the row. The `.inPlace` branch
gains a holder arm beside the tmux one. In order:

1. **Park**, through `performHolderHibernate` with a new eligibility policy,
   `HibernateEligibilityPolicy.profileSwap`. Under it the park skips the
   typed-input rail and the screen-trust rails, and skips the
   transcript-tail rail. It still reads the screen once, as a display capture
   only: a readable daemon-rendered frame becomes the row's
   `suspendedSnapshot`, the tab's backdrop, as it does for every park, and an
   unreadable one leaves the snapshot empty. Neither what the frame shows nor
   whether it can be read refuses the park. Everything else is the park as it stands: park
   intent is written before the process is touched, then the ending ladder —
   polite `/exit`, poll, `SIGTERM` to the identity-verified child, abandon the
   holder — and the same "child survived the escalation" outcome, which
   rolls the park intent back and leaves the row awake. The row parks with
   reason `.auto`, so a daemon that dies between the halves leaves a row the
   next focus-wake heals, not one that needs a manual wake.
2. **Re-home**, which is the existing cold-swap block: set the parked row's
   `profile_id` to the destination profile and broadcast
   `terminalProfileChanged`. The transcript carry already happened upstream.
   On a fresh plan the row must also name the new conversation, and that id
   and its transcript path are written in the **same guarded statement** as
   the profile, under the same compare-and-set — the commitment the tmux arm
   makes through `prepareProfileAgentRespawn`. One write, so there is no
   second one left to fail after the profile has moved.
3. **Wake**, through `wakeHolderSection` with the swap's own spawn command and
   a model-proxy route minted the way `HibernationCoordinator.wake` mints
   one. The section rather than the public `wake` entry, because `wake`
   always resumes and the swap's plan may say fresh: a blank session swapped
   on tmux spawns fresh rather than showing "no conversation found", and the
   holder arm matches it.

The arm holds a **swap claim** on the row for the whole of that composition,
taken before the park and released after the wake on every exit. Each of the
three verbs singleflights itself and releases when it returns, so between the
park and the re-home the row is parked and unclaimed — and the app wakes
exactly the active tab's parked terminal on a selection change, which is the
very tab "Switch account" was pressed on. Without a claim spanning the
composition an ordinary focus-wake lands in that window, un-parks the row and
starts a session under the account being switched away from; with it, such a
wake answers in-flight and the swap proceeds. The swap's own park and wake are
unaffected by construction rather than by a flag: the park consults only the
hibernate singleflight, the wake half the swap calls consults only that and the
wake singleflight, and the claim is read by the public wake alone. A swap of a
row some other park, wake or swap already holds is refused before anything is
touched.

Park comes before re-home, and the order is load-bearing. If the profile were
re-homed first and the child then survived the ladder, the row would claim the
new account while the old process ran on under the old one — the state the
current refusal exists to prevent. With park first, every point at which the
daemon could die lands in a state something owns: parked under the old profile
(the next focus-wake resumes it there, and a retry of the swap takes the cold
path), or parked under the new one (the next focus-wake resumes it there).

The app holds a per-terminal "switching account" record for as long as the
RPC is in flight, set before it is sent and cleared when it returns, on
success or error. It is set only for a row the app holds awake: a parked row
takes the cold path and has no park or wake to ride, and a second swap on a
row already switching neither replaces nor clears the first's record. An ordinary pane's identity includes the row's parked state,
so it rebuilds on each flip; a switching pane's identity leaves the parked
state out, so it rebuilds once, when the record clears or the wake's fresh
attach arrives, and not on the park. While switching, the placeholder shows
the park's snapshot under the "Switching account to <profile>…" caption, with
no hibernation banner. When the swap fails the record clears and the row
renders whatever state it was left in. The mid-turn warning on "Switch account"
(`busyCaption`, shown when `activityState == .working`) applies as it does
for tmux. The response is the updated row with the same terminal id, as the
tmux arm returns. The wake's minted incarnation id rides on the row as it does
after any wake.

## Failure outcomes

Each half fails into a named state, and the RPC error names the half:

- **Park refused (including a park already in flight for this row, whose
  outcome the swap cannot know), or the child survived the ladder.** The row
  stays awake on the old profile with nothing about it changed. The actuation
  finishes `transportFailed` with the park's reason. Same shape as the tmux
  arm's failed interrupt. An in-flight park belongs here because park intent is
  written before the ladder runs and a surviving child rolls it back: a swap
  that re-homed on the strength of that intent could leave the row awake under
  the new account with the old process still running. The retry is sound
  whichever way the ladder went — a row it parked takes the cold path, and a
  row it rolled back is parked by the retry itself.
- **The row changed under the switch.** The re-home's compare-and-set found a
  row that is no longer the one the park left — deleted, or moved by something
  the swap claim does not cover, such as a worktree whose status left the set
  the guarded write is allowed in. Nothing was recorded, and the error says so
  rather than claiming to know where the row is parked, because it may no
  longer be parked at all.
- **Re-home failed** (a database write after a successful park). The row is
  parked on the old profile, on the session id and transcript it already had:
  the profile and, on a fresh plan, the fresh session id are one guarded
  write, so a re-home that fails leaves both as they were. The error says so
  and that the next focus wakes it there; a retry of "Switch account" takes
  the cold path and succeeds with no process to interrupt. The single write is
  what makes that promise true for a blank session too — a fresh id recorded
  against a re-home that never landed would leave the row naming a
  conversation whose transcript was never carried to the destination profile,
  which is the "no conversation found" the swap exists to avoid.
- **Wake failed** (no holder registry, the `TBDHolder` helper missing beside
  the daemon, a spawn that threw, pids that could not be recorded). The row is
  parked on the new profile, so the swap has taken effect at the account
  level, and the next focus-wake or menu wake retries the resume. This
  mirrors the tmux contract, where the row keeps the new profile before the
  respawn so a failed respawn still leaves it on the new account. The
  actuation finishes `transportFailed` with the wake's reason.

Each half already emits one text per cause, and the app, the CLI and the tests
keep asserting those. The arm adds exactly two strings of its own, for the two
states no half owns: a swap the claim refused, and a row that changed under the
switch. `holderInPlaceSwapRefusal` and the tests that pin it are deleted; a
holder row is no longer a category error at that branch.

## What stays as it is

- An `.inPlace` swap of a row that is **already parked** takes the cold path,
  on either transport: re-home without waking.
- `.fork` keeps its holder path.
- `swapDeskRole` and the trust seed run unchanged; the row and its watch-desk
  role survive the swap.
- The `.manual`, `.merge` and `.automatic` policies keep every rail they have.
  `.profileSwap` is a fourth policy, not a switch on the others.

## Reconcilers

No new kind of durable resource. The park half hands the old holder to the
same ending ladder manual hibernation uses. The wake half creates a holder
through `HolderRegistry.spawn` and records its pids before the park marker
clears, which is the ordering `WorktreeLifecycle+Create` and the wake already
use; `AgentReaper`'s holder leg sweeps by those pids and `OrphanGC`'s
rendezvous leg covers the socket, lock and log of a holder that could not
unlink them. A half-finished wake (pids recorded, marker not cleared) is
healed by the wake's own adopt guard on the next attempt and by startup
reconciliation.

## Testing

Daemon unit tests, fast pass, no live processes:

- **Both branches of the new policy.** A park with typed-but-unsent text on
  the screen, a park over a transcript whose tail is mid-write, and a park
  over a re-adopted screen whose content is unobserved each **proceed** under
  `.profileSwap` and each still **refuse** under `.manual`, with the refusal
  text each rail emits today.
- **The holder arm**, driven with the fakes the holder wake tests use. A
  refused park and a park answered by another park already in flight each
  leave the row awake on the old profile with nothing else changed, both
  through the RPC handler. A refused wake, asked of the wake half directly
  because reaching it through the RPC needs a park over a real pty, leaves the
  row parked on the new profile; each finishes the actuation `transportFailed`
  naming the half. The success path, the re-home failure and the wake failure
  as the RPC reports it need a park that really ends a process, so they are
  live (below).
- **The refusal is gone.** The test asserting `holderInPlaceSwapRefusal`
  becomes one asserting the swap proceeds; the app and CLI tests that pinned
  the string go with it.
- **Cold path unchanged.** An `.inPlace` swap of an already parked holder row
  re-homes and never spawns.

Live test in `TBDDaemonLiveTests`, real holder, stub Claude: swap a running
holder session to a second profile, then assert the old child is gone, a new
holder child runs under the row, the row's profile is the destination, and the
session id is unchanged. A blank-session variant asserts a fresh spawn rather
than a resume.

A live test also pins the claim, with the concurrent wake it exists to refuse:
inside the same instant between park and re-home, an ordinary wake of the row
through the coordinator's public entry point is answered in-flight, and the
swap then finishes as it always does — the row resumed under the destination
profile on the session id it started with.

A third live test pins the re-home failure, the one outcome that has no
observable staging point from outside the RPC: a test seam on the router opens
the instant between the successful park and the re-home, and a test moves the
worktree out of the status the handler captured at entry so the re-home's lock
refuses before any write. The row is then parked on the old profile with no
replacement process, the actuation reads `transportFailed`, and a retry with
the status restored takes the cold path and re-homes without waking. A
blank-session variant drives the same seam for the plan that mints a new id:
the row keeps the blank conversation it had, the retry re-homes that
conversation as it stands, and a wake then resumes it on the destination
account. What guards that pairing itself is a fast-pass test on the store
write — both fields land together under a matching snapshot, and a snapshot
that no longer matches writes neither.

A fourth pins the wake failure, whose response is the odd one of the three:
success-shaped, carrying the re-homed row, with the failure stated only in the
actuation. It is staged on the registry rather than through a seam — the
spawner resolves its executable path on every spawn, so the fixture spawns
from a symlink of its own and removing that link is the daemon whose
`TBDHolder` helper moved, with every running holder untouched. The park and
the re-home then run as they always do and the wake can start nothing: the RPC
returns a parked row on the destination account naming no processes, the
actuation reads `transportFailed` naming the wake half, and an ordinary
`terminal.wake` with the link restored resumes that session there under
`--resume`, which is the retry the outcome promises.

All three failure outcomes are therefore driven through the RPC handler, so
each one's response shape and actuation record are pinned as the app meets
them: the two park refusals in the fast pass, the re-home and wake failures
here.

Manual soak, in the PR's test plan, after a restart from main: "Switch
account" on a holder tab while idle, mid-turn (with the warning), and on a
re-adopted row after a daemon restart.

## Rejected alternatives

- **A holder "respawn job" verb, keeping the holder process and its socket.**
  Seamless is not on offer even then: the child's exit closes the pty, so the
  viewer would still be handed a new fd and would still re-attach. What the
  verb would buy is one fewer process and one fewer rendezvous file, at the
  cost of a protocol version bump, a holder binary that must keep answering
  every version ever shipped, and a new hand-over path through the viewer.
  Issue #851 sized it at roughly a day. The composed path costs none of that
  and reuses two halves that already soak.
- **Dropping in-place swaps on holder rows**, hiding "Switch account" or
  routing it to "Fork session". Fork changes the tab and the session id, and
  it would leave the tmux transport with a capability the holder never gains
  while the tmux transport is on its way out.
- **Obeying the park's rails, in full or the transcript rail alone.** The
  tmux arm has never obeyed them, and the screen-trust rail would make the
  swap refuse on every re-adopted row after a daemon restart until its screen
  was observed again — the case a user reaching for "Switch account" after a
  restart is most likely to be in.
- **A dedicated `holder_in_place_swap_enabled` column and toggle.** A
  migration, a toggle and a later graduation for an action the tmux arm has
  never gated, on a transport that is itself behind a soak flag.

## Relationship to other documents

- Issue #851's plan lists this as item 8, "in-place profile swap on holder, or
  an explicit decision to drop it". This spec is that decision.
- [`2026-09-01-holder-app-gap-findings.md`](2026-09-01-holder-app-gap-findings.md)
  is a dated audit record and stays as written; its "Surprises" note that the
  in-place swap refuses holder rows describes the tree it measured.
- The holder transport design,
  [`2026-08-30-pty-holder-session-transport-design.md`](2026-08-30-pty-holder-session-transport-design.md),
  defines the park and wake halves this composes.
