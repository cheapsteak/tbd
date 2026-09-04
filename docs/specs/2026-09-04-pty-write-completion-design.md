# Completing a write to a session's pty

## Summary

A write to a holder-backed session's pty master can commit a prefix of the
payload and drop the remainder. It is not a rare failure: a raw-mode pty
accepts 1,022 bytes and then refuses, so every payload above a kilobyte into an
agent session depends on the child draining its input *during* the write, and
both of TBD's writers give up on a clock — the viewer after 20 ms, the daemon
after 250 ms — with the prefix already delivered.

Nothing can un-write a prefix, and nothing can ask a pty how much room it has,
so the defect cannot be avoided; it can only be repaired by **finishing the
write**. The design rule is one sentence: **whoever committed the prefix owns
the remainder, and nothing else may write to that pty until the remainder has
landed.** The second clause is the hard part. A write that spans several
main-actor turns is no longer atomic with respect to the person at the
keyboard, and a keystroke that lands between two of its turns tears the payload
— for a bracketed paste, between its markers.

The accepted answer to "who writes an injection" is already committed:
[`2026-09-03-single-typist-injection-design.md`](2026-09-03-single-typist-injection-design.md)
makes the daemon the only injection writer, routes every injection through the
session's holder, and has the holder finish it from an outbox bounded by the
child's death. That spec also says, in one sentence, that the viewer finishes
the person's own pastes and holds subsequent keystrokes behind the remainder.
**This document is that sentence, designed** — the viewer-side outbox and the
hold on user bytes — and it is the piece of single-typist that can land first
and on its own, because it needs no protocol change and fixes the two victims
that are entirely inside the app. It does not re-derive the holder outbox; it
sequences against it.

Three victims were examined. All three are reachable, and one of them is worse
than a truncation: a large paste whose end marker is lost leaves the child in
bracketed-paste mode, where everything typed afterwards is absorbed into the
paste. The verdicts and the evidence are in "The three victims" below.

## The defect

### The mechanism, measured

A pty master's input queue is bounded by `TTYHOG`, and the bound binds in raw
mode only:

- **Raw mode** (`ICANON` off — what every full-screen agent TUI sets) — a
  non-blocking master accepts **1,022 bytes** and then returns `EAGAIN`, with
  the short write on the very first call. 1,022 is `TTYHOG − 2`.
- **Canonical mode** (a shell at its prompt) — a MiB accepted with no short
  write at any size tried.

Measured directly on a development macOS machine (arm64) by opening a pty pair,
leaving the slave unread, and writing to a non-blocking master until the kernel
refused; the method and the numbers are recorded in the measured addendum to
[`2026-09-03-injection-delivery-alternatives.md`](2026-09-03-injection-delivery-alternatives.md).
The mechanism is `ptcwrite` in XNU's pty driver: the master's write path
refuses once the slave's raw and canonical queues together hold `TTYHOG − 2`
bytes and the line discipline is non-canonical. Two consequences of that code,
read from the published source rather than measured, matter to this design:

- **Commitment is per byte, not per call.** `ptcwrite` feeds the queue a byte
  at a time until it is full and then returns how many it took. A six-byte
  paste marker can therefore be torn — three bytes accepted, three refused —
  not merely lost whole.
- **`poll(POLLOUT)` says "some room", never "how much".** There is no
  interface on the master side that reports the input queue's free space, so
  a writer cannot know before writing whether a payload will fit.

So any payload above about a kilobyte into an agent session is delivered
whole only if the child drains its input while the write is in progress. A
child that is busy — rendering, in a synchronous computation, or blocked — does
not, and the write returns short.

### Where the writers give up

- **The viewer** – `PTYWrite.all`
  (`Sources/TBDApp/Terminal/PTYWrite.swift:74`) loops on `write(2)` and a
  `poll(POLLOUT)` in 5 ms slices (`:101`) inside a **20 ms** total budget
  (`:63`), and returns `.partial(written:)` (`:56`) when the budget expires
  with a prefix delivered. Its caller `writeToHolderPTY`
  (`Sources/TBDApp/Terminal/TerminalPanelView.swift:2272`) maps `.partial` to
  `false` and logs one line (`:2282`). Above it, `performOutgoingWrite`
  (`:2159`) is synchronous and main-actor, and its `Bool` is the only report
  the write ever makes.
- **The daemon** – `PTYDescriptor.writeAll`
  (`Sources/TBDDaemon/Holder/HolderReader.swift:1085`) is the same loop with a
  **250 ms** budget (`:988`), throwing `writeTimedOut(unwritten:)` (`:1103`)
  with the prefix delivered. It runs under the descriptor's lock (`:1086`),
  the same lock the drain thread's `read` takes (`:1026`), so every
  millisecond it waits is a millisecond the daemon is not reading the child's
  output.

