# Fleet supervision — design (living draft)

Status: **complete draft, pending operator review.** Captures the decisions
settled in the design conversation of 2026-07-26, after a plain-language
editing pass. Companion to
[`2026-07-26-fleet-supervision-requirements.md`](2026-07-26-fleet-supervision-requirements.md),
which carries the stories (P0-1 … P3-1) this doc cites. This is the ideal-state
design; migration from the current implementation is deliberately out of scope
and will be planned separately.

## 1. The placement test

"Compiled vs. prompt" is the wrong distinction. Behavior can live in three
places. Each place has its own test:

- **Compiled (daemon)** — facts and safeguards that must hold no matter what a
  model says. These include deriving state, gathering facts, enforcing the
  operating posture, keeping the ledger, verifying facts before sending, and
  scheduling. Ask two questions: *If this were wrong, would the rest of the
  system be built on a lie?* And: *Must it run for forty agents every cycle
  without calling a model?*
- **Authored artifacts (files, resolved through three tiers)** — choices on
  which two reasonable repositories or operators could differ. Examples
  include what counts as stuck, local rules, and what response a situation
  calls for. Team-specific behavior cannot be compiled. It also cannot be left
  for the supervisor to invent, because invented judgment cannot be reviewed,
  versioned, or passed between shifts.
- **The supervisor's reasoning** — only decisions that require reading text
  produced during the current shift. These include choosing a context-aware
  next step from an agent's actual transcript (P0-7), sorting and wording
  escalations, and making judgment calls that policy explicitly assigns to the
  supervisor. A threshold or state calculation placed in the prompt is a fact
  disguised as judgment.

The requirements brief names six specific items and asks where each one landed.
The applications appear throughout this document; this table collects them for
a quick audit:

| Named item | Home | Where argued |
| --- | --- | --- |
| State derivation | Compiled. It is fact; a wrong answer poisons everything downstream, and it runs for the whole fleet every cycle. | §2 |
| Intervention thresholds | Compiled default numbers, global. Per-repo tuning is deliberately deferred (§15). Crossing a threshold produces a case; the response is judged. | §2, §13 |
| Cooldowns and dedup | Excluded by the brief (solved elsewhere). The sliver in this design — "intervention already in flight" and "re-check pending" checks — is compiled into the sweep. | §4 |
| Per-repo policy | Authored: the playbook (advisory prose) plus standing rules (binding, operator-ratified). | §5, §8 |
| Mode enforcement (P0-3) | Compiled: the verb gate. Capability gating, never prompt wording. | §3 |
| The shift/morning account | Compiled: a ledger written by the verb handlers; views are queries; the supervisor adds attributed notes only. | §6 |

**This placement means the daemon, not the supervisor, drives the loop.** A
compiled sweep follows the same pattern as the existing hibernation sweep: a
cheap polling tick and a pure decision function. It calculates state, applies
the mechanical reasons not to act, and wakes the supervisor only when it has a
work order. Waking the supervisor is the result of a check, never the way the
check is performed (P0-6, P1-2). The supervisor never polls or sweeps, and it
never writes state or history directly. The daemon never makes a judgment.
Information and commands flow in one direction: daemon → work order →
supervisor → verb → daemon.

## 2. State model (P0-5, decomposed)

The original requirement is too large as written. Split it by priority:

**P0 — session state.** Record what each agent is doing now: `working`, `idle`,
`awaiting input`, `rate-limited (until?)`, `parked (reason)`, `gone`,
`unknown (why)`. Every stored value includes the value, its source, and the
time it was observed. It is never only an enumeration value. This makes
`unknown` honest and traceable. It also prevents downstream code from using an
old fact without seeing its age.

The sources are existing machine interfaces. The Claude hook → command-line
interface (CLI) → remote procedure call (RPC) pipeline provides working, idle,
and awaiting-input events at no added per-event cost. `scheduled_resumes` plus
classification of the end of the transcript identifies rate limits.
`hibernatedAt`/`hibernateReason` identifies parked agents. tmux pane and process
liveness identifies gone agents. This design adds two things:

1. **Verify before intervening, not before displaying.** Hook events are
   accurate enough for the user interface (UI). Before using a state to justify
   an intervention, however, the daemon checks the pane's live process once.
   This requires one tmux subprocess. If the event and live process disagree,
   the result is loudly reported as `unknown`. The daemon never silently picks
   one input.
2. **Install Claude Code's Notification hook** so "awaiting input" carries a
   structured reason. A future list of automatically allowed permissions (P2-3)
   will match this reason. The one-minute re-check (P1-6) will also use it to
   answer, "Did the agent advance past the prompt?"

One more session-state fact comes free from the same source: **context load** —
the tokens currently in a session's context window, read from the last
assistant record's `usage` block at the transcript tail (the same tail read
that already classifies rate limits). The window size (the denominator) is not
in the transcript, so the app carries a small compiled model → window-size
table — a universal fact about models, not about any repo's process. The
statusline is deliberately **not** used as the source: its stdin JSON carries
the same numbers, but claiming the `statusLine` settings key would overwrite a
statusline the operator configured — a display slot the user owns. The data
was always in the transcript; TBD reads it there, and the current pane-read
for context goes away.

