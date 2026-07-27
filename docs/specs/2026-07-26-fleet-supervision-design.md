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

## 8. Capacity awareness (P1-1, decomposed)

- **P0 — never poke a rate-limited agent**: free; that's session state.
- **P1 — fleet-wide hold**: several agents capped at once → hold interventions
  until the window resets. The per-profile usage snapshots already exist in the
  daemon.
- **P2 or never — cross-account rebalancing**: not compiled, ever. It presumes
  a multi-account topology and is a workflow judgment. If it exists, it is a
  playbook instruction to a supervisor that already has the usage facts.

## 9. Not yet walked

- **Shift lifecycle (P2-2)** — who creates the supervisor session, shift start,
  clean handover, disposal of the desk worktree. *(not yet walked)*
- **Operator surfaces** — posture control, queue intake, escalation UX sketch.
  *(not yet walked)*
- **Delivery acknowledgement** — how the design observes that a dispatched
  message actually landed (the brief allows relying on targeted, draft-safe
  delivery but not on send-success; the answer will be an observation, likely
  the re-check reading transcript/state, stated explicitly). *(not yet walked)*
- **Runaway detection (P2-4)** — the cheap-signal half. *(not yet walked)*
- **Out-of-band heartbeat (P3-1)**. *(not yet walked)*
- **The strongest argument against this design** — owed by the brief's
  deliverable outline; to be written once the above close. *(not yet walked)*