Both budgets exist for good reasons — the viewer's because a keystroke must be
answered in the turn it arrived in, the daemon's because an actor must not park
on a child that has stopped reading — and both are wrong as *truncation
points*, because expiry discards the remainder rather than keeping it.

## The three victims

Each case was traced through the code rather than assumed. Line numbers are
against the tree this document was written in.

### Case 1 — a daemon injection into an attached session: reachable, as described, with a second shape

The chain: `performHolderSend`
(`Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift:3127`) composes
the whole message — dispatch envelope, body, submitting `\r` — and hands it to
`HolderInjectionCourier.deliver`
(`Sources/TBDDaemon/Holder/HolderInjectionCourier.swift:201`). With a viewer
attached, the courier puts an `.injection` frame on the sidecar; the app's
handler (`Sources/TBDApp/AppState+TerminalFocus.swift:128-140`) routes it to
the panel (`Sources/TBDApp/Terminal/TerminalInjectionRouter.swift:94`), which
calls `OutgoingInputQueue.enqueueInjection`
(`Sources/TBDApp/Terminal/OutgoingInputQueue.swift:264`) →
`performOutgoingWrite` → `writeToHolderPTY` → `PTYWrite.all`. A payload above
1,022 bytes into a child that does not drain within 20 ms returns `.partial`;
the panel reports `false`; the app acks `written: false`; the courier takes the
`.viewerReportedNothingWritten` arm (`HolderInjectionCourier.swift:235`) and
calls `writeDirectly`, which looks up the daemon's reader
(`Sources/TBDDaemon/Daemon.swift:843-851`).

What happens next depends on the attach state, and the two outcomes are both
wrong:

- **An acknowledged attach.** `confirmAttach`
  (`Sources/TBDDaemon/Holder/HolderRegistry.swift:1396`) stops the daemon's
  reader and with it the descriptor, so `reader(for:)` is nil, the courier
  answers `.notDelivered`, and `performHolderSend` records
  `.transportFailed` and returns the error (`:3173-3181`). **The session
  holds a truncated fragment; the caller is told the send failed.** The
  error is honest and the state is wrong — and the fragment includes the
  dispatch envelope's opening tag with no closing tag and no `\r`, so it sits
  unsubmitted in the composer for the next human or injection to append to.
- **A timed-out attach.** `cancelPendingAttach`'s `.unacknowledged` arm leaves
  the reader suspended with its descriptor open (the courier's own doc comment
  at `HolderInjectionCourier.swift:186-198` names this), so the fallback
  *writes the whole payload on top of the prefix*: **prefix plus whole, in the
  composer, and the actuation row records a successful dispatch.** The
  duplicate-versus-loss fork, resolved on the duplicate side, with the
  duplicate being a fragment.

One refinement to the brief's statement: the ordinary way a viewer's child is
"not draining" at the instant of an injection is that it is *busy*, and
supervision nudges are sent precisely when an agent is busy or stuck. This
case is not an edge of the injection path; for payloads above a kilobyte it is
its common path.

### Case 2 — a human's paste into a holder-backed panel: reachable, silent, a regression

The brief's belief is confirmed by the code. The route:

- `TBDTerminalView.paste` (`Sources/TBDApp/Terminal/TBDTerminalView.swift:103`)
  hands the pasteboard to `onControlModePaste`, whose decision
  (`Sources/TBDApp/Terminal/PasteInterception.swift:46`) is `.passthrough`
  whenever no control-mode attach is live — which is every holder-backed
  panel — so `super.paste` runs (`TBDTerminalView.swift:117`).
- SwiftTerm's paste path, when the child has enabled bracketed-paste mode,
  makes **three separate `send` calls**: the start marker, the payload as one
  chunk, the end marker
  (`.build/checkouts/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift:2351-2356`).
  On the main thread its delivery buffer drains synchronously and preserves
  each call's boundary
  (`.build/checkouts/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift:1053-1054`,
  `:1073-1075`), so `Coordinator.send(source:data:)`
  (`TerminalPanelView.swift:2052`) sees three chunks in one main-actor turn.
- `send` calls `outgoingQueue.enqueueUserBytes` for each (`:2109-2113`);
  `enqueueUserBytes` (`OutgoingInputQueue.swift:209`) is synchronous and
  fire-and-forget; `performOutgoingWrite` takes the `.localPTY` arm and,
  because the panel holds `holderWriteFD` (`TerminalPanelView.swift:830`),
  calls `writeToHolderPTY` → `PTYWrite.all` with the 20 ms budget.

A payload above 1,022 bytes into a child that does not drain the whole of it
within 20 ms is written short. What the user then sees and does not see:

