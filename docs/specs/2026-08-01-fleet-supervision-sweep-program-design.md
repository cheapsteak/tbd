# Fleet supervision — the sweep program and desk briefing

Status: **normative sub-document of the fleet-supervision design.** Sibling of
the [wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md),
with the same authority as the design sections it details; `design §N` below
refers to
[`2026-07-26-fleet-supervision-design.md`](2026-07-26-fleet-supervision-design.md).
It specifies two things that arrive from one placement argument: how live-agent
**cases are detected** — a project-authored sweep program submitting proposals
to a compiled intake, held to a compiled liveness contract — and how
**briefings land on a desk** — standing conduct installed at spawn, work
orders rendered through a project-authored hook. The requirements doc carries
the Built/Enabled classification and the outside-first ratchet this document
applies
([`2026-07-26-fleet-supervision-requirements.md`](2026-07-26-fleet-supervision-requirements.md)).

## 1. What TBD does not decide: theory of work, theory of attention

The design states that TBD has no **theory of work** — what done, stuck, or
abandoned mean is a project's convention, authored, never compiled (design §2).
This document names the sibling refusal: TBD has no **theory of attention** —
*when the fleet deserves evaluation* is equally a convention. One project
thinks in durations: look every few minutes, worry at forty idle. Another
thinks in forge events: look when a pull request becomes mergeable, when a
review lands, when checks go green. A third looks only during working hours.
A compiled tick as the sole trigger would quietly enshrine the first theory as
the only one.

Both theories are authored in the same artifact. The **sweep program** holds a
project's theory of attention (its triggers) and its theory of work for the
live half of the fleet (what the facts mean once it looks) — the exact
counterpart of the wake program, which holds both theories for the parked
half. Compiled TBD keeps what remains when both theories are subtracted: how
to look (the fact snapshot), how to act (the verbs), what happened (the
record), and whether anyone is actually looking (the liveness contract, §6).

A rule of thumb runs through every artifact in this document, stated once:
**representation follows consumer.** Content read by judgment is prose (the
playbook). Content read by lookup is structured data (`supervision.json`, the
snapshot, proposals). Content that decides is code (the sweep program, the
renderer). Schemas exist only where a parser is the reader.

## 2. The placement split

Authored, per project — the judgment-facing pipeline:

- **When to look** — the sweep program's triggers (§4).
- **What the facts mean** — the sweep program's case-cutting logic, including
  every threshold number (§7).
- **How the briefing reads** — the work-order renderer (§9).
- **What conduct governs** — the playbook, standing in the desk's session
  layer (§8).
- **What to do** — the desk's judgment, under that conduct (design §4).

Compiled, always — the integrity-facing pipeline:

- **The fact snapshot** — state with source and observed-at, work facts,
  runaway counters (design §2, §13). Fact: a wrong answer poisons everything
  downstream.
- **The event path for prompt cases** — a pending `AskUserQuestion` or
  permission prompt is a *reported fact*, not an inference: the hook payload
  states that a question is on screen and the agent is waiting. There is no
  detection heuristic in it for a project to iterate on, it is the case kind
  where the agent is provably blocked right now, and the hook event is the
  only live signal — the transcript is blind while a picker is open
  (`docs/research/2026-07-31-askuserquestion-dismissal/findings.md`). It
  bypasses the sweep program entirely. A project that wants routine prompts
  handled without a desk fixes them at the source (design §2, prong 1).
- **Work-order assembly, the not-to-act floor, delivery, the ledger** — §3,
  §9, design §4–§6, §12.
- **Every liveness contract** — desk dead-man's switch (design §9), act
  re-check (design §12), sweep watchdog (§6), renderer fallback (§9).

