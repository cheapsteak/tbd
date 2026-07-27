# Fleet supervision — design (living draft)

Status: **in-progress brainstorm capture.** Sections marked *(not yet walked)* are
placeholders; everything else reflects decisions settled in conversation on
2026-07-26. Companion to
[`2026-07-26-fleet-supervision-requirements.md`](2026-07-26-fleet-supervision-requirements.md),
which carries the stories (P0-1 … P3-1) this doc cites. This is the ideal-state
design; migration from the current implementation is deliberately out of scope
and will be planned separately.

## 1. The placement test

"Compiled vs. prompt" is the wrong axis. There are three homes for behavior, each
with its own admission test:

- **Compiled (daemon)** — what must be true regardless of what any model says:
  state derivation, fact gathering, the posture switch and its enforcement, the
  ledger, send-time verification, scheduling. Test: *if this were wrong, would the
  rest of the system be building on a lie?* And: *must it run for forty agents
  every cycle without a model call?*
- **Authored artifacts (files, three-tier resolved)** — everything where two
  reasonable repos or operators would answer differently: what counts as stuck,
  house rules, what a situation warrants. If it varies by team, it cannot be
  compiled — and it also must not be left to the supervisor's improvisation,
  because improvised judgment can't be reviewed, versioned, or carried between
  shifts.
- **The supervisor's reasoning** — only what requires reading language produced
  during this shift: deriving a context-aware next step from an agent's actual
  transcript (P0-7), triaging and phrasing escalations, judgment calls policy
  explicitly routes to it. Every threshold or state derivation that drifts into
  the prompt is a fact pretending to be judgment.

**Structural consequence: the supervisor does not drive the loop — the daemon
does.** A compiled sweep (same shape as the existing hibernation sweep: cheap
poll tick, pure decide function) computes state, applies the mechanical outs,
and wakes the supervisor only with a work order. Waking is the conclusion of a
check, never the way the check is performed (P0-6, P1-2). The supervisor never
polls, never sweeps, never writes state or history directly; the daemon never
composes judgment. Every arrow points one way: daemon → work order → supervisor
→ verb → daemon.

## 2. State model (P0-5, decomposed)

The original story is too large as written. Its internal 80/20:

**P0 — session state.** What is each agent doing right now: `working`, `idle`,
`awaiting input`, `rate-limited (until?)`, `parked (reason)`, `gone`,
`unknown (why)`. Every stored value carries three things: the value, its source,
and when it was observed — never a bare enum — so "unknown" is honest and
attributable, and nothing downstream can act on an old fact without seeing that
it is old.

Sources are machine interfaces that already exist: the Claude-hook → CLI → RPC
pipeline (working / idle / awaiting-input; event-driven, zero marginal cost),
`scheduled_resumes` plus transcript-tail classification (rate-limited),
`hibernatedAt`/`hibernateReason` (parked), tmux pane/process liveness (gone).
Two additions over today:

1. **Verify before intervening, not before displaying.** Hook events are good
   enough for the UI. But before a state justifies an intervention, the daemon
   makes one fresh check of the pane's live process (one tmux subprocess). If
   the event and the live process disagree, the result is `unknown`, loudly —
   never a quiet choice of either input.
2. **Install Claude Code's Notification hook** so "awaiting input" carries a
   structured reason. The reason is what a future permission allowlist (P2-3)
   matches against, and what the one-minute re-check (P1-6) reads to answer
   "did it advance past the prompt?"

**P1 — make existing work facts survive the night.** The daemon already computes
nearly all work state: PR status per worktree (batched GraphQL, persisted
`PRStatus` with state + checks rollup), branch/conflict sweeps, merge-transition
detection. Two real gaps, both plumbing: the PR fetch only runs when the app
polls, so it goes dark overnight — move it onto the daemon's clock; and a failed
fetch is indistinguishable from "no PR" — record `undetermined (cause)` as its
own outcome. No new vocabulary, no new derivation.