**P1 — make existing work facts available overnight.** The daemon already
calculates almost all work state. It gets pull request (PR) status for each
worktree through batched GraphQL requests. It persists `PRStatus`, including
state and a summary of checks. It also sweeps for branch conflicts and detects
merge transitions. Two implementation gaps remain. First, PR fetching runs
only when the app polls, so it stops overnight; move it to the daemon's clock.
Second, a failed fetch looks the same as "no PR"; record
`undetermined (cause)` as a separate result. This needs no new terms or state
calculation.

**P2 — add nothing unless experience proves it is needed.** Do not add verdict
enumerations or a schema for the stages of work. A "work arc" differs by
repository, team, and person. Compiling a fixed set of arcs would recreate the
old system's worst defect. Policy and the supervisor should read the raw facts
the app already has. If operator hooks repeatedly implement the same
calculation in the future, consider moving that specific calculation into the
app.

## 3. The two modes (P0-2, P0-3)

There is one operating posture: **off / supervised / autonomous**. It is a
configuration column in the daemon. It can be set from the app and CLI, is
broadcast when it changes, and survives a restart, just like every other daemon
toggle.

**Enforcement controls capabilities; it does not rely on prompt wording.** The
supervisor acts only through daemon commands, called verbs. In supervised mode,
the daemon turns consequential verbs into proposals. The call succeeds, but
the daemon adds the action to a queue instead of executing it. No prompt can
confuse the supervisor into acting autonomously because the verb cannot execute
in that mode. The verb handlers write ledger rows. The supervisor therefore
cannot misreport its actions because it is not the reporter.

**The human-in-the-loop split: authored *what*, compiled *how*.**
- *What is consequential* is policy (per repo, per verdict) — two reasonable
  repositories can reasonably differ.
- *How a human is involved* uses one compiled mechanism: the
  **approve-before-act proposal queue**. The posture switch applies to the
  entire fleet, so it must make the same promise everywhere. A single queue and
  interaction pattern also let the operator clear the morning queue in minutes
  (P0-10).
- The veto-window variant (act after a cancellable delay) is rejected outright:
  a missed veto allows an action that was never approved. That would silently
  turn supervised mode into autonomous mode, exactly the false promise P0-3 is
  intended to prevent.

Compiled defaults are as conservative as possible. In supervised mode, every
verb that affects the fleet becomes a proposal. In autonomous mode, verbs
execute and questions are collected into escalation batches. Standing rules
(§5) can relax these defaults. Files shipped by a repository cannot.

## 4. The wake-to-action loop

Example flow in autonomous mode at 2:00 a.m. with forty agents:

1. **Tick.** The daemon sweeps the fleet table in its own process. It uses no
   model and starts no subprocesses. It silently skips agents that are working,
   or parked with no outstanding work. It writes no log and wakes nobody.
2. **Hit.** An agent has been idle for 40 minutes and has uncommitted work.
   Before doing anything, the daemon checks the mechanical reasons to stop: a
   never-touch flag, a rate limit, insufficient quota, an intervention already
   in progress, or a pending re-check timer.
3. **Corroborate.** The daemon checks the pane's live process once. If it
   disagrees with the hook state, the daemon records `unknown` in a prominent
   ledger line and stops. It must not guess.
4. **Work order.** The daemon prepares a case file. It includes the agent's
   identity, session state and its age, work facts, the repository's selected
   playbook, and the transcript path. If one tick finds several cases, the
   daemon puts them in one work order and wakes the supervisor once.
5. **Wake.** The daemon delivers the order through the adapter for that kind of
   agent, just as it would for any other session. The supervisor is an ordinary,
   visible session in its own worktree (P0-4). An operator can open its tab,
   watch it think, and type into it.
6. **Judgment.** The supervisor reads the transcript and writes a specific next
   step. It never sends only "continue" (P0-7). This is the loop's only model
   reasoning.
7. **Act through the daemon, never around it.** `tbd supervise intervene …`.
   The daemon performs three steps. First, it **re-verifies** every external
   claim in the message against live sources at send time. An old premise stops
   the send and returns the conflicting facts (P0-8). Second, it **checks
   posture**. In supervised mode, a consequential action becomes a proposal.
   The supervisor uses the same code path in either mode. Third, the daemon
   **delivers** the message through the adapter and **writes the ledger line
   itself**.
8. **Short follow-up.** The act arms a one-minute re-check (daemon timer, in
   memory). The result is added to the action's ledger line. A new blocked state
   becomes a new case within one minute instead of fifteen (P1-6).
9. **Everything else costs nothing.** The other agents: zero tokens, zero sends.

Boundary cases:
- **Supervisor can't decide** → `tbd supervise escalate` with the exact item,
  exact proposed command, and recommendation. Those lines appear unchanged in
  the morning queue. An answer becomes a durable decision and is never asked
  again (P1-5).
