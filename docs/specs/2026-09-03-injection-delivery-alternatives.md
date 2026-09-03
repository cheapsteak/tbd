# Injection delivery on the holder transport: can input always arrive, and never twice?

**Status:** design research, not a decision. Written to answer one question a
human put to two proposed options — "both sound bad; is there no way to have
things always arrive, but not possibly twice?" — by attacking the framing
rather than arbitrating between the options.

**Short answer.** Yes, for every failure that is a *timer* rather than an
*event*. The two options were posed as a choice about **who performs the
write**. That is the wrong axis. Every duplicate the current design can
produce comes from **two processes being allowed to write the same message**,
and every ambiguity it has to resolve comes from **resolving a writer's
silence with a deadline** instead of a liveness verdict. Remove either and the
duplicate disappears; remove both and what remains is the irreducible residue
every local system has — a writer that dies between its syscall and its
record — which manifests as "unknown, and visible", never as "twice". The read
side of the same design already refuses to seize on a timeout for precisely
this reason ("a lost ack and a lost app are indistinguishable on the wire",
[`docs/specs/2026-08-30-pty-holder-session-transport-design.md:252-258`](2026-08-30-pty-holder-session-transport-design.md));
the write side chose a timer, and that inconsistency is the whole problem.

The recommendation (section 9) is a design in which the daemon is the **only**
process that ever writes an injection, the app's role shrinks to *telling* the
daemon when a user paste is open, the write is completed rather than abandoned
on a short write, and — as user-land belt-and-braces for Claude sessions — a
`UserPromptSubmit` hook drops a repeat of a dispatch id it has already seen.
Under that design "arrives twice" is not a cost to be absorbed; it cannot be
produced.

---

## 1. The problem, in delivery-semantics terms

### 1.1 What the system is

Reading a pty master is exclusive; two readers each get a random share of the
bytes. Writing is not exclusive, but not atomic either. A holder process owns
the master and never reads it; the daemon reads it while no viewer is open;
the app reads it while a panel is open. The daemon, the app, and the holder
each can hold a descriptor for the same master
([spec, "Reader arbitration"](2026-08-30-pty-holder-session-transport-design.md)).

Something in TBD decides an agent should receive input — `tbd terminal send`,
a queued prompt, a supervision nudge, the limit-resume actuator — and the
bytes must land in that session's input queue. The current rule
([`Sources/TBDDaemon/Holder/HolderInjectionCourier.swift`](../../Sources/TBDDaemon/Holder/HolderInjectionCourier.swift)):

- **Detached** – the daemon writes its own descriptor (`deliver`, the
  `.detached` arm).
- **Attached** – the daemon puts an `.injection` frame on the app sidecar and
  waits up to `ackDeadline` (five seconds, the initializer default) for an
  `.injectionAck`.