**P2 — nothing, until proven otherwise.** No verdict enums, no work-arc schema.
A "work arc" differs by repo, team, and person; a compiled taxonomy of arcs is
the old system's worst defect waiting to regrow. Policy and the supervisor read
the raw facts the app already has. If operators' hooks someday keep
reimplementing the same derivation, that specific derivation has earned a look
at graduating into the app.

## 3. The two modes (P0-2, P0-3)

One posture: **off / supervised / autonomous**, a config column in the daemon
(settable from app + CLI, broadcast on change, survives restart — the same rail
as every other daemon toggle).

**Enforcement is capability gating, not prompt wording.** The supervisor acts
only through daemon verbs. In supervised mode the daemon downgrades consequential
verbs to proposals: the call succeeds but enqueues instead of executing. The
supervisor cannot be prompted or confused into acting autonomously, because the
verb physically does not execute. Ledger rows are written by the verb handlers,
so the supervisor also cannot misreport what it did — it isn't the reporter.

**The human-in-the-loop split: authored *what*, compiled *how*.**
- *What is consequential* is policy (per repo, per verdict) — two reasonable
  repos genuinely differ.
- *How a human is looped in* is one compiled mechanism: the **approve-before-act
  proposal queue**. The posture switch is fleet-global, so its promise must mean
  one thing fleet-wide. One queue, one interaction contract, is also what makes
  the morning queue answerable in minutes (P0-10).
- The veto-window variant (act after a cancellable delay) is rejected outright:
  a missed veto is an unsanctioned action — supervised mode quietly becoming
  autonomous mode, the exact label-lie P0-3 exists to kill.

Compiled defaults are maximally conservative: in supervised mode every
fleet-touching verb proposes; in autonomous mode verbs execute and questions
batch into escalations. Relaxation comes from standing rules (§5), not from
files a repo ships.

## 4. The wake-to-action loop

Reference walk (autonomous mode, 2:00 a.m., forty agents):

1. **Tick.** In-process sweep over the fleet table. No model, no subprocesses.
   Agents that are working, or parked with nothing outstanding, are passed over
   silently — no log, no wake.
2. **Hit.** An agent is idle 40 min with uncommitted work. Mechanical outs
   checked first: never-touch flag, rate-limit, quota headroom, intervention
   already in flight, pending re-check timer.
3. **Corroborate.** One live probe of the pane's process. Disagreement with the
   hook state → `unknown` + loud ledger line + stop. Guessing is the forbidden
   move.
4. **Work order.** The daemon composes a case file: agent identity, session
   state + freshness, work facts, the repo's resolved playbook, transcript path.
   Multiple cases in one tick → one work order, one wake.
5. **Wake.** Delivered through the same per-agent-kind adapter used for any
   session. The supervisor is an ordinary, visible session in its own worktree
   (P0-4) — open its tab, watch it think, type into it.
6. **Judgment.** The supervisor reads the transcript and composes a specific
   next step — never a bare "continue" (P0-7). This is the only model reasoning
   in the loop.
7. **Act through the daemon, never around it.** `tbd supervise intervene …`.
   The daemon: (a) **re-verifies** every external claim in the message against
   live sources at send time — a stale premise kills the send and returns the
   discrepancy (P0-8); (b) **checks posture** — supervised + consequential ⇒
   proposal instead, same supervisor code path either way; (c) **delivers** via
   the adapter and **writes the ledger line itself**.
8. **Short follow-up.** The act arms a one-minute re-check (daemon timer, in
   memory). Outcome lands on the action's ledger line; a new blocked state
   becomes a fresh case within a minute, not fifteen (P1-6).
9. **Everything else costs nothing.** The other agents: zero tokens, zero sends.

Boundary cases:
- **Supervisor can't decide** → `tbd supervise escalate` with exact item, exact
  proposed command, recommendation. The morning queue is those lines, verbatim.
  An answer becomes a durable decision — never re-asked (P1-5).
- **Supervisor stuck or gone** → it is a session like any other; the same
  machinery watches it. The sweep keeps accumulating mechanical facts, nothing
  judgment-shaped happens, and the failure is surfaced loudly. The daemon never
  impersonates the supervisor's judgment.

