# Single-typist injection on the holder transport

## Summary

On the pty-holder transport, **the daemon is the only process that ever types
an injection into a session** — attached or detached, agent or shell. Every
injection is carried to the session's holder as a `write` request and written
there, by the process that owns the master and never reads it. The viewer's
role in injection shrinks to two signals: it tells the daemon when a user paste
is open, and it holds the person's keystrokes for the span of an injection.

Three properties follow from the shape rather than from a policy:

- **No injection can be written twice.** A duplicate requires two acts of
  writing the same message. There is one injection writer, so there is no
  second act — nothing has to be deduplicated, retracted, or forgiven.
- **No injection waits on a GUI's scheduling.** The writer is a process with no
  window, no main actor and no App Nap, whose death is a session-ending event
  the daemon already detects.
- **A write that starts is finished.** The process that made the syscall owns
  the remainder and completes it, bounded by the child's death rather than by a
  clock. A prompt no longer half-arrives.

The research this transcribes, including the delivery-semantics argument and
the measurements, is
[`2026-09-03-injection-delivery-alternatives.md`](2026-09-03-injection-delivery-alternatives.md).
This document is the decision and the contract; that one is the reasoning and
the prior art. The transport spec it fits inside is
[`2026-08-30-pty-holder-session-transport-design.md`](2026-08-30-pty-holder-session-transport-design.md),
whose "Input is not arbitrated, but it is serialized" states the same rule in
brief.

## The delivery rule

One rule, applied to every injection — `tbd terminal send`, queued prompts,
supervision nudges, and any future actuator:

1. The daemon composes the whole message (dispatch envelope, body, and the
   submitting `\r` when asked for) as it does today, and hands it to the
   courier as one payload.
2. If a viewer holds the session's pty, the daemon asks it for a **paste
   lease** and waits, bounded. If no viewer holds it, there is no paste to
   collide with and the daemon proceeds at once.
3. The daemon sends the payload to the session's holder as a `write` request.
   The holder appends it to that session's outbox and answers immediately.
4. The holder drains the outbox into the pty master from its own `poll` loop,
   non-blocking, in order, until every byte is accepted or the child is gone.
5. The daemon records what happened against the actuation row, and releases the
   viewer's keystroke hold.

There is no branch on attach state except step 2's lease, no acknowledgement
that a write happened elsewhere, and no deadline that licenses a second write.

## What "single typist" covers, and what it does not

The claim is precise, and stating it loosely would make it false.

- **Injections have one writer: the daemon.** This is the whole of the
  guarantee above.
- **The person at the keyboard still types directly.** Keystrokes and pastes go
  from the viewer to the pty over the descriptor the viewer already owns
  (`TerminalPanelView.swift:1961`, `:2065`). They must: routing a keystroke
  through two processes to reach the pty is the latency this transport exists
  to remove. Two writers therefore exist on the descriptor — a person and the
  daemon — which is exactly why the keystroke hold below is mandatory rather
  than optional.
- **Terminal protocol replies follow the reader, like resize.** When the child
  asks the terminal a question (device attributes, cursor position), the
  emulator that answers is whichever one is currently reading — the daemon's
  headless emulator while detached (`HolderReader.swift:1050-1060`), SwiftTerm
  while attached. At most one emulator reads at a time, so at most one replies;
  this is the reader arbitration already specified, not a second typist.
- **The tmux transport is untouched.** Holder-backed sessions are the only ones
  this rule applies to; tmux sessions keep serializing input through the tmux
  server as they always have.

## The paste lease

A bracketed paste is `ESC[200~`, the payload, `ESC[201~`, and every byte the
child reads between the markers is delivered to it as pasted text. An injection
that lands there is silently absorbed. Only the viewer knows whether a paste is
open, so only the viewer can say when it is safe.

- **`injectionIntent` (daemon → viewer)** names the session and carries the
  injection's own id. It means: I am about to write to this pty; tell me when
  you are not mid-paste, and hold the person's keystrokes until I say I am
  done.
