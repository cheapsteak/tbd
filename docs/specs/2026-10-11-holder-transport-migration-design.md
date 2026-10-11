# Moving a session to the pty holder, on request

## Summary

A person can move a session from the tmux transport to the pty holder in place:
same row, same tab, same label and pin, same Claude session id and transcript.
The session's program is parked and respawned on the holder; nothing is
extracted from a running tmux server. Nothing moves without a gesture.

This is the mechanism by which the tmux transport's remaining sessions leave it,
so the tmux path can be deleted without stranding a session somebody still
wants. A second, much smaller piece completes that guarantee: once the tmux path
is gone, a row still recorded as `tmux` refuses its wake with a reason naming
this migration, so a session nobody got around to moving produces a clear
message rather than a broken tab.

## Why a gesture rather than a behaviour

The transport a session runs on is recorded per row at spawn and kept for life.
Flipping the default changes what new sessions get; it moves nothing that
already exists. Sessions therefore outlive the default that created them, and
the last tmux-backed ones would outlive the tmux code itself.

Moving a session costs something real: its program is killed and started again.
An agent session reappears through `claude --resume` with its conversation
intact, which is close to invisible; a shell loses whatever was running in it.
A cost that depends on what the session is doing is a cost its owner should
choose to pay, at a moment they pick. So the migration is an action, surfaced
per session and as a fleet-wide run, and the daemon never initiates it.

## What it is not

**It does not extract a live pty from a tmux server.** The transport design
rejects live migration, and that stands: a pty whose master is held by a tmux
server cannot be handed to a holder without the server's cooperation, and
nothing in tmux offers it. Migration is park, rewrite, wake.

**It does not seed the new session with the old screen.** An agent redraws its
own alternate screen on resume, and a shell's scrollback is not worth a
mechanism. The migrated session starts clean.

## The mechanic

One session is the unit, and it is a composition of operations that already
exist. The in-place profile swap — park, re-home, wake, one tab, same row, same
session id — is the same shape with a different column rewritten
([spec](2026-09-22-holder-in-place-profile-swap-design.md)).

- **A running session** is parked, its `transport` rewritten, and woken. The
  wake is the ordinary one: everything above the wake path's single transport
  branch is already transport-independent — profile, environment, settings
  overlay, trust seed, transcript sync, and the `claude --resume` argv — so the
  migrated session resumes through the same code any other wake uses.
- **A parked session** is only rewritten. Nothing is running, so there is
  nothing to park and nothing to respawn; its next ordinary wake lands on the
  holder.

### The rewrite is a compare-and-set, not a lock

The write is the sibling of `TerminalStore.setParkedProfileID`: it changes the
row only while the complete launch state the caller observed is still current,
so a wake or a replacement that wins the race rejects the write atomically
rather than leaving the row naming a transport the live process is not on. The
guard is the mechanism that makes the migration safe against a concurrent wake;
no new claim or lock is introduced.

### The park honours every live rail

The migration parks under the ordinary manual-park policy, so the rails that
read live state still apply: the typed-screen check, the typed-input check, and
the transcript-tail rail. This is deliberate and is the opposite of the profile
swap's policy, which stops honouring them because switching accounts should
interrupt regardless.

The difference is in what the two actions destroy. Unsent typed input is exactly
what a park-and-respawn would throw away, so a rail that refuses the park is
protecting the session, and its refusal becomes a *skipped* line carrying that
rail's own reason. A person then sends or clears the input and runs the
migration again. No new eligibility policy is added, and in particular the tmux
leg's typed-input rail is left exactly as it is.

## What migrates, and what is skipped

- **Idle sessions migrate.** Sessions TBD already knows to be busy are skipped
  and named, from the activity state it already tracks; a run reports them so a
  person can retry or move them one at a time.
- **Shells migrate plainly** — a fresh program in the same working directory.
- **Agents migrate through `--resume`** on the session id the row records, the
  same argv a wake builds.
- **The row keeps its identity**: id, label, pin, profile, Claude session id,
  transcript path, and history entries all survive, because only the transport
  column changes.
- **The tmux coordinates are blanked.** A row that no longer lives in tmux must
  not carry a window or pane id: a stale pane coordinate is what let daemon
  keystrokes reach a different session than the one addressed, and holder rows
  record empty coordinates for exactly this reason.

No database migration is needed. The `transport` column exists and already
carries both values; this feature writes a value the schema has always allowed.

## Failure, and why nothing rolls back

Each session's migration is claim-free but ordered: park, rewrite, wake.

- **The holder cannot be started** — the helper is missing or unspawnable. The
  migration refuses before touching the row, which is left exactly as it was,
  running or parked, on tmux. The refusal names the reason.