**The work order, decomposed by author**, is the worked example of this split.
Sorted by who writes each piece: the playbook and mode conduct are the
project's file; the evidence string is the project's sweep program (§3); the
decisions in scope are the operator's words; a question payload is the agent's
words, verbatim. TBD authors none of the prose a desk reads. The only text
TBD generates is fact rendering — "idle 47 min, observed via hook at 02:13" —
and even that presentation passes through the project's renderer (§9). What
stays compiled is the **envelope**: the guarantee that the assembled structure
contains the decisions in scope (design §8, the never-re-ask promise), the
active mode selection, the verbatim question, and the transcript path, and
that the record shows both what was assembled and what was delivered.

The old system is the cautionary precedent for collapsing this split. Its
recurring desk briefing was a prompt template compiled into the binary
(`NightwatchDeskPrompts.judgePrompt`,
`Sources/TBDShared/NightwatchDeskPrompts.swift:91`; `docs/nightwatch.md` §5),
mixing mechanism, policy, and a section literally titled "Field learnings —
apply these rules" — conduct learned on real shifts that could only be taught
by editing Swift and rebuilding. Every sentence of that content now has an
authored home; only the envelope remains compiled.

## 3. The intake

The sweep program reaches TBD through one public surface: an **evaluation
report** submitted to the daemon. Every evaluation ends in a report, findings
or none; proposals are a report's content, not a separate message kind.

```
tbd supervise report --project <name>     # report JSON on stdin
```

A report:

```jsonc
{ "version": 1,
  "proposals": [
    { "agent": "<sessionID>",
      "condition": "idle-with-uncommitted-work",
      "evidence": "idle 47m; 2 files uncommitted; PR #522 reviewed 20m ago" }
  ] }
```

- **`condition` is a free string** — the project's own vocabulary. An enum
  here would rebuild the old system's rules vocabulary (the `clearance`
  table's verdict kinds, shipped with zero production readers —
  `docs/nightwatch.md` §1) one layer down.
- **`evidence` is authored per-case prose** that rides into the work order —
  the sweep program's voice in the desk's briefing.
- **A report with no proposals is still a report** — the attested "looked,
  found nothing." It is not a courtesy: it is what makes a quiet fleet
  distinguishable from a dead sensor (§6).

The daemon processes every submission the same way, synchronously:

1. **Timestamp and attribute.** Every submission updates the project's
   liveness record — last contact, evaluation count. A submission *carrying
   proposals* is additionally ledgered with who submitted, when, and what,
   before anything else happens: the intake is actuation-adjacent (a
   proposal can wake a desk, which spends real tokens), so provenance on
   proposals is not optional. A report with no proposals writes no ledger
   line — the design's noise rule holds (design §6: quiet contact is one
   status field, not forty lines an hour); its durable trace is the
   shift-close line's coverage summary (§6).
2. **Apply the not-to-act floor.** Compiled checks against TBD's own records
   drop proposals that must not become cases *now*: an intervention already
   in flight for that agent, a pending act re-check, a rate-limited target
   that cannot execute anything. These are ledger bookkeeping, not theory —
   they protect the record's integrity (never double-treat before the first
   treatment is assessed) and the wake count (design §5's honestly priced
   resource). The same facts appear in the snapshot, so a script can reason
   with them; the floor holds regardless of whether it did. Skipping the
   floor is never unsafe — verb-time preconditions still refuse at the act
   (design §3) — it is the economy layer, and it is not the script's to
   waive. The command's synchronous response tells the program each
   proposal's disposition — accepted, or dropped with the mechanical
   reason — so a drop is visible to its submitter without a recurring
   ledger line for every evaluation an intervention stays in flight.
3. **Compose and deliver.** Surviving proposals become cases, grouped into
   one work order per project, rendered (§9), and delivered exactly as the
   design specifies (design §4 steps 3–5): spawn the desk lazily, deliver
   through the agent-kind adapter, write the ledger request-first.

The readout the sweep program reads is the other half of the contract:

```
tbd supervise readout --project <name>    # JSON on stdout, schema-versioned
```