## 5. Where policy lives

**In-repo directory: `.agents/`** — named for the audience, not the tool. House
process for any agent-driving tool; TBD claims *filenames*, never the
directory, and must tolerate (and never touch) unrecognized files there. In the
ideal state the worktree lifecycle hooks live there too (`.agents/hooks/…`),
giving exactly one in-repo location; `.worktree-hooks/`, `conductor.json`, and
`.dmux-hooks/` become deprecated resolver tiers (machinery the resolver already
has).

**The playbook — `supervision.md`, prose, read by the supervisor.** Resolved
through the existing three-tier chain: operator per-repo copy
(`~/tbd/repos/<id>/supervision.md`, file-backed editor in the app) →
`.agents/supervision.md` in the repo → the tool's shipped default. First match
wins, whole file, no merging. Included per-agent in every work order; an order
spanning two repos carries two labeled playbooks.

- **One playbook, not one per mode.** Mode arrives as context in the work
  order; per-mode advice is a prose section ("When running autonomously: …").
  Splitting files by mode would rebuild mode-as-prompt-wording as an authoring
  surface and invite unenforced promises. Anything that must *bind* by mode has
  to earn its way into standing rules, where the daemon enforces it.
- **Seeding without clobbering:** the tool's content lives only in the tier the
  tool owns (the shipped default, freely replaced on updates). Operator and repo
  tiers are written exactly once, on an explicit "Customize playbook…" gesture
  that copies the current default in — and never again. No boot-time
  reconciliation, ever.
- The shipped default contains only universals (what stuck means, smallest
  intervention that restores progress, escalate instead of guessing, one
  intervention per agent per wake). No commands, no bot names, no org anything.

**There is no `supervision.json`.** An earlier draft had a small structured
policy file the daemon would enforce (consequential-verb overrides, never
lists, thresholds). It melted into the standing-rules store, which the daemon
needs anyway:

1. **Compiled conservative defaults** cover a brand-new repo safely.
2. **Operator gestures become standing rules**: approving a proposal offers
   "and everything like this" — scoped by verb / repo / worktree, for the shift
   or forever. One row, one click.