- **No error anywhere.** `enqueueUserBytes` has no caller to report to, so
  the `false` goes to `noteUserWriteOutcome` (`OutgoingInputQueue.swift:228`),
  which logs — once, at `.info` — that user input "reached no transport" and
  "keystrokes are being dropped" (`:236`). Both halves are false: the
  transport is alive and a prefix was written. The next keystroke logs a
  "recovery". Nothing reaches the pane or the panel.
- **The composer shows a shortened paste.** For a paste the user can see in
  full that is a visible truncation; for a long one it is not.
- **It is a regression on both predecessors.** The local-PTY path hands the
  payload to `LocalProcess.send`, which writes through `DispatchIO`
  (`.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:222-245`)
  — a queued, completing write that never truncates. The control-mode path
  ships the paste as a `.paste` frame that tmux completes. The holder path is
  the first of the three in which a paste can be cut short.
- **The gap between permitted and delivered is large.** Nothing caps a
  passthrough paste; `SidecarFrameCodec.maxPasteBytes`
  (`Sources/TBDShared/SidecarFraming.swift:133`) is just under 4 MiB and
  applies to the control-mode frame, so a multi-megabyte paste is accepted at
  the view and delivered to the extent of the child's draining in 20 ms.

What could not be measured, and is stated as a judgment: how often 20 ms
suffices for a paste of a few KiB into an *idle* agent. The budget allows four
5 ms slices; a child that reads and re-renders on every chunk of input — the
shape of a TUI composer — will not drain a 4 KiB paste in four slices on most
turns. Treat the outbox path below as the ordinary path for any paste above a
kilobyte, not as a rare one.

### Case 3 — a bracketed paste whose end marker is lost: reachable; the consequence is the child's to decide

The sequence inside one main-actor turn, from `send` (`:2109-2113`):

1. `ESC[200~` — six bytes; accepted, since the queue is usually not full.
2. The payload — `PTYWrite.all` writes 1,022 bytes (less the marker), then
   polls for the rest of its 20 ms, then returns `.partial`.
3. `ESC[201~` — a fresh `PTYWrite.all` with a fresh 20 ms. If the queue is
   still full — the child has not drained at all in the last 5 ms slice of
   step 2 and does not in the next 20 ms — it returns `.nothingWritten`, the
   panel reports `false`, and **the end marker is dropped.** No line is
   logged: the edge already fired in step 2.
4. `endUserPaste()` runs regardless, so the *app's* bookkeeping says the paste
   is closed while the *child's* is still open.

So the transport-level precondition is a child that does not drain for roughly
40 ms after the payload filled its queue. A render pass or a garbage-collection
pause in an agent TUI is that long routinely, so this is reachable, and it is
reachable from the same paste that truncates in case 2 — it is the second
half of the same event, not an independent one. Two further shapes fall out of
the per-byte commitment described above:

- **A torn end marker**: room for three bytes leaves `ESC[2` in the queue and
  `01~` dropped. The child's parser sees an unfinished CSI sequence followed by
  whatever is typed next, which is worse than a clean loss.
- **A cut inside the payload**: a multi-byte UTF-8 sequence or an escape
  sequence in the pasted text can be split, and the remainder never arrives.

Whether a lost end marker *wedges* the session is a property of the child's
paste parser, which is outside this repository and was not verified:

- A parser following the xterm convention accumulates until `ESC[201~` with no
  timeout. Everything typed afterwards — including Enter and Ctrl-C, which in
  raw mode are just bytes — is appended to the paste. In a TUI that renders a
  large paste as a placeholder, typed text vanishes into the placeholder. That
  is the "swallows everything typed afterwards" outcome the brief describes,
  and it is what the convention predicts.
- A parser with a burst timeout self-heals after its timeout. The repository's
  own comments note that at least one agent TUI has a paste-burst heuristic
  (`RPCRouter+TerminalHandlers.swift:3118-3126`), but whether it also bounds
  an *explicit* bracketed paste is not known.
- **There is a recovery, and it is not obvious**: pasting anything small
  again sends a fresh `ESC[200~ … ESC[201~`, whose end marker closes the
  child's paste state. A user who does not know that sees a session that has
  stopped responding to the keyboard.

The recommendation is to treat this as session-wedging until an agent TUI is
observed to recover on its own. It does change the priority: case 2 loses a
paste, case 3 loses the keyboard, and they are the same paste.

**A consequence for the single-typist paste lease.** The lease relies on the
viewer knowing whether a paste is open. Today "open" means "between
`beginUserPaste()` and `endUserPaste()`", two calls in one main-actor turn.
With a lost or still-queued end marker the child is mid-paste long after that
turn, so an injection the viewer clears as "outside the paste" lands inside it
and is absorbed. Completing the user's paste is therefore not only a fix for
the person at the keyboard; it is what makes the lease's answer true. The
refinement this forces is in "Sequencing against single-typist".

