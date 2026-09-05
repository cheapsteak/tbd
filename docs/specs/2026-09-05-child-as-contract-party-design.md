# The child is a party to the transport contract

## Summary

The pty-holder transport
([`2026-08-30-pty-holder-session-transport-design.md`](2026-08-30-pty-holder-session-transport-design.md))
has a complete theory of one boundary and none of the other two. The boundary
it theorizes is **who reads the pty master**: exactly one reader, arbitrated by
the daemon, transferred on an acknowledged edge, failing toward reading nothing.
That theory is rigorous, instrumented, and it holds — a fleet of holder-backed
agent sessions ran through a day of ordinary daemon and app restarts with zero
double-reader incidents, which is the strongest evidence a design can get for
an invariant that is silent when violated.

The two boundaries it does not theorize are the ones every silent failure
crossed:

- **Transport → child.** Every acknowledgement on the input path terminates at
  *accepted by the kernel's input queue* — `PTYWrite.Outcome`
  (`Sources/TBDApp/Terminal/PTYWrite.swift:36-43`), the outbox contract in
  [`2026-09-04-pty-write-completion-design.md`](2026-09-04-pty-write-completion-design.md),
  the actuation row's `dispatched`. Nothing asks whether the child consumed the
  bytes, in what mode it interpreted them, or whether it acted.
- **Emulator → consumer.** Every machine read terminates at *rendered from an
  emulator grid*. Nothing says which of the two stores answered, how stale it
  is, or whether the text is faithful.

tmux carried both boundaries implicitly. It tracked each pane's modes, so a
paste was bracketed exactly when the program had asked for bracketing; it owned
a key table, so `Enter` was a key rather than a byte that might land inside a
burst; and `capture-pane` returned spaces for cells nobody wrote. The holder
replaced tmux without replacing any of that, and the specs that followed each
name the consequences as out of scope
([`2026-09-03-single-typist-injection-design.md`](2026-09-03-single-typist-injection-design.md),
"What this does not solve"). The defects that surfaced in the field are the
predicted ones.

This design makes the child a party to the contract, in two halves that are
each useful alone and complete only together:

- **A typed screen contract** replaces `terminal.output`'s bare string. The
  same object that tells a machine reader what is on screen tells the input
  path what modes the child is in — so it closes the read gap and the two
  input gaps (a submitting Enter absorbed by a paste heuristic; named keys
  refused) with one type.
- **Delivery verification on holder sends**, armed by default for the daemon's
  own supervision rails. The verifier reads the transcript, not a pane, and is
  therefore transport-independent by construction; the refusal that keeps it
  off the holder transport rests on a misdescription of what it reads.

The two halves are the two directions of one claim. The mode oracle makes the
daemon's *composition* correct for the child it is typing into; verification
*observes* whether the child acted. Either alone leaves a silent class open:
an oracle without verification fixes the two shapes that are known and says
nothing about the next one, while verification without the oracle makes every
stall loud and leaves every stall a stall.

## The evidence

Field measurements on one machine running a live fleet, all on the holder
transport with `pty_holder_enabled` on. They are evidence for the theory above,
not a work list; each has its own fix and owner.

- **Four stalled agent sessions in one day**, each presenting the same way — a
  busy-looking screen, no progress, 0% CPU. One sat for hours on a brief that
  had arrived truncated; neither side could tell. The transport's record for
  every one of them reads `dispatched`.
- **`--text --submit` loses its Enter at ~230 bytes**, as well as at 4 KB. It
  is not a size effect. `performHolderSend` composes envelope, newline, body
  and `\r` as one write
  (`Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift:3222-3233`),
  deliberately, so a message never straddles a routing decision. The tmux arm
  pastes the body inside an *explicit* bracketed paste and presses Enter as a
  second act (`:3112-3126`). On the holder the `\r` arrives in the same read
  as a multi-line chunk, and an agent TUI's paste-burst heuristic keys on the
  *shape* of a chunk, not its byte count — the envelope's newline is enough. A
  bare `?` with `--submit` is two bytes and submits. The handler's own comment
  predicted this outcome for "a very large `--text --submit`" (`:3190-3196`) and
  named the fix: exposing the child's bracketed-paste mode.