3. **Playbook prose promotes by one confirmation**: the first time the
   supervisor meets a hard-rule-shaped sentence ("never touch an open PR
   without a human"), it escalates once — "make this standing?" — and the yes
   converts prose into a binding rule, logged.

The authority principle this encodes: **repos advise; operators bind.** A repo
file that binds tool behavior on the operator's machine before any human
ratified it was a small security oddity about to be normalized. The trade,
stated honestly: a repo cannot ship rules that bind before one per-install
confirmation; conservative defaults and the queue cover that window. If teams
ever need identical bindings across many machines with zero confirmation, the
promotion flow is the seam it grows back through.

**Specific-session designations (P1-3) are DB flags, not policy files.** "Don't
poke *my* live session" points at a runtime object that exists for hours — a
per-terminal/worktree flag set by a UI/CLI gesture (the `keepWarm` precedent),
checked mechanically by the sweep. Repo files carry rules about *kinds* of
things; the DB carries gestures about *particular* things.

## 6. The account (P0-9, P1-7)

**The ledger is the account; everything else is a view of it.**

- `~/tbd/shifts/<shift-id>/ledger.jsonl` — append-only, one JSON object per
  line, written **only by daemon code at the moment it acts**. Line kinds:
  **action** (intervention/wake/pause: message text, justifying state snapshot,
  posture; outcome arrives as a later line referencing the action's id),
  **proposal** and **resolution**, **escalation** and **resolution**,
  **decision** (standing rule created, any origin), **anomaly** (state went
  unknown; send-time verification caught a stale premise; fetch failed;
  supervisor dark — deliberate inaction is recorded with the same seriousness
  as action), **note** (the one supervisor-authored kind: attributed prose via
  `tbd supervise note`, may reference lines, can never modify them).
- Structurally unable to claim: an action nobody performed (only verb handlers
  write action lines), an outcome nobody observed (outcomes come from the
  re-check), certainty it didn't have (unknowns are anomalies, not values).
- Quiet ticks write nothing. Sweep liveness is one status field, not forty
  lines an hour.
- **`account.md`** sits beside the ledger: a rendering the daemon regenerates on
  every append, displayed live by the side panel. Nobody writes the account;
  the supervisor can only add attributed notes *into* it. Markdown is what the
  record looks like; JSONL is what it is. (Full markdown-as-source is rejected:
  machine-parsing prose back out of a display format is the screen-scraping
  mistake relocated to a file.)
- **End-of-shift and morning views are queries** over the shift's window: done
  (actions + outcomes), open (unresolved proposals/escalations), needs-you (the
  escalation batch), went-wrong (anomalies), now-binding (decisions). A closing
  supervisor narrative is a final note *on top of* the derived report — color,
  not authorship.

## 7. Persistence and storage map

The distinction that places everything: **live coordination state** (read to
gate behavior — an input to the system's next action — mutated by concurrent
actors, rendered live) versus **append-only history** (never read to gate
anything; wrongness causes wrong retellings, not wrong actions) versus
**human-authored process**.

- **DB: the posture. One config column. Nothing else supervision-specific.**
  It is read on every gated verb, settable from two surfaces, and must be seen
  identically by all of them the instant it changes — the config singleton's
  job description.
- **Shift directory** (`~/tbd/shifts/<shift-id>/`): `ledger.jsonl` +
  `account.md`. The proposal queue is **not a store** — it is an in-memory
  projection of the ledger (created minus resolved), rebuilt on boot by
  replaying the file. Expiry is *computed at approval time* ("is this proposal
  still current?"), not a background writer — which removes the only
  multi-writer race and with it the argument for a table. Shift-scoped
  decisions are ledger events projected the same way; they die with the shift,
  and the shift directory is self-contained for debugging or sharing.
- **Durable files**: `~/tbd/supervision/standing-rules.json` — the
  gate-enforced rules, operator-owned, atomically rewritten on each gesture,
  hand-editable (they are the operator's rules; the daemon reloads on change),
  loaded in memory for per-verb lookups. Every change also appends a ledger
  line, so current-rules and how-they-got-here live in the right places.
  Plus the playbook tiers (§5).
- **In-memory, deliberately not durable**: armed one-minute re-check timers and
  the sweep's transient tracking. A mid-shift daemon restart drops them; the
  cost is a one-cycle delay, not a broken promise. Not everything that gates
  deserves durability — only what an operator or a mode label has promised.
- **Crash rule** (replay finds an approved proposal with no action line):
  never auto-execute a stale approval. Surface it as an anomaly — "approved at
  7:58, daemon restarted before acting; approve again if still wanted." The
  unknown-degrades-to-inaction constraint applied to our own machinery.

Net property: **supervision adds one column to TBD's database.** Everything
else it knows is in files a human can open.

## 8. Remembered things: three kinds, three homes

Naming this precisely because the categories blur easily:

1. **Binding rules** — enforced by the daemon at the verb gate, no model in the
   loop: `~/tbd/supervision/standing-rules.json`. Structured because prose
   cannot be enforced without interpretation; operator-local because a rule
   that binds the operator's daemon must be ratified by the operator ("repos
   advise; operators bind"). Created only by gestures: approval
   generalization, prose promotion, CLI. Inspectable in a small settings
   surface (a window onto the file — list, origin links, revoke; the file
   stays the truth).
2. **The playbook** — advisory prose, human-curated, travels with the repo
   (`.agents/supervision.md`, three-tier). The tool never writes it after
   seeding.
3. **Learned knowledge (P2-1)** — machine-appended prose, raw and uncurated:
   `~/tbd/repos/<id>/learnings.md`, appended via `tbd supervise learn`,
   ledger line per append, included in every future work order for that repo.
   Effective immediately; promoted by a *human commit* into the repo playbook
   when an entry proves out. The tool freely rewrites only files it owns;
   the supervisor's desk has no repo checkouts and the daemon never commits
   to repos.

The interlock: a learning is considered; if it keeps mattering and is
rule-shaped, the supervisor proposes making it binding; one approval turns it
into a standing rule. Prose knowledge and binding rules connect through the
single ratification gesture.

### Why the binding tier is structured at all (post-#509 accounting)

With merge authority delegated to GitHub, the verbs left to gate are modest —
send, wake, pause, approve-a-prompt — so it is fair to ask whether the binding
tier could melt into prose too. It cannot, for exactly four reasons, and the
design should never grow past what they require:

1. **The supervised-mode promise (P0-3).** The verb gate consults posture and
   rules with no model in the loop. Prose relaxations would mean either
   maximal conservatism forever or the supervisor self-gating by interpreting
   prose — the label-lie again.
2. **"Never re-ask me" (P1-5).** The thing that would re-ask is the daemon's
   queue; only the gate remembering the approval can suppress the 3 a.m., 4
   a.m., and 5 a.m. repeats.
3. **Never-lists must hold when nobody is watching.** A rule that binds while
   the model is the only mind awake is definitionally not a prompt.
4. **`intervene` is instruction injection.** Fleet agents run with permissions
   skipped; a supervisor message is arbitrary instruction to an agent with
   full tool access. Merging could be delegated to the forge; this action
   surface is TBD's alone, and the gate in front of it is the one piece of
   enforcement nobody else can hold.

Consequence of the reduced scope: the rule store stays a flat list — scope +
verb + stance + lifetime. No conditions language, no rule interactions, no
SHA-pinning. Nothing left at stake demands more.

Storage, settled: standing rules are a **file**
(`~/tbd/supervision/standing-rules.json`), loaded into memory at startup,
consulted in-memory on every verb, atomically rewritten on each gesture,
reloaded on hand-edit. "Structured" is a statement about format and reader
(the gate cannot interpret sentences), not about storage. Tens of rules, one
writer at a time: nothing a database provides is needed.

### Prior art in the current system (and what #509 changed)

The pre-redesign system handled these as: a hardcoded `STANDING_RULE` prompt
string (one team's closeout command and review-bot name compiled into the app
— the brief's cautionary tale, verbatim); the merge gate's `clearance` table
(per-PR, SHA-pinned, mechanically enforced operator authorizations); an
`approved-prs.jsonl` the desk agent was *asked by prompt* to consult (binding
until the model forgets — the P0-3 label-lie at the decision layer); and the
desk's own notes file as both memory and action log (hence P1-7's
"self-report").

PR #509 (merged 2026-07-26) deleted the merge gate and the clearance/audit
stores with it — correctly, since their authority (may this merge?) was
delegated to GitHub branch protection. Two consequences. First: the clearance
table is history, not justification — its shape happened to be right (scoped,
enforced, voidable, auditable), but the case for standing rules stands
entirely on the four reasons above, not on lineage to deleted code. Second:
post-#509 there is **no** enforced operator-decision mechanism in the system
at all — the verb gate + standing rules is the first, not an upgrade.

## 9. Shift lifecycle (P2-2)

- **A shift is born from the posture switch, and only from it.** off →
  supervised/autonomous mints a shift id, creates `~/tbd/shifts/<id>/`, writes
  the opening ledger line, stands up the supervisor. Supervised ↔ autonomous
  mid-shift is the *same* shift with a posture-change ledger line (every
  action line already records its posture). Only off ends a shift.
- **The desk is a scratch space, tracked by ID** (never display string), with
  the supervision skill via the plugin mechanism. Its opening briefing is its
  first delivered message: posture, standing-rules summary, and anything
  unresolved from the previous shift, replayed from that shift's ledger —
  escalations never die silently with a shift.
- **Shift end is a teardown with a caller.** Stop sweep → bounded request for
  a closing note (color, not a dependency — a dead supervisor doesn't block
  close) → final `account.md` render → closing ledger line → dispose of the
  desk (session ended, scratch worktree deleted). Everything durable already
  lives outside it. The old system's desks accumulated because cleanup had no
  caller; here the caller is the same gesture that ends the shift.
- **Each shift starts fresh on purpose.** No resumed supervisor context.
  Continuity lives in artifacts (playbook, standing rules, learnings, prior
  ledgers) — the *system* learns, not one session's context. A supervisor
  that dies mid-shift: anomaly line, replacement spawned into the same shift,
  briefed with the account so far.
- **Off is meaningful**: no shift exists, nothing observes the fleet, the last
  shift's residue is fully on disk. No half-on states.

## 10. Operator surfaces (intent, not screens)

Principle: **you act where you already read.**

- **The account panel is also the inbox.** The "needs you" section of the live
  `account.md` *is* the queue: proposals (target, verbatim message, supervisor
  reasoning, state freshness) with approve/reject inline. Approve offers
  generalization inline — this once / this shift / always for this repo —
  which is the standing-rules mechanism's only creation UI. Reject takes an
  optional one-liner, delivered to the supervisor in its next work order.
  Escalations: exact item, exact command, recommendation, answer box. Every
  action is also a CLI verb (`tbd supervise queue/approve/reject/answer`);
  nothing exists only as a button.
- **The supervisor's tab stays a plain conversation.** Typed instructions are
  conversation — steering, not policy. The two durable channels for rules are
  the playbook (advisory) and standing rules (binding); the chat is neither.
  If you type something rule-shaped, the supervisor may propose making it
  standing through the normal ratification path.
- **Standing rules get a boring inspection surface** — list, scope, origin
  (linking to the creating shift's ledger), revoke. File-backed pattern:
  tilde path + copy button, hand-edits respected. Its job is that "why did
  the daemon do that on its own?" is answerable at a glance.
- **Morning flow**: open TBD → last shift's account → answered down the
  needs-you batch in minutes (P0-10), each answer a decision line, each
  "never again" a scope choice on an answer already being given.

## 11. Capacity awareness (P1-1, decomposed)

- **P0 — never poke a rate-limited agent**: free; that's session state.
- **P1 — fleet-wide hold**: several agents capped at once → hold interventions
  until the window resets. The per-profile usage snapshots already exist in the
  daemon.
- **P2 or never — cross-account rebalancing**: not compiled, ever. It presumes
  a multi-account topology and is a workflow judgment. If it exists, it is a
  playbook instruction to a supervisor that already has the usage facts.

## 12. Delivery acknowledgement

The send call cannot confirm landing (one adapter pushes without ack; the
other can fail on a turn race). Landing is therefore an observation the design
was already making: **the one-minute re-check doubles as the ack read.** Every
dispatched message carries its ledger id as a marker. At re-check the daemon
reads two machine facts — does the session's transcript now contain the
marker, and did session state transition to `working`? Three outcomes, all
recorded on the action's ledger line:

- *Landed and acting* — done.
- *Landed but still blocked* — a fresh case within a minute (P1-6).
- *Not landed* — retry the delivery once; if the second re-check still shows
  nothing, stop: anomaly line + escalation. Two silent failures means
  something structural is wrong with that session, and a third blind send is
  how duplicate-message bugs are born.

No new machinery: the timer exists for P1-6, the transcript path is captured
per terminal, the marker is the ledger id being written anyway.

## 13. Runaway detection (P2-4)

Detection is compiled counters; response is judged. Cheap facts per cycle,
all from interfaces already read: turns this window (appended transcript JSONL
records — a tail count, not content parsing), hook-event churn, and
commits/diff unchanged across N cycles (the git sweep already knows).
Threshold: global default, per-repo override in the DB settings surface (like
the idle threshold).

Crossing a threshold does not *do* anything — it produces a case in the next
work order ("agent Y: 31 turns, no commits in 90 minutes"). The supervisor
reads the transcript and judges: genuinely looping → `pause` (a consequential
verb: proposal in supervised mode, standing-rules-gated in autonomous);
legitimately grinding on a hard problem → note and leave it.

**Auto-pause-on-threshold is refused deliberately.** "Burning quota without
progress" and "thinking hard" are indistinguishable in counters, and pausing
a working agent is exactly the kind of wrong action that destroys trust in
the subsystem overnight.

## 14. Out-of-band heartbeat (P3-1)

The daemon writes a tiny `status.json` in the shift directory each sweep tick
(posture, last-sweep timestamp). The watchdog is an opt-in `launchd` job with
no logic beyond: *if a shift claims to be active and the status file hasn't
moved in ~10 minutes, raise a notification.* It reads a file — not the socket,
not the DB — so a dead daemon cannot take it down. It never acts on the fleet:
a safety net that can only wake the operator, never machinery impersonating
the supervisor. A down daemon means silence-plus-alarm — the
unknown-degrades-to-inaction constraint at the largest scale.

## 15. Deliberately not built

- **A verdict enum / work-arc schema** — work interpretation differs by repo,
  team, and person; a compiled taxonomy is the old system's defect regrown.
- **`supervision.json`** — melted into standing rules; repos advise, operators
  bind.
- **Per-mode playbooks** — mode is context in one playbook; splitting files
  invites unenforced promises.
- **The act-with-veto-window HITL variant** — a missed veto is an unsanctioned
  action; supervised mode must not quietly become autonomous mode.
- **Cross-account rebalancing** — presumes one person's topology; if it exists
  at all it is playbook prose to a supervisor that already has the usage facts.
- **Auto-pause on runaway counters** — see §13.
- **A supervisor patrol loop** — the daemon drives; judgment is woken with
  work orders (see §16 for the cost of this).
- **Repo-shipped binding rules** — binding requires per-operator ratification;
  the promotion flow is the seam through which shared bindings could return
  if teams demand them.
- **DB tables for the queue, decisions, or ledger** — the queue is a
  projection of the ledger; decisions are a file; the ledger is per-shift
  JSONL. Supervision adds one column to the database.
- **A supervisor-authored account** — the record produces the summary; the
  supervisor gets color (attributed notes), not authorship.

## 16. The strongest argument against this design

**The judgment tier can only be as insightful as the trigger vocabulary that
wakes it.** The supervisor is strictly reactive: it reasons only about cases
the sweep can mechanically notice — idleness, blockage, counters crossing
thresholds. Whatever the sweep cannot express never reaches judgment at all.
Three agents failing the same way for the same systemic reason arrive as three
independent cases, or as none. A pattern spanning the night — the kind of
thing an expensive patrolling supervisor might have caught precisely because
it was looking without being told what to look for — has no path into a work
order. The design buys affordability (P0-6) and enforceability (P0-3) by
capping its only reasoning component's field of view at what compiled code
thought to measure. If that cap proves too tight, the pressure will show up as
operators asking "why didn't the supervisor notice X overnight?" — and the
mitigation seam is a periodic low-frequency digest work order (a fleet-wide
summary as a case, once every N cycles), which restores patrol-like synthesis
at bounded cost without inverting the architecture. It is deliberately not
designed here; it should be built when that pressure is real, not before.

Two secondary honest costs:

- **Cold start.** Conservative defaults plus operator ratification means the
  first nights are approval-grinding, and value accrues only as standing
  rules and learnings accumulate. An operator who doesn't invest gets a
  nagging queue and may conclude the subsystem is useless. The old system
  worked on night one *for its one team* because policy was welded in;
  generality was purchased with per-operator training cost. The bet: the
  ratification gestures are cheap enough (scope choices on answers already
  being given) that training happens as a side effect of use.
- **Safe-and-useless is a quiet failure mode.** The substrate's honesty bias
  means that if the event pipeline rots, nights become unknown-heavy and the
  system correctly does nothing. Anomaly lines make this loud in the account
  — but the symptom of a broken sensor layer is an empty, calm-looking night,
  and distinguishing "nothing happened" from "nothing was seen" requires
  actually reading the anomaly section. The account renderer should make
  unknown-heavy nights visually unmistakable.
