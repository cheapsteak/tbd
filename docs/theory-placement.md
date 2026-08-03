# Theory placement: what gets compiled, what gets authored

Status: standing doctrine, advisory. This is the long form of the root
`CLAUDE.md` rule **"Compile only what user-land cannot do well"** — the
definition that rule leans on, the tests that apply it, the
counter-examples that bound it, and the discipline for what applying it
uncovers. It is written for two readers: a session at design time,
deciding where a proposed behavior should live, and a reviewer at PR
time, deciding whether a compiled thing is a theory somebody should have
been asked about. It adds no process — no required spec section, no
gate — and it does not claim TBD should hold no theories. The failure it
exists to prevent is narrower and worse: TBD holding a theory *nobody
chose*, because the code happened to be where a decision landed.

Worked examples throughout cite the fleet-supervision specs, whose
rejected-alternatives entries are the case files
([design](specs/2026-07-26-fleet-supervision-design.md),
[sweep program](specs/2026-08-01-fleet-supervision-sweep-program-design.md),
[wake program](specs/2026-07-26-fleet-supervision-wake-program.md)). This
document states each case in one line and points; the specs hold the full
arguments.

## What a theory is

A **theory** is an answer to a question on which two reasonable projects
could differ, encoded somewhere that makes disagreement expensive. "An
agent idle forty minutes is stuck" is a theory: one team's stall is
another's long build. "When silence becomes failure" is a theory. "What
to replace a dead supervisor with" is a theory. Each is a legitimate
answer some project would choose differently — and a compiled fork or
constant is the most expensive possible place to disagree with, because
it changes by rebuild and release.

Three neighbors are not theories, and telling them apart is most of the
work:

- **A fact** — a session idle since 02:13, a delivery at time T. Differing
  isn't reasonable; facts get timestamped and served, never evaluated by
  the tool that holds them.
- **A mechanism** — how a paste lands in a composer, how two sends to one
  target serialize. Differing isn't meaningful; no project's convention
  changes what a dead tmux pane is.
- **An invariant** — the record is append-only; one supervisor per
  project. Differing is corruption, not customization.

Facts, mechanisms, and invariants compile. Theories are the contested
tier, and for them the question is never *whether* an answer exists —
supervision without an answer to "when is silence failure" does not
work — but *who chose it and how cheaply they can change their mind*.

## Theories hide behind nouns

A compiled theory rarely announces itself. It arrives fused to a
mechanism inside a noun, and the noun resists deletion because half of it
is load-bearing. The productive move is never "delete the feature"; it is
**un-fuse**: split the noun into the mechanism and the theory it was
welded to, keep the mechanism compiled, and ship the theory as an
editable default.

The supervision redesign's case law, one line each:

- The *shift* fused record windowing (mechanism — the ledger and its
  queries) to a theory of ceremony (what happens at a coverage boundary).
  Windowing stayed compiled; ceremony became a per-project transition
  hook (design §9, §10's deliberately-absent list).
- The *drive* verb fused the send transport to a theory of
  accountability. The transport stayed public; the accountability became
  the actuation log every send passes through (design §3, §6).
- The *note* verb fused file-append to a theory of memory — where
  narrative lives, in what format, when it rotates. The append needed no
  verb at all; the memory theory became the project's journal file and
  the conduct that governs it (design §6).
- The *dead-man's switch* fused a clock to a theory of continuation —
  when to kill a silent supervisor, whether to kill it, what to replace
  it with. The clock TBD genuinely owed stayed compiled (below); the
  continuation policy moved into the sweep program (design §9, §15).

When a design conversation stalls on "should we keep X," ask what X is
made of. It is usually two things, and only one of them is contested.

## The battery

Six tests. Each is cheap to run against a proposed compiled behavior; a
behavior that fails several is a theory, and the placement rule says
theories ship as authored defaults, not as compiled law.

1. **The two-reasonable-projects test.** Could two sane teams want this
   different? If yes, it is authored. This is the entry-level filter and
   the design's own stated tie-breaker (design §1). *Example: what counts
   as "stuck" — one repo's forty idle minutes is another's normal test
   run (sweep program §5).*
2. **The tunable-number smell.** A compiled constant with units of time
   or count is a hypothesis wearing mechanism's clothes. Facts get
   timestamped; hypotheses get evaluated — and whoever evaluates owns the
   theory. *Example: the sixty-minute unanswered-briefing threshold read
   as liveness mechanism until this test flagged it; it now ships as a
   named constant in the reference sweep program beside idle-forty
   (design §15, sweep program §7).*
3. **The when/whether/what-instead probe.** Mechanism answers *how*. A
   compiled *when*, *whether*, or *what instead* is a decision looking
   for its owner. *Example: delivery-time desk replacement answered
   "what instead" inside the pipe; the honest split kept the transport's
   one attempt and gave the caller the decision (design §3, §12).*
4. **The named-consumer counterfactual.** Relocating a theory is earned
   by naming a real consumer who wants it different — and failing to
   name one is itself a tell, in the other direction: a compiled guard
   whose beneficiary cannot be named is a priori insurance, not a
   requirement. *Example: provider failover — replace a dark desk on a
   different model or harness — named the consumer that dissolved
   compiled continuation; the never-double-treat precondition, whose
   motivating incident nobody could cite, dissolved for the opposite
   reason (design §3, §9).*
5. **The vocabulary test.** Punt a theory by exposing facts and public
   actuations and letting the caller own the loop — never by
   parameterizing the compiled thing. Policy arguments (`--retry`,
   `--timeout`, rule schemas) move the theory halfway: TBD ends up
   executing policy it does not own, behind vocabulary it must version
   forever. A clean descope adds fact surfaces and actuations; it adds
   no policy grammar. *Example: briefing persistence became the
   submitting program's loop over a pinned result vocabulary, not retry
   flags on the pipe (design §12, sweep program §3).*
6. **The disguise dual.** The specs already name one direction: a
   threshold placed in a prompt is a fact disguised as judgment. Audit
   the other direction with equal suspicion: a judgment compiled behind a
   constant is a theory disguised as mechanism. *Example: "pause halts a
   runaway" was a goal wearing a verb; pinning its mechanism (an
   interrupt payload) exposed that everything else in it was judgment
   (design §3, §10).*

