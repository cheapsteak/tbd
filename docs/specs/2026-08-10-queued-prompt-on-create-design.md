# Queued prompt on worktree creation

Status: design, approved. Ships behind `queued_prompt_enabled`, default OFF.

## The problem

Creating a worktree is fast to *start* and slow to *finish*. `worktree.create`
returns as soon as the DB row exists, but the agent you want to talk to appears
much later — after a `git fetch`, a `git worktree add`, and, when the repo has
one, a blocking `preSession` hook that may run for minutes
(`WorktreeLifecycle+PreSession.swift`, timeout 600s). The person who pressed
Cmd+N already knows what they want done. Today they must watch a spinner before
they can say it.

The fix is to decouple composing the prompt from delivering it: take the text
immediately, park it, and let the daemon hand it to the agent whenever the agent
turns up.

## Scope

In scope: a prompt modal on every worktree-creation path in the app, durable
parking of the text, and one delivery path into the primary agent.

Not in scope: changing what creates a worktree, changing creation timing,
prompting existing worktrees, or a queue of more than one prompt per worktree.
A second parked prompt replaces the first.

## Flag

`queued_prompt_enabled` — a `config` column, off by default, flipped by
`config.setQueuedPrompt` and surfaced in `DaemonCapabilitiesResult`. The
Settings toggle drives the RPC, following `control_mode_enabled`
(`SettingsView.swift:262`).

One flag, daemon-side, rather than a UserDefaults twin: the behavior that needs
gating is the daemon typing into a session, not the modal drawing itself. With
the flag off, the app does not open the modal, `worktree.setPendingPrompt` is
refused, the spawn path ignores the column, and a delivery already armed when
the flag went off stops before it types (see "Undeliverable prompts").

### Unset is a third state

The column is added with **no** SQL default, so it is genuinely NULL until
somebody touches the toggle:

- **NULL** — never chosen. Resolves to the shipped default.
- **0 / 1** — an explicit gesture, honored forever.

Every boolean flag before this one is added as
`addColumnIfMissing(..., defaults: false)`. SQLite stores that default in the
schema and returns it for rows written before the column existed, and the
singleton row is seeded naming only two columns (`Database.swift:345`), so a
fresh install and an old one both read `0` — indistinguishable from a
deliberate opt-out. `ConfigRecord`'s fields are already `Bool?` and `toModel()`
already writes `?? false`, but that fallback is unreachable in any real install.

Dropping the SQL default makes it reachable. `toModel()` resolves
`queued_prompt_enabled ?? Config.queuedPromptDefault`, the single place the
shipped default lives, and graduation edits that constant. Nothing else needs
to know.

## Data model

Two migrations, both additive: `v73_config_queued_prompt` for the flag above,
and `v74_worktree_pending_prompt`, which adds two columns to `worktree`:

- **`pending_prompt TEXT`** — the parked text, NULL when nothing is parked.
- **`pending_prompt_submit BOOLEAN NOT NULL DEFAULT 1`** — whether delivery ends
  with Enter.

Migration, the GRDB record, and the `Models.swift` Codable type land in one
commit; both fields are optional on the model so existing rows decode.

`pending_prompt_submit` carries a SQL default where the flag column deliberately
does not, and the asymmetry is the point: this is data, not a feature gate. It is
also unreachable, because `setPendingPrompt` — the only writer — always names
both columns, so the default can only describe a row with nothing parked and
therefore no submit choice to remember.

The column is also the recovery store. It is cleared on a successful paste and
on nothing else, so a delivery that failed leaves the text where the operator
can get it back.

### Exactly one writer clears it