## What is fixed, and what must not break

The constraints this design is written against, each from a prior decision:

- **A keystroke must not acquire a scheduling hop.** The output direction of
  the same panel carries an explicit warning from the paint-starvation
  investigation (`TerminalPanelView.swift:819-823`), and `OutgoingInputQueue`
  is a `@MainActor final class` rather than an actor for the same reason
  (`OutgoingInputQueue.swift:21-35`). Typing stays synchronous and inline.
- **The main actor must not block.** A longer inline wait is not an option.
- **The bound ordering holds.** `pasteHoldBound` (2 s,
  `OutgoingInputQueue.swift:109`, `:137`) stays strictly shorter than the
  daemon's `ackDeadline` (5 s, `HolderInjectionCourier.swift:151`); nothing
  here adds a wait between an injection's arrival and its acknowledgement.
- **One writer per session at any moment.** Two processes may hold write
  descriptors on a pty master — that is ordinary (`TerminalPanelView.swift:474`)
  — but a message must be contiguous on the wire. A multi-turn write must
  therefore hold every other byte bound for the same pty behind it.
- **Never report a write as done when it was not.** The ack chain, the
  actuation record and the courier's fallback all rest on this.
- **The single-typist decision stands.** The daemon is the only injection
  writer; the holder finishes injections from its outbox; the viewer holds
  keystrokes for the span of an injection. Nothing here reopens those.

## Avoidance is not available

The brief asks whether the prefix can be kept from being committed at all.
Each formulation was checked against the mechanism:

- **Refuse if it will not fit.** Needs the queue's free space, which the
  master side cannot read; `poll(POLLOUT)` reports only that at least one byte
  would be accepted. Not available.
- **Chunk and confirm.** Writing in queue-sized pieces changes nothing about
  commitment — each piece is committed the same way, per byte — and the first
  piece is still a prefix if the second is refused. What chunking *can* buy is
  boundary alignment: a writer that never asks the kernel to take part of a
  marker or part of a UTF-8 sequence cannot be torn *inside* one, only
  *between* them. That is worth having, and it is a property of how the
  remainder is cut, not a way to avoid having one.
- **A smaller unit of commitment.** The unit is a byte and the kernel offers
  no transaction. There is no formulation in which a prefix is never
  committed, short of not writing until the child is known to be reading —
  and the only probe of that is the write itself.
- **Sender-side retry.** Cannot un-write; doubles the prefix. It is the
  courier's fallback today, and case 1's second shape is what it produces.

So repair — finishing the write — is the only option, and the design space is
*who* holds the remainder, *what* is held behind it, and *what bounds* the
holding.

## The rule: whoever committed the prefix owns the remainder

- **The process whose syscall committed the prefix keeps the remainder and
  finishes it.** For the viewer's own bytes that is the viewer. For an
  injection under single-typist that is the holder, from its outbox. For an
  injection in the interim before the holder verb lands, it is the viewer when
  attached — the case 1 chain above — and the daemon when detached.
- **Nothing else bound for that pty is written until the remainder has
  landed.** Within one process this is a FIFO outbox: every later chunk from
  every stream is appended behind the remainder, whole, in arrival order.
  Across processes it is the single-typist keystroke hold, which this design
  builds the viewer half of.
- **The bound is the descriptor, not a clock, for a wait on the kernel; a
  clock, for a wait on another process.** A remainder waits on the child
  draining, and the descriptor reports the terminal condition of that wait —
  `EIO` when the last slave closes, `EBADF` after teardown. A clock adds
  nothing but a truncation point. A hold that waits on *another process's*
  report — the single-typist injection hold waiting for `injectionDone` —
  needs a clock, because that process can die silently. Keeping the two kinds
  of bound distinct is what makes each defensible.

## The design: a viewer-side outbox in `OutgoingInputQueue`

`OutgoingInputQueue` is already the single serialization point for everything
one panel writes, main-actor confined, and it already holds and releases. It
gains an outbox: the remainder of a short write, and everything that arrives
while the outbox is non-empty.

### The write step

`performOutgoingWrite` keeps its synchronous shape and its `Bool`. Behind it,
`writeToHolderPTY` makes **one non-blocking attempt** and hands whatever the
kernel refused back to the queue:

- `PTYWrite.all` is called with a budget of **zero** — one `write(2)`, no
  `poll`. The 20 ms budget existed only because there was nowhere to keep a
  remainder; with an outbox, waiting inline buys nothing and costs the main
  actor. The `Outcome` collapses accordingly: `.complete`, `.partial(written:)`
  now meaning "the rest is the caller's to keep", and `.failed(errno:)`;
  `.nothingWritten` becomes `.partial(written: 0)` for a full queue and
  `.failed` for a dead descriptor.
