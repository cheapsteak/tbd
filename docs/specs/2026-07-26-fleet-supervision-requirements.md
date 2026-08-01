# Design brief: fleet supervision for TBD (blue-sky redesign of "Nightwatch")

You are designing, from scratch, the fleet-supervision subsystem of TBD — a macOS tool for
running many Claude Code agents in parallel. An implementation of this subsystem exists and
works after a fashion; it has been mined for the requirements below, and those requirements
are your starting point. The implementation itself is not — see the reading instructions.

This is a reference design meant to be argued with, not adopted verbatim. Favour a strong,
specific point of view over implementability compromises.

## The substrate

TBD's unit of work is a git worktree. Each worktree has one or more tmux panes; each pane
runs an interactive coding agent as a full-screen TUI (usually Claude Code). A background
daemon owns a SQLite database of worktrees, terminals, and sessions, and exposes RPC over a
unix socket to a SwiftUI app and a CLI. The daemon spawns sessions, manages their lifecycle
(including hibernating idle ones), tracks PR status, and can deliver text into any pane. A
fleet is five to forty of these agents; overnight, nobody is watching them.

## What the subsystem is

**One supervising agent autonomously drives the other agents.** The supervisor is itself a
reasoning agent — a full Claude Code session in its own dedicated worktree — not compiled
logic. The daemon's job is to feed it, schedule it, bound it, and account for it. Take
agent-as-supervisor as settled; do not design a purely-compiled alternative.

It runs in two modes, and the distinction is the spine of the design:

1. **Human-supervised mode** — a human is present. The supervisor observes, judges, and
   proposes; a human stays in the loop on anything consequential.
2. **Fully autonomous mode** — nobody is watching, typically overnight. The supervisor acts
   on its own judgment.

(The current code calls these "daywatch" and "nightwatch". Ignore those names; more
importantly, ignore how the current code draws the distinction — see story P0-3.)

## How to use the repo

Repo root: `/Users/chang/tbd/worktrees/tbd/20260725-condemned-anteater`

Read the repo to understand how TBD works generally — its data model, RPC surface, config
precedence, hook system, terminal and session lifecycle, settings surfaces. Ground your
design in those real mechanics. Particularly worth your time:

- `Sources/TBDShared/HookResolver.swift` + `docs/worktree-hooks.md` — the existing
  three-tier config precedence you are required to reuse
- `Sources/TBDDaemon/Database/Database.swift` — schema and migration discipline
- `Sources/TBDShared/Models.swift` — the shared data model
- `Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift` — how layered prompts already work
- `Sources/TBDApp/Settings/RepoHooksSettingsView.swift` — how a file-backed per-repo setting
  is surfaced to the operator

Do NOT anchor on the existing Nightwatch implementation or its documentation. The
requirements below are the useful residue of that implementation; start from them, not from
its structure. Skip these files, and if you stumble into them, do not treat them as design
input:

```
docs/nightwatch.md
docs/specs/2026-07-03-nightwatch-daywatch-design.md
Sources/TBDDaemon/Nightwatch/
Sources/TBDDaemon/Server/RPCRouter+NightwatchHandlers.swift
Sources/TBDDaemon/Database/{ClearanceStore,AuditStore}.swift
Sources/TBDShared/{Models_Nightwatch,NightwatchDeskPrompts,NightwatchSkillContent}.swift
Sources/TBDCLI/Commands/NightwatchCommand.swift
Sources/TBDApp/**/Nightwatch*.swift
```

## Requirements

Each story is tagged with the mode it applies to: **[S]** human-supervised, **[A]** fully
autonomous, **[both]**. Stories marked *(implied, not yet implemented)* are clearly implied
by the current system's intent but absent or broken in it; treat them as requirements all
the same.

### Two ways a story can bind TBD

A story binds TBD in one of two ways, and several stories below are tagged with the
distinction:

- **Built** — TBD implements the behavior itself. The guarantee is the behavior. Untagged
  stories are Built; it is the default.
- **Enabled** — TBD guarantees that a program authored outside it, written against TBD's
  public surfaces, *can* implement the behavior: the facts it needs are readable — cheaply,
  with provenance, able to express not-knowing — the actuations it needs are invokable with
  their safety semantics stated, and those surfaces are documented and stable. What the
  program then does with them is authored and owned outside TBD, which neither supervises
  nor guardrails it. Its correctness is its author's, like any cron job's.