An instrument readout: read-only, the current values printed for whoever is
consuming them, implying no action. It prints the project's live-agent
facts — session state with source and observed-at, work facts, runaway
counters, and the not-to-act facts. The sweep program reads the readout at
the start of each evaluation and submits its report at the end; an operator
or any other script may read it freely at any time. Both
schemas are documented public surfaces under the requirements doc's Enabled
rules: a fact the reference script cannot obtain from them is a failed
conformance check and a concrete, scoped API request.

## 4. Triggers and the default tick

Triggers are entirely the project's. Cron, launchd, a webhook receiver
listening for forge events, a manual run while debugging a script — all
equivalent at the intake, which neither knows nor asks what prompted a
submission.

TBD ships scheduling as a **default, not a monopoly** — the same shape as a
component's default props. The daemon runs the seeded reference script (§7)
on a timer, per project, until the project overrides:

- **Keep the tick, edit the script** — the common case. Tuning a threshold is
  editing a constant; the schedule is untouched.
- **Go external, bring your own triggers** — `"schedule": "external"` in the
  project's `supervision.json` entry. The project now owns its theory of
  attention outright, and declares a contact window in exchange (§6).
- **Keep the tick alongside your own triggers** — legitimate and cheap: the
  tick becomes a reporting floor under an event-driven program.

The selection is the `sweep` object inside the project's entry in
`~/tbd/supervision/supervision.json` (design §8), on the default-props
chain: no object means TBD's schedule at the default interval; an interval
value overrides the cadence; `"external"` stands TBD's scheduler down, and
the object then declares the contact window §6 requires:

```jsonc
// ~/tbd/supervision/supervision.json
{
  "projects": {
    "acme-platform": {
      "repos": ["<repoID-a>", "<repoID-b>"],
      "mode": "autonomous",
      "sweep": { "schedule": "external", "contactWindow": "30m" }
    }
  }
}
```

When the daemon itself runs the script, failure detection is direct — a
crash, timeout, or unparseable output is observed as an exit condition and
recorded (§6). When the project owns the triggers, failure detection is the
watchdog's, by silence. Either way the seeded default means "flip the switch
and supervision works": no project starts with a scheduling chore, and the
never-installed-schedule failure class does not exist for the default path.

## 5. Liveness contracts: which durations are whose

"Idle 40 minutes" does double duty in supervision conversations, and the two
duties land on opposite sides of the compiled/authored line:

- **Durations about the supervised work are authored hypotheses.** An agent
  idle 40 minutes is a *guess* that something is wrong — project-variable
  (one team's stall is another's long build), owned by the sweep program,
  evaluated on whatever cadence its theory of attention supplies. TBD never
  evaluates these durations; it timestamps the facts so any evaluator can.
- **Durations about the supervision machinery are compiled contracts.** Each
  measures silence against an expectation *the system itself created*, and
  none involves judgment:
  - a **work order** delivered at T with no ledger line by the deadline — the
    desk dead-man's switch (design §9);
  - an **act** performed at T, verified about a minute later — the re-check
    (design §12);
  - a **declared contact window** with no intake submission inside it — the
    sweep watchdog (§6).

The compiled clocks never point outward at the fleet. Every one of them
points at the supervision system itself. The fleet's idleness is judgment;
the machinery's idleness is integrity — if it went unmeasured, the record
would lie by omission.

## 6. Detecting a dead sweep program

The rule that makes detection possible: **"nothing going on" is never
expressed as silence.** A healthy sweep program that finds nothing still
submits its report — one with no proposals (§3). That single obligation — the
reference script honors it out of the box — makes three states cleanly
distinguishable at the intake:

- **Reports with proposals** — the program ran and found work.
- **Reports with no proposals, arriving within the window** — the program ran
  and the fleet is genuinely quiet. Quiet contact updates the liveness
  record, never the ledger (noise rule, §3); the shift-close line carries the
  coverage summary, so the account can still say "checked 14 times, nothing
  found": an *attested* calm night, durably.
- **No contact past the declared window** — nobody looked. Dead cron, crashed
  script, uninstalled schedule — the daemon cannot tell which and does not
  need to: it responds by tier (below). Silence means exactly one thing.