- **The remainder is cut on a boundary the child can parse.** The outbox
  keeps the unwritten bytes exactly as the kernel left them — the kernel
  decides the cut, per byte — so the alignment obligation is on the *next*
  write, not on this one: when the outbox drains, it offers the kernel the
  whole remainder, and whatever the kernel takes next continues the same byte
  stream without a gap. A torn marker or a split UTF-8 sequence is healed by
  the very next accepted bytes, provided nothing else was written in between.
  That proviso is the hold.
- `true` from the write means **accepted by a writer that will complete or
  report** — the same meaning `true` already carries on the other two arms of
  `performOutgoingWrite`, whose own comment (`TerminalPanelView.swift:2147-2158`)
  defines it as "handed off" to `DispatchIO` or the sidecar's send queue.
  `false` means, and now only means, that nothing was written and nothing
  will be: no descriptor, or `EIO`/`EBADF` on the attempt. A prefix followed
  by `EIO` reports `false` and drops the outbox: the child is gone, and the
  honest answer to "was it written" is no.

### The hold on user bytes

- **While the outbox is non-empty, `enqueueUserBytes` appends instead of
  writing.** The append is O(1) on the main actor with no hop; the keystroke's
  *write* happens when the descriptor is next writable. This is not a latency
  cost in the ordinary case, because the ordinary case has an empty outbox and
  writes inline exactly as today; it is a cost only while the pty is refusing
  bytes — when the alternative to queueing the keystroke is dropping it.
- **Order is FIFO across both streams.** A paste's three chunks, the
  keystrokes after it, and an injection released from the paste hold are
  written in arrival order and never interleaved. A keystroke typed after a
  short paste lands after the paste's end marker, which is the property case
  3 needs.
- **No byte bypasses the hold, including `0x03`.** The same ruling
  single-typist makes for its injection hold, for a stronger reason here: the
  queue is full, so an interrupt moved to the front cannot be written either;
  the bypass would reorder the person's input against itself and deliver
  nothing sooner.
- **Held, never dropped.** Nothing the person typed is discarded while the
  panel owns the pty. The outbox has no size cap of its own; the paste that
  filled it was already accepted at the view, and the bytes are a copy in the
  app's memory.

### Draining

- A **write-readiness source on the main queue**
  (`DispatchSource.makeWriteSource(fileDescriptor:queue:)` on `holderWriteFD`,
  precedent: the read source at `Sources/TBDApp/TBDApp.swift:405`) is resumed
  when the outbox becomes non-empty and suspended when it empties. Its handler
  runs on the main queue, so it is main-actor by construction
  (`MainActor.assumeIsolated`), and it drains with the same zero-budget
  `PTYWrite.all`: write what the kernel takes, keep the rest, return to the
  run loop. The source fires at most once per kernel-accepted chunk — about
  once per KiB the child reads — so a multi-MiB paste costs the main queue a
  few thousand short callbacks spread over the seconds the child takes to read
  it, which is the child's pace and not the app's.
- **The bound is `EIO`/`EBADF`, never a clock.** A child that does not drain
  for thirty seconds holds the outbox for thirty seconds. That is the truth of
  the session: tmux, in the same state, buffers the same bytes for the same
  time. What the user gets is not a timeout but a signal (below).
- **`EIO` drops the outbox and logs** how many bytes were unwritten, at
  `.error`, once. The reader's own `EOF` handling ends the panel's session;
  the write side does not need to.

### Teardown and detach

- **`stopHolderReader`** (`TerminalPanelView.swift:949`) cancels the write
  source before closing `holderWriteFD` (`:960`); both are main-actor, and a
  cancelled source on the same serial queue cannot fire after its
  cancellation. The outbox is dropped there, with one `.error` line naming
  the byte count, and `shutdown()` keeps its existing job of releasing parked
  injections as unwritten.
- **A detach with a remainder outstanding drops it.** The handback carries
  the screen, not unwritten input, and a person who closes a tab during a
  stall loses the tail of their own paste — logged, not silent. One hazard
  is named rather than solved: if the remainder held a paste's end marker,
  the child is left mid-paste after the handback and a later injection can
  be absorbed into it. Keeping the writer alive past the handback just long
  enough to land the marker is possible — writers are not readers, and the
  descriptor rules allow it — but it puts new state into the most delicate
  teardown in the file for a case that requires a large paste, a stalled
  child, and a close inside the stall. It is a decision, below.

### The injection path, in the interim before single-typist

Until the holder `write` verb lands, an injection into an attached session is
still written by the viewer, and the outbox changes what a short one means:

- **The remainder of an injection goes into the same outbox**, behind the
  paste hold it already respects, and subsequent user bytes are held behind
  it. This is the single-typist keystroke hold, exercised early and for the
  same payload shape, with one difference: it is released by the descriptor
  rather than by an `injectionDone` frame, because in the interim the viewer
  is the process making the syscall and can see the completion itself.