`PendingPromptCoordinator.deliverParkedPrompt`, immediately after a paste it
watched succeed. Nothing else in the daemon clears the column: the spawn path
neither reads it nor writes it, and `park` only ever sets it (or empties it on
the operator's own Discard). That is a structural property rather than a
discipline, and it is the reason this design has no read-and-clear races to get
right.

The clear is still a compare-and-swap naming what was delivered
(`clearPendingPrompt(ifTextIs:submit:)`). One prompt per worktree means one
*value*, and a park can land inside a delivery — which reads the text, sleeps
out the settle, suspends through the send, and comes back to clear. An
unconditional clear would destroy that newer prompt, and its own cycle, finding
the column empty, would return silently: no delivery and no notification, after
the operator was told `.awaitingReady`. The submit bit is part of a prompt's
identity, since the same words staged rather than sent are a different prompt.

## Components

**The modal** (`TBDApp`) opens on every creation path — Cmd+N, the sidebar `+`
profile popover, and the existing-branch picker — immediately after
`createWorktree` has fired its RPC. It holds a multi-line prompt field and a
"send immediately" checkbox, **unchecked by default**. Escape dismisses it and parks
nothing; the worktree is already being created and keeps running with an idle
agent, exactly as today.

**Both composers type like a chat box**, because that is what they are: Return
sends, Shift+Return and Option+Return break the line, and ⌘↩ stays a send alias
for the muscle memory it built. The same semantics in both — the creation modal
and the read-back composer are near-identical sheets, and a Return that means
different things in each would be its own bug.

That costs an `NSTextView` behind an `NSViewRepresentable`. SwiftUI's
`TextEditor` never submits, and `TextField(axis: .vertical)` submits for free
but grows with its content instead of scrolling — wrong for a first message,
which is a task brief and routinely a paragraph. Of the three chords only
Option+Return is a standard key binding; Shift+Return resolves to the same
`insertNewline:` command as a plain Return, so the modifier is read from the
event. A Return that commits an input-method candidate never sends.

A creation while a modal is already up **queues** behind it, and opens when that
one closes. Each modal names its worktree, because two of them otherwise look
identical. Both worktrees are already being created either way — what queues is
only the asking. The alternative, swapping the presented modal for the newer
target, risks the operator finishing a message for the second worktree that gets
parked against the first: `.sheet(item:)` handed a replacement item may keep
presenting the old one.

While the modal is on, `createWorktree` no longer sets `editingWorktreeID`.
Rename-on-create and the modal cannot both own focus, and the prompt is the
reason the modal exists; renaming stays available from the sidebar.

**Two surfaces for a parked message, split by one rule.** Text in the column
means one of two things, and the app names them separately:

- **Pending** — no agent has announced itself yet, so the daemon has not tried
  to deliver. A footer banner in the pane says so: "TBD sends it as soon as the
  agent is ready." It is the sibling of the auto-resume footer, which makes the
  same kind of promise about the same pane, and it exists because delivery takes
  a few seconds during which the operator would otherwise watch an idle agent
  with no sign their message is coming.
- **Undeliverable** — TBD tried and could not, or knows it never will. Every one
  of those outcomes records a notification saying which, and the status-bar
  surface is failures-only.

The boundary is the daemon's own delivery trigger, so the two are complements
and cannot both be on. There is no third "delivered but unverified" state,
because the app must never describe a delivered draft as a failure — and a
successful paste is all TBD can honestly claim, so it clears the column and says
nothing.

Both open the same composer: the parked text, editable, with Copy, Discard and
the send-immediately bit. Editable because a message worth resending is usually
worth amending first, and discardable because a retained prompt does not prove
an undelivered one. Where delivery cannot happen, Deliver is disabled and says
why; Copy always works. An emptied composer cannot be sent — empty text is the
unpark signal, and Discard is the deliberate way to ask for that.

Nothing marks a worktree row. A row is glanceable, always visible, and has no
room to say which of the two states it means.

**`worktree.setPendingPrompt(worktreeID, text, submit)`** is a second,
independent RPC sent when the modal is submitted. It never blocks and never
participates in creation. A `nil` text unparks, which is how Discard clears the
column without a verb of its own.

**`PendingPromptCoordinator`** (daemon actor) owns the parked state, the wait,
the paste and every write to the column. Giving those a single owner is the
whole reason the actor exists.

**`spawnPrimaryTerminals`** passes no prompt and touches no column. Its entire
involvement is one call, after the primary terminal row exists, saying that the
pane is up (`notePrimaryTerminalExists`).

## Delivery

**There is one path: paste.** The coordinator waits for the primary agent's
`SessionStart` hook, waits out a measured settle the hook does not cover, and
types the text into the pane — pressing Enter only when the operator ticked
"send immediately". Then it clears the column.

The wait is bounded on an injected clock by `pendingPromptReadinessTimeout`,
120s. Not a judgement about when an agent is stuck: a generous ceiling on how
long a spawned process takes to emit its first hook, which expires loudly into
the recovery path rather than deciding anything.

**The ceiling starts when the pane exists, not when the prompt is parked.** A
`preSession` hook can run for ten minutes, and a prompt parked behind one would
otherwise burn its whole ceiling before its agent ever spawned. So the spawn path
tells the coordinator that a primary terminal row now exists, and that hand-off
is where the timer is armed. It passes no prompt and writes no column; the
coordinator re-reads both for itself.

### Submitting is opt-in, and unverified

The checkbox ships unchecked. When it is ticked the delivery presses Enter once
and reports nothing about what happened next.

That is not a gap to be closed later — **unsubmitted delivery is unverifiable by
construction, and submitting does not make it verifiable enough to be worth
claiming.** Staged text in a composer enters no conversation, fires no hook, and
produces no state change TBD can observe; reading the rendered pane is banned
(see the repo's no-screen-scraping rule), and it is the wrong layer anyway. The
only machine record that could ever answer is the transcript, and a transcript
holds *submitted turns only* — so the observable exists exactly when the
operator chose the option that makes it least necessary.

Confirming a submitted delivery against the transcript, and correcting what is
not seen, is the obvious next step and is deliberately not taken. Its false
negatives are neither rare nor cheap. An agent that takes the prompt and works
on it writes enough tool output to push the message out of any bounded tail
window within a couple of minutes, and the correction — which necessarily begins
by *clearing* the composer, since the two failure shapes are indistinguishable
from a transcript — then fires into a live session, wiping whatever the operator
has since typed and re-sending a prompt that landed perfectly well. Measured
here at 112 seconds after a delivery that worked. A verifier whose failure mode
is destroying the operator's input is worse than no verifier.

So the honest claim is the small one: the bytes left the daemon. **The column is
cleared on a successful paste** — accepted risk included, that a paste tmux
reports as delivered may be discarded by a TUI that was not yet reading its pty.
The settle below is the mitigation for that, and it is the only one.

### `SessionStart` is not evidence that the pane can receive input

The hook says a session exists. It does not say the agent's TUI has attached
its input handling, and on a real pane those are apart by long enough that the
delivery can be swallowed whole.

Measured on this machine against live Claude panes, the same bytes through the
same tmux sequence:

- **at the hook** — the paste never appears; the composer is empty and no turn
  starts. The TUI is still coming up and is not reading its pty yet.
- **inside the window** — the text reaches the composer but its Enter does not
  submit. tmux emits the bracketed-paste wrappers only when the pane has that
  mode on, so until the TUI enables it the payload's own newlines and the
  trailing Enter arrive as one burst, and the TUI's paste-burst detection
  coalesces them. A single-line prompt survives this window, having no interior
  newline to coalesce — which is why single-line prompts appeared to work and
  multi-line ones did not.
- **after it** — the identical bytes submit normally.

**The window is about half a second, and it was bisected rather than guessed.**
Unsubmitted pastes at increasing offsets after the hook: **+0.07s lost, +0.42s
lost, +0.72s landed, +1.15s landed**, and everything beyond landed.

**Nothing marks the transition, which is why the answer is a duration rather
than a signal.** Two candidates were checked and both fail:

- **A tmux format for the pane's bracketed-paste state does not exist.** The
  full format list (`display-message -a -p`) in 3.6a carries none.
  `client_termfeatures` does advertise `bpaste`, but that is the *client's*
  capability, not the pane's DECSET 2004 state, and it reads the same before and
  after the TUI comes up.
- **`pane_key_mode` is a red herring.** It genuinely flips `VT10x` → `Ext 2`
  when the TUI starts, which makes it look like the event wanted — but it flips
  **~2.9s before** the hook, so it cannot discriminate the bad window at all.
  Anyone reaching for it is reaching for a fact that is already true when the
  delivery starts.

No hook fires when the input path comes up either. So the delivery waits out the
measured window and then types.

**The paste waits `pendingPromptSettleDelay` (1s) after `SessionStart`.** That is
the measured dead window doubled — cheap insurance on a path where the operator
is already waiting. It is applied unconditionally, including for an agent whose
row already proves readiness: that row may have been stamped by a hook that
landed milliseconds ago, which is exactly the dangerous case, so a conditional
here would be wrong precisely when it matters and would save a second when it
does not.

Re-measure it if Claude Code's startup changes. The method is the bisect above —
unsubmitted pastes at increasing offsets after `SessionStart`, judged by whether
the words reach the composer.

### What counts as ready

Readiness is `transcriptPath != nil || activityState != .unknown`, the fields
the `SessionStart` hook writes.

Neither is written *exclusively* by hook traffic: parking a session stamps
`activityState = .idle` and window recreation stamps `.unknown`. Neither
weakens the answer — a parked session did once announce itself, and a recreated
window reads as not-yet-announced — but the predicate is "has this pane's agent
ever announced itself", not "a hook fired just now".

The row is read after the pane exists, so it may already carry that answer, and
whoever arms the wait must use it rather than assuming a hook is still to come.
Forcing "not ready" over a row that already proves readiness waits for a second
`SessionStart` that is never coming, burns the whole ceiling, and ends in a
"did not report a session" notice about a live agent.

It is specifically **not** `claudeSessionID`. A fresh Claude spawn is launched
with a pre-chosen `--session-id`, so that field is populated before the process
starts and reads as ready while the TUI is still booting — a paste there lands
in nothing. The distinction is load-bearing and carries its own test.

### Delivery is verbatim, with the envelope suppressed

`terminal.send` prefixes agent-bound text with a `<tbd-dispatch/>` envelope so a
fleet dispatch is attributable. A queued prompt is the operator's own words and
must reach the model byte-identical to what was composed, so the coordinator
sends through the daemon-internal send core with the envelope suppressed.

Suppression is internal only, never a parameter on the public `terminal.send`
verb: an envelope any caller could omit would let any caller impersonate a
human, which is precisely the property the envelope exists to provide. The act
is still written to the actuation log under its own rail, so the record of who
typed what stays complete.

The paste does **not** buy the pending-input hibernate veto.
`InputActivityTracker.recordInput` has one caller, the app's own keystroke
stream, and nothing in the tmux paste path touches it — so an unsubmitted queued
prompt staged in a composer is invisible to the idle sweep, exactly like any
other daemon-side paste. Wiring the veto to daemon-side pastes is a separate
change, and this design does not make it.

### Envelope-free delivery is bounded by the socket, not by this verb

`worktree.setPendingPrompt` can put envelope-free text into an agent that is
already running, and submit it. That is accepted, and the boundary it sits
behind is the daemon socket rather than the verb.

- **The socket is the trust boundary.** Any process that can reach it can
  already create worktrees and spawn agents with arbitrary prompts on their
  command lines. Envelope-free delivery through this verb grants no capability
  that socket access did not already confer.
- **The envelope is attribution, not a machine-origin guarantee.**
  `terminal.send --keys` already types envelope-free literal text —
  `PacedKeySender.tokenize` has no key-name whitelist — so reading the envelope
  as a security control would be false comfort about a property it never had.
- **What the envelope does buy** is that a fleet dispatch stays attributable by
  default, and that is why suppression remains daemon-internal rather than
  becoming an RPC parameter: everything routed through the public verb keeps its
  framing.

### One park, one paste

A second park replaces the first, in the column and in the arming. The
superseded cycle wakes to find it no longer owns its slot and leaves quietly:
it must not type, must not clear, and must not announce a timeout for a prompt
that was replaced rather than lost.

**The ownership check sits after the settle, not before it.** The settle is the
window in which two cycles are alive at once, which is exactly what "Deliver
Now" pressed twice — or pressed while its own RPC is still in flight — produces.
Checking before the sleep would let both cycles pass and the model would read
the prompt twice.

**A superseded delivery is never cancelled.** A submitted send is two acts, a
paste and an Enter, and both run through a bounded process that treats
cancellation of the enclosing task as a hard deadline. Cancelling between them
leaves the operator's words unsubmitted in the composer, where the next paste
lands on top and one Enter submits both as a single prompt. Nothing is bought in
exchange: the successor's column is protected by the compare-and-swap, and its
arming and notices by the generation tokens.

### Undeliverable prompts

Seven causes, and every one of them leaves the text in the column and notifies:
the paste threw, the pane is dead or missing, the resolved primary terminal is a
plain shell, that primary is a **hibernated** agent, the worktree is archived,
the readiness ceiling expired, or the flag was switched off while the delivery
waited.

Three are answered at `park` rather than at delivery, because the app must never
promise something the daemon will refuse. An **archived** worktree has no
terminal rows — archive deletes them — so it looks exactly like a worktree still
being created, and the honest answer for the two is opposite; parking there
would leave text nothing will ever read. A worktree whose spawn has already
happened and produced a **shell** primary has nothing coming either — and the
tell is the labels on its rows, not their number: a worktree holding nothing but
the blocking `preSession` hook's tab (or no rows at all) still has its primary
ahead of it, and parking there is the promise this feature is for. A
**hibernated** primary is a pane with no composer in it. All three are
refused, with the reason, and nothing is parked.

**A hibernated primary is asked about twice — at `park` and again immediately
before the paste — and the second time is the one that matters.** Hibernation
kills the agent process and respawns the pane to a bare shell while the row
keeps `kind == .claude` and reads as having announced itself (parking stamps
`activityState = .idle`), so every signal the delivery consults says "agent,
ready" about a shell prompt. Typing there stages the operator's words at a
command line, and with "send immediately" ticked runs them. The kind check
cannot see it and the pane consultation cannot either — it distinguishes
missing, dead and live, and a hibernated pane is live. Only the row's parked
timestamp answers, which is also the answer that needs no screen text.

The second ask is not belt-and-braces: a delivery is suspended through a
readiness wait bounded at 120s and then through the settle, and the idle sweep
parks sessions on its own schedule. The window between "eligible" and "typing"
is precisely the window this feature opened, so eligibility is re-read at the
end of it rather than inherited from the start. Waking is the operator's
gesture, so the text waits for it.

**The flag stops a delivery that is already armed.** It is read again in that
same guard, immediately before the send: a kill-switch that only gates the next
park would leave an armed cycle typing up to two minutes after the operator
turned the feature off.

**Copy works on every one of those paths.** Deliver-now is disabled, with the
reason in the sheet, for the two causes the app can see in its own state — an
archived worktree and a shell primary — because a button that always fails is
worse than no button. It stays enabled for a hibernated primary, which the app
does not model: the daemon refuses that park and the refusal reaches the sheet
as the reason nothing was sent, which is the correct outcome by the weaker
route. Nothing is delivered on a refusal either way.

Nothing is retried indefinitely. A prompt that fires hours later, unattended,
into a session whose context has moved on is worse than one that waits to be
asked for.

### The licence to type is granted once, and spent

The text survives a daemon restart; the arming does not, matching
`DeliveryVerifier`'s deliberate choice that a restart costs cadence, never data.
Concretely, `park` grants an in-memory licence for the worktree on the branch
where no pane exists yet, and the first pane hand-off spends it.

That single rule covers three cases that used to need their own machinery:

- **After a restart** the licence is gone, so the pane that comes up types
  nothing and the prompt surfaces as recoverable instead.
- **After an undeliverable outcome** the text stays in the column on purpose,
  but the licence is spent — so a revive, a Watch Desk session, or an
  archive-and-revive weeks later types nothing into a conversation the words
  were never written for.
- **Deliver-now** re-parks, which grants the licence again. The operator's own
  gesture is what makes a retained prompt deliverable, which is the attendedness
  the design wants.

A pane that meets outstanding text with no licence says so once per worktree per
daemon session. Once, because the text stays in the column and every later spawn
would otherwise repeat the same notice.

## Creation is not slowed

The modal opens after the create RPC is already in flight, and submitting sends
a separate RPC. No creation-path code awaits the prompt. This is asserted, not
assumed: a test fixes the ordering of `worktree.create` before
`worktree.setPendingPrompt`.

## Testing

Both branches of the flag, per the branching-conditional rule:

- Flag off — the modal never opens, `setPendingPrompt` is refused, and a
  hand-written column value is never delivered and never announced.
- Flag on — a prompt parked before the pane exists is pasted exactly once when
  the pane is ready, and the column is cleared only then.

The invariant, asserted three ways, because it is the whole justification for
this design:

- **The spawn path neither reads nor writes the column.** Driven with no
  coordinator attached at all, so nothing else in the process could touch it:
  after a full spawn the text is still there, and none of it reached the command
  line. Making `spawnPrimaryTerminals` take the column again reds this test and
  seven others.
- **The clear names what was delivered.** A park landing while a delivery is
  suspended survives its predecessor's clear, and is then delivered itself.
- **The compare-and-swap is atomic.** Ten concurrent clears of the same text,
  exactly one winner — the boolean is what the coordinator uses to decide it
  delivered.

Paste-once semantics:

- Exactly one send, of exactly the parked bytes, to the primary terminal.
- Enter iff the submit bit was set — at the coordinator, and again over RPC,
  because the bit crosses two boundaries and either could drop it.
- A repeated park of the same words pastes once. The ownership check must sit
  after the settle for this to hold; move it earlier and the test reds.
- The wire defaults `submit` to off when the key is absent.

Retention on every undeliverable cause: a failed paste, a shell primary, a
missing send path, an archived worktree, an expired readiness ceiling. Each
notifies, and each leaves the text in the column.

The two facts re-read immediately before the paste, each asserted from the state
it is meant to catch — a change that landed *after* the prompt was eligible:

- **A hibernated primary**, three ways. Parking against one is refused; a
  session parked during the readiness wait is not typed into; and neither is one
  parked during the settle. The fixture hibernates through the store's own park
  routine rather than setting a field, and checks what that row actually looks
  like — still `kind == .claude`, and already reading as announced — because a
  fixture that hand-builds a friendlier row would test the assumption instead of
  the bug.
- **The flag switched off mid-flight.** A cycle armed while the flag was on, and
  disabled before the settle expires, types nothing.

The settle, in virtual time, both halves: one tick short of it nothing has been
typed, and the paste follows the tick that clears it. Only the pair
discriminates.

Readiness: the ceiling is bounded on the injected clock and not one tick before
it; a pre-chosen `--session-id` is **not** readiness; an activity state alone
is.

The licence: a prompt from a previous daemon is announced and never typed, and
announced once rather than on every later spawn; a retained prompt is not typed
into a later spawn's agent; re-parking makes it deliverable again; a pane coming
up after a delivered prompt claims no stranded text.

The wiring, over RPC rather than against the actor: parking and readiness
(`terminal.sessionEvent`) drive a paste end to end with no direct actor call, so
deleting either wiring line reds.

Migration and models: the three flag states are distinguishable after migration
— a row that predates it reads NULL rather than `0`, and an explicit `false`
survives a change to `Config.queuedPromptDefault` while NULL follows it — and
the GRDB record and Codable model round-trip, including rows written before the
migration.

Ordering — the create RPC precedes the parking RPC.

**One step is live-only, and stays a manual check.** No test can see the race
itself: dry-run tmux has no pty, no TUI and no bracketed-paste mode, so a
harness will always report a delivery the real pane may have discarded — and the
settle is sized by a measurement only a live pane can produce. Before shipping a
change to the delivery path, run the differential on a real pane: create a
scratch space, park a **multi-line** prompt containing a slash with "send
immediately" on, and confirm exactly one user turn carries it. Do it once more
with a prompt that produces a **long** turn, which is the case that hid a
duplicate send. Single-line prompts pass this window on their own and prove
nothing. `~/tbd/actuations.jsonl` says how many sends it actually took.

## Rejected alternatives

- **Hold the prompt in `AppState`.** No migration and no daemon change, but the
  app cannot see the `SessionStart` hook and cannot wait out the settle behind
  it, so every prompt would paste into a booting TUI — and the text would die
  with an app restart during the very preSession window this feature exists to
  fill.
- **Hold it in daemon memory only.** Survives an app restart, but loses the text
  on a daemon restart, a hole `WorktreeLifecycle+Recovery.swift:136` already
  names for these phase-2 parameters, and offers nothing to recover from a
  failed delivery.
- **Delay `worktree.create` until the modal is submitted, reusing its existing
  `prompt` parameter.** Zero new state — and it makes creation wait on typing,
  which is the cost the feature exists to remove.
- **Expose envelope suppression on `terminal.send`.** Simpler than an internal
  send path, and it hands every caller the ability to type as a human.
- **Retry until it lands.** Rejected above; unbounded delivery into a stale
  session.
- **Put the prompt on the spawn's own command line.** A prompt parked before the
  agent exists can ride `claude` / `codex` as a trailing argv through the
  existing spawn-command builders, and that is genuinely the strongest form of
  delivery available: atomic with the spawn, no paste, no readiness signal, no
  settle, and no window in which the bytes can reach the wrong process. It was
  built and then removed, and the rationale is kept intact so it can be restored
  on evidence.

  It costs a **second writer**. The spawn has to read the column, take it with a
  compare-and-clear, put it back when it turns out it cannot use it, and read it
  again after the pane exists to catch a park that landed in the gap — each of
  those a transaction an operator's Discard or a second park can land inside.
  Four review rounds went into those races. Every one of them is unreachable
  once the coordinator is the only writer.

  And it does not cover the feature. Argv delivery has no non-submitting form —
  a trailing positional argument to `claude` starts a turn — so an unsubmitted
  prompt must paste anyway; so must one sharing a command line with a
  caller-supplied prompt, one riding a resume that has to open idle at the
  composer, and one larger than the command line can carry (macOS `ARG_MAX` is
  1 MiB for the environment *and* the argument vector together, so the ceiling
  sat at 512 KiB). Keeping it meant maintaining both paths and a decision
  procedure between them, for a case that stopped being the common one the
  moment submitting became opt-in.

  Restoring it needs evidence that the paste path loses text in practice —
  actuation-log counts against a real fleet, not a plausible story — and a way
  to keep the single writer, most likely by having the coordinator own the
  command-line hand-off rather than the spawn path reading the column.

## Graduation

Soak with `config.setQueuedPrompt true` and a daemon restart.

Graduation changes `Config.queuedPromptDefault` to `true` and ships. Because
the column carries no SQL default, everyone who never touched the toggle is
still NULL and picks the new behavior up; everyone who explicitly turned it off
stays off. No forcing `UPDATE` migration is needed — that dance is only
required for flags whose SQL default already backfilled their rows. The flag is
deleted once the default has held.