- **`--keys` is refused outright** (`:2848-2852`). A key table needs the
  child's cursor-key mode to choose `ESC[A` over `ESCOA`; SwiftTerm tracks it
  (`applicationCursor`, `bracketedPasteMode`, `isCurrentBufferAlternate` in
  `.build/checkouts/SwiftTerm/Sources/SwiftTerm/Terminal.swift:509-588`), but
  only inside whichever emulator is currently reading.
- **1,595 `U+0000` cells across five of nine sessions** in one `terminal.output`
  sweep: a differential painter positions past cells it is not changing, and
  the render projected those cells literally. Fixed in the render
  (`Sources/TBDDaemon/Holder/HolderReader.swift:1255-1285` now projects a
  never-written cell as a space), and no consumer had noticed, because every
  consumer matches on text and a NUL displays as nothing.
- **A machine read of any session a person has open returns an error that
  says the session is gone.** `holderTerminalOutput` (`:1911-1936` in the
  handlers file) requires `reader(for:)`; the attach acknowledgement stops that
  reader (`Sources/TBDDaemon/Holder/HolderRegistry.swift:1396-1431`), and a
  released slot answers nil (`:426-429`). The transport spec's answer — pull a
  snapshot from the app (`2026-08-30-pty-holder-session-transport-design.md:531-538`)
  — is not built: `SidecarFrameType` has five cases and none is a snapshot
  request (`Sources/TBDShared/SidecarFraming.swift:26-32`).

What was instrumented held. The double-reader counter
(`HolderRegistry.swift:297-306`, `:878`) never exceeded one. The faults were
all at the two boundaries with no counter.

## The screen contract

### Shape

`terminal.output` answers with a typed screen rather than a string. The
`TerminalOutputResult` in
`Sources/TBDShared/RPCProtocol.swift:3808-3811` is a single `output: String`,
and a string cannot carry the two facts the transport spec's own failure
policy requires it to carry — which store answered, and that the answer is
stale (`2026-08-30-pty-holder-session-transport-design.md:548-553`).

- **`lines: [String]`** – the requested tail of scrollback plus viewport, one
  entry per row, right-trimmed, trailing blank rows dropped. **Whitelisted:**
  every character is printable or a tab; a never-written cell is a space; the
  trailing half of a wide glyph is omitted. The whitelist is enforced by the
  type's construction, not by each render site remembering to — a row that
  would contain a control character is a bug in the projection, and the
  constructor refuses it rather than shipping it.
- **`cursor: (row, column)`** – in viewport coordinates, plus whether it is
  visible. The login driver and the pending-input rail both reason about
  where the cursor sits.
- **`size: (columns, rows)`** – the grid the lines were rendered from. A
  consumer that compares against the pty's own size can see a grid that
  disagrees with the child.
- **`modes`** – the child-facing state a writer needs before composing input:
  `bracketedPaste`, `applicationCursor`, `alternateScreen`. Read from the
  emulator that produced the lines, so lines and modes are one observation.