- **The ack is `written: true` on acceptance.** Acceptance by a writer that
  completes or reports is the meaning `true` already has on the other two
  arms, and it is the meaning single-typist gives its own `accepted` outcome
  ("a success, not a deferral: the bytes are in the process that owns the
  pty"). The viewer owns the pty while attached. The ack is sent in the same
  turn as today, so the 2 s / 5 s ordering is untouched.
- **What this fixes at once.** Case 1's first shape — truncated fragment plus
  an honest error — becomes a completed injection and a truthful dispatch.
  Case 1's second shape — prefix plus whole through a timed-out attach — is
  gone, because `false` is no longer produced for a partial.
- **The residue, named.** An app that dies with an injection remainder in its
  outbox has acked `true` for bytes that will not land. The daemon's
  app-death path seizes the session (`HolderRegistry.swift:1457`, `:1519`),
  so the event is loud, but the actuation row reads dispatched. This is the
  same residue the `localProcess` and sidecar arms carry today under the same
  `true`, and it is the residue single-typist deletes by deleting the viewer's
  injection write altogether. The alternative — acking on completion — would
  push a slow child's ack past the 5 s deadline and trigger the fallback on a
  write still in progress, which the alternatives research already rejected
  (`2026-09-03-injection-delivery-alternatives.md`, section 8). A two-phase
  sidecar ack would be correct and is not built, because single-typist
  deletes the frames it would ride on.

### The signal, instead of silence

- **The diagnostic stops lying.** `noteUserWriteOutcome` is fed `false` only
  when there is genuinely no transport; a short write is not a transport
  failure and never reaches it. A separate edge-triggered `.info` line marks
  the start and end of an outbox episode with the peak byte count.
- **The user sees backpressure.** When the outbox has been non-empty for
  longer than a short threshold (on the order of a second, on an injected
  clock), the panel shows that the session is not accepting input and how
  much is waiting, and clears it when the outbox drains. The mechanism is a
  published pending-byte count on the coordinator; the presentation is a
  minor UI question and not fixed here. In-pane status lines of the
  `"\r\n[...]\r\n"` kind are *not* used for this: they write into the
  scrollback of a session that is mid-paste.
- **Senders learn `accepted` versus `delivered`** under single-typist's
  outcomes; the interim ack cannot carry the distinction and does not
  pretend to.

## The daemon's paths

### The detached path and the holder verb

A queued prompt into a *detached* session — the most common supervision
shape — goes through `HolderReader.write` (`HolderReader.swift:520`) and the
250 ms `writeAll`. Above a kilobyte into a busy agent it truncates exactly as
the viewer's path does, and returns an honest `writeTimedOut`. This document
does not give that path a stopgap, for two reasons that are both in the
single-typist spec:

- **The fix is the holder outbox**, drained from the holder's own `poll` loop
  (`Sources/TBDHolder/Holder.swift:392-435`, 50 ms slices at `:604`) with
  `POLLOUT` on the master while an outbox is non-empty, bounded by `EIO`.
  That is designed, approved and unbuilt; building a second outbox in the
  daemon's `DrainLoop` first would spend the same effort in the place the
  spec chose not to put it.
- **Lengthening the budget is the one move that must not be made.** `writeAll`
  holds the read lock across its `poll` waits; a longer wait stalls the drain,
  and a child blocked on its output does not read its input. Raising 250 ms
  makes the detached path *less* likely to complete, not more.

### The version-skew fallback

Single-typist keeps the daemon's direct write for sessions whose holder
predates the `write` verb — a write-only handle, demoted from the reader on
attach. That handle inherits `writeAll` and its 250 ms truncation point for
the remaining life of those sessions. The recommendation is to leave it
budgeted and honest: the population is bounded (holders are never upgraded in
place, so it only shrinks), the error names the unwritten count, and the
alternative is a daemon-side outbox drained off the lock — real work for a
shrinking population. If the interim before the verb lands turns out to be
long, that judgment should be revisited; it is a decision, below.

## Candidates, evaluated

Each candidate against the brief's criteria: does the whole payload arrive,
can it double, can it tear or truncate, can it wedge the session, what it
costs, and what it newly breaks.

- **Loop longer inline** – raising 20 ms or 250 ms. Arrives only if the child
  drains within the new budget; never doubles; truncates past the budget;
  still wedges on a lost marker; costs nothing to build; blocks the main actor
  (viewer) and stalls the drain under the lock (daemon). Rejected: it moves
  the truncation point without removing it.
- **Refuse or chunk-and-confirm** – see "Avoidance is not available". Not
  buildable on a pty.
- **A viewer outbox with a hold on user bytes** (recommended for the viewer's
  own writes and the interim injection) – arrives whenever the child ever
  drains, bounded by `EIO`; never doubles from this process; cannot tear,
  because nothing from this process is written between remainder chunks;
  cannot leave a marker unwritten while the panel lives; costs a small
  addition to `OutgoingInputQueue`, a write source, and a diagnostic; newly
  creates the felt cost of held keystrokes during a stall (which were being
  dropped before) and the drop-on-detach residue.
- **A background writer thread owning the descriptor** – the read side's
  shape, mirrored. Same delivery properties as the outbox; but every
  keystroke would hop to the thread, or the queue would need a two-locus
  "inline if idle, else hand off" rule with a lock between the main actor and
  the thread. Rejected on the no-hop constraint and on complexity that buys
  nothing the main-queue source lacks.
- **A two-phase sidecar ack** (accepted now, delivered later) – would let the
  daemon's record distinguish the two states in the interim. Rejected: it
  builds frames and deadline logic that single-typist deletes, and the
  interim's `accepted`-means-`true` already carries the honest half.
- **The daemon completes through a retained write-only dup** – single-typist's
  rejected primary and surviving fallback. Not re-litigated here.
- **The holder outbox** – single-typist's answer for injections; arrives,
  never doubles, cannot be torn by another injection, bounded by `EIO`. Not
  re-derived here; this design sequences before it.
- **Sender-side retry** – the courier's fallback today. Doubles the prefix.
  Rejected as a mechanism; kept out of the interim by never reporting `false`
  for a partial.

## Sequencing against single-typist

**This is a piece of that work, and it goes first.** Specifically:

- The viewer outbox and the hold on user bytes *are* the keystroke hold
  single-typist mandates, built with the user's own remainder as its first
  client. When `injectionIntent` / `injectionDone` land, they become a second
  reason for the same hold, with a clock bound of their own because they wait
  on another process. Nothing has to be rebuilt.
- It needs no protocol change, no holder change and no daemon change, so it
  can land alone, be soaked alone, and fix cases 2 and 3 alone.
  The felt cost of holding keystrokes — the one thing single-typist's soak
  would otherwise be the first to discover — is discovered here, on the
  person's own pastes, before the daemon depends on it.
- Case 1 is fixed *properly* by the holder verb and *adequately* by the
  interim semantics above; the interim code is the same outbox and is deleted
  with the viewer's injection path when the verb lands.

Two refinements to single-typist follow from the outbox, and should be
carried into it when it is implemented rather than left to be rediscovered:

- **"Paste open" for the lease means "until the end marker has been accepted
  by the kernel"**, not "until `endUserPaste()` was called". With an outbox
  the two can differ by as long as the child stalls, and a lease answered on
  the delegate call is answered while the child is still mid-paste. The
  viewer's own hold bound (2 s) and the daemon's lease bound (3 s) keep their
  ordering; what changes is the residue they bound. Single-typist states that
  an expired lease means the viewer is not running its main actor; with the
  outbox it can also mean the viewer is alive and a large paste is still
  draining into a stalled child. Both resolve the same way — the daemon
  writes, the injection is absorbed into the paste, visible and never
  doubled — and the second is rarer than the first. An explicit "still
  draining" answer that extends the lease is the obvious refinement and is
  deferred until a soak shows the residue is felt.
- **The two kinds of bound stay distinct.** The user-remainder hold is
  bounded by the descriptor; the injection hold is bounded by a clock.
  Single-typist's text says its hold "ends on `injectionDone` or after its
  own bound" and should not be read as applying that bound to the person's
  own remainder.

## Reconcilers

Per the doctrine in
[`2026-08-15-named-reconciler-doctrine-design.md`](2026-08-15-named-reconciler-doctrine-design.md):
**this design introduces no new kind of durable resource and no new creation
path to one.** The outbox is memory in the app, owned by a descriptor whose
close drops it, in a panel whose teardown is already ordered; it writes no
file, mints no process, and touches no row. The write source is a dispatch
source cancelled by the same teardown that closes its descriptor. Nothing
outlives the request that created it except in the app's own memory, and an
app that dies takes its outbox with it — which is the interim residue named
above, not an orphan.

## Flag

**No flag of its own.** The change is confined to holder-backed panels, which
exist only under `pty_holder_enabled` (default off, `Config.ptyHolderDefault`,
`Sources/TBDShared/Models.swift:1698`) and have never shipped on. It replaces
the panel's write step, which the repo's rule names as flag-worthy — and the
flag it lands behind is the one wrapped around the entire transport, for the
reason single-typist gives: a second column would keep selectable a quadrant
(holder on, completion off) that is known-defective in the three ways this
document records. Both branches remain testable, because a tmux panel's write
path is untouched. If this were to land after `pty_holder_enabled` had
graduated, it would need its own default-off column with the tri-state
discipline.

## Testing

- **The outbox against a real pty**: a pty pair with the slave in raw mode and
  unread, which the measured 1,022-byte ceiling makes deterministic. A 4 KiB
  write leaves a remainder; bytes enqueued afterwards are held in order; a
  read on the slave drains in order and the slave receives every byte exactly
  once; closing the slave produces `EIO`, drops the outbox, and logs once.
- **The paste shape end to end**: three chunks through the production
  `Coordinator.send` path with a full queue; the end marker is delivered after
  the payload, and a keystroke enqueued after the paste is delivered after the
  marker. This is the test that discriminates case 3.
- **The interim ack**: a partial injection acks `true`; a full-queue
  injection acks `true`; a dead descriptor acks `false`; a prefix followed by
  `EIO` acks `false`. The daemon-side courier tests already cover what each
  answer makes the daemon do.
- **Teardown with a remainder**: `stopHolderReader` cancels the source before
  the close, drops the outbox, logs the count, and a write source that fires
  after cancellation is impossible on the same queue.
- **The signal**: with an injected clock, the pending-byte indicator appears
  after the threshold and clears on drain; the "no transport" line is never
  logged for a short write.
- **The write source on a pty master**: an implementation-time check that a
  write-readiness source on a `dup` of a pty master fires when the slave
  drains. If it does not, the fallback is a `poll(POLLOUT)` on a helper thread
  that hops to the main queue once per readiness — one hop per accepted chunk,
  never per keystroke.

## What could not be determined

- **How an agent TUI's parser treats a missing `ESC[201~`** — whether it
  accumulates indefinitely (a wedge) or times out (a self-heal). The design
  does not depend on the answer; the priority of the fix does.
- **How long agents stall without draining stdin**, which sets how often the
  hold is felt at the keyboard and how often single-typist's lease residue
  occurs. Unmeasured; the outbox's backpressure indicator is what will
  measure it in the field.
- **Whether kqueue write-readiness fires on a `dup` of a pty master** on the
  deployed macOS. Expected from the driver's kqueue support; to be checked
  before the fallback is discarded.
- **How often 20 ms suffices today** for a paste above a kilobyte into an idle
  agent — that is, how often the outbox path will be the path taken. The
  design treats it as ordinary.
- **Per-byte tearing of a marker at the kernel** is read from the pty
  driver's source, not measured. The measured addendum's probe establishes
  the ceiling, not the cut boundary.

## Decisions that need a human

1. **Sequencing.** Land the viewer-side outbox and user-byte hold now, as the
   first slice of single-typist, with the holder `write` verb next and no
   separate stopgap for the daemon's detached path. *Recommended: yes.*
   The alternative — a daemon-side outbox in `DrainLoop` as an interim —
   builds half of single-typist's sender-outcome surface in the place the
   spec chose not to put it.
2. **Interim ack semantics.** While the viewer still writes injections,
   `written: true` means "accepted by a completing writer", matching the
   other two arms and single-typist's `accepted`. *Recommended: yes*, with
   the app-death residue recorded in the PR. The alternative keeps today's
   honest-error-with-truncated-fragment until the verb lands.
3. **The bound on the user's own remainder.** Descriptor-bounded, no clock,
   with a visible indicator; versus a clock bound that releases held
   keystrokes to interleave into the remainder. *Recommended: no clock.*
   Expiry would only convert a wedge into a tear while the queue is full.
4. **Interrupt bypass.** None; `0x03` is held with everything else, as
   single-typist rules for its own hold. *Recommended: none.*
5. **Detach with a remainder outstanding.** Drop and log, with the mid-paste
   hazard named; versus keeping the writer alive past the handback to land a
   pending end marker. *Recommended: drop and log*, and file the marker case
   as a follow-up if the soak shows it.
6. **The lease refinement for single-typist.** "Paste open" means until the
   end marker is kernel-accepted; the bounds keep their values; the new
   residue is recorded; a "still draining" extension is deferred.
   *Recommended: yes*, applied to the single-typist spec when it is
   implemented.
7. **The version-skew fallback.** Leave `writeAll` at 250 ms and honest for
   sessions whose holder predates the verb, rather than giving the daemon's
   handle an outbox. *Recommended: leave it*, revisited if the interim before
   the verb is long.
8. **The inline budget.** Drop `PTYWrite.defaultBudgetMilliseconds` to zero
   once the outbox exists, so no keystroke ever polls on the main actor.
   *Recommended: zero.*
9. **Flag.** No column of its own; ships under `pty_holder_enabled`.
   *Recommended: none.*
10. **The backpressure indicator's form.** A panel-level indicator with the
    pending byte count after about a second, not an in-pane status line.
    *Recommended: panel-level*; the exact presentation is a minor UI choice
    for the implementer.