- **A rail refuses the park.** The session is skipped and reported, unchanged.
- **The rewrite is rejected** because a wake or replacement won the race. The
  session is skipped and reported; the row is consistent by construction.
- **The wake fails after the rewrite.** The row is left parked and recorded as
  holder-backed, which the ordinary wake path already handles: its next wake
  spawns a holder and resumes the session. The worst case is a session that
  comes back on the holder later rather than now.

Nothing unwinds an earlier success. A fleet-wide run migrates sessions
sequentially — so a machine with a large fleet is not asked for many
simultaneous respawns — continues past a failure, and reports the outcome of
each: migrated, skipped with a reason, or refused with a reason. Earlier
successes are finished sessions, not steps in a transaction, and rolling them
back would mean moving working sessions off the transport they now run on.

## Surfaces

One RPC method, exposed three ways: a per-session action in the app's row
context menu, the CLI equivalent, and a fleet-wide run composed from the
per-session one. The run's report is its product — a person needs to know what
did not move and why, not merely that something did.

The actions are unflagged. A gesture that does nothing until somebody asks for
it needs no switch, which is why "Hibernate now" has never had one.

## The backstop

Deleting the tmux path removes the code a `tmux` row's wake would take. From
that point a row still recorded as `tmux` refuses its wake with a reason naming
this migration, instead of failing obscurely inside a path that no longer
exists. This is a refusal and nothing more: no migration logic, no flag, a
handful of lines. It is what keeps "a session never silently breaks" true
without a daemon-initiated migration.

## Out of scope

- **Prompting on app launch.** Asking a person to run the migration when they
  open the app is wanted, and is not this design. It acts without a gesture, so
  it ships behind a default-off flag of its own when it is built.
- **Automatic or wake-time migration.** A session is never moved by the daemon's
  own decision. The backstop refusal covers the row nobody moved.

## Reconcilers

This introduces no new kind of durable resource. The holder session a migration
creates is created through the same spawn path every other holder session uses,
and is therefore already covered: `HolderRegistry` adoption, the `AgentReaper`
holder leg, the `OrphanGC` rendezvous arms, and the reconcile pass. The tmux
window the park retires is retired by the park, and a window the park failed to
retire is the reconcile pass's, as it is for every other park.

## Testing

- An idle agent session migrates: the transport flips, the id, Claude session id
  and transcript path are unchanged, the tmux coordinates are blanked, and the
  respawn carries `--resume` with the recorded session id.
- A parked session migrates with nothing spawned at all — asserted on a
  spawn-counting double, because "no respawn" is the whole difference between
  the two paths.
- A busy session is skipped and named, and its row is untouched.
- A session with unsent typed input is skipped with the rail's reason, proving
  the migration park honours the rails rather than overriding them.
- An unspawnable holder refuses and leaves the row exactly as it was, in both
  the running and parked variants.
- A rejected compare-and-set is reported as skipped, with the row consistent.
- A fleet-wide run containing one refusal still migrates the rest and reports
  the one.
- The backstop refuses a `tmux` row's wake with its stated reason.
- Any wait introduced by the migration takes an injected clock.

## Rejected alternatives

- **Migrating at wake time.** A parked tmux row could be rewritten as it wakes,
  which would need no gesture at all. It was rejected because it moves a session
  at a moment nobody chose and cannot ask: a person waking a session wants it
  back, not relocated. The backstop refusal gives the same protection against a
  forgotten row for a fraction of the behaviour.
- **Rewriting at park time.** Parking a tmux session could record it as
  holder-backed so every wake is already a holder wake. It decides earlier than
  necessary, churns rows that may never be woken again, and park must succeed —
  so it has no way to refuse, which is the thing a migration most needs.
- **A proactive sweep.** A boot or reconcile pass could migrate every parked
  tmux row. Nothing needs that convergence: an unwoken parked row costs nothing,
  and the delete requires that no wake take the tmux branch, not that the fleet
  be drained. A sweep would act on rows nobody asked about, with no person
  waiting for its answer, and would duplicate the decision in a second place.
- **Extracting the live pty.** Rejected by the transport design and unchanged
  here; tmux offers no way to surrender a pty master.
- **Seeding the migrated session with the parked screen.** The snapshot-preamble
  machinery could put the old screen above the new prompt. An agent redraws its
  alternate screen on resume, so it would show through for a moment and then be
  replaced, and a shell's scrollback does not justify the mechanism.
- **A dedicated park-eligibility policy.** The migration could stop honouring
  the live rails, as the profile swap does. The actions differ in what they
  destroy: a swap preserves the conversation and interrupts it, while a
  migration would discard input the person typed and has not sent.