- **`source`** – which store answered: `daemon` (the daemon is the reader and
  rendered its live emulator), `viewer` (a viewer holds the pty and answered a
  pull), or `staleDaemon` (a viewer holds the pty, did not answer, and this is
  the daemon's emulator as it stood at attach). A consumer's policy is keyed
  on this field, so the policy cannot be applied by accident.
- **`age`** – how long ago the answering store last consumed a byte from the
  pty, so "stale" is a number rather than an adjective.
- **`output: String`** – the lines joined with `\n`, kept for one reason:
  scripts and skills read `tbd terminal output` today and the CLI prints it.
  It is derived from `lines` and carries no information of its own.

### Two stores, and the pull that reaches the live one

The two-store model stands: the daemon's emulator is authoritative while
detached, the viewer's SwiftTerm is authoritative while attached. What this
design builds is the pull the model has always required.

- **Daemon as reader** – render the live emulator, `source: .daemon`. This is
  the path that exists today, minus the string.
- **Viewer as reader** – the daemon asks the app for the screen over the FD
  sidecar, which already carries daemon-originated frames with an app answer
  (`injection` / `injectionAck`, `SidecarFraming.swift:30-31`). Two frame
  types join them: `screenRequest`, naming the session and the line depth, and
  `screenReply`, carrying the typed screen. Adding a case is cheap in both
  directions — a peer built before the case existed skips the frame and logs
  it (`SidecarFraming.swift:19-24`) — so an old app simply never answers and
  the bound below covers it. The app answers from its live SwiftTerm through
  the same cell walk the handback preamble already uses
  (`Sources/TBDTerminalSerialization/TerminalCellWalk.swift`, consumed by
  `Sources/TBDApp/Terminal/HolderHandback.swift`), so the two stores project
  identically by construction. The answer is `source: .viewer`.
- **Viewer holds the pty and does not answer** – the pull is bounded on an
  injected clock. On expiry the daemon answers from the emulator it suspended
  at attach, `source: .staleDaemon`, `age` counted from the attach. The
  emulator is retained across an attach for exactly this — it is not stopped
  at the acknowledgement, only suspended, which is what the transport spec's
  "frozen-at-attach" fallback assumed and the current release path does not
  do (`HolderRegistry.swift:1416-1431` stops it). The memory cost is one
  emulator per attached session, which is the cost the transport spec already
  budgeted for every session.
- **No reader at all** – the session is gone or never adopted. An error, as
  today, and the error says which.

Each consumer declares what it does with `.staleDaemon`, and the declaration
is in the consumer, where a reviewer can see it:

- **The input-path oracle (below)** – uses the stale modes and records that it
  did on the actuation row. Modes flip rarely; a wrong guess produces the
  visible, recoverable outcome the transport spec already accepts for a lost
  ack, and a refusal would stall every supervision send whenever the app is
  napping — the moment supervision most needs to send.
- **The hibernation pending-input check** – fails closed, as the transport
  spec rules: a stale screen cannot prove the composer is empty.
- **Fleet supervision, `tbd terminal output`** – accept, and surface the
  source and age. A desk that reads `staleDaemon, 40 minutes` has learned
  something a string could never tell it.

### The same object is the input side's mode oracle

`performHolderSend` composes a message once and hands it to the courier whole
— that atomicity is correct and stays. What changes is that the composition
consults the screen contract first, and the modes decide the bytes:

- **Bracketed paste on** – the body is wrapped in `ESC[200~` … `ESC[201~`
  and the submitting `\r` follows the end marker, all in one write. The
  message is still one message; the Enter is provably outside the paste,
  which is the property the tmux arm's two-act delivery had and the holder
  arm lost. A paste heuristic that keys on chunk shape sees an explicit paste
  and a separate keystroke, because that is what the bytes say.
- **Bracketed paste off** – bare bytes, as today. A shell at its prompt, or a
  program that never asked for bracketing, must not receive markers it will
  print.
- **Named keys** – `--keys` gains a table on the holder transport, keyed on
  the modes: `Enter`, `Escape`, `Tab`, `BSpace`, `C-<x>` and the function of
  Space are mode-independent; the arrow and navigation keys select the
  application or normal sequence on `applicationCursor`. Keys are paced
  through the existing `PacedKeySender`, for the reason its tmux use records:
  a redrawing TUI drops back-to-back keys.
- **The refusal stops.** `holderKeysRefusal` (`:2848-2852`) is retired with
  the table; a key the table does not name is refused by name, as a tmux key
  the daemon cannot map is today.

The oracle is consulted at composition time, which is a moment, and the child
can change a mode between that moment and the write. That window exists on
tmux too — the server reads the pane's mode when it pastes, not when the
bytes land — and it is accepted here for the same reason: a mode that flips
mid-send produces a visible mis-paste, not a silent one.

### What this does not change

- **The holder still never reads** (`Sources/TBDHolder/Holder.swift:9-13`).
  The oracle lives in the daemon's composition step and is fed by whichever
  emulator reads; nothing about the holder's contract moves. When the holder
  `write` verb lands, the daemon composes exactly as here and hands the holder
  finished bytes.
- **The no-TUI-scraping rule stands.** The contract makes screen reads honest;
  it does not make them the right source for agent *state*. "Is the agent
  stuck" belongs on hook and transcript state, as the rule already says. The
  screen contract serves the readers that legitimately need a screen — the
  login driver, the pending-input check, a person running
  `tbd terminal output` — and the input composer, which needs modes and
  nothing else.

## Delivery verification on holder sends

### The verifier is transport-independent by construction

The delivery verifier observes a send by reading the **tail of the session's
transcript** for the dispatch envelope it typed
(`Sources/TBDDaemon/Actuation/DeliveryVerifier.swift:41-49`, `:354-368`), and
its own doc says why: "Never a pane read: screen text is a display surface,
not an API" (`:314`). The facts it consults are the terminal row's transcript
path, activity state and session id (`:10-28`). None of those is a tmux
coordinate. A holder-backed agent session reports its transcript path through
the same `SessionStart` hook as a tmux one, so the observation has everything
it needs.

Today the holder arm refuses `--verify` before composing anything
(`RPCRouter+TerminalHandlers.swift:3205-3208`, refusal text at `:2835-2839`),
and the comment justifying it says the verifier "re-reads a tmux pane, and
there is none" (`:3176-3177`). That misdescribes it. The one leg of the
mechanism that does touch a pane is the **evidence-bounded re-delivery**:
`redeliverVerifiedPayload` (`:3336-3400`) consults the pane, pastes through
tmux and presses Enter through tmux. That leg is a transport call, and it
routes the same way every other send does.

### What changes

- **The refusal is lifted.** A verify-armed send to a holder-backed agent
  session is composed by `performHolderSend`, delivered by the courier, and
  armed for observation exactly as the tmux arm arms it. Eligibility stays
  what `supportsDeliveryObservation` says (`:3453-3455`) — an agent kind with
  a transcript — and is transport-blind.
- **Re-delivery routes by transport.** `redeliverVerifiedPayload` branches as
  the send handler does: a holder row composes through the oracle and delivers
  through the courier; the session-id re-check that guards against typing into
  a stranger (`:3368-3370`) is already transport-independent and runs on both
  arms. The pane consultation's holder equivalent is the registry's recorded
  child status — a child the holder reports exited is refused, as a dead pane
  is.
- **The daemon's own rails arm verification by default.** Sends originated by
  a daemon rail — fleet supervision nudges, queued prompts, the limit-resume
  actuator — are verify-armed on holder sessions whenever
  `delivery_verification_enabled` is on, without the caller passing
  `--verify`. A person or a script keeps opting in per send. The rails are the
  senders whose silence costs hours: nobody is looking at the screen when a
  desk nudges an agent at three in the morning, and the record is the only
  witness.
- **Nothing about the ladder changes.** Requested, dispatched, landed
  (`2026-07-26-fleet-supervision-design.md` §12) stays the record's shape; the
  third rung simply becomes reachable on the transport where it is needed
  most. `undetermined` is never retried, and the single retry is bounded by
  evidence — both rules unchanged.

### Where the halves meet

A verified send on the holder transport is: compose against the child's modes
(the oracle), write, observe the transcript (the verifier), retry once on
positive evidence of non-delivery, composing again against the modes as they
are then. The oracle is what makes the first attempt likely to land; the
verifier is what makes a failure to land loud within one observation deadline
instead of hours. A send that lands after retry is recorded as landed with two
dispatches between which the observation sits; a send that does not is
recorded as not landed, and that row is the signal this whole design exists to
emit.

## What stays silent, stated

- **Shell sessions have no transcript**, so verification cannot observe them.
  The oracle still serves them — bracketed paste off means bare bytes — and a
  shell in canonical mode never met the input-queue ceiling in the first
  place. The residue is a shell that received a send and did nothing, which
  is what a shell does with a command it does not understand.
- **A mode that flips between query and write** produces a visible mis-paste.
  Accepted, as above.
- **A viewer that never answers a pull** yields `staleDaemon` for as long as
  it holds the pty. That is the transport spec's alive-but-silent arm, and it
  is now a labeled answer with an age instead of an error that names the
  wrong cause.
- **An app that dies with an injection remainder in its outbox** has acked
  `written: true` for bytes that never landed. Verification is what turns that
  residue into a not-landed row; the outbox spec names it and this design does
  not re-open it.

## Reconcilers

Per
[`2026-08-15-named-reconciler-doctrine-design.md`](2026-08-15-named-reconciler-doctrine-design.md):
**this design introduces no new kind of durable resource and no new creation
path to one.** The retained emulator is daemon memory released with the
session's reader; the sidecar frames are memory in two processes bounded by a
clock; the verification arming is a task the verifier already owns and
forgets on completion; the actuation rows are appended to a log that already
exists, under a query-time delivery rule that leaves nothing stale.

## Flag

- **The screen contract** is an additive change to an RPC result and a
  correction to the send composition. It ships under `pty_holder_enabled`,
  which has never shipped on and wraps the whole path it corrects, for the
  reason the outbox spec gives: a second column would keep selectable a
  quadrant (holder on, mode-blind composition) that is known to stall agents.
- **Verification on holder sends** rides `delivery_verification_enabled`,
  the existing default-off soak flag for the observation machinery. Lifting
  the holder refusal adds no reachable behavior while that flag is off, and
  default arming for daemon rails is gated on it.

## Testing

- **The whitelist is structural.** Constructing a screen from a grid holding
  a NUL, a control character or a wide glyph's trailing cell yields a space, a
  refusal, or an omission respectively — asserted on the constructed value,
  never on a render site.
- **Source and age.** The three answers are each constructible in a test: a
  detached session answers `daemon`; an attached session with a responding
  app answers `viewer` and its lines match the app's own serializer; an
  attached session with a silent app answers `staleDaemon` after the bound on
  an injected clock, with the emulator's at-attach content.
- **The oracle decides the bytes.** With bracketed paste on, a submitting send
  produces `ESC[200~`, body, `ESC[201~`, `\r` in one write; with it off, bare
  bytes and `\r`. With `applicationCursor` on, `--keys Up` produces `ESCOA`;
  off, `ESC[A`. Each case asserts on the bytes the courier receives.
- **The paste-burst shape, end to end.** A real pty with a raw-mode child that
  implements the burst heuristic receives an enveloped send above the
  threshold and observes a submit — the test that discriminates the Enter
  loss.
- **Verification on the holder arm.** A verify-armed holder send is armed
  rather than refused; an observation finding the envelope records landed;
  one not finding it records not landed and re-delivers through the courier,
  not through tmux; a daemon-rail send is armed without `--verify` when the
  flag is on and not when it is off.
- **The stale-source policies.** The hibernation check refuses on
  `staleDaemon`; the oracle proceeds and records the source.

## Out of scope, named so nobody re-derives them

- **Jiggle scoping.** The size jiggle is load-bearing on exactly one edge —
  re-adoption after a daemon restart, where the emulator is empty — because
  an Ink-style TUI's runtime emits a resize event only on a real geometry
  change, so a bare `SIGWINCH` heals nothing there. It is redundant on attach
  (`HolderRegistry.swift:1414`: the preamble already carries a current screen
  from an emulator that was draining continuously, and the viewer already owns
  the size ioctl per the transport spec's "resize follows the reader") and on
  handback (`:1701`: the preamble carries the app's screen). When it does run,
  the grid should move with the tty so the emulator is never at a width the
  child is not, and adoption should assert the size so a stranded width heals.
  Its own spec.
- **A per-session health record** over RPC — owner, last-drain time, outbox
  depth, tty size against grid size, child modes and liveness. Every fact is
  already in daemon memory. The screen contract's `source` and `age` are the
  two of them a reader needs now; the rest is its own spec.
- **The reader-count log.** The transport spec promises an always-on
  assertion that logs loudly on a second live drain loop; what exists is a
  test-facing counter (`HolderRegistry.swift:297-306`, `:878`) with no log at
  `> 1`. One line of code, and not this spec's.
- **The holder `write` verb** and the rest of single-typist. This design
  sequences ahead of it: the verb moves the injection writer into the one
  process that knows nothing about modes, so the oracle must be in the
  daemon's composition step before the verb makes that step the only one.

## Rejected alternatives

- **Keep the string and add fields beside it.** A string with a `stale: Bool`
  next to it is the same lie with a footnote: consumers that match on text
  keep matching on text, and the whitelist has nowhere to live. The typed
  lines are what make the invariant enforceable at construction.
- **The app streams its screen to the daemon continuously.** The transport
  spec rejected this as a standing per-byte tax; a pull on demand costs
  nothing between reads.
- **Make the app the oracle always.** The app is not always attached, and
  when it is not the daemon's emulator is the only store there is. Keying on
  `source` is the same model the reads already use.
- **Ask the child its modes.** The child is a program, not a terminal; there
  is no query it answers. The emulator that parsed its `DECSET`s is the only
  witness, which is why the oracle is the emulator.
- **Split the Enter into a second, paced write on the holder.** Mirrors the
  tmux arm's two acts, but reintroduces a message split across a routing
  decision — the hazard "one message" exists to prevent — and it treats the
  symptom while leaving the composer blind to bracketing. Wrapping inside one
  message keeps atomicity and fixes the cause.
- **Observe delivery from the screen.** A composer that shows the text is not
  evidence the agent read it; the transcript is. The no-scraping rule already
  says so, and the verifier already obeys it.
- **Arm verification on every send by default.** A person typing
  `tbd terminal send` at a session they are watching does not need a
  transcript read a minute later, and at-least-once re-delivery is a decision
  a person should make per send. Rails have no person; they get the default.
- **Refuse a send when the oracle cannot answer.** Turns a silent stall into
  a loud refusal, at the price of every supervision send failing whenever the
  app naps. The recorded `staleDaemon` provenance keeps the refusal's honesty
  without its cost.

## Decisions for a human

Each carries a recommendation and the cost of the other answer. None is
settled by the prose above.

1. **Result shape.** Replace `TerminalOutputResult`'s string with the typed
   screen, keeping `output` as a derived joined-lines field so existing
   scripts and the CLI keep working. *Recommended: yes.* The alternative — a
   new RPC method beside the old one — leaves the old one answering wrongly
   for attached sessions until every consumer migrates.
2. **Pull transport.** Two sidecar frame types, `screenRequest` /
   `screenReply`, beside `injection` / `injectionAck`. *Recommended: yes.*
   The alternative, a daemon-to-app request over the RPC subscription channel,
   is a new direction on a channel that only pushes today.
3. **Retain the daemon's emulator across an attach**, suspended rather than
   stopped, so `staleDaemon` has content. *Recommended: yes.* The alternative
   keeps today's release and makes `staleDaemon` an empty screen with an age,
   which is honest but useless.
4. **The oracle's stale-source policy.** Proceed on `staleDaemon` modes and
   record the source on the actuation row. *Recommended: proceed.* The
   alternative — refuse — is genuinely arguable: it never mis-pastes, and it
   fails every supervision send while the app naps. This one is open.
5. **Composition rule with bracketed paste on.** Wrap the body in explicit
   markers with `\r` after the end marker, in one write. *Recommended: yes.*
   The alternative keeps bare bytes and depends on the receiver's heuristic,
   which is the defect.
6. **Build the named-key table now**, mode-aware and paced, rather than
   keeping the refusal until single-typist lands. *Recommended: now.* The
   alternative leaves the documented remedy for a stuck composer refused on
   the transport where composers get stuck.
7. **Lift the holder `--verify` refusal** and route re-delivery by transport.
   *Recommended: yes.* The alternative keeps the third rung unreachable on
   the transport that needs it, on the strength of a comment that is wrong.
8. **Default arming for daemon rails** — supervision nudges, queued prompts,
   limit-resume — on holder sessions while `delivery_verification_enabled`
   is on. *Recommended: yes.* The alternative lifts the refusal only, and the
   rails that stalled for hours keep sending unverified unless somebody
   remembers a flag.
9. **Whether default arming applies to tmux sessions too**, for symmetry.
   *Recommended: not in this change* — the tmux arm already has explicit
   bracketing and a separate Enter, and widening the soak widens the blast
   radius of a re-delivery bug. Open, and cheap to revisit.
10. **Sequencing against single-typist.** Oracle and verification land before
    the holder `write` verb. *Recommended: yes.* The alternative ships a
    faster path to the same stall and moves the composer further from the
    modes it needs.