- **`injectionClear` (viewer → daemon)** answers one intent by its id. The
  viewer answers immediately when no paste is open, and otherwise when the
  paste's end marker has been **accepted by the kernel** — which is
  `endUserPaste` plus however long the viewer's outbox takes to land the
  marker, since a stalled child can leave the marker queued for as long as it
  stalls ([`2026-09-04-pty-write-completion-design.md`](2026-09-04-pty-write-completion-design.md)).
  The machinery is the hold-and-release `OutgoingInputQueue` already has
  (`beginUserPaste`/`endUserPaste`, and the outbox behind them), holding its
  own answer instead of somebody else's bytes. Answering starts the keystroke
  hold.
- **`injectionDone` (daemon → viewer)** ends the hold, whatever the write's
  outcome.

Both new frames are ordinary sidecar frame types
(`SidecarFraming.swift:26-31`), which is cheap in both directions because an
unrecognized type byte is returned by the scanner and skipped with a log by
each receive loop rather than desyncing the stream
(`SidecarFraming.swift:236-241`, `FDSidecarClient.swift:304-307`,
`FDVendingServer.swift:345-348`). A viewer built before the lease existed
simply never answers, and the daemon's bound covers it.

**What bounds the wait, and what expiry means.** The viewer bounds at
`pasteHoldBound` (two seconds, `HolderInputTiming.pasteHoldBound` in TBDShared)
how long an open paste may defer its answer: a paste still open at that point
gets the answer anyway. That clock covers the paste being open; it does not
cover the end marker's journey into the kernel, which is bounded by the
descriptor instead. The daemon's lease bound must therefore be strictly
*longer* than the viewer's hold bound — three seconds against two. That
ordering is load-bearing in the same way its predecessor was, and in mirror
image: were the daemon's bound the shorter one, every injection the viewer
legitimately held would be written while the paste was still open, making the
between-markers collision systematic instead of rare.

With that ordering, an expired lease has two readings. The first, and the one
the bound is sized for: **the viewer is not running its main actor at all.** A
paste is three synchronous main-actor delegate calls with no suspension point
between them, so a live app answers within a turn. The daemon writes when the
bound expires, and the worst case is that the injection is absorbed into a
person's paste — visible in the composer, the trailing `\r` rendered as a
newline rather than a submit, and observable as not-landed. It is a paste
collision, and it can never be a duplicate, because nobody else writes.

The second reading is the rarer of the two, and it resolves the same way: the
viewer is alive and a large paste is still draining into a stalled child, so
the end marker has not been accepted yet. Both readings end with the daemon
writing on its bound, the injection absorbed into the person's paste, visible
in the composer and never doubled. An explicit "still draining" answer that
extends the lease is the obvious refinement, and it waits on a soak showing
the residue is felt.

**The two kinds of bound stay distinct.** The keystroke hold that waits on
another process's `injectionDone` is bounded by a clock, because that process
can die silently. The viewer's own remainder is bounded by the descriptor —
`EIO` or `EBADF` — and by nothing else; the hold's clock bound does not apply
to it.

A stale viewer claim — a session whose viewer record outlives its panel —
degrades to exactly that bounded wait per injection, rather than to a send path
that stops working.

## The keystroke hold

**Mandatory, not optional, and forced by measurement.** A raw-mode pty master
accepts 1,022 bytes and then refuses (`TTYHOG − 2`; measured and recorded in
the addendum to
[`2026-09-03-injection-delivery-alternatives.md`](2026-09-03-injection-delivery-alternatives.md)).
An agent's TUI runs in raw mode, so any prompt worth queueing spans several
write turns. A keystroke that lands between two of those turns splits the
injection down the middle — and for a bracketed payload, splits it between its
markers.

- **Where it lives.** `OutgoingInputQueue`, the viewer's single serialization
  point for everything one panel writes: it is the only place that sees the
  person's bytes, it is main-actor confined, and it already holds and releases.
  The hold is on user bytes now, rather than on injections it no longer sees.
- **Held, never dropped.** Held keystrokes queue in order and flush on release.
  Nothing the person typed is discarded at any point in this design.
- **Bounded.** The hold ends on `injectionDone` or after its own bound,
  whichever comes first. Expiry releases the hold and resumes writing — a
  wedged agent must not be able to make the keyboard stop responding, and a
  tear is recoverable where a frozen keyboard is not. The bound is a few
  seconds: long enough to cover an ordinary multi-turn write, short enough that
  nobody wonders whether the app has crashed.