## What legitimately stays compiled

The placement rule cuts both ways, and a doc about melting theories must
say plainly what does not melt. Five things stay compiled because
user-land cannot do them well:

- **Facts and their timestamps** — a wrong fact poisons every consumer
  downstream, and per-event derivation across a fleet is a cost argument
  user-land loses (design §2).
- **Transport correctness** — pastes, panes, serialization, race-safe
  wake. Nobody's convention changes these.
- **Integrity of the record** — nobody is the reporter of their own acts.
  The daemon writes what it executed, for every caller; a self-kept
  record is a claims tier, not a fact tier (design §3, §6).
- **The one clock that rings when the watcher stops** — every authored
  watcher is a process that can die unnoticed; the chain terminates only
  at a compiled clock (the contact window), and exactly one such clock is
  owed (sweep program §6).
- **The brake** — the operator's atomic stop over TBD's own hand,
  rechecked at the act (design §3, §8).

Two structural principles govern the theories TBD *does* hold:

- **Content, not law.** A shipped default is a theory — the reference
  sweep program's thresholds, the default transition ceremony, the
  shipped continuation policy are all opinions. TBD holds them as
  editable artifacts: shipped inside the install, improving with
  releases, seeded exactly once into a project's ownership on the
  customize gesture, and never rewritten after. What TBD declines is
  holding a theory as behavior only a rebuild can change (sweep program
  §7).
- **The floor principle.** A theory that moves out leaves a fact-shaped
  floor behind: silence displayed, acts logged, the machinery's own
  failures notified. The floor never re-implements the theory — it makes
  the theory's *failure visible*, so an authored watcher that rots shows
  up in the record instead of impersonating a calm night (design §9,
  §15).

## Melting a theory exposes the next one

Dissolving a compiled theory is not the end of an audit; it is the start
of the next one. The dissolved theory was *hiding* the layer beneath it,
because the noun's machinery answered the next question implicitly and
nobody had to ask it. The supervision redesign ran this chain: deleting
the shift exposed a theory of ceremony (what happens at a coverage
boundary, now that nothing compiled happens); authoring ceremony exposed
a theory of continuation (who revives a dead supervisor, now that no
close gesture disposes of it); interrogating continuation exposed
delivery persistence (who retries a failed briefing); dissolving the
acting verb exposed theories of memory and narrative (where the record's
story lives, once the record stops pretending to be one).

So the discipline, stated as an instruction: **when a theory melts, ask
immediately what the melt made visible, and run the battery on that** —
name the next theory before a review names it for you. The signals are
the same ones the battery uses, newly applied to whatever the deleted
machinery used to decide implicitly: any *when/whether/what-instead* the
old noun answered by existing is now an unowned decision, and unowned
decisions default silently back into compiled code unless they are
assigned.

Two corollaries for pacing. First, expect a sequence of small
interrogations, not one grand audit — each layer only becomes visible
after the previous one lands, so a single-pass sweep will always miss
the tail. Second, leave the trail: every dissolved theory earns a
rejected-alternatives entry in the relevant spec, written as timeless
rationale with the field-evidence signature that would justify
rebuilding it. Those entries are how the next session picks up where
this one stopped, and they are the reason the chain above can be cited
instead of re-derived.