**What the watchdog does, by tier — and what it never does.** The
last-contact age is a plain displayed fact wherever supervision status
appears: an operator glancing at the app sees "last sweep report 4 min ago,"
no alarm involved. The watchdog proper begins where display ends, because a
status surface nobody is watching protects nobody overnight — that is the
subsystem's founding premise. A missed window writes an **anomaly line into
the ledger**, so the coverage gap is part of the durable account whether or
not anyone was looking; persistent silence (§10) raises an **operator
escalation through the existing escalation path** — no new channel, one more
source writing into the one the design already has. The desk is deliberately
never prompted: a broken sensor is an operator's problem, not a judgment
call, and a desk told "your own sweep is dead" could do nothing but relay
the message. Nor is this new timer machinery — the daemon already runs
compiled cadences (the fact maintenance, §14's status write); the watchdog
is one more deadline on the clock TBD already holds. It complements §14
rather than duplicating it: §14's out-of-band watchdog asks whether the
*daemon* is alive; this one asks whether anyone is *feeding* it.

**The contact window** is the declared expectation silence is measured
against. While the default tick runs, the window defaults to a multiple of
the tick interval (§10) and the operator declares nothing. A project on an
external schedule declares its own window in `supervision.json`. A project
that declines even that — a purely event-driven program with no periodic
report has no honest cadence to declare — gets the degraded account in so
many words:
its coverage renders as **unknown**, in the morning account and on the status
surfaces. Every position is available; the one eliminated is the accidental
version, where the account implies watchfulness nobody was providing. The
old system ran the accidental version for five nights: a component reported
missing at every tick had never been installed at all, and judge sessions
escalated restarts for software that was never built (design §9). The
watchdog exists so that failure shape cannot recur quietly.

**Why the watchdog's clock is TBD's.** Any user-land watchdog is itself a
process that can die unnoticed; adding layers moves the silent-death point
without removing it. The chain terminates only at a process whose failure is
already visible — one that cannot be dead while everything seems fine. The
daemon is that process: if it is down, sessions are unmanaged, the app shows
it, the product is visibly broken. The alarm must also be written into the
ledger — the compiled, append-only record the operator trusts — by something
other than the thing being measured, and the daemon owns that record. This is
the placement rule's own exception pair (liveness attestation, integrity of
the record) applied, not overridden. The guarantee is stated as the
conditional it is: **while TBD runs, silence in the record is meaningful.**
Daemon liveness itself belongs to the layer that already owns it (launchd,
and an operator's eyes on a visibly broken app). Projects may stack further
watchdogs above TBD's; the compiled one is the floor, not the ceiling.

## 7. The reference sweep script

Seeded per project when the project first comes under supervision — once,
never clobbered, the wake program's seeding discipline exactly. The seeded
copy is real, editable logic, not an example: the default tick runs it, so
every project has working supervision from the first shift with nothing
authored.

- **It carries the threshold numbers as named constants** — the
  idle-intervention threshold, the runaway turn and no-progress windows
  (§10). Tuning is editing a constant in a file the project owns. There is
  no per-repo threshold configuration surface in TBD and none deferred:
  numbers live in the script, which also preserves the design's one-column
  property (design §7) permanently — a number never becomes a config column.
- **It is the conformance artifact** for the readout and report contracts,
  alongside the reference wake script for its surfaces: it may use only
  documented public surfaces (`tbd supervise readout`, `tbd supervise
  report`). A fact it cannot obtain that way is a failed conformance check
  and a scoped API request — the mechanism by which TBD's surface grows,
  pulled by a real consumer.
- **It reports on every evaluation**, findings or none, satisfying §6's
  report obligation.
- Its case-cutting defaults are deliberately modest — the design's compiled
  sweep semantics, relocated: idle past the threshold with uncommitted work
  proposes a case; runaway counters past their windows propose a case; facts
  it cannot interpret propose nothing. Sophistication is the project's to
  add; the seed is a floor, not a ceiling.

## 8. Standing conduct: how the playbook reaches the desk

The playbook — including **all of its mode sections** — is installed as a
standing instruction layer when the desk session is spawned, through the
agent-kind adapter. Each work order then carries the **active mode's name**,
not its text. The desk holds the project's whole conduct for the life of its
session; the order tells it which posture is selected right now.

What this buys, in order of importance:

- **Compaction cannot eat the conduct.** A long shift summarizes old turns;
  a playbook embedded in an early message can be compacted into mush by
  work order fifteen. Standing layers are re-included by construction —
  verified for both shipped desk kinds (dated note, §13). Since deliberate
  recycling is an optimization and auto-compaction bears desk survival
  (design §9), conduct must live where compaction cannot reach it.
- **A mode switch is zero-delta.** The next order names a different section
  the desk already holds — mode selection takes effect on the next order
  (design §3) with no conduct re-delivery and no desk restart. The daemon
  delivers no section at all; it delivers the selection.
- **Standing weight.** Conduct in the session's instruction layer reads as
  *who you are*; conduct in message one of forty reads as something someone
  said earlier.
- **One copy per session**, prompt-cached, instead of one per order — on a
  busy night, tens of thousands of tokens of duplication removed from the
  context window that the mid-shift ceiling already threatens.

**Mid-shift playbook edits** are the one thing a spawn-time layer cannot
carry, and the file cannot be re-read into a live session by either shipped
agent kind (dated note, §13) — so the delta travels in the next work order:
the changed text, marked as superseding the standing conduct. The daemon
tracks, per desk session, the hash of the conduct that session stands on;
orders carry deltas only while the hashes differ. Re-baselining does not
wait for a full replacement: both shipped agent kinds support a **conduct
reload** — relaunch the desk's session process *resuming the same
conversation*, with the refreshed playbook as its standing layer (dated
note, §13) — so the daemon schedules exactly that at the desk's next idle
moment, and nothing of the shift's context is lost. Where an adapter lacks
resume, deltas simply ride until the next recycle. Either way a replacement
or reloaded desk spawns with the current playbook, which is also why a
replacement desk needs no special briefing path. The ledger records the conduct hash per order either way, so
"what conduct governed this act" is answerable per action against a
versioned file.

**Installation is an adapter capability**, like the context apparatus
(design §9). The Claude adapter delivers the playbook as a named layer in
the `SystemPromptBuilder` stack TBD already applies at spawn
(`Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift`) — the same
mechanism as the existing `TBD_PROMPT_CONTEXT` layer; the Codex adapter
passes it as `developerInstructions` at thread start (dated note, §13). An
agent kind with no such mechanism falls back to embedding the playbook in
the first work order of each desk session, and nothing else changes.

## 9. The work-order renderer

Between compiled assembly and delivery sits one authored transform: a
per-project hook that turns the assembled work order into the text that
lands on the desk. The shape is Claude Code's statusline exactly — a program
receiving structured JSON on stdin whose stdout becomes the surface:

- **No hook present** — the built-in renderer formats the order. The default
  path has zero setup and is the common case.
- **Hook present** — the daemon passes the assembled work order (same schema
  family as §3, versioned) on stdin; stdout, bounded (§10), is the delivered
  briefing.
- **Hook crashes, times out, or emits nothing** — the built-in renderer
  formats the order and the daemon writes a loud anomaly line. Delivery is
  never held hostage to a broken formatter; the failure default is stock
  behavior plus a visible record, the same honesty pattern as §6. The
  timeout rides the injected-clock seam like every compiled delay.

The split this creates is the load-bearing part. **Assembly** — which facts,
which decisions, which payloads are in the structure — is compiled: the
envelope's guaranteed contents are how "your decisions ride in every order"
stays a promise. **Rendering** — how that structure reads — is authored,
because how a briefing lands is voice and emphasis, which is conduct's
territory, not the tool's. The residual risk is a project's renderer
dropping content the envelope guaranteed, and the design's trust model
already has a name for it: an authored program's correctness is its
author's, like any cron job's. TBD's obligations are that the full structure
reaches the renderer and that the ledger records both the assembled
structure and the delivered text's hash — so a desk that re-asked an
answered question is *diagnosable* (the record shows whether the renderer
dropped the decision or the desk ignored it), which is strictly more than an
all-compiled pipeline could say about a desk that ignores its briefing.

With the renderer in place, the delivery story states as one rule: **the
envelope embeds what is new, installs what is standing, and points at what
is durable** — case data and deltas in the order, conduct in the session
layer, transcripts and playbooks by path with hashes in the ledger.

## 10. Defaults

| Number | Default | Where it acts |
| --- | --- | --- |
| Default tick interval | 5 min | §4 |
| Contact window, TBD schedule | 3 × tick interval | §6 |
| Contact window, external schedule | declared, or coverage unknown | §6 |
| Watchdog escalation | 3 consecutive missed windows | §6 |
| Sweep script timeout (daemon-run tick) | 60 s | §4 |
| Renderer timeout | 10 s | §9 |
| Renderer output bound | 256 KiB | §9 |
| Report size bound | 1 MiB | §3 |
| Idle-intervention threshold | 40 min | §7 (reference script constant) |
| Runaway: turns in window | 30 turns | §7 (reference script constant) |
| Runaway: no-progress window | 90 min | §7 (reference script constant) |

The first eight are compiled constants; the last three ship as named
constants in the seeded reference script and are listed here as its
documented defaults, not as TBD's.

## 11. Rejected alternatives

- **A compiled case-cutting sweep** — the daemon evaluating thresholds and
  cutting cases itself. Rejected by the placement tie-breaker (design §1):
  the heuristic passes no compiled test decisively — it is project-variable
  judgment about what facts mean, the definition of authored territory — and
  compiling it freezes exactly the logic projects most need to iterate on.
  It would also compile a theory of attention: a tick as the only trigger
  forces duration-thinking on event-shaped projects.
- **A daemon-invoked decision script** — the daemon keeps the tick and pipes
  facts to an authored script on stdin, stdout returning cases. Attractive
  because liveness attestation comes free ("I called and nobody answered"),
  but it buys attestation by owning the trigger, which compiles the theory
  of attention anyway. The intake-plus-watchdog shape buys the same
  attestation directly and leaves triggers authored. The daemon-run default
  tick (§4) preserves this shape's out-of-box convenience without its
  monopoly.
- **A fully external sweep with no liveness contract** — maximum symmetry
  with the wake program: TBD exposes surfaces and neither runs nor monitors
  anything. Rejected on failure asymmetry: a dead wake program leaves parked
  sessions parked — a safe state, deferred work — while a dead sweep leaves
  stuck agents unnoticed all night, the product's core promise silently off,
  indistinguishable from calm. The parked half accepts that ambiguity
  deliberately; the live half measured its cost at five days once and does
  not accept it again (§6).
- **A compiled baseline with an authored overlay** — the specced sweep stays
  and a script may add or suppress cases. Fails toward stock behavior
  instead of silence, which is its one virtue, but creates two concurrent
  decision layers to reason about, and delivers tuning as *suppressing the
  output of logic the project cannot edit* — backwards. The seeded reference
  script provides stock-behavior-by-default without a second layer.
- **Routing prompt cases through the sweep program** — uniformity at the
  cost of putting script latency and script bugs on the one path where the
  agent is provably blocked and the hook event is the only live signal.
  There is no authored detection logic in a reported fact, so the descope's
  motivation does not apply. Script-level prompt handling can migrate in
  later on field evidence, as any capability can.
- **A single fleet-global sweep script** — one script seeing all projects.
  The project is the policy unit everywhere else (desk, playbook, wake
  program, mode); a global script would reimplement project membership
  dispatch inside user code and let one project's syntax error silence every
  project's cases. Per-project scripts make an edit's blast radius the
  project that edited.
- **A schema for `condition`** — an enum of case kinds. Rules-vocabulary
  thinking; see the intake (§3) and the `clearance` precedent.
- **Re-delivering the playbook in every work order** — robust and simple,
  and what the old system's nudge loop did with its whole compiled briefing,
  but it funds the desk's most likely failure (the mid-shift context
  ceiling) with pure duplication, and re-delivery is the anomaly against the
  design's own transcript-by-path rule. The standing layer plus deltas (§8)
  keeps every property re-delivery had — mode switches on the next order,
  replacement desks briefed on arrival — without the copies.