- **What expiry costs.** Keystroke-granularity interleave into an injection
  whose child is not draining, which is tmux parity and visible.

One point decided narrowly here rather than left to be discovered in a soak: no
byte bypasses the hold, including `0x03`. Letting an interrupt jump the queue
reorders the person's own input against itself, and the bound already ends the
hold; if a soak shows the bound is felt at the keyboard, shortening it is the
first move, not a bypass.

## The holder `write` verb

The daemon does not write injections through its own descriptor. It asks the
holder to write them.

**Why the holder.** The holder is single-threaded by construction and
structurally never reads the master — the invariant its whole design rests on
(`Holder.swift:9-20`). A write verb there keeps the one-reader invariant
enforced by *shape* rather than by discipline: the daemon needs no descriptor
at all for an attached session, so there is nothing it must promise not to
read. Two further consequences are worth naming because they are not obvious:

- **Daemon writes serialize for free.** One process, one loop, one outbox per
  session, FIFO.
- **It keeps an unbounded write off the daemon's drain.** The daemon's
  descriptor guards `read` and `writeAll` with the same lock
  (`HolderReader.swift:1012-1015`, `:1062-1064`). A write that completes rather
  than giving up would hold that lock across its `poll(POLLOUT)` waits and
  stall the drain — and the drain is a liveness requirement, not a convenience:
  a detached job cannot finish exiting while its output sits unread (the
  transport spec's "Daemon death"). Routing the write elsewhere removes the
  conflict instead of arguing about lock granularity.

### Protocol shape

`HolderRequest` gains `write(id:bytes:)` and `HolderResponse` gains
`writeAccepted(id:queued:)` and `writeCompleted(id:written:outcome:)`
(`HolderProtocol.swift:90-106`). `HolderProtocolVersion.current` goes to 2
(`:3-11`).

- **`write` is answered immediately.** `writeAccepted` means the bytes are in
  that session's outbox — a copy in the holder's memory, which cannot block.
  It never means they reached the child.
- **`writeCompleted` is pushed** when the outbox for that id drains, carrying
  how many bytes were written and whether it ended by completion or by the
  child's death. The holder already pushes unsolicited frames from its reaping
  branch, and `HolderFraming.drain` already returns every frame in a read with
  the contract that callers queue what they do not use
  (`HolderFraming.swift:43-50`), so the shape exists. What must change is on
  the daemon side: `HolderClient.receive(answering:)` treats the first queued
  frame as the current request's answer and drops the connection otherwise
  (`HolderClient.swift:474-492`, `:529-541`). A completion push must be routed
  to a sink and skipped in place, alongside the exit pushes
  `retireQueuedFrames` already recognizes (`:432-462`).
- **Requests stay non-blocking.** The daemon must not hold a holder connection
  open awaiting a completion: one client at a time is the holder's contract
  (`Holder.swift:486-501`), so a hung child would otherwise block `describe`
  and `handOverPTY` for that session too.

### The write inside the `poll` loop

The holder's loop already multiplexes its listener, its client, and a `WNOHANG`
`waitpid`, on a 50 ms slice (`Holder.swift:392-435`, `:604`). The outbox joins
it:

- The master is set `O_NONBLOCK` before the first write. The flag lives on the
  shared open file description, so it rides every `dup` the holder hands out —
  which is already the state readers expect and set for themselves
  (`HolderReader.swift:985-987`).
- While an outbox is non-empty the master joins the poll set with `POLLOUT`.
  Each pass writes what the kernel accepts and keeps the remainder. **A short
  write is the ordinary case, not an error** — 1,022 bytes at a time into a
  raw-mode pty.
- **The loop never blocks on the pty.** A blocking write into a full input
  queue would stop the holder serving, reaping, and reporting its child's exit
  — turning a busy agent into an unreachable session.
- **`EIO` ends a write**, and only `EIO` (or the child's reaping) does: on a pty
  master it means the last slave has closed, so there is no child left to
  deliver to. The outbox is discarded and `writeCompleted` says so.
- **Order is FIFO across ids.** A second `write` for a session queues behind the
  first; it is never interleaved with it.

### Size, and one message

`HolderFraming.maximumFrameSize` is 1 MiB (`HolderFraming.swift:30`) and the
payload is JSON, so one frame carries roughly 768 KiB of bytes. A payload above
that is split across consecutive `write` frames under **one id**: the outbox is
FIFO and there is no other injection writer, so the message is still delivered
whole and in order, and completion is still reported once. The 4 MiB sidecar
cap that guarded the app's frame scanner (`HolderInjectionCourier.swift:118-134`)
no longer applies to injections, because injections no longer ride the sidecar;
the holder frame limit replaces it.

### Version skew

Long-lived sessions keep running the holder binary they were born with, so the
daemon must interoperate with every holder that has ever shipped
(`HolderProtocol.swift:3-6`). The holder wire is *not* forgiving the way the
sidecar is, and the difference decides the design:

- **An old holder cannot be probed.** `HolderRequest` is a Codable enum, so an
  unknown case fails to decode (`HolderFraming.swift:65`), and the holder treats
  an unparseable frame as a reason to drop the client
  (`Holder.swift:527-533`, `:438-440`). From the daemon's side that is
  indistinguishable from a holder that died. Sending `write` speculatively to
  find out whether it is understood is therefore not available.
- **So the version is negotiated, not probed.** `HolderChildDescription` gains
  an optional `protocolVersion`. Every handshake already returns a description,
  and an absent field decodes as nil from a holder that predates the verb —
  which the daemon reads as version 1. An older daemon decoding a newer
  holder's description ignores the unknown key, so the other direction needs
  nothing.
- **A new daemon against an old holder** keeps a write handle for that
  session's remaining life instead: on attach, the registry demotes its reader
  to a write-only handle rather than closing the descriptor
  (`HolderRegistry.swift:1282-1305`). The one-reader invariant is then held by
  discipline for those sessions — a handle with no `read` method — which is
  what every comparable system lives with, and it is scoped to sessions that
  predate the verb. Holders are never upgraded in place, so this population
  only shrinks; when it is empty the fallback has no live callers.
- **An old daemon against a new holder** asks only for verbs that already
  existed and is answered exactly as before.

## Finishing the write

Above a kilobyte into a raw-mode pty a short write is the *ordinary* path, not
an edge, so a writer that gives up after one attempt truncates by default. The
viewer already finishes what it starts: it keeps the remainder the kernel
refused and drains it on write-readiness, bounded by the descriptor
([`2026-09-04-pty-write-completion-design.md`](2026-09-04-pty-write-completion-design.md)).
The daemon's own path still gives up, after a 250 ms budget
(`HolderReader.swift:965`, `:1062-1088`) — and under single typist that is the
path every injection takes.

- **The process that started a write finishes it.** The holder finishes
  injections; the viewer finishes the person's own pastes, resuming from
  `OutgoingInputQueue` when the descriptor is writable and holding subsequent
  keystrokes behind the remainder. Whoever owns the bytes owns the remainder.
- **Bounded by `EIO`, never by a clock.** A child that is slow to drain is
  indistinguishable from a child that is fast, given a clock; it is perfectly
  distinguishable given the descriptor, which reports `EIO` when the last slave
  closes. So the bound is the child's death, which is an event.
- **No budget survives as a truncation point.** A budget may still exist to
  keep a *loop* responsive — the holder's `poll` slice is one — but expiry
  returns to the loop with the remainder queued, never discards it.

## Sender outcomes

Completing a write is open-ended by construction: a wedged agent may not drain
for minutes. The sender therefore gains an outcome it did not have.

- **`delivered`** — every byte was accepted by the kernel's input queue.
- **`accepted`** — the holder has the whole message and is writing it; the
  remainder waits on the child alone. This is a success, not a deferral: the
  bytes are in the process that owns the pty, and no other outcome can
  supersede them.
- **`endedEarly(written:)`** — the child died with bytes unwritten. How many
  were written is known exactly, because the writer counted them.
- **`notDelivered`** — refused before any byte was accepted: no holder, holder
  gone, session ended.

`terminal.send` returns `accepted` rather than parking its caller until a slow
child drains, and the actuation row records which outcome it was. Nothing about
this makes the record depend on a sweep: delivery status is computed at query
time from the rows that exist, so an act whose completion was never recorded
renders unconfirmed by construction rather than leaving a stored lie behind
(`ActuationRecordReader.swift:168-190`).

## What this deletes

- The sidecar `.injection` and `.injectionAck` frames, and
  `SidecarInjectionAck`.
- The five-second ack deadline (`HolderInjectionCourier.swift:151`), the
  `ackDeadlineElapsed` write reason and its documented duplicate
  (`:88-90`), and the late-ack accounting.
- The viewer's injection write path, and with it the question of what a viewer
  should do with a partial injection.

## Reconcilers

Per the doctrine in
[`2026-08-15-named-reconciler-doctrine-design.md`](2026-08-15-named-reconciler-doctrine-design.md),
the question is answered rather than skipped: **this design introduces no new
kind of durable resource, and creates no new path to one.** It mints no socket,
no process, no git object, no database row and no file; the only thing it puts
on disk is one more outcome value in the actuation log that every send already
appends to.

- **The holder's outbox** is memory inside a process that already has named
  reconcilers. Its rendezvous files are swept by `OrphanGC`
  (`Sources/TBDDaemon/GC/OrphanGC.swift:699-702`, gated by
  `gcHolderRendezvousEnabled`); its child is swept by `AgentReaper`
  (`Sources/TBDDaemon/Process/AgentReaper.swift:285`, gated by
  `reapHolderChildrenEnabled`); a session row whose holder is gone is
  reclaimed by the reconcile arm gated on `holderRowReconcileEnabled`
  (`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift:631`). An
  outbox cannot outlive the holder that holds it, so it inherits all three.
- **The paste lease** is daemon memory bounded by an injected clock. Expiry is
  the reclaim, and it happens whether or not anybody sweeps.
- **The keystroke hold** is viewer memory bounded by its own clock, released on
  `injectionDone`, on expiry, or with the panel.
- **The actuation record** gains one outcome value in an append-only log whose
  delivery rule is computed at query time; no row is left to go stale.

## Flag

**This ships under `pty_holder_enabled`, and takes no flag of its own.**

The reasoning, since two sibling behaviors in this same subsystem each took one
anyway. `gcHolderRendezvousEnabled`, `reapHolderChildrenEnabled` and
`holderRowReconcileEnabled` are separate gates because each is a *destructive
reclaimer that acts with no user gesture* — unlinking files, signalling
processes, deleting rows in a background sweep — and because
`pty_holder_enabled` must be ON for their subject to exist at all, so it cannot
express the soak protocol they need: transport on, one destructive reclaimer on
at a time (`Models.swift:1538-1548`).

Injection is not that shape. It acts only on an explicit dispatch that would
have written to the session anyway, it destroys nothing, and it is reachable
only on holder-backed sessions — which exist only when `pty_holder_enabled` is
on, and which have never shipped with it on
(`Models.swift:1587-1590`, `:1655-1660`). The repo's rule does name
"wholesale-replaces a load-bearing path (input routing)" as flag-worthy, and
this is that; the flag it lands behind is the one already wrapped around the
entire path, which has no users to protect.

A second column would also have a broken quadrant. Holder on, single-typist
off is the arrangement this design replaces, and it is known-defective in ways
already recorded: the ack deadline resolves a writer's silence with a timer, so
an app that is alive but slow gets written over and the injection doubled, and
a viewer claim outliving its panel stops sends working for the daemon's
lifetime. Keeping it selectable would
preserve a path we have decided is wrong and would double every soak.

Both branches of the gate remain testable, because both still exist: a tmux
session's input path is untouched, and a holder session's is this one.

This judgment is scoped to the current state. If injection were ever retrofitted
onto tmux sessions, or if this landed after `pty_holder_enabled` had graduated,
it would need its own default-off column with the tri-state discipline
(`ALTER TABLE config ADD COLUMN … INTEGER;` with no SQL default, resolved
through a single `Config` constant).

## Testing

- **The lease, both answers and its expiry**, on an injected clock: cleared
  immediately with no paste open, cleared on `endUserPaste`, and written on
  expiry when nothing answers.
- **The bound ordering** — a viewer hold that outlasts the daemon's lease bound
  must be constructible in a test and must produce a paste collision rather
  than a between-markers write in the ordinary case.
- **The keystroke hold** holds, releases in order on `injectionDone`, and
  releases on its own bound; and no held byte is dropped in either path.
- **The holder's outbox**: a short write resumes on the next writable pass; a
  second write queues behind the first; `EIO` ends the write and reports how
  much was written; the loop keeps serving requests and reaping its child while
  an outbox is draining.
- **Version skew, both directions**: a holder reporting no `protocolVersion`
  takes the write-handle fallback and the daemon never sends `write` to it; a
  holder reporting version 2 takes the verb. A test must observe the fallback
  actually writing, not merely being selected.
- **The completion push** is routed rather than mistaken for another request's
  answer — a `writeCompleted` arriving between a request and its response must
  not drop the holder connection.

## What this does not solve

- **The ~1 KB coupling.** While a viewer is attached it is the session's
  *reader*, and an agent blocked writing output does not read its input. So a
  viewer that stops draining lets the child stall, the input queue stays full at
  1,022 bytes, and the remainder of a large injection waits for that viewer to
  wake. "Independent of the app" is true for the first kilobyte and no further.
  The injection still always arrives and still never arrives twice; only its
  completion is coupled. Closing it means keeping the reader draining — an App
  Nap assertion while a viewer holds a pty descriptor is the obvious next move,
  and it is not part of this design.
- **A writer that dies between its syscall and its record.** A daemon that
  crashes after the holder accepted the bytes and before the actuation row is
  completed leaves the record unknown. This is the irreducible residue every
  local system carries; it presents as "unknown, and loud" — the RPC never
  returns — never as "twice".
- **Bytes arriving twice by a path that is meant to.** The transcript-side
  verifier performs a single evidence-bounded re-delivery under the same
  dispatch id when it observes an act verifiably not landed. That is
  at-least-once on purpose, bounded by evidence rather than by a timer, and it
  is untouched. Receiver-side dedupe on the dispatch id is a separate,
  user-land piece of work.
- **Named-key sends.** `--keys` remains refused on holder-backed sessions; this
  design carries text, not a key table.
- **A trailing Enter absorbed by a TUI's paste-burst heuristic** on a very large
  submit. That is a receiver heuristic, closed by exposing the child's
  bracketed-paste mode, not by delivery.
- **Shell sessions gain nothing new.** They carry no dispatch envelope and, in
  canonical mode, never met the input-queue ceiling in the first place.

## Rejected alternatives

- **A write-only handle in the daemon (instead of the holder verb).** The
  daemon keeps a descriptor across an attach, wrapped so it exposes only
  `write`. It is cheaper — no protocol bump, no skew story — and it is what
  comparable systems live with. Rejected as the primary design because the
  one-reader invariant then rests on nobody ever adding a `read` to that type,
  where the holder route makes it structural: the holder cannot read, so a
  write routed through it cannot become a second reader. It survives as the
  version-skew fallback, where its scope is bounded and shrinking.
- **Re-vending a descriptor per injection.** Structural between injections,
  disciplinary during one, and it puts an fd-vend round trip on every
  supervision nudge.
- **The viewer as sole writer, with a daemon outbox and liveness-gated
  takeover.** Also reaches one writer without a timer, but it changes what
  `terminal.send` means (a deferred state), keeps injection latency tied to a
  GUI's scheduling, needs two-phase frames and an outbox, and still has a
  crash-mid-write policy to choose.
- **Keeping the ack and shortening or lengthening its deadline.** No deadline
  distinguishes "the app wrote and its ack is late" from "the app never wrote",
  which is the two-generals shape; the choice is not between deadlines but
  between having two writers and having one.
- **Making the duplicate harmless instead of impossible.** Receiver-side dedupe
  converts "acts twice" into "acts once" and leaves "bytes twice" untouched —
  and only for agents exposing a pre-prompt hook. Worth having as
  belt-and-braces; not an answer to the question asked.