- **Supervisor stuck or gone** → it is a session like any other; the same
  machinery watches it. The sweep continues to collect mechanical facts, but
  makes no judgments. It reports the failure prominently. The daemon never
  pretends to provide the supervisor's judgment.

## 5. Where policy lives

**In-repo directory: `.agents/`** — the name describes its audience, not a
specific tool. It contains local process guidance for any tool that drives
agents. TBD owns particular *filenames*, never the directory. It must accept
and never alter files it does not recognize. In the ideal state, worktree
lifecycle hooks also live there (`.agents/hooks/…`), leaving one location in
the repository. `.worktree-hooks/`, `conductor.json`, and `.dmux-hooks/` become
deprecated levels in the lookup order, using resolver machinery that already
exists.

**The playbook — `supervision.md`, prose read by the supervisor.** The existing
three-level lookup chooses it in this order: the operator's per-repository copy
(`~/tbd/repos/<id>/supervision.md`, file-backed editor in the app) →
`.agents/supervision.md` in the repo → the tool's shipped default. First match
wins. The system uses the whole file and never merges levels. Every work order
includes the playbook for each agent. An order spanning two repositories
contains two labeled playbooks.

- **One playbook, not one per mode.** Mode arrives as context in the work
  order; per-mode advice is a prose section ("When running autonomously: …").
  Separate files for each mode would make prompt wording appear to enforce the
  mode and would invite promises the daemon cannot enforce. Any mode-specific
  behavior that must *bind* must become a standing rule that the daemon
  enforces.
- **Seeding without overwriting:** tool-provided content lives only in the level
  the tool owns: the shipped default, which updates may freely replace. The
  operator and repository levels are written exactly once. An explicit
  "Customize playbook…" action copies in the current default, and the tool
  never writes them again. It never reconciles these files at startup.
- The shipped default contains only universals (what stuck means, smallest
  intervention that restores progress, escalate instead of guessing, one
  intervention per agent per wake). It contains no commands, bot names, or
  organization-specific content.

**There is no `supervision.json`.** An earlier draft included a small,
structured policy file for the daemon to enforce. It would have held overrides
for consequential verbs, never-act lists, and thresholds. That content now
lives in the standing-rules store, which the daemon needs anyway:

1. **Compiled conservative defaults** cover a brand-new repo safely.
2. **Operator actions become standing rules**: approving a proposal offers
   "and everything like this" — scoped by verb / repo / worktree, for the shift
   or forever. One row, one click.