## 12. Testing

- **Intake round-trip** — the reference script's report against a synthetic
  readout becomes a work order; a report with no proposals updates the
  liveness record, writes no ledger line, produces no work order, and is
  counted in the shift-close coverage summary.
- **Floor** — a proposal duplicating an in-flight intervention or targeting
  a rate-limited agent is dropped, its disposition returned in the report
  command's response, and the submission still counts as contact.
- **Watchdog** — a missed window writes the anomaly line; the configured
  consecutive count escalates; contact resets the count; a project with
  `schedule: external` and no declared window renders coverage unknown, and
  both branches of the schedule setting behave (per the flag-branch rule).
- **Dead-vs-quiet** — a quiet-report night and a no-contact night produce
  distinguishable accounts.
- **Seeding** — first supervision touch seeds script and playbook; a second
  touch never overwrites either.
- **Standing layer** — spawn installs the full playbook via the adapter; a
  mode switch changes only the name carried in the next order; a playbook
  edit produces a superseding delta in the next order; a conduct reload
  resumes the same session with the refreshed layer and clears the delta;
  the no-mechanism agent kind falls back to first-order embed.
- **Renderer** — hook output is delivered verbatim within bounds; crash,
  timeout, and empty output each fall back to the built-in renderer plus an
  anomaly line; ledger carries assembled structure and delivered hash in
  all cases.