- **No usable answer** – the daemon writes anyway
  (`DaemonWriteReason.ackDeadlineElapsed`, documented in the file as "the
  branch that can duplicate, and it is meant to").
- **Late ack** – recorded and ignored (`record(_:)`, `lateAcksObserved`),
  deliberately never used to retract the direct write.

The routing exists so that a daemon injection can never land inside a user's
bracketed paste (`ESC[200~ … ESC[201~`), where the child would absorb it as
pasted text. The app-side
[`OutgoingInputQueue`](../../Sources/TBDApp/Terminal/OutgoingInputQueue.swift)
(uncommitted in this worktree at the time of writing) is the serialization
point that holds an injection while a paste is open, bounded by
`pasteHoldBound` (two seconds).

### 1.2 Three properties, not one

The human's sentence contains three distinct guarantees, and they have
different costs:

- **Always arrives** – *liveness*: no injection is silently dropped.
- **Never twice** – *safety against duplication*: no injection is written to
  the input queue by two acts.
- **Never doubled or torn** – *safety against interleaving*: no injection is
  split by another writer's bytes, and no partial prefix is left behind.

The current design buys the first by paying with the second, and the third is
broken independently (section 8). Treating the three as one trade is the
false binary.

### 1.3 Where duplicates actually come from

A duplicate requires **two acts of writing the same message**. In the current
design the two acts are the app's write and the daemon's fallback write. The
fallback exists because the daemon cannot distinguish "the app wrote and its
ack is late" from "the app never wrote". That is the two-generals shape: an
acknowledgment over a channel that can delay or lose it cannot make the
sender certain
([Two Generals' Problem, Wikipedia](https://en.wikipedia.org/wiki/Two_Generals%27_Problem)).

But the impossibility result forbids *certainty about a remote party's
state*. It does not forbid three things this system can have:

- **One writer.** If only one process ever writes injections, there is no
  second act to duplicate the first. The question "did the other side write?"
  is never asked because there is no other side.
- **Local certainty about one's own write.** A `write(2)` returns a count.
  The process that made the syscall knows exactly how many bytes entered the
  input queue. Uncertainty exists only in the *observer* of a writer, never
  in the writer itself.
- **Liveness verdicts instead of deadlines.** The daemon can already tell
  "app process gone" from "app process alive" with an identity-verified check
  (pid plus executable plus start time,
  [spec, "App death"](2026-08-30-pty-holder-session-transport-design.md)).
  A dead writer cannot write late. A timer cannot tell the two apart; a
  process check can.

Martin Kleppmann's fencing argument is the canonical statement of why the
timer is the flaw: a lease holder "paused for an extended period of time
while holding the lock" resumes and "may go ahead and make some unsafe
change", and "you cannot fix this problem by inserting a check on the lock
expiry just before writing"
([How to do distributed locking](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)).
The current design's late-ack path is exactly his figure: client 1 (the app)
paused past the lease (the ack deadline), client 2 (the daemon) writes, client
1 resumes and writes too. His fix is a fencing token checked **by the
resource**. A pty cannot check tokens (section 7, design 4), so the fix
available here is the other one: do not have two writers.

### 1.4 Bytes arriving twice versus the agent acting twice

These are different problems with different owners:

- **Bytes twice** is a transport property. It is visible (the envelope and
  the body appear twice in the composer), it cannot be unprinted, and it is
  what the human objected to.
- **Acting twice** is a receiver property. It is what would actually cost
  something — a prompt executed twice, a supervision nudge that spends two
  turns. It can be prevented at the receiver *for agents that expose a
  pre-prompt hook*, using the id already on the wire (section 2), and it
  cannot be prevented at all for a shell.

Receiver-side dedupe converts "acts twice" into "acts once" and leaves
"bytes twice" untouched. The single-writer designs in section 7 prevent
"bytes twice" and therefore both.

### 1.5 What is impossible versus merely unbuilt

- **Impossible** – a writer that dies *between* its `write(2)` returning and
  its recording of that fact leaves the record unknown. This is the residue
  of every idempotency system, including Stripe's, whose server "simply
  replies with a cached result" on retry and which therefore also depends on
  the *record* of the first attempt surviving
  ([Stripe, Designing robust and predictable APIs with idempotency](https://stripe.com/blog/idempotency)).
  Here it means: a daemon that crashes after writing and before completing
  the actuation row. The caller's RPC never returns, so this is loud, not
  silent.
- **Unbuilt** – everything else. Single-writer routing, completing short
  writes, a paste lease, liveness-gated takeover, receiver-side dedupe. None
  of it is blocked by an impossibility result; the current fail-open timer is
  a choice.

---

## 2. The in-house lead: the id is already on the wire

### 2.1 What exists

- **The envelope.** `RPCRouter+TerminalHandlers.swift:3340-3341` composes
  `<tbd-dispatch id="<actuation-row-id>" from="<label>"/>` and
  `performHolderSend` (`:3143-3157`) prepends it, plus `\n`, to the body,
  then appends `0x0d` if `--submit`, and hands the whole thing to the courier
  as one message. The id is the actuation row's own id, so there is exactly
  one identifier namespace.
- **Who gets it.** Only agent sessions: `carriesDispatchEnvelope`
  (`:3358-3364`) returns false for a shell, and the queued-prompt-at-creation
  path suppresses it deliberately (`DispatchEnvelopeDisposition.suppressed`,
  `:2731-2749`) so the text reaches the model byte-identical to the argv
  path.
- **Who reads it back.**
  [`DeliveryVerifier.needles(forActuationID:)`](../../Sources/TBDDaemon/Actuation/DeliveryVerifier.swift)
  (`:477-478`) scans the transcript tail for both spellings of
  `tbd-dispatch id="…"`. On a verifiably not-landed observation it performs
  a single, evidence-bounded re-delivery under the identical id
  (`:158-161`, `:269-280`) and never re-delivers on startup replay (`:526`).
  This is worth noticing: **TBD already has an at-least-once retry path, and
  it is the good kind** — bounded by evidence of absence, not by a timer.
  Holder-backed rows refuse `--verify` today (`holderVerifyRefusal`, `:2763`)
  because the observation re-reads a tmux pane.

### 2.2 Who could dedupe on the id, and what it would take

- **The agent itself, via a `UserPromptSubmit` hook (Claude Code).** The
  hook "fires when you submit a prompt, before Claude processes it", its input
  JSON carries the full `prompt` text, exit code 2 "blocks prompt processing
  and erases the prompt", and the hook "cannot replace or rewrite the prompt
  text" — it can only block or add `additionalContext`
  ([Claude Code hooks reference](https://code.claude.com/docs/en/hooks)).
  A hook script that extracts every `tbd-dispatch id="…"` from `prompt`,
  consults a per-session seen-set (a file keyed by `session_id`), and exits 2
  when every id in the prompt was already seen would make a second delivery
  of the same dispatch **act zero times**. TBD already ships a TBD-owned
  settings overlay carrying its `SessionStart` hook
  ([`ClaudeSpawnCommandBuilder.swift:92`](../../Sources/TBDDaemon/Claude/ClaudeSpawnCommandBuilder.swift)),
  so the landing spot exists and the mechanism is user-land, which is where
  the project's placement rule wants it.
- **The transcript-side verifier.** It can *observe* a duplicate (two
  envelope lines with one id) but cannot *absorb* one — by the time the
  transcript shows it, the model has seen it.
- **The app.** It can dedupe injections it is asked to write (an
  injection-id seen-set), but the duplicate in question is the daemon's
  fallback write, which never passes through the app.
- **Nothing, for a shell.** No envelope is sent, and a shell executes what
  it is given. `--submit` into a shell twice runs the command twice.

### 2.3 Where receiver-side dedupe breaks

- **Fusion.** A duplicate that lands while the first delivery is still
  sitting *unsubmitted* in the composer — or a daemon rewrite on top of a
  truncated prefix — produces **one** prompt containing the id twice. The
  hook sees that id for the first time and lets the whole thing through; the
  model receives a garbled message. The hook cannot rewrite it. This is the
  common shape of the current design's duplicate, not the rare one.
- **Mid-turn arrival.** Claude Code queues input that arrives while it is
  working. Whether the queued message fires `UserPromptSubmit` on submission
  or on dequeue was not verified here (section 11).
- **The suppressed envelope.** The queued prompt at worktree creation carries
  no id by design and cannot be deduplicated.
- **Codex.** No equivalent hook was confirmed; the design docs say the Codex
  adapter would use the app-server protocol's in-protocol acknowledgement
  (`supportsDeliveryObservation`, `:3381-3383`).
- **Blast radius.** The hook runs on every human-typed prompt too. A bug in
  it blocks the person at the keyboard.
- **The visible duplicate remains.** Blocking "erases the prompt" from the
  conversation, but the human saw it arrive.

**Verdict on the lead.** It does not dissolve the problem. It converts the
*worst* consequence of a duplicate (acting twice) into a non-event for the
one agent that exposes a hook, and only when the duplicate arrives as its own
prompt. It is worth building as the last line of defense behind a design that
does not produce duplicates in the first place. It is not a reason to keep a
design that does.

---

## 3. Prior art

### 3.1 Delivery semantics

- **Idempotency keys (Stripe)** – the client mints a key, retries with the
  same key, and "the server simply replies with a cached result of the
  successful operation"
  ([Stripe](https://stripe.com/blog/idempotency)). The dedupe lives at the
  *receiver that performs the effect*, backed by a durable record of the
  first attempt. Implication: TBD's `<tbd-dispatch id>` is a well-formed
  idempotency key; what is missing is a receiver that keeps the record and
  checks it, which for a pty does not exist and for an agent exists only as
  a hook.
- **Kafka's "exactly-once"** – the idempotent producer attaches a producer id
  and "a sequence number that the broker will use to dedupe any duplicate
  send", persisted "to the replicated log, so even if the leader fails, any
  broker that takes over will also know if a resend is a duplicate"; the
  guarantee is explicitly scoped — side effects outside Kafka "would not be
  guaranteed exactly once"
  ([Confluent, Exactly-once semantics are possible](https://www.confluent.io/blog/exactly-once-semantics-are-possible-heres-how-apache-kafka-does-it/)).
  Implication: "exactly-once" is always *at-least-once delivery plus a
  deduplicating receiver inside a boundary*; the boundary here would be the
  agent, and the pty is outside it.
- **"Effectively once"** – the industry's honest name for the same thing:
  "you can't guarantee a message is delivered exactly once, but you can
  guarantee its effect is applied exactly once"
  ([Exactly-once delivery: the myth and the reality](https://hosseinnejati.medium.com/exactly-once-delivery-the-myth-and-the-reality-ff2f9b0d4bd5),
  [Kafka's exactly-once: the truth behind the marketing](https://patrickkoss.substack.com/p/kafkas-exactly-once-delivery-the)).
- **Two Generals** – proves that "no matter how many rounds of confirmation
  are made, there is no way to guarantee" mutual certainty over a lossy
  link, and explicitly permits "schemes that accept the uncertainty of the
  communications channel and not attempt to eliminate it"
  ([Wikipedia](https://en.wikipedia.org/wiki/Two_Generals%27_Problem)).
  Implication: it forbids the daemon *knowing* whether a silent app wrote.
  It says nothing against the daemon being the one that writes.
- **Fencing tokens and leases (Kleppmann)** – a lease that expires on a timer
  is unsafe unless "the storage server takes an active role in checking
  tokens, and rejecting any writes on which the token has gone backwards"
  ([Kleppmann](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)).
  Implication: a pty does not check anything, so a timer-based writer lease
  cannot be made safe; a token-checking *proxy* (the holder) could.
- **Transactional outbox** – the relay "might publish a message more than
  once. It might, for example, crash after publishing a message but before
  recording the fact that it has done so"; therefore "a message consumer
  must be idempotent, perhaps by tracking the IDs of the messages that it
  has already processed"
  ([microservices.io, Transactional outbox](https://microservices.io/patterns/data/transactional-outbox.html)).
  Implication: an outbox is the right shape for "defer until the writer is
  available" (design 3), and it does not remove the crash-between-write-and-
  record residue; it only narrows it to a crash.

### 3.2 Terminal multiplexers and remote terminals

- **mosh** – "runs two copies of SSP, one in each direction. The connection
  from client to server synchronizes an object that represents the keys
  typed by the user, and with TCP-like semantics"
  ([mosh.org](https://mosh.org/)). Each datagram is "a 'diff' instructing the
  remote site how to construct state m from some prior state n < m", which
  is idempotent at the recipient
  ([Mosh paper](https://mosh.org/mosh-paper-draft.pdf), section on SSP).
  The sender diffs from an `assumed_receiver_state`, giving "benefit of the
  doubt to unacknowledged states transmitted recently enough ago", and
  retransmits on a timer until acked
  ([`transportsender-impl.h`](https://raw.githubusercontent.com/mobile-shell/mosh/master/src/network/transportsender-impl.h)).
  **The lesson is not "make input idempotent"; it is that mosh has one
  writer.** The server applies keystrokes to the pty; the client only ever
  retransmits *to the same server*, which dedupes by state number. There is
  no second path that writes when the first is slow. A retransmit to an
  idempotent single writer never duplicates; a fallback to a *different*
  writer always can.
- **tmux** – "keeps all its state in a single main process, called the tmux
  server", and "any text typed into that outside terminal is sent to the
  active pane" through it
  ([tmux wiki, Getting Started](https://github.com/tmux/tmux/wiki/Getting-Started)).
  `send-keys` and client keystrokes are serialized by that one process. This
  is exactly the property the holder migration gives up for latency. Note
  what tmux does **not** protect against: a `send-keys` still lands between
  a user's keystrokes; tmux only guarantees it does not land *inside* one
  write and (in practice) not inside a client's paste burst. That is the
  bar to match — not "never interleaved with typing".
- **abduco** – the server owns the pty; a client's `MSG_CONTENT` packet is
  written with `write_all(server.pty, …)`, a loop over partial writes;
  clients are served sequentially in one event loop, so two clients'
  packets interleave only at packet boundaries
  ([`server.c`](https://raw.githubusercontent.com/martanne/abduco/master/server.c)).
- **dtach** – same shape: `MSG_PUSH` from a client is written to the pty by
  the single master process
  ([`master.c`](https://raw.githubusercontent.com/crigler/dtach/master/master.c)).
  A spiritual successor's docs state the property plainly: "concurrent
  senders have no ordering or atomicity guarantees … callers should
  serialize sends if ordering matters"
  ([holdpty](https://github.com/marcfargas/holdpty)).
- **wezterm, kitty, zellij** – `wezterm cli send-text` sends "as though it
  were pasted … as a bracketed paste" via the mux server
  ([wezterm docs](https://wezterm.org/cli/cli/send-text.html)); kitty's
  `send-text` goes over the kitty control socket to the kitty process
  ([kitty remote control](https://sw.kovidgoyal.net/kitty/remote-control/));
  zellij's `write` / `write-chars` go through the zellij server
  ([zellij CLI actions](https://zellij.dev/documentation/cli-actions)).
  Every one of them has a single process that owns the pty and serializes
  all input. None of them has TBD's situation — two processes holding
  descriptors to one master — and so none of them has TBD's problem.

The pattern across the whole space: **one writer per pty is universal.** TBD
is unusual in allowing two, and the duplicate is the direct price of that.
The single-writer property does not have to be "one writer for everything"
(that is what costs latency); it only has to be "one writer per *message
class*" — user keystrokes from the app, injections from exactly one other
place.

### 3.3 Terminal-level mechanisms

- **`TIOCSTI`** – inserts one character into a tty's input queue as if
  typed. Linux 6.2 disabled it by default (`CONFIG_LEGACY_TIOCSTI`) because
  it "continues to be used as a malicious privilege escalation mechanism,
  and provides no meaningful real-world utility any more"; OpenBSD removed
  it entirely
  ([tty: Allow TIOCSTI to be disabled](https://lkml.iu.edu/hypermail/linux/kernel/2210.1/07558.html),
  [Linux TIOCSTI man page](https://man7.org/linux/man-pages/man2/TIOCSTI.2const.html)).
  XNU still implements it, but unprivileged callers need the descriptor
  open for reading **and** the tty to be their controlling terminal
  (`EACCES` otherwise), and it inserts one byte per `ioctl`
  ([`xnu/bsd/kern/tty.c`](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/kern/tty.c),
  `case TIOCSTI`). It is one byte at a time into the same queue a master
  write feeds, on the slave side the daemon does not hold. It offers nothing
  here.
- **Is a master `write()` atomic?** Not by contract — POSIX atomicity
  applies to pipes and FIFOs, and "TTYs don't have a PIPE_BUF-style
  atomicity guarantee"
  ([POSIX write() is not atomic in the way that you might like](https://utcc.utoronto.ca/~cks/space/blog/unix/WriteNotVeryAtomic)).
  In XNU's implementation, however, `ptcwrite` takes `tty_lock(tp)` for the
  duration of the call, inserts characters one at a time through the line
  discipline, releases the lock only inside `ttysleep` when the input queue
  reaches `TTYHOG - 2`, and with `FNONBLOCK` returns the partial count (or
  `EWOULDBLOCK` if nothing went)
  ([`xnu/bsd/kern/tty_dev.c`](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/kern/tty_dev.c));
  `TTYHOG` is 1024
  ([`xnu/bsd/sys/tty.h`](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/tty.h)).
  Read from source, not measured (section 11), the consequence is: **two
  writers on one Darwin master interleave only at `write()` boundaries and
  at the point where a writer's queue fills.** A keystroke never tears an
  injection mid-byte; it lands *between* an injection's chunks only when the
  injection is larger than the free queue space and the child has not yet
  drained. That is the same granularity tmux gives.
- **The input queue is small.** With `TTYHOG` at 1024, any injection above
  roughly a kilobyte *requires* multiple `write()` calls with the child
  draining in between. A short write on a large prompt is the normal case,
  not a fault. This is why the truncation question (section 8) is not a
  corner case.
- **Advisory locking / input transactions.** There is nothing in the tty
  layer that groups writes. `flock` on the master would only coordinate
  cooperating processes that already share a protocol — which is what the
  sidecar is.
- **Bracketed paste.** The markers are in the input stream and nowhere
  else; "applications detect pasted text by waiting for `\e[200~` on
  stdin"
  ([xterm bracketed paste](https://invisible-island.net/xterm/xterm-paste64.html),
  [bracketed paste mode](https://cirw.in/blog/bracketed-paste)). Only the
  process that *wrote* the start marker knows a paste is open. There is no
  kernel- or terminal-level way for a third writer to learn that, and no way
  to be excluded during one, without a side channel. The side channel is the
  sidecar, and the app already tracks the state it would report
  (`OutgoingInputQueue.isPasteOpen`).

---

## 4. What TBD does today, precisely

Cited so the designs below can be judged against the real code rather than
the spec's description of it.

- **Detached** – `HolderInjectionCourier.deliver` → `writeFromDaemon` →
  `HolderReader.write` (`HolderReader.swift:497-500`) → `writeAll`
  (`:1062-1084`), which holds a lock, loops on `EAGAIN` with `poll(POLLOUT)`,
  and after a `writeBudgetMilliseconds` of **250 ms** throws
  `writeTimedOut(unwritten:)` — **with the prefix already written**. The
  courier reports `.notDelivered` and the actuation row records
  `.transportFailed`. So the daemon's own path can truncate.
- **Attached, happy path** – `.injection` frame → app
  `TerminalInjectionRouter.deliver` → panel closure → `OutgoingInputQueue.
  enqueueInjection` (held if `isPasteOpen`, released on `endUserPaste` or
  after `pasteHoldBound` = 2 s) → `performOutgoingWrite`
  (`TerminalPanelView.swift:1952`) → `writeToHolderPTY` (`:2066`) →
  `PTYWrite.all` with a **20 ms** budget. `.complete` acks `written: true`;
  `.nothingWritten` and `.partial` both ack `written: false` (`:2070-2080`).
- **Attached, `written: false`** – the courier's
  `viewerReportedNothingWritten` arm calls `writeDirectly`, which looks up
  `registry.reader(for:)` (`Daemon.swift:838-852`). After an *acknowledged*
  attach that reader is gone: `confirmAttach` records the viewer, then
  `stopPublished(reader)` closes the descriptor
  (`HolderRegistry.swift:1282-1305`). So the fallback answers
  `.notDelivered`, the prefix of a `.partial` stays in the composer, and the
  caller is told the send failed. The courier's own doc comment names this
  the "known gap".
- **Attached, deadline elapsed** – same `writeDirectly`; same outcome after
  an acknowledged attach. The fail-open that can duplicate actually fires
  only in two states: a *timed-out* attach, where `cancelPendingAttach`'s
  `.unacknowledged` arm keeps the viewer claim but leaves the reader merely
  suspended (`HolderRegistry.swift:1394-1416`), and the vended-but-not-acked
  window, where the app already holds its dup while the courier still takes
  the detached branch — two writers for one RPC round trip.
- **Late ack** – `record(_:)` finds no waiter, increments
  `lateAcksObserved`, logs, and does nothing else.
- **Ordering** – one `terminal.send` per terminal at a time, through
  `terminalSendSerializer` (`RPCRouter+TerminalHandlers.swift:2797`); the
  courier is called once with the whole message (`:3171`).

Two facts stand out. First, the ambiguity window that the fail-open exists
for — an app that is alive but slow — is a **timer** (5 s), and the read side
of the same registry refuses to act on timers. Second, **both** writers give
up on a short write after a small budget, so "arrives" is not actually
guaranteed today for any payload the child does not drain within 20–250 ms.

---

## 5. The evaluation criteria

Each design below is scored on the same six questions:

- **Arrives** – can an injection be silently dropped?
- **Doubles** – can the same message be written by two acts?
- **Tears or truncates** – can another writer's bytes land inside it, or a
  prefix be left behind?
- **Build cost** – what has to be written.
- **Living cost** – what it makes worse day to day.
- **New failure mode** – what it breaks that works today.

---

## 6. The two rejected options, restated on the right axis

- **Option A** (app writes; daemon keeps a write-only dup so its 5 s fallback
  can always fire) – two writers, timer-resolved. Arrives: yes. Doubles: yes,
  whenever the app is slower than 5 s, which App Nap makes routine. Tears:
  yes (the vended window; partial + rewrite). Living cost: the duplicate,
  plus a read-capable descriptor the daemon must promise not to read.
- **Option B** (app writes; no fallback; report failure) – one writer,
  timer-resolved-to-failure. Arrives: no, whenever the app is slow. Doubles:
  no. Tears: partial stays truncated. Living cost: injections silently
  depend on a GUI's scheduling.

The axis that separates them is *who writes*. The axis that determines the
outcomes is *how many may write* and *what resolves silence*. Option A is
(two, timer); Option B is (one, timer-as-failure). Neither of the two good
quadrants — (one, nothing to resolve) and (one, liveness verdict) — was
offered.

---

## 7. Candidate designs

### Design 1 — Dedupe at the receiver on the dispatch id

The `UserPromptSubmit` hook of section 2.2, layered on the current design.

- **Arrives** – unchanged (at-least-once stays).
- **Doubles** – bytes yes; *acts* no, for Claude sessions, when the
  duplicate arrives as its own prompt. Fused duplicates and the suppressed
  envelope pass through.
- **Tears or truncates** – unchanged.
- **Build cost** – small: a hook script, an entry in the TBD-owned settings
  overlay, a per-session seen-set under the profile dir. User-land per the
  placement rule; changed by editing a file.
- **Living cost** – a hook on every prompt; a "prompt blocked" line in the
  UI when it fires; the human still sees the duplicate arrive.
- **New failure mode** – a hook bug blocks human prompts. Nothing for
  shells or Codex.

Verdict: build it, as the last line, not as the answer.

### Design 2 — The daemon is always the sole injection writer; the app grants a paste lease

The app **never writes injections**. Every injection is written by the
daemon, whether or not a viewer is attached. The app's remaining role is to
tell the daemon when a user paste is open, so the daemon defers.

The mechanics:

- The daemon sends `injectionIntent(terminalID, injectionID)` on the sidecar.
  The app answers `clear(injectionID)` at once if no paste is open, or as
  soon as the open paste closes (the `OutgoingInputQueue` already has exactly
  this hold-and-release machinery; it would hold *its own* pending user
  paste-close notification rather than someone else's bytes). The daemon
  writes on `clear`, or after a bound if no answer comes.
- The daemon writes with its own loop, completed to the end of the message
  (section 8), never abandoned on a budget.
- Optional, cheap, and worth doing: the daemon's intent also asks the app to
  **hold user keystrokes** until `written(injectionID)` or a short bound.
  This closes the keystroke-between-chunks interleave for large payloads.
  It costs nothing when the app is napping, because a napping app is not
  producing keystrokes.

Why the bound expiry is harmless here, where it was harmful in Option A: the
only thing the app's silence can mean is that the app is not running its main
actor. A paste is three synchronous delegate calls on that actor with no
suspension point between them (`OutgoingInputQueue.swift`, the `@MainActor`
rationale). So an app that has not answered is either not mid-paste, or has
been descheduled *inside* a single main-actor turn for longer than the bound.
The former is the common case and the write is safe. The latter is
vanishingly rare, and its consequence is the injection being absorbed into
the paste: visible in the composer, the `\r` rendered as a newline rather
than a submit, the actuation observable as not-landed. It is a
paste-collision, and **it can never be a duplicate**, because nobody else
writes.

**The descriptor question.** This is where Option A's second objection lives
— the daemon holding a read-capable dup while the app reads. Three answers,
in increasing structural strength:

- **Type-level discipline.** Wrap the dup in a `HolderWriteHandle` whose only
  method is `write`; the reader type never receives it. Every process in
  section 3.2 lives with this level of discipline. The registry would stop
  closing the descriptor in `confirmAttach` and instead demote the reader to
  a write handle.
- **Re-vend per write.** The holder already answers `handOverPTY` with a dup
  over `SCM_RIGHTS` (`HolderProtocol.swift:90-97`). The daemon could hold no
  descriptor while attached, ask for one per injection, write, and close.
  Structural between injections; disciplinary during one.
- **Route the write through the holder.** Add a `write(bytes)` request to
  `HolderRequest`. The holder is single-threaded by construction
  (`Holder.swift:15-20`), already owns the master, and **never reads it** —
  so a write verb there preserves the single-reader invariant structurally,
  serializes daemon writes for free, and gives the daemon no descriptor at
  all while a viewer is attached. It also makes the holder a token-checking
  proxy if fencing is ever wanted (design 4). Cost: a protocol version bump
  (the `rejected(version:)` path exists), the holder's `poll` loop gains one
  request kind, and version skew with already-running holders has to be
  handled (an old holder refuses the verb; the daemon falls back to its own
  handle for that session until it is respawned). The daemon must *wait for
  the holder, not time out on it*: the holder is not an app, it does not
  nap, and its death is a session-ending event the daemon already detects.

Scored:

- **Arrives** – yes. The writer is a process with no GUI, no App Nap, and a
  liveness contract; the write is its own syscall.
- **Doubles** – **no, structurally.** One process writes injections. There
  is no second act.
- **Tears or truncates** – no truncation (the daemon completes the write).
  Keystroke-granularity interleave is possible only for payloads larger than
  the free input queue while the user is actively typing — the same as tmux —
  and the optional keystroke hold closes even that.
- **Build cost** – moderate. New sidecar frame pair (`injectionIntent` /
  `clear`), the app-side lease answer (mostly a re-wiring of
  `OutgoingInputQueue`'s existing hold), the descriptor change in
  `HolderRegistry.confirmAttach`, removal of the app's injection write path
  and of `SidecarInjectionAck`. If the holder route is chosen, a holder
  protocol version.
- **Living cost** – none new. Injections stop depending on the app's
  scheduling entirely.
- **New failure mode** – the paste-collision residue above, only when the
  app is descheduled inside a paste turn beyond the bound. Visible, never
  doubled.

### Design 3 — The app is always the sole writer; the daemon keeps an outbox and takes over only on confirmed death

The mirror of design 2: while attached, the app writes everything, the
daemon never fails open, and undelivered injections wait in a daemon-side
outbox until the app answers or is *confirmed dead* by the same
identity-verified check the read side uses.

- **What makes a takeover safe** – the read side already answers this: seize
  only on confirmed process death, never on silence
  ([spec, "App death"](2026-08-30-pty-holder-session-transport-design.md)).
  A dead app cannot write late. A confirmed-dead app's outbox drains through
  the daemon with no duplicate risk *except* for items the app had begun.
- **Narrowing the ambiguous set** – a two-phase report from the app
  (`taking(id)` before the write, `written(id, count)` after) shrinks the
  unknown set to "items whose `taking` arrived and whose `written` did not
  before the app died". That is an event (crash mid-write), not a timer.
  Policy for those is a deliberate choice — rewrite (visible duplicate, rare)
  or drop (loss, rare) — and either is defensible because it is bounded by a
  crash, not by App Nap.
- **The wedged-but-alive app** – the human's worry. The observation that
  dissolves it: while a viewer is attached, **the app is also the session's
  reader**. An app that is not running its main actor is not draining the
  pty, the child's output queue fills within a few kilobytes, and the agent
  blocks on its next write to stdout. Delivering the injection to a session
  in that state buys nothing; the agent cannot act on it until the reader
  recovers. So deferring injections while the app is alive-but-silent costs
  **no more than the stall that is already happening**, and the outbox
  drains the moment the app wakes or dies.

Scored:

- **Arrives** – yes, eventually; deferred exactly as long as the session is
  stalled anyway.
- **Doubles** – only on app crash mid-write, by explicit policy.
- **Tears or truncates** – no, if the app completes its writes (section 8).
- **Build cost** – moderate. An in-memory outbox per terminal in the daemon
  (durability across daemon restart is not needed: an RPC whose daemon died
  never returned, so the caller already knows), two-phase frames, the seize
  path the spec already plans for reads, and a change to what
  `terminal.send` *means* while deferred — today `.dispatched` means written,
  and a "queued for the viewer" state would need its own outcome and
  actuation status.
- **Living cost** – injection latency equals app latency. Mitigated by the
  App Nap assertion below, which the read side wants anyway.
- **New failure mode** – a caller of `terminal.send` can wait a long time or
  receive "deferred" rather than "written". Supervision rails that expect a
  synchronous verdict need to learn the new state.

### Design 4 — A lease with a heartbeat and a fencing token on the attachment

A wedged app loses its writer claim on a timer; a fencing token prevents a
revived app from writing after losing it.

- The token is only as good as the resource's willingness to check it, and
  **a pty checks nothing.** An app that resumes from a pause with a stale
  token can still `write(2)` to its dup, and the kernel will accept the
  bytes. The token would be honored only by cooperating code in the app,
  which is exactly the code that was paused past the deadline — Kleppmann's
  "you cannot fix this problem by inserting a check … just before writing".
- It becomes enforceable only if every injection write traverses a proxy
  that checks tokens: the holder (design 2, third variant). At that point
  the app is not writing injections at all, and the token has nothing to
  fence.
- The existing attach generation (`viewerAttachment` returns a `UInt64`;
  `confirmAttach` is generation-checked) is already a fencing token for the
  *read* handover, and that is where it belongs.

Scored: does not improve on designs 2 or 3 for injection; reintroduces the
timer the read side rejected; useful only if a timer-based *reader* handover
is ever adopted, and then only with the holder as the checking resource.

### Design 5 — Make the duplicate harmless rather than impossible

"Effectively once" applied here means: keep at-least-once, make every
receiver idempotent. For Claude this is design 1. For a shell there is no
general idempotence — a command is not a state. For a composer that has not
yet submitted, a duplicate fuses rather than repeats (section 2.3), and no
receiver can un-fuse it. Effectively-once works when the receiver owns the
effect and keeps the record; a tty owns the effect and keeps nothing. This is
the Kafka boundary argument in miniature: inside the agent, yes; at the pty,
no.

Verdict: a complement to a single-writer design, not a substitute for one.

### Design 6 — Two things the prior art suggests that were not on the list

- **The App Nap assertion.** App Nap applies priority reduction, timer
  throttling and I/O throttling to an app that "isn't the foreground app"
  and "hasn't taken any IOKit power management or NSProcessInfo
  assertions"; `beginActivityWithOptions:` with `NSActivityUserInitiated`
  (or the `AllowingIdleSystemSleep` variant) "prevents the system from
  deferring the operations or putting your app in App Nap"
  ([App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html),
  [Prioritize Work at the App Level](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html)).
  An app that holds a pty descriptor is the session's *reader* and carries
  the drain-liveness obligation the spec measured ("a job that exits with
  anything unread stops in a half-exited state until somebody drains"). It
  should hold such an assertion for as long as it holds any pty. This does
  not change the design analysis — a napping app is still possible under
  memory pressure — but it removes the *routine* cause of "alive but
  silent" under every design, and the read side benefits as much as the
  write side.
- **One writer per message class, not one writer per pty.** The
  multiplexers all have one process writing everything because they were
  never latency-bound the way the holder migration is. TBD does not need
  that: user keystrokes may keep their direct path from the app, and the
  single-writer property need only hold for *injections*. Darwin's
  `ptcwrite` locking (section 3.3) is what makes the two classes safe to
  mix at `write()` granularity.

### Scoreboard

Short cells only; the reasoning is above.

| Design | Arrives | Doubles | Truncates | Timer-resolved |
|---|---|---|---|---|
| Today (A-shaped, no dup) | no | yes | yes | yes |
| Option A | yes | yes | yes | yes |
| Option B | no | no | yes | yes |
| 1 hook dedupe (alone) | no | bytes yes, acts no | yes | yes |
| 2 daemon sole writer | yes | no | no | no |
| 3 app sole writer + outbox | yes (deferred) | crash-only | no | no |
| 4 lease + fencing | yes | yes | yes | yes |

---

## 8. The truncation question

The app reports a partial write as "not written" and drops the remainder
(`writeToHolderPTY`, `TerminalPanelView.swift:2075-2084`, with a doc comment
saying it is left so on purpose pending the descriptor decision). The daemon
does the same thing on its own path after 250 ms
(`HolderReader.writeAll`, `:1079-1080`).

**Is there any reason not to finish the write?** No. The process that
started the write owns the descriptor and the bytes; a short write on a pty
is the *expected* outcome for any payload above the ~1 KiB input queue, and
the child's draining resumes within milliseconds in the ordinary case. Two
qualifications, neither of which is an architectural change:

- **Finish it off the synchronous path, not on it.** The 20 ms budget exists
  because `performOutgoingWrite` must answer in the keystroke's main-actor
  turn. The remainder should stay in `OutgoingInputQueue` as a pending chunk
  and resume when the descriptor is writable (a `DispatchSource` write
  source on the fd, or the same `poll` on a background thread), while the
  queue **holds subsequent user keystrokes behind it**. Today a keystroke
  typed after a partial injection is written *after the prefix and before
  the remainder would have gone*, which is the tearing the design says it
  prevents. The queue is the right place because it is already the
  serialization point.
- **The ack waits for completion, so the deadline must not be a completion
  deadline.** A child that does not drain for six seconds would push the ack
  past 5 s and trigger the fail-open on a write that is still legitimately
  in progress. Under design 2 this is moot: the daemon writes and completes,
  and there is no ack. Under any design that keeps an app-side write, the
  fix is to acknowledge *acceptance* immediately (which proves liveness) and
  report *completion* separately.

One thing finishing the write does **not** fix, and should not be confused
with it: `performHolderSend`'s own comment notes that a very large
`--text --submit` can have its trailing Enter absorbed by a TUI's
paste-burst heuristic because this arm cannot wrap the body in an explicit
bracketed paste without knowing the child's paste mode. That is a receiver
heuristic, not a delivery problem; exposing bracketed-paste mode from the
daemon's emulator closes it.

So: finish the write. It removes one of Option B's stated costs and one of
Option A's stated reasons with no architectural decision required, and it
should land regardless of which design is chosen.

---

## 9. Recommendation

**Adopt design 2: the daemon is the only process that ever writes an
injection, and the app's role in injection shrinks to a paste lease.** Land
it with three companions:

- **Complete every write** (section 8), on both the daemon's path (raise or
  remove the 250 ms `writeTimedOut`, bounded by child death — `EIO` — rather
  than by a timer) and, for user pastes, the app's.
- **The App Nap assertion** while the app holds any pty descriptor
  (design 6).
- **The `UserPromptSubmit` dedupe hook** (design 1) as user-land
  belt-and-braces for Claude sessions, keyed on the id that is already on the
  wire. It costs a file, and it converts any duplicate that ever does slip
  through some path nobody has thought of — including the verifier's own
  evidence-bounded re-delivery, which is the one *intended* at-least-once
  path — into a non-event.

For the descriptor question inside design 2, prefer **routing the write
through the holder** if the holder protocol version bump is tolerable; it is
the only variant in which the daemon holds *no* descriptor for an attached
session and the single-reader invariant stays structural. If it is not, the
type-level write handle is what every other system in this space lives with,
and the invariant it protects is "no second *reader*", which a handle with no
`read` method honors.

Why design 2 over design 3, which also reaches the good quadrant: design 3
has to change what `terminal.send` means (a deferred state), keeps injection
latency tied to a GUI's scheduling, needs an outbox and two-phase frames, and
still has a crash-mid-write policy to choose. Design 2 needs one new frame
pair and deletes the ack. Its one residue — the paste collision when an app
is descheduled inside a paste turn past the bound — is rarer than design 3's
crash-mid-write, and is visible and never doubled.

**What "always arrives, never twice" looks like under this recommendation,
honestly stated:**

- **Never twice** – structurally true. No second writer exists.
- **Always arrives** – true for every failure that is a timer. The
  remaining ways an injection does not land are all *events*, all loud, and
  none silent: the daemon crashes between its `write(2)` and completing the
  actuation row (the RPC never returns; the row stays unfinished); the holder
  dies mid-write (the session is ending); the app is descheduled inside a
  paste turn past the bound (the injection is visible in the composer,
  unsubmitted, and a holder-side delivery observation — once built — reports
  it not-landed).
- **Never torn or truncated** – true with the write completed and the
  optional keystroke hold; without the hold, keystroke-granularity
  interleave on payloads above the free queue while the user is mid-word,
  which is tmux parity.

The constraints do force a trade, and here is exactly where: a process that
dies between acting and recording cannot be made to have recorded. That is
the entire irreducible residue, it is the same one Stripe and Kafka carry,
and it presents as "unknown" — never as "twice".

---

## 10. What has to be built, in order

- **Finish the write** — app queue holds the remainder and subsequent
  keystrokes; daemon `writeAll` bounded by `EIO`, not by 250 ms.
- **Paste lease frames** — `injectionIntent` / `clear` on the sidecar;
  `OutgoingInputQueue` answers `clear` immediately or on `endUserPaste`,
  bounded by `pasteHoldBound`.
- **Daemon keeps a write path while attached** — holder `write` verb, or a
  write-only handle that `confirmAttach` demotes the reader to instead of
  closing it.
- **Delete** the app's injection write, `SidecarInjectionAck`, the ack
  deadline, and the late-ack accounting.
- **App Nap assertion** while any pty descriptor is held.
- **`UserPromptSubmit` dedupe hook** in the TBD-owned settings overlay, with
  a per-session seen-set.
- **Flag.** This replaces a load-bearing input path and sends input to
  sessions, so it lands behind a default-off config column per the repo
  rule, with both branches tested.

---

## 11. What could not be determined without more information

- **Whether XNU's lock-across-`ptcwrite` behavior holds on the current
  macOS pty path as deployed.** Read from the published source, not
  measured. A short test with two writers hammering one master would settle
  it and is worth running before relying on write-boundary granularity.
- **How Claude Code handles a second `<tbd-dispatch>` message arriving
  mid-turn** — whether it is queued as a separate prompt (hook can dedupe) or
  appended to the pending composer text (fusion; hook cannot). This decides
  how much design 1 is worth on its own.
- **Whether Codex exposes any pre-prompt hook** or only the app-server
  protocol's acknowledgement.
- **Field frequency of the 5 s ack deadline expiring.** No measurement
  exists; the spec says the policy "does not rest on the exact magnitude".
  The recommendation does not depend on it, but it would quantify what the
  current design has been costing.
- **How long a Claude Code child can go without draining stdin** during a
  synchronous render or GC pause. This sets how long a completed write can
  legitimately take and therefore whether the optional keystroke hold needs a
  bound longer than `pasteHoldBound`.
- **Holder version-skew policy.** How a daemon should treat a running holder
  that refuses a new `write` verb — fall back to its own handle per session,
  or respawn — depends on how long holders are expected to outlive daemon
  releases.
- **Whether the sidecar can carry a per-message `clear` cheaply enough** at
  supervision cadence. It is one small frame per injection, so almost
  certainly yes, but `FDVendingServer.sendFrame` is a synchronous send on
  the actor and the courier's cap comment warns about parking it.

## Measured addendum: the input-queue ceiling applies to agents, not to shells

The body reads `TTYHOG` from XNU source and reasons that any injection above
about a kilobyte short-writes routinely. That is right, and it is narrower and
sharper than stated: **the ceiling binds in raw mode and effectively does not
exist in canonical mode.**

Measured on this machine (macOS 26.1, arm64) by opening a pty pair, leaving the
slave unread, setting the master non-blocking, and writing until the kernel
refused more:

- **Canonical mode** (the default; a shell sitting at its prompt) — 1,048,576 of
  1,048,576 bytes accepted. No short write at any size tried, whether written in
  one call or in 64 KiB chunks.
- **Raw mode** (`ICANON` off — what a full-screen TUI sets) — **1,022 bytes**
  accepted, then `EAGAIN`, with the short write occurring on the very first
  call. 1,022 is `TTYHOG - 2`, matching the mechanism the body cites.

The probe is eight lines of Python and needs no build; it is worth re-running
on any host where this behaviour is load-bearing.

**Why this makes the truncation defect worse rather than milder.** A coding
agent's TUI runs in raw mode, so the ~1 KiB ceiling is precisely the regime
TBD's own injections land in — and a queued prompt or a supervision nudge is
exactly the kind of payload that exceeds it. A plain shell at a prompt, which
is the case where a partial write would be least consequential, is the one case
that never sees it. The failure is concentrated on the sessions the product
exists to drive.

It also means "finish the write" is not an optimisation for a rare edge: for
agent sessions above a kilobyte it is the *ordinary* path, and any writer that
gives up after one attempt truncates by default rather than by accident.