The split carries a migration direction, stated once so no later descope has to re-argue
it: **capability starts outside TBD and migrates in only when field use proves a need** —
one piece at a time, each argued on its own evidence. This is the
brief's own standing bias ("prefer the extension point") given a ratchet: the outside
position is the default, and every move inward is deliberate.

An Enabled guarantee also has a proof artifact. **The shipped reference implementation —
today, the wake program's reference script — may use only documented public surfaces.**
A fact it cannot obtain that way is a failed conformance check and a concrete, scoped API
request; that is the mechanism by which TBD's surface grows, pulled by a real consumer
rather than pushed by speculation. The corollary is a cost accepted here rather than
discovered later: the surfaces an Enabled story depends on — listing output shapes,
`hibernateReason` values, wake semantics, exit codes — stop being incidental CLI output
and become a contract that migration and future change must respect.

### P0 — without these the subsystem has no point

- **P0-1 [both]** As an operator, I want a single supervision function watching the whole
  fleet and intervening on my behalf, so that a stuck or idle agent doesn't sit dead for
  hours because nobody noticed. What must be singular is my experience of it: one switch,
  one record, one morning report, one place to look. The judgment layer underneath may
  shard by policy scope (the design's one-desk-per-project invariant) — how many sessions
  do the judging is the design's choice, provided a quiet fleet costs nothing and the
  account stays whole.
- **P0-2 [both]** As an operator, I want a single supervision switch — on / off —
  persisted in the daemon and settable from the app and the CLI, so that I can hand over or
  take back the fleet with one gesture, and a daemon restart resumes the same state without
  me. One column, one gesture, one shift for the whole fleet, resuming across restarts.

  The supervised/autonomous distinction is **per-project mode selection**, which is
  configuration rather than lifecycle (design §3): with no verb gate (see P0-3 below) the
  daemon has no behavioral fork on posture to make, so a mode is authored conduct and
  belongs with the project whose conduct it describes, while the switch that starts and
  stops supervision stays global.

  The switch governs what TBD itself runs — the sweep and the desks — and does not reach
  across the process boundary to programs the operator schedules. The wake program's off
  gesture is its scheduler's (`launchctl unload`), owned by whoever installed it: you stop
  the things you start. The reference wake program reads the switch from the public status
  surface and exits quietly when supervision is off — authored courtesy, not a guarantee TBD
  makes on the program's behalf.
- **P0-3 [both]** As an operator, I want the two modes to differ *mechanically*, not merely
  in prompt wording, so that the label's promise ("a human stays in the loop") is enforced
  by the system rather than requested of the supervisor. *(implied, not yet implemented —
  today the entire difference is one hint sentence in a prompt, and the conservative rule it
  states references a field the data doesn't even carry.)*

  *Descoped by operator decision: **this story is not implemented as written.** TBD builds
  no compiled verb gate — the mechanism that would have made the modes differ mechanically —
  declining it as over-engineering. The models running the supervisor desks are trusted to
  follow conduct instructions and are already resistant to prompt injection, and TBD declines
  to build a second anti-injection layer on top of them. What replaces enforcement is
  instruction plus visibility: a mode is authored conduct prose telling the desk what to act
  on, propose, and escalate; the daemon delivers that conduct in every work order, records
  which mode was active on every action line, and writes each action to the ledger the
  instant it happens, with the account rendering it beside the operator. So the label's
  promise is honest rather than enforced — "attended" instructs and shows you, it does not
  restrain. The concern this story raises (a mode label that is a false promise) is answered
  by refusing to claim enforcement at all, rather than by building it. The bet this rests on
  is stated in design §3 and argued against itself in design §16, which names the failure
  signature that would justify revisiting it.*
- **P0-4 [both]** As an operator, I want the supervisor to be a visible, first-class session
  I can open, read, and type into at any time, so that supervision is inspectable and
  steerable, never a black box running somewhere I can't see.
- **P0-5 [both]** As the daemon, I want to answer what any managed agent is doing right now —
  working, idle, awaiting input, rate-limited, gone — cheaply enough to ask about every agent
  every cycle, and again a minute later, without a model call and without reading rendered
  screen text. Where a state genuinely cannot be established from a machine interface, I want
  that surfaced as not-known rather than approximated, so that the rest of supervision is built
  on facts with known provenance.

  This is the substrate the rest of the design stands on: P0-6 sweeps with it, P0-7 decides
  intervention from it, P1-2 uses its work-state half to decide whether waking is warranted,
  P1-6 asks again shortly after acting, and P2-4 watches it over time for agents looping
  without progress. Note that it has two halves with different sources and different costs —
  *session* state (working, idle, blocked, dead) and *work* state (branch, commits, request,
  checks) — and that P1-6 in particular needs the first: an unchanged branch says nothing about
  whether an agent moved past a confirmation prompt.
- **P0-6 [both]** As an operator, I want fleet state checked on a regular cadence by cheap,
  model-free mechanics, with the supervisor's (expensive) reasoning woken only when there is
  a genuine judgment call, so that a night of supervision costs a fraction of my model quota
  rather than consuming it on mechanical sweeps.
- **P0-7 [A]** As an operator, I want stuck agents unstuck with a specific, context-aware
  next step derived from the agent's actual conversation — never a generic "continue" — so
  that interventions advance work instead of making agents re-idle.
- **P0-8 [both]** As an operator, I want any dispatched message that asserts external state
  ("your PR merged", "checks are failing") verified against live sources at send time, so
  that agents are never handed stale premises. (Hard-won: hand-composed wakes and gate
  notices have repeatedly described PRs that had merged days earlier.)

  *This is **authored discipline**, on both sides of the process boundary, and for a wake
  program the story is **Enabled** rather than Built.* For a desk the discipline is the
  shipped playbook's universal: derive the facts live, in the same breath as the send. For a
  wake program it is the discipline the old wake.py already practiced ("re-derives truth AT
  WAKE TIME") with no daemon help, and the reference script demonstrates it. The daemon does
  not re-verify a desk's `drive --text` claims, and does not inspect message content at all,
  for anyone. Three findings put the obligation there. **The owner is authored, not
  compiled.** The running system never compiled this check: it lived entirely in authored
  content the desk executed itself — `wake.py` "re-derives truth AT WAKE TIME", and the
  playbook already says "before dispatching any message that asserts PR state, re-read live
  state in the same breath as the send." The hand-composed wakes this story cites as
  hard-won predate that rule; the authored discipline *was* the fix, and it worked. **A
  compiled guarantee is not implementable as stated.** No compiled code finds "every
  external claim" in free prose without a model. Either the desk declares its claims
  structurally on the call — in which case verification covers only what the desk chose to
  declare, which is no stronger than conduct — or the daemon parses prose, which is judgment
  work at the wrong layer. The sentence reads like a guarantee; implemented honestly it
  could never be one. **And the field evidence says the failure is source choice, in the
  authored tier all along.** Field measurement caught desks re-verifying faithfully and
  being lied to anyway: `gh pr view` (GraphQL) served 17.5-hour-stale, internally
  self-consistent state where REST was correct every time, and `git ls-remote` beat the API
  by ~20s on a force-pushed head. A compiled verifier would consult those same lying
  oracles, and a re-verification that consults a lying oracle is worse than none, because it
  returns confidence. Which API tells the truth this week is data, not design — it lives as
  a dated source note in the reference wake script, where it can rot without touching a
  spec.*

  *What is **Built** is narrow, and is stated here exactly. Fresh work facts carrying
  source and observed-at in every work order (design §2). Public surfaces a desk or a
  program can re-derive from — a desk is a full agent session and can run `gh` and `git`
  itself. The ledger recording every dispatched message verbatim (design §6), so a stale
  premise is visible in the account the moment it ships: visibility, not prevention. And
  one small obligation — **display-tier honesty**: TBD's persisted `PRStatus` is
  display-tier, so wherever it appears on a public surface it carries its observed-at, and
  the account never renders it as current truth (that cache was observed reporting "Ready
  to merge" for PRs merged days earlier). That is TBD's own honesty rule applied to TBD's
  own cache, not a workaround for anyone's API. The failure signature that would justify
  building compiled freshness machinery, pre-committed here so nobody has to argue it
  from scratch: the account recurrently showing fleet agents acting on stale premises
  carried by desk messages. That pattern, in the record, is the argument — and such a build
  would be argued in the open, never a quiet restoration.*
- **P0-9 [both]** As an operator, I want a **live** account of the shift — open beside my work,
  updating as things happen, showing what has been done, what is still open, and what needs me
  — so that supervision is legible while it is running, not only after it has stopped. The
  end-of-shift and morning accounts should then be views over that same running record, rather
  than prose composed at the end from the supervisor's recollection.

  *Surface note:* a side panel able to display a live-updating markdown document is being built
  separately and does not exist yet. Assume it will; do not design the panel. What is yours to
  decide is what the running record contains, who appends to it and when, and how the
  end-of-shift views are derived from it.
- **P0-10 [A]** As an operator, I want questions the supervisor cannot resolve escalated in
  small, specific batches — exact item, exact proposed command, a recommendation — so that
  the morning's decision queue is answerable in minutes, not an interrogation.

### P1 — the difference between working and trustworthy

- **P1-1 [A]** As an operator, I want the supervisor capacity-aware: when several agents are
  rate-capped at once it holds interventions instead of piling on, and it never nudges an
  individually rate-limited agent, so that a quota wall doesn't turn into a night of wasted
  pokes. *(A stronger version exists in the current system — rebalancing stuck sessions onto
  less-loaded accounts rather than passively freezing — motivated by one saturated account
  stalling a whole fleet overnight. Treat that as conditional: it presumes an operator with
  several accounts configured, which may be one person's topology rather than a general need.
  Design the holding behaviour; argue for or against rebalancing.)*

  *This story splits along the Built/Enabled line. Holding is **Built** for the desks TBD
  runs (design §11). For the wake program it is **Enabled** — the per-profile usage and
  rate-limit facts the daemon already holds must be exposed on a public, machine-readable
  surface so a program can hold on its own. That surface does not exist today; it is the
  first concrete API request the Enabled conformance test has produced.*
- **P1-2 [A]** As an operator, I want *whether* to wake a parked session decided from cheap
  facts derived entirely outside it — branch, commits not yet on main, whether a pull request
  exists and its state, whether checks fail — so that the supervisor never has to hold the arc
  of anyone's work in its head, and sessions with nothing outstanding are not woken at all.
  Waking is expensive; it should be the conclusion of a check, not the way the check is
  performed. *(implied, partially broken today — the live check exists and works, but every
  parked session is woken regardless of its verdict, including the ones just found complete.
  On the night that motivated the check, all 24 were complete.)*

  *The story's intent survives; its assigned owner is not the daemon.* A compiled wake gate
  in the daemon's sweep — a global "outstanding work" fact list whose any-true verdict wakes
  a parked session — is structurally wrong, not mistuned: its "commits not on the default
  branch" fact reads true forever for a squash-merged branch, so 33 of 70 active worktrees
  on a live fleet — and 24 of 24 on this story's own motivating night — were finished work
  such a sweep would have woken every cycle, one into a resume worth 750k tokens re-entering
  work merged five days earlier. Completion is a fact about intent and forge state; git
  commit identity cannot express it, and no compiled fact list can. So rather than an
  inference to repair, **the wake decision sits outside the daemon entirely — and outside
  the desk, which never needed to be involved** (the old system's wake.py composed verified
  wakes with no model). Waking parked sessions is a **project-authored wake program**: an
  external script, seeded once from a shipped reference and never clobbered, that reads what
  is parked and why from TBD's public surfaces, derives live git and forge facts itself,
  decides in its own vocabulary, composes the wake text, schedules its own cadence, and
  actuates through `tbd terminal wake`. The story is thereby classified **Enabled** (see the
  classification note above): TBD's obligation is that the program's inputs and actuation
  are public, documented, and stable — never to guarantee or guardrail the program's
  correctness. TBD builds no compiled choke point at actuation (capacity holds, dedup,
  send-time freshness, a daemon-written ledger line): that would make TBD the guarantor of a
  program TBD does not run, does not schedule, and — seeded once, never clobbered — cannot
  repair. The rails are the program's to honor, readable from the same public surfaces, and
  the reference script honors all of them. A project with no wake program gets no automated
  wakes — parked worktrees appear in the account with their facts, and a merged pull
  request means silence, never a wake. The story's clauses are all preserved: the facts are
  still cheap and derived outside the session, waking is still the conclusion of a check,
  and sessions with nothing outstanding are not woken by construction — nothing wakes at
  all unless a program a human authored concludes it should. Full design:
  [`2026-07-26-fleet-supervision-wake-program.md`](2026-07-26-fleet-supervision-wake-program.md).*
- **P1-3 [both]** As an operator, I want worktrees whose progress matters most looked at
  first, so that the important work gets attention early in every pass.
- **P1-4 [both]** As a repo maintainer, I want my repo's supervision policy — what counts as
  stuck, what interventions are appropriate, house rules the supervisor must follow —
  authored as an artifact in or beside my repo and resolved through TBD's existing
  three-tier precedence, so that process travels with the repo instead of living in one
  operator's tool.

  *Worked example, and the seam this requirement is really about.* Take the wake decision in
  P1-2. Deriving the facts is app-global: whether a branch has commits not on main, whether a
  request is open or merged, whether checks fail, whether any of that could not be established.
  Those are properties of git and the forge, identical in every repo, and cheap. What those
  facts **warrant** is not. Commits with no request means "wake and finish it" in one repo and
  "leave it, that is how we park experiments" in another; an open request with failing checks
  means "fix it" in one and "never touch a request without a human" in another; and what
  *finished* should trigger — a closeout command, an archive, nothing — is purely local
  vocabulary. State it as: **the check yields a verdict; the repo decides what the verdict
  warrants.** The supervisor then needs neither the arc of the work nor the house rules in its
  head — it reads facts it did not have to earn and a policy it did not have to invent.

  The current system draws this line in the wrong place, and the damage is legible: its
  verified wake messages hardcode one team's closeout command and one team's named review bot
  as the definition of ready. Every other repo is told to run a command it does not have and
  satisfy a reviewer it does not use.

  Mode belongs on the same axis (see P0-3): one verdict can warrant escalate-to-human when
  supervised and act-directly when autonomous, authored per repo rather than requested of the
  agent in prose.

  *For parked sessions the worked example resolves more strongly than "the check yields a
  verdict; the repo decides what the verdict warrants" — the repo authors the entire check.
  The [wake program](2026-07-26-fleet-supervision-wake-program.md) (P1-2) owns
  fact-gathering, verdict, and warrant alike, in the project's own vocabulary, including
  project-local state (markers, claim conventions) the app could never know. The
  fact-versus-warrant line is unchanged for everything the daemon still derives: session
  state and work facts, which feed the account.*
- **P1-5 [both]** As an operator, I want decisions I have already made remembered durably
  for the rest of the shift, so that I am never re-asked a question I answered an hour ago.
- **P1-6 [A]** As an operator, I want the supervisor to re-check an agent shortly after
  intervening (on the order of a minute, not the next full cycle), so that an agent that
  advanced to a confirmation prompt doesn't hang there for fifteen minutes.
- **P1-7 [both]** As an operator, I want every supervisor action recorded in a durable,
  queryable ledger — what, to whom, why, when — written by the machinery that performed it,
  so that the morning account is verifiable and not merely the supervisor's self-report.
  *(implied, not yet implemented — today's action log is the agent's own notes file.)*

  The ledger's honesty must run in both directions. Daemon authorship protects against a
  desk overclaiming what it did; the mirror-image failure, observed in the field, is a
  transport that reports success into a dead pane, letting the daemon write "drove agent X"
  for a message nobody received — a false line no desk authored. The resolution (design §4,
  §12) is a ladder of claims: an action line asserts the **request** and is appended
  durably before dispatch, so no crash can produce an act with no record; the adapter's
  synchronous return records dispatch, refusal, or transport failure, with `terminal.send`
  itself returning honest errors for dead or misidentified panes; and delivery is a later
  passive machine observation (a sentinel envelope carrying the action's ledger ID, found
  in the target's own transcript — no cooperation from the receiving agent) recorded as an
  outcome line. An action with no confirming outcome by its deadline renders as unconfirmed
  at query time, and observation deadlines derive from the durable lines themselves, so a
  mid-shift daemon restart resumes overdue observations from the record rather than
  carrying recovery state; what to do about a stale unconfirmed action is playbook
  judgment, not compiled repair.

### P2 — maturity

- **P2-1 [both]** As the supervisor, I want standing rules I learn during operation ("this
  repo rejects unsigned commits") recorded somewhere durable that the tool never clobbers,
  so that each shift is smarter than the last.
- **P2-2 [both]** As an operator, I want ending a shift to be a deliberate, clean handover —
  summary posted, supervisor session disposed of or parked on purpose — so that watch-desk
  worktrees don't silently accumulate forever.
- **P2-3 [A]** As an operator, I want agents that stall on routine permission prompts
  advanced past an operator-authored allowlist of safe approvals — and never past anything
  else — so that a trivial "allow this read?" doesn't cost a night.

  *As written, this story presumes a mechanism — matching an operator's
  allowlist against a rendered dialog — that the design refuses, for the same reason it refuses
  to keystroke-drive the Channels consent prompt: it requires screen-scraping or blind key
  timing, and it defeats the dialog while leaving it in place. The design satisfies the
  story's intent by other means. Permission behavior is decided at the source — the
  agent's own config: the repo's committed settings plus the operator's per-repo settings
  overlay, which TBD delivers and never counter-configures. The spawn-time bypass flag
  removes only *default* permission checks; a repo's explicit `permissions.ask` rules still
  prompt, deliberately, because they are that repo's chosen human gates. Config-answerable
  dialogs are pre-answered by seeders before spawn. The precise scope of "never advanced,
  never auto-granted" is what the story most needs restated: it binds **compiled machinery**.
  TBD builds no per-project prompt-approval layer — no matcher, no allowlist, no auto-grant,
  nothing standing beside a repo's permission config and contradicting it — and never will.
  What still happens is *judgment*: a stalled prompt reaches the supervisor as a case (via
  Claude Code's `Notification` hook event), and answering it is an ad hoc act through the
  `drive` verb, guided by its project's mode and playbook, which advise escalating when unsure and treat
  prompts guarding merges or credentials as deserving a human. Nothing about that act
  accumulates into a standing approval. Recurrence is the signal: when the account shows the
  same prompt driven night after night, the fix is a reviewed change to the repo's own
  permission config — the tangle removed where it was created, complexity draining toward the
  source instead of pooling in TBD. A repo that means "a literal human, never a model" says so
  in its playbook — advice, like all conduct, with nothing enforcing it (there are no rules of
  any kind to bind; see the P0-3 descope above and design §3). "Never past anything else" thus
  holds where it must — in the machinery, which ships no prompt-approval layer — without
  pretending a delegate cannot exercise judgment. See the design doc §2.*
- **P2-4 [A]** As an operator, I want runaway agents — looping, burning quota without
  progress — detected and flagged (or paused, in autonomous mode), so that one wedged
  session doesn't eat the shift's budget.

### P3 — genuinely nice-to-have

- **P3-1 [A]** As an operator, I want an optional heartbeat that survives the daemon being
  down entirely, so the safety net doesn't share fate with the process it watches.

  *The waking half of the safety net has this property by construction — the wake program
  (P1-2) schedules itself outside the daemon, so its detection loop survives the daemon
  being down (actuation still needs the daemon up, which is all this story ever asked).
  Live-session supervision — the sweep and the desks — still
  shares the daemon's fate; whether that half needs an external heartbeat remains open, and
  the outside-first rule above says any answer starts as an external program too.*

### Behaviours of the current system that are accidents, not requirements

Left out of the stories deliberately; do not design for them:

- The merge-gate half — clearance ledger, audit-of-would-merge rows, compiled size ceilings.
  Excluded by mandate below; being deleted, not replaced.
- The specific tick protocol: a 15-minute interval, a subprocess exit code as the entire
  signal channel, discarded stdout. Cadence is a requirement; this encoding is not.
- Identifying the supervisor's worktree by its display string.
- Classifying agent state by regexing captured pane text — this is the constraint below, not
  a requirement; the current sweep does it and is marked as debt in the tree.
- The one-shot "shift ending" prompt that is blind to which mode is ending, and the desk
  worktree being left behind because its cleanup path has no caller.
- Three divergent install trees for the supervisor's playbook and scripts, one of which the
  tool never writes.
- Everything organization-specific in the shipped playbook: a repo slug, a review-bot login,
  a coworker's name, one machine's fleet snapshot. Data, not design.

## A note on mechanism — material, not a mandate

**A standing bias, stated so you can argue with it rather than absorb it silently.** Where a
behaviour could either be compiled into the app or exposed as an extension point that someone
authors outside it, prefer the extension point. The subsystem being replaced is the case
against the alternative: it grew a large amount of bespoke compiled machinery to serve what was
substantially one team's process, and the process ended up welded into a general-purpose tool
where nobody else could change it and its own author could not edit it without being
overwritten. Compiled code should earn its place by being genuinely universal — a fact everyone
needs, a correctness property, a surface. Judgement should be authored. If you conclude some
piece of judgement really does belong compiled, say why it is the exception.

Where repo-authored policy (P1-4) physically lives is yours to decide, but decide it
explicitly rather than by default. The relevant facts:

TBD already has a hook system with exactly the three-tier precedence this brief requires, a
timeout-bounded executor, a CLI, and a settings editor. It already gates: the setup hook blocks
primary terminals from spawning until it finishes, and there is a pending state for that wait.
So a blocking pre-wake hook would be a new *event*, not a new semantic.

Two things complicate the obvious move of making everything a hook.

**Hooks currently answer yes-or-no.** The executor surfaces an exit status and captures output,
but no event consumes that output as data. A wake decision wants an answer *plus* a payload:
which verdict, what to say, or escalate instead. That extension does not exist yet, and it is
the same extension any richer event would need — worth designing once rather than per event.

**Cadence.** Hooks fire today at rare moments: a worktree is created, a worktree is archived.
Supervision is a recurring sweep. Forty parked sessions on a fifteen-minute cycle is forty
subprocess spawns per cycle, all night, to answer what is usually a lookup — *this verdict, in
this mode, warrants that*.

That asymmetry suggests a split rather than a single mechanism: something declarative for the
large majority that really is a mapping, with a hook as the escape hatch for what a table
cannot express — do not wake anything during a deploy freeze, check whether I am on call, ask
an internal system whether this ticket is still live. TBD already splits along a similar line
elsewhere: structured settings the daemon resolves get a database column, user-authored blobs
get a file. Argue for whatever you conclude, including that this split is wrong.

## Delivery is assumed — but not as a single protocol

Getting a message into a running agent session is out of scope; assume an adapter exists per
agent kind. Two real mechanisms have been investigated, and they are worth knowing about
because their differences are what you should design against.

For Claude Code, the research-preview **Channels** interface: an MCP server bound to the session
emits a notification, and Claude Code starts a turn from it. Crucially it does not write into
the composer — in testing, a message arrived while an unsent human draft was present and the
draft survived byte-for-byte. Findings, including the caveats:
`https://github.com/cheapsteak/tbd/blob/b0e3ab35ef677fc6788920eef687d4df7f13257e/docs/research/2026-07-26-claude-code-channels/findings.md`
and the upstream docs at `https://code.claude.com/docs/en/channels`.

For Codex, the app-server protocol (`https://learn.chatgpt.com/docs/app-server`) instead exposes
request-shaped operations: steer input into the active turn, start a turn when the thread is
idle, and a completion notification to wait on. Steering carries an expected-turn identifier, so
the request *fails* if the turn changed underneath it.

**What you may rely on everywhere.** Delivery reaches the one session it was addressed to.
That holds for every adapter, and the design may lean on it without further thought.

**What you may rely on only where a channel exists: leaving a human's unsent text alone.**
Both mechanisms above deliver without touching the composer, so where one of them is the
adapter, a half-typed human draft survives untouched — the mechanism provides that safety,
and the design does not have to earn it. But not every agent offers such a mechanism. Where
the adapter is typing into the terminal, that safety does not exist: typed delivery can
submit a human's unsent draft together with the message — words the human never sent. A
design that delivers by typing must say so, name this risk plainly, and state what limits
it; it may not quietly borrow the safety of a channel it is not using.

**What you may not.** That the call itself tells you the message was received. One mechanism
pushes without acknowledgement; the other is a request that can fail on a turn race; neither
generalizes to the other. Acknowledgement is available — the delivered message becomes visible
in the session's transcript, and agent-side hooks can signal receipt — but it is a *separate
observation you choose to make*, not something the send hands back. If your design needs to know
a message landed, say how it finds out.

**And do not weld to either.** Two agent kinds already need two different adapters with
different guarantees, and a third will differ again. Whatever supervision asks for should be
expressible in terms of the properties above rather than any one protocol's verbs.

## Hard constraints

- **Never infer agent state by reading rendered terminal text.** Screen text is a display
  surface, not an API — scraping breaks silently when the TUI changes and couples TBD to one
  agent version. State comes from machine interfaces: Claude Code's lifecycle hooks, its
  structured transcript on disk, tmux control-mode events, process exit codes, TBD's own DB.
- **Nothing repo-specific may be compiled into the app.** TBD is general-purpose; the current
  implementation's worst defect is one company's org policy, repo slug, review-bot name, and
  a coworker's name shipped as string literals and rewritten over the operator's own edits on
  every boot. Repo-specific process lives in artifacts the repo or operator authors, and the
  tool must never clobber them.
- **Reuse TBD's existing three-tier config precedence** — operator-local-per-repo, then
  checked-into-the-repo, then app-global default; first match wins, no merging — rather than
  inventing a new resolution scheme.
- **Anything stateful must survive daemon restart** — the posture, decisions the operator has
  already made, the action ledger, anything the account is later derived from. The daemon
  restarts often, sometimes mid-shift; state held only in memory is state you do not have.
- **Unknown state degrades to inaction plus a loud report**, never to a guess. This puts a
  requirement on the vocabulary itself: whatever the app derives about a session must be able to
  *express not-knowing* as a distinct outcome, not fold it into a confident one. That
  distinction is app-side and not repo-authorable — a shared vocabulary is what lets anything
  reason across repos or render a fleet at all. What a repo may decide is what not-knowing
  *warrants* (do nothing, look again later, escalate) and what gets said about it. A repo can
  have any behaviour it likes on uncertainty; it must not be able to make the app claim
  certainty it never had.

## Out of scope — design nothing for these

- Whether a change may merge or ship. That authority is delegated to GitHub — branch
  protection, required checks, auto-merge. The compiled merge-gate half of the current
  implementation is being deleted outright.
- Judging code or review quality.
- Choosing what new work to start, or backlog prioritization.
- Mutual exclusion or ownership arbitration between concurrent actors. Solved elsewhere.
- Rate limiting and deduplication of interventions, and interrupt safety around them. Solved
  elsewhere; assume an intervention is delivered once, at a safe moment.
- How a mid-shift daemon restart appears to the supervisor. Deferred; assume a restart does not
  disturb it.
- Notifying the operator that something happened, on any channel — in-app, macOS, or reaching
  them off-machine. Addable in isolation once the mechanism exists; assume a way to raise a
  notification is available.
- Per-session "never touch this session" designations. Deferred to its own design pass with
  its own brainstorm; the design's actuation preconditions are the seam such a flag binds to
  when it lands.
- Which model runs which part of the work, and any cheaper triage tier beneath the supervisor.
  Solved separately.
- How the app's appearance reflects the posture, and the chrome showing posture and supervisor
  liveness. Already built; assume both exist.
- The default-off flag the subsystem ships behind. A house rule with a known shape; assume it is
  in place.
- Proving destructive operations such as archival are safe.
- The mechanics of delivering a message into a live agent session. Assume a delivery adapter
  exists; see "Delivery is assumed" below for which properties you may rely on, where each
  holds, and the one you may not.

## Deliverable

Write a markdown design document to:

```
/private/tmp/claude-501/-Users-chang-tbd-worktrees-tbd-20260725-condemned-anteater/485FD618-0F5B-4488-9741-9AE2A112DC68/scratchpad/fleet-supervision-design.md
```

Sections it needs:

1. **The problem in your own terms** — including which part you judge actually hard.
2. **Compiled Swift vs. the supervisor's own prompt and tools.** The supervisor is a
   reasoning agent; every threshold, state derivation, cooldown, and policy rule could
   plausibly live on either side. State the test you use to place each thing, and apply it
   explicitly to at least: state derivation, intervention thresholds, cooldowns and dedup,
   per-repo policy, mode enforcement (P0-3), and the shift/morning account. This section is
   required regardless of your structure.
3. **The state model** — what the daemon can actually know about each fleet agent from machine
   interfaces, what it cannot know, and how the design behaves at the boundary. This is P0-5
   worked out: name the interface each state comes from, and its cost, since the whole design's
   affordability rests on the answer.
4. **The two modes** — what mechanically differs, and how the human-in-the-loop promise of
   supervised mode is enforced rather than requested.
5. **Where policy lives** — who authors what, in what artifact, resolved through the
   three-tier precedence; what the tool ships as its own default and how it seeds without
   ever clobbering. Draw the fact-versus-warrant line explicitly (P1-4), and make the
   mechanism choice from the note above an argued decision rather than an assumption.
6. **Persistence and restart** — what state exists, where it lives, what a mid-shift daemon
   restart looks like from the supervisor's chair.
7. **The account** — the running record first: what it contains, who appends to it, at what
   granularity, and what it is never allowed to claim. Then the shift wrap-up and morning
   report as views derived from it. If your design has the supervisor writing the summary
   rather than the record producing it, argue for that explicitly.
8. **Operator surfaces** — posture control, visibility, escalation intake; sketch intent,
   don't design screens.
9. **What you deliberately did not build, and why.**
10. **The strongest argument against your own design.**

Aim for a document a senior engineer would argue with productively: decisive, specific,
opinionated. Where a requirement above and your judgment conflict, say so and argue — the
stories are extracted from a flawed system and are themselves open to challenge, but silence
is not a challenge.