3. **Playbook prose promotes by one confirmation**: the first time the
   supervisor encounters a sentence that sounds like a hard rule ("never touch
   an open PR without a human"), it asks once, "make this standing?" A yes
   converts the prose into a logged, binding rule.

This implements one authority principle: **repos advise; operators bind.** A
repository file must not control tool behavior on an operator's machine before
a human approves it. Treating that behavior as normal would be a security
problem. The tradeoff is explicit: a repository cannot ship a binding rule
without one confirmation on each installation. Conservative defaults and the
queue protect the period before confirmation. If teams later need identical
rules on many machines with no confirmation, the promotion flow is the place
to add that capability.

**Specific-session designations (P1-3) are database (DB) flags, not policy
files.** "Don't poke *my* live session" refers to a runtime object that exists
for hours. A UI or CLI action sets a flag for that terminal or worktree,
following the `keepWarm` precedent. The sweep checks the flag mechanically.
Repository files contain rules about *kinds* of things. The DB records operator
choices about *particular* things.

P1-3's other half — *worktrees whose progress matters most get looked at
first* — reuses an existing operator gesture the same way: the worktree
**pin**. The sweep orders cases in the work order pinned-first (the pin state
worktrees already carry), then by case age, and the supervisor works the list
top-down. Pinning is already how an operator marks what matters, so priority
costs no new schema and no new concept. Like every fact, ordering only shapes
attention — it never changes what any verb is allowed to do.

## 6. The account (P0-9, P1-7)

**The ledger is the account; everything else is a view of it.**

- `~/tbd/shifts/<shift-id>/ledger.jsonl` — an append-only file with one
  JavaScript Object Notation (JSON) object per line, written **only by daemon
  code at the moment it acts**. It supports these line kinds:
  **action** records an intervention, wake, or pause, including the message
  text, the state snapshot that justified it, and the posture. A later line
  references the action's ID and records its outcome. **proposal** and
  **resolution** record proposed actions and their results. **escalation** and
  **resolution** record questions and their answers. **decision** records a
  standing rule created from any source. **anomaly** records an unknown state,
  an old premise found during send-time verification, a failed fetch, or a dark
  supervisor. Deliberate inaction is recorded as seriously as action. **note**
  is the only kind the supervisor writes. It is attributed prose added with
  `tbd supervise note`. It may reference other lines but can never change them.
- Its structure prevents several false claims: an action nobody performed
  because only verb handlers write action lines; an outcome nobody observed
  because outcomes come from the re-check; and certainty the system did not
  have because unknowns are anomalies, not values.
- Quiet ticks write nothing. Sweep liveness is one status field, not forty
  lines an hour.
- **`account.md`** sits beside the ledger. The daemon regenerates this view
  after every append, and the side panel displays it live. Nobody writes the
  account directly. The supervisor can only add attributed notes *into* it.
  Markdown is the record's presentation; JSON Lines (JSONL) is its source.
  Markdown cannot be the source because parsing prose back out of a display
  format would repeat the screen-scraping mistake in a file.
- **End-of-shift and morning views are queries** over the shift's time window.
  The views are done (actions + outcomes), open (unresolved proposals and
  escalations), needs-you (the escalation batch), went-wrong (anomalies), and
  now-binding (decisions). A closing supervisor narrative is a final note *on
  top of* the generated report. It adds context but does not author the record.

## 7. Persistence and storage map

Three categories determine where data belongs. **Live coordination state** is
read to allow or block behavior, affects the system's next action, can be
changed by concurrent actors, and appears live. **Append-only history** is
never used to allow or block behavior; an error there produces an inaccurate
account, not a wrong action. The third category is **human-authored process**.

- **DB: the posture. One config column. Nothing else supervision-specific.**
  Every gated verb reads it. Both the app and CLI can set it, and all surfaces
  must see the same value immediately after a change. That is the purpose of
  the shared configuration object.
- **Shift directory** (`~/tbd/shifts/<shift-id>/`): `ledger.jsonl` +
  `account.md`. The proposal queue is **not a separate data store**. It is an
  in-memory view of the ledger: created proposals minus resolved proposals.
  The daemon rebuilds it at startup by replaying the file. It checks expiry
  when the operator approves a proposal by asking, "Is this proposal still
  current?" No background process writes expiry. This removes the only race
  between multiple writers and therefore the need for a table. Shift-scoped
  decisions are ledger events viewed in the same way. They end with the shift,
  and the shift directory contains everything needed for debugging or sharing.
- **Durable files**: `~/tbd/supervision/standing-rules.json` — the rules
  enforced at the command gate, including repo automation membership and its
  default stance (§8). The operator owns the file. It is atomically
  rewritten after each operator action and can be edited by hand. The daemon
  reloads it after a change because these are the operator's rules. It also
  loads the file into memory for per-verb lookups. Every change appends a
  ledger line. The current rules and the history of how they were created
  therefore live in the appropriate places. The playbook tiers (§5) are also
  durable files.
- **In-memory, deliberately not durable**: active one-minute re-check timers
  and the sweep's temporary tracking. A daemon restart during a shift loses
  them. The result is a one-cycle delay, not a broken promise. State used to
  gate an action needs durability only when an operator or mode label has made
  a promise about it.
- **Crash rule** (replay finds an approved proposal with no action line):
  never automatically execute an old approval. Report it as an anomaly:
  "approved at 7:58, daemon restarted before acting; approve again if still
  wanted." This applies the rule that uncertainty must lead to inaction to the
  supervision machinery itself.

Net property: **supervision adds one column to TBD's database.** Everything
else it knows is in files a human can open.

## 8. Remembered things: three kinds, three homes

These categories need precise names because they are easy to confuse:

1. **Binding rules** — enforced by the daemon at the verb gate, no model in the
   loop: `~/tbd/supervision/standing-rules.json`. The format is structured
   because prose cannot be enforced without interpretation. It is local to the
   operator because the operator must approve any rule that binds their daemon
   ("repos advise; operators bind"). Rules are created only by operator actions:
   approval generalization, prose promotion, or CLI. A small settings surface
   makes them inspectable. That surface is a view of the file with a list,
   links to origins, and a revoke action. The file remains the source of truth.
2. **The playbook** — advisory prose, human-curated, travels with the repo
   (`.agents/supervision.md`, three-tier). The tool never writes it after
   seeding.
3. **Learned knowledge (P2-1)** — raw, uncurated prose appended by the machine:
   `~/tbd/repos/<id>/learnings.md`, appended via `tbd supervise learn`,
   ledger line per append, included in every future work order for that repo.
   It takes effect immediately. When an entry proves useful, a *human commit*
   promotes it into the repo playbook. The tool freely rewrites only files it
   owns. The supervisor's desk has no repo checkouts, and the daemon never
   commits to repos.

The categories connect in one controlled way. The supervisor considers a
learning. If it continues to matter and looks like a rule, the supervisor
proposes making it binding. One approval turns it into a standing rule. A
single confirmation connects prose knowledge to binding rules.

### Why the binding tier is structured at all (post-#509 accounting)

GitHub now has merge authority, so few verbs remain behind the gate: send,
wake, pause, and approve-a-prompt. It is reasonable to ask whether prose could
replace the binding tier. It cannot, for exactly four reasons. The design must
not grow beyond what these reasons require:

1. **The supervised-mode promise (P0-3).** The verb gate consults posture and
   rules without using a model. If prose could relax them, the system would
   either remain maximally conservative forever or let the supervisor control
   its own capabilities by interpreting prose. The latter would make the mode
   label a false promise again.
2. **"Never re-ask me" (P1-5).** The daemon's queue would repeat the question.
   Only a remembered approval at the gate can prevent it from asking again at
   3 a.m., 4 a.m., and 5 a.m.
3. **Never-lists must hold when nobody is watching.** When the model is the
   only active decision-maker, a binding rule cannot depend on a prompt.
4. **`intervene` injects instructions.** Fleet agents run with permission
   checks skipped. A supervisor message can contain any instruction for an
   agent with full tool access. Merge authority could move to the code-hosting
   service, but only TBD controls this action. No other system can enforce the
   gate in front of it.

Because the scope is small, the rule store remains a flat list with scope,
verb, stance, and lifetime. It has no language for conditions, no rule
interactions, and no Secure Hash Algorithm (SHA) pinning. The remaining risks
do not justify anything more complex.

The storage decision is settled: standing rules are a **file**
(`~/tbd/supervision/standing-rules.json`), loaded into memory at startup,
checked in memory for every verb, atomically rewritten after each operator
action, and reloaded after a manual edit. "Structured" describes the format and
its reader: the gate cannot interpret sentences. It does not imply database
storage. With tens of rules and one writer at a time, a database adds nothing.

### Repo automation membership (operator-configurable)

Which repos the supervisor may act on is an operator setting, not a design
constant. It has two pieces:

- **A default stance**, chosen by the operator: default-in (every repo is
  automatable unless marked out) or default-out (no repo is automatable until
  marked in). The system ships with default-in, because the autonomous posture
  is already an explicit operator choice and this matches the old system's
  watch-everything behavior; an operator who wants deliberate per-repo
  onboarding flips one control.
- **A per-repo mark**: in, out, or follow-the-default. Only explicit marks
  are stored; a repo with no mark follows the default, so flipping the default
  never requires touching individual repos.

Both live in `standing-rules.json` as entries alongside the verb rules — same
file, same loader, same gate, one source of truth for "may the daemon act
here." Membership is checked before any verb executes **and before proposals
are created**: a repo that resolves to *out* generates no proposals in
supervised mode and no actions in autonomous mode. It still appears in the
fact sweep and the account — observability is never gated, and "repo X needed
attention but is out of automation" is the honest report. Because membership
is enforced at the same model-free gate as the never-lists, it holds when
nobody is watching (reason 3 above).

### Prior art in the current system (and what #509 changed)

Before the redesign, the system represented these concepts in four ways. It
had a hardcoded `STANDING_RULE` prompt string, which compiled one team's
closeout command and review-bot name into the app. This is the exact warning
example from the brief. The merge gate had a `clearance` table with
per-PR, SHA-pinned operator approvals that code enforced. A prompt asked the
desk agent to consult `approved-prs.jsonl`, so it was binding only until the
model forgot, which is the false mode promise described in P0-3. Finally, the
desk's notes file served as both memory and action log, creating the
"self-report" problem in P1-7.

PR #509, merged on 2026-07-26, correctly deleted the merge gate and its
clearance and audit stores because GitHub branch protection now decides whether
a PR may merge. This has two consequences. First, the clearance table is
history, not a reason for this design. Its shape happened to be useful: scoped,
enforced, revocable, and auditable. But the four reasons above provide the full
case for standing rules; deleted code does not. Second, after #509 the system
has **no** enforced mechanism for operator decisions. The verb gate and
standing rules will be the first such mechanism, not an upgrade.

## 9. Shift lifecycle (P2-2)

- **A shift is born from the posture switch, and only from it.** off →
  supervised/autonomous creates a shift ID, creates
  `~/tbd/shifts/<id>/`, writes the opening ledger line, and starts the
  supervisor. A switch between supervised ↔ autonomous during a shift keeps
  the *same* shift and adds a posture-change ledger line. Every action line
  already records its posture. Only switching to off ends a shift.
- **The desk is a scratch space, tracked by ID** rather than by its display
  string. It receives the supervision skill through the plugin mechanism. Its
  first delivered message is an opening briefing with the posture, a summary
  of standing rules, and anything unresolved from the previous shift. The
  daemon gets those unresolved items by replaying the previous shift's ledger.
  Escalations never silently disappear when a shift ends.
- **Shift end is a teardown with a caller.** The sequence is: stop the sweep →
  make a time-limited request for a closing note → render the final
  `account.md` → write the closing ledger line → dispose of the desk by ending
  its session and deleting its scratch worktree. The note adds context but is
  not required; a dead supervisor cannot block closing. All durable data
  already lives outside the desk. Desks accumulated in the old system because
  nothing initiated cleanup. Here, the same operator action that ends the shift
  initiates cleanup.
- **Each shift starts fresh on purpose.** No resumed supervisor context.
  Continuity lives in artifacts: the playbook, standing rules, learnings, and
  earlier ledgers. The *system* learns; one session's context does not. If a
  supervisor dies during a shift, the daemon writes an anomaly line, creates a
  replacement in the same shift, and briefs it with the account so far.
- **Off is meaningful**: no shift exists, nothing observes the fleet, the last
  shift's residue is fully on disk. No half-on states.

### Supervisor context recycling

The supervisor runs all night and receives work orders full of playbooks and
transcripts, so its context grows fast — and a session cruising at a huge
context pays for that context on every turn. Waiting for auto-compaction is the
expensive path. Instead, the daemon recycles the desk deliberately, using the
mid-shift replacement path above. This works because of a decision already
made: the supervisor externalizes everything durable as it goes (ledger,
standing rules, learnings, account, escalations). **Its handoff document
already exists — it is the shift record.**

The sequence, all daemon-driven:

1. **Detect** — the supervisor is a session like any other, so its context
   load is already a session-state fact. Threshold: a config number, default
   around 200k tokens.
2. **Hold** — the daemon stops delivering work orders to the desk. New cases
   queue; the sweep keeps running; the fleet stays watched. The recycle waits
   until the supervisor is idle with no case in flight.
3. **Flush** — a bounded request, same shape as the shift-end closing note:
   "anything in your head not yet in artifacts, write it now as notes or
   learnings." If the supervisor is wedged, the recycle proceeds without it —
   that is exactly the crash path, which was already designed to be
   survivable.
4. **Recycle** — tear down the desk session, spawn fresh into the same shift,
   and deliver the standard replacement briefing (posture, standing rules,
   account so far, open escalations) **plus the predecessor's transcript
   path**. Anything that lived only in the old context — a hunch
   mid-investigation, steering the operator typed earlier — is not lost; it is
   demoted from context to disk, and the new supervisor can search its
   predecessor's transcript on demand without paying for that history on every
   future turn. A ledger line links the old session ID to the new one.

**This runs automatically, in both modes, with no proposal.** Everything else
consequential in this design needs a gesture or a gate; this deliberately does
not. Recycling the desk touches no fleet agent and destroys no work state,
because the desk was built disposable — it is self-maintenance of the
supervision machinery, not an act on the fleet. It appears in the account
("3:12 a.m. — supervisor recycled at 214k context, 4 learnings flushed"), not
in the proposal queue. If a recycle ever loses something that mattered, that
is an artifact-externalization bug to fix — the answer is "that should have
been in the record," never "a human should have approved the recycle."

**Fleet agents are explicitly excluded from this.** Auto-compaction is fine
for them; no handoff templates, recycle flags, or compaction counters exist
for fleet sessions. The per-agent context fact is available for free (§2), and
its only fleet-facing use is informational: a wake case may mention a parked
session's context load, as input to judgment.

*Note on the brief:* the requirements brief deferred supervisor self-handoff
("assume the supervisor persists for the shift"). This section overrides that
deferral by operator decision, and the reason is worth recording: the deferral
assumed handoff was a hard open problem, and the shift-record design had
already solved it as a side effect.

## 10. Operator surfaces (intent, not screens)

Principle: **you take action where you already read the relevant information.**

- **The account panel is also the inbox.** The "needs you" section of the live
  `account.md` *is* the queue. Each proposal shows the target, exact message,
  supervisor reasoning, and age of its state. Approve and reject controls
  appear beside it. Approval also offers scope choices: this once / this shift
  / always for this repo. This is the only user interface (UI) that creates
  standing verb rules; automation membership is managed in the Fleet
  Automation settings tab below. A rejection can include an optional one-line
  explanation,
  which reaches the supervisor in its next work order. Each escalation shows
  the exact item, exact command, recommendation, and an answer box. Every
  action is also a CLI verb (`tbd supervise queue/approve/reject/answer`).
  Nothing exists only as a button.
- **The supervisor's tab stays a plain conversation.** Typed instructions are
  conversation. It steers the session but does not set policy. The two durable
  channels for rules are
  the playbook (advisory) and standing rules (binding); the chat is neither.
  If you type something rule-shaped, the supervisor may propose making it
  standing through the normal ratification path.
- **Fleet automation gets its own Settings tab.** It replaces the current
  Settings section and holds the automation-membership section — the
  default-in/default-out control and the per-repo in/out/follow-default list
  (§8) — alongside the standing-rules inspection surface described next. Both
  are views of `standing-rules.json`, following the house file-backed-settings
  pattern: tilde-abbreviated path shown, copy button, manual edits respected.
  Every control has a CLI twin (`tbd supervise automation ...`).
- **Standing rules get a simple inspection surface** with the rule list, scope,
  origin, and a revoke action. The origin links to the ledger for the shift
  that created the rule. The file-backed view shows the tilde path, provides a
  copy button, and respects manual edits. Its purpose is to answer "why did the
  daemon do that on its own?" at a glance.
- **Morning flow**: open TBD → open the last shift's account → answer the
  needs-you batch in minutes (P0-10). Each answer creates a decision line.
  Each "never again" is a scope choice attached to an answer the operator is
  already giving.

## 11. Capacity awareness (P1-1, decomposed)

- **P0 — never poke a rate-limited agent**: this requires no extra work because
  rate limiting is already session state.
- **P1 — fleet-wide hold**: several agents capped at once → hold interventions
  until the limit window resets. The daemon already has usage snapshots for
  each profile.
- **P2 or never — cross-account rebalancing**: not compiled, ever. It presumes
  a particular arrangement of multiple accounts and requires workflow
  judgment. If it exists, it must be a playbook instruction for a supervisor
  that already has the usage facts.

## 12. Delivery acknowledgement

The send call cannot confirm delivery. One adapter sends without an
acknowledgement, and the other can fail if a turn changes at the wrong time.
The design already has a later observation that can confirm delivery:
**the one-minute re-check also checks acknowledgement.** Every sent message
includes its ledger ID as a marker. During the re-check, the daemon reads two
machine facts: whether the session transcript contains the marker, and whether
the session state changed to `working`. It records one of three results on the
action's ledger line:

- *Landed and acting* — done.
- *Landed but still blocked* — a fresh case within a minute (P1-6).
- *Not landed* — retry delivery once. If the second re-check still finds
  nothing, stop, write an anomaly line, and escalate. Two silent failures
  indicate a structural problem with the session. A third send without
  evidence would risk duplicate-message bugs.

This requires no new machinery. The timer already exists for P1-6, the
transcript path is recorded for each terminal, and the marker is the ledger ID
the daemon already writes.

### Delivery adapters: parity for the fleet, a channel for the desk

Which adapter a session can be reached by is itself a per-session fact, with
the same source-and-freshness treatment as any other fact.

**Fleet agents: `terminal.send` (paste + submit), the mechanism that exists
today.** This is the parity choice. Claude Code's research-preview Channels
interface was validated as a prototype
(`docs/research/2026-07-26-claude-code-channels/findings.md`, landed on
`main` separately): it delivers a
message without touching the composer, but it needs agent-side integration (an
MCP config and a startup flag with per-session consent), which collides with
TBD's no-agent-cooperation constraint for sessions the user owns. Fleet
delivery stays typing; overnight, composers are empty and the draft-safety gap
is theoretical.

**The desk alone: channel-first, with a verified fallback.** The desk is TBD's
own infrastructure — TBD spawns it, owns its configuration, and disposes of
it — so the no-cooperation constraint does not apply, and the desk is also the
one session where a human and the daemon share a composer, which is exactly
where draft-safe delivery pays. At desk spawn the daemon performs a
**handshake**: emit a channel ping, then read the desk transcript for the
channel envelope. Confirmed → the channel is the shift's adapter. Not
confirmed (consent declined, feature removed, registration silently failed) →
`terminal.send` for the shift, with one anomaly line noting degraded delivery.
Mid-shift, the acknowledgement path above extends naturally: a channel send
that fails acknowledgement twice is redelivered by typing and the adapter is
marked degraded. The handshake decouples correctness from the channel's
research-preview status entirely — the feature disappearing in an update
demotes delivery to typing within one re-check cycle, recorded, no human
needed.

A side benefit: channel messages arrive in a typed envelope
(`<channel source kind>`), so work orders and follow-ups are attributable and
distinguishable from operator typing in the same session.

**The consent question — options recorded for a later choice, in preference
order.** The development-channel consent prompt is interactive and
per-session; a 3 a.m. desk recycle has nobody present to answer it. The
options, none decided here:

1. **Approved plugin channel** (plain `--channels`, no dev-consent flow; TBD
   already ships a plugin into every spawn). Caveat: approval requires
   Anthropic review, which is unlikely to be granted for TBD — listed for
   completeness, not counted on.
2. **Pre-seed the consent** if it persists in any config file, following the
   `ClaudeTrustSeeder` precedent (TBD already pre-answers Claude's
   folder-trust dialog for scratch spaces). Legitimate for the desk
   specifically: the consent warns that an external process can inject turns,
   and the desk's external process is the daemon that owns it. Needs
   investigation — "per-session" in the findings suggests it may not persist.
3. **Manual consent when the shift start is attended** — the operator answers
   the prompt once when flipping the posture. Unattended recycles then run
   degraded until the next attended start.
4. **Fallback, always available: typing.** If every route fails, the desk
   runs on `terminal.send` like the fleet, and the account says so.

**Driving the consent prompt with keystrokes is refused**, whatever the
options above yield: it requires either scraping the screen to find the
prompt or blind keystroke timing, and auto-typing "yes" into a consent dialog
defeats the dialog while leaving it in place as theater. Degraded delivery is
the honest failure mode.

## 13. Runaway detection (P2-4)

Compiled counters detect possible runaway behavior; the supervisor judges the
response. Each cycle collects inexpensive facts from interfaces the daemon
already reads. These facts are the number of turns in the current window,
counted from appended transcript JSONL records without parsing their content;
the rate of hook events; and whether commits or the diff stayed unchanged
across N cycles, which the git sweep already knows. Each threshold is a
compiled global default. Per-repository overrides are deliberately deferred
(§15): the old system had none, numeric tuning does not fit the standing-rules
shape (§8 deliberately has no language for parameters), and a new repo-table
column would quietly break §7's one-column property. If real shifts prove a
repo needs different numbers, a repo-table column is the house pattern for it —
added as a conscious amendment to §7, not a side effect.

Crossing a threshold does not itself cause an action. It creates a case in the
next work order, such as "agent Y: 31 turns, no commits in 90 minutes." The
supervisor reads the transcript and decides. If the agent is truly looping, it
uses `pause`. This is a consequential verb, so it becomes a proposal in
supervised mode and passes through the standing-rules gate in autonomous mode.
If the agent is making legitimate progress on a hard problem, the supervisor
adds a note and leaves it alone.

**The design deliberately rejects automatic pauses at a threshold.** Counters
cannot distinguish "burning quota without progress" from "thinking hard."
Pausing a working agent by mistake would destroy trust in overnight
supervision.

## 14. Out-of-band heartbeat (P3-1)

On every sweep tick, the daemon writes a small `status.json` file in the shift
directory. It contains the posture and last-sweep timestamp. The watchdog is an
optional `launchd` job with one rule: *if a shift claims to be active and the
status file has not changed in about 10 minutes, raise a notification.* It
reads a file instead of the socket or DB, so a dead daemon cannot make the
watchdog unavailable. The watchdog never acts on the fleet. It can only alert
the operator; it cannot pretend to be the supervisor. A down daemon therefore
means silence plus an alarm. This applies the rule that uncertainty must lead
to inaction at the largest scale.

## 15. Deliberately not built

- **A verdict enum / work-arc schema** — interpretations of work differ by
  repository, team, and person. A compiled classification would recreate the
  old system's defect.
- **`supervision.json`** — melted into standing rules; repos advise, operators
  bind.
- **Per-mode playbooks** — one playbook receives the mode as context. Separate
  files would invite promises the daemon does not enforce.
- **The act-with-veto-window human-in-the-loop (HITL) variant** — a missed veto
  allows an unapproved action. Supervised mode must not silently become
  autonomous mode.
- **Cross-account rebalancing** — assumes one person's account arrangement. If
  it exists at all, it is playbook prose for a supervisor that already has the
  usage facts.
- **Auto-pause on runaway counters** — see §13.
- **Per-repo threshold overrides** — global compiled defaults only, at parity.
  Numbers do not fit the standing-rules shape, and a repo-table column would
  break the one-column property (§7); if operation proves the need, that
  column is the house pattern for it, added as a conscious amendment. See §13.
- **A supervisor patrol loop** — the daemon drives the loop and wakes the
  judgment layer with work orders. See §16 for the cost of this choice.
- **Repo-shipped binding rules** — binding requires approval from each
  operator. If teams later require shared binding rules, the promotion flow is
  where that capability can return.
- **DB tables for the queue, decisions, or ledger** — the queue is a view
  derived from the ledger, decisions live in a file, and each shift has its own
  JSONL ledger. Supervision adds one column to the database.
- **A supervisor-authored account** — the record produces the summary. The
  supervisor can add context through attributed notes but cannot author the
  account.
- **Fleet-agent context management** — auto-compaction is fine for fleet
  sessions. No handoff templates, recycle flags, or compaction counters for
  agents; the context fact is informational only (§2, §9). Deliberate
  recycling exists solely for the supervisor's own session (§9).
- **The statusline as a data source** — its stdin JSON carries context data,
  but claiming the `statusLine` settings key would overwrite the operator's
  own statusline. The same numbers live in the transcript, which TBD already
  reads (§2).

## 16. The strongest argument against this design

**The judgment layer can only be as insightful as the triggers that wake it.**
The supervisor is strictly reactive. It reasons only about cases the sweep can
detect mechanically, such as idle agents, blocked agents, and counters that
cross thresholds. Anything the sweep cannot describe never reaches the
judgment layer. Three agents failing in the same way for the same system-wide
reason may arrive as three separate cases, or may not arrive at all. A pattern
that develops across the night has no path into a work order. A more expensive
patrolling supervisor might notice such a pattern precisely because it was
looking without being told what to find.

The design makes the system affordable (P0-6) and enforceable (P0-3) by limiting
its only reasoning component to the facts that compiled code measures. If that
limit is too restrictive, operators will ask, "Why didn't the supervisor notice
X overnight?" The place to address that problem is a periodic, low-frequency
digest work order. It would present a fleet-wide summary as a case once every N
cycles. This would restore patrol-like analysis at a limited cost without
reversing the architecture. This document deliberately does not design that
feature. It should be built only when the need is real.

Two secondary honest costs:

- **Cold start.** Conservative defaults and operator approval make the first
  few nights heavy on approvals. The system becomes more useful only as
  standing rules and learnings accumulate. An operator who does not make that
  investment will see a repetitive queue and may decide the subsystem is
  useless. The old system worked on the first night *for its one team* because
  its policy was built into the product. Supporting different teams introduces
  a training cost for each operator. The design assumes confirmation will be
  cheap enough because it appears as a scope choice on an answer the operator
  is already giving. Training should therefore happen during normal use.
- **Safe-and-useless is a quiet failure mode.** The system is designed to be
  honest about uncertainty. If the event pipeline breaks down, the night will
  contain many unknown states and the system will correctly do nothing.
  Anomaly lines call this out in the account. Even so, a broken sensor layer can
  look like an empty, calm night. Distinguishing "nothing happened" from
  "nothing was seen" requires reading the anomaly section. The account renderer
  should make nights with many unknown states visually unmistakable.