## 13. Dated source note: standing-instruction mechanics per agent kind

Facts below are point-in-time observations of external tools, recorded here
so they can rot without touching the design (the wake program's dated-note
discipline). Verified 2026-08-01.

- **Claude Code** — `--append-system-prompt` appends to the system prompt at
  launch; TBD already delivers named prompt layers through it via
  `SystemPromptBuilder`, and the desk's playbook layer rides that same
  stack. (`CLAUDE.md` in the desk worktree would also load as project
  instructions, but a materialized copy on disk can diverge from the
  resolved playbook, so it is not used.) Resuming a session
  (`claude --resume <id>`) launches a fresh process that rebuilds its launch
  flags, which is what makes the conduct reload (§8) a resume with a
  refreshed layer value — expected to behave as at spawn; verify at
  implementation.
- **Codex** (codex-cli 0.146.0; flags verified from the binary, behavior
  from `openai/codex` source) — the additive standing mechanism is
  `developer_instructions`: per-invocation via
  `codex exec -c developer_instructions="..."`, or per-thread via the
  app-server protocol's `developerInstructions` field on `thread/start` —
  one field in the same call that spawns the desk. `thread/resume` and
  `thread/fork` accept the same field (schema-verified), which is what makes
  the conduct reload (§8) a resume with a refreshed value. It lands as the
  first developer-role message, above `AGENTS.md`. Compaction re-injects both
  developer instructions and `AGENTS.md` into rebuilt history
  (`codex-rs/core/src/compact.rs`), so the layer survives by design.
  `AGENTS.md` in the desk worktree is the file-based alternative (loaded
  root-down, 32 KiB combined budget) but arrives as a user-role message.
  Caveats: the app-server is flagged experimental; `AGENTS.md` is cached per
  session and **not re-read on file edits** — which is why mid-shift
  playbook edits travel as work-order deltas (§8) rather than file writes;
  the former `experimental_instructions_file` key is renamed
  `model_instructions_file` and *replaces* base instructions — not the
  mechanism to use here.
