# Fleet supervision migration plan

Status: approved direction, companion to
[`2026-07-26-fleet-supervision-design.md`](2026-07-26-fleet-supervision-design.md)
(the target) and [`../nightwatch.md`](../nightwatch.md) (the as-built baseline).
Starting point: `main` after PR #509, which already deleted System A (the merge
gate, `clearance`, `audit_log` — tables dropped by migration
`v60_drop_nightwatch_merge_gate_tables`). What remains to migrate is System B —
the Watch Desk — and the mode plumbing around it.

This document is deliberately about **dispositions, sequence, and gates**, not
line-level edits. Each slice gets its own scratch implementation plan when
someone picks it up (those are never committed; see `docs/CLAUDE.md`).

## 1. Shape of the migration

Almost none of the old code transforms into the new system. The new daemon
loop, on/off switch, ledger, and delivery layer are fresh builds; the old code's
fate is deletion. What genuinely migrates is **state and knowledge**, in four
kinds:

1. **Policy and doctrine** locked inside compiled string literals
   (`NightwatchSkillContent.swift`, `NightwatchDeskPrompts.swift`) and inside
   target repos' `.nightwatch/policy.json` files — each unit moves to the home
   the design assigns it, or is retired (§3).
2. **Runtime artifacts** the desk agent produced (`queue/*`, field-learning
   edits; `handoff.py` was one of these until it was absorbed into the binary) —
   harvested before anything is deleted (§3), and any durable prose among them
   lands in the advisory PR rather than a learnings file (design §8).
3. **Config state**: the `nightwatch_mode` column and the app's experimental
   flag — superseded by the supervision on/off column, orphaned in place (§6).
4. **The desk worktree** — harvested, then archived by hand (§5).

So the plan is: **build new alongside, carry those four across, cut over,
delete.**

### Ground rules

- **Coexistence** (operator decision, 2026-07-26): the frozen System B keeps
  running until the new system passes the parity gate (§5). Something must
  keep working throughout; the freeze notice in the root `CLAUDE.md` keeps the
  old system bug-fix-only meanwhile.
- **Mutual exclusion, compiled**: the daemon refuses to turn the new
  supervision switch on while `nightwatch_mode ≠ off`, and refuses to set
  `nightwatch_mode` while supervision is on, each with an error naming the other
  switch. Two supervisors driving one fleet is never
  valid, and operator discipline is not a mechanism. The second half keys on
  **an open shift as well as the switch**: off is a pause, not an ending
  (design §3), so a paused shift still owns the fleet's record and its desks
  are still alive — `nightwatch_mode` may only be set once the shift is
  explicitly closed. Flipping the old system on under a merely-paused new one
  would put two supervisors on one fleet with the record of the second still
  open.
- **Default-off throughout**: the supervision column ships defaulting to off and
  is the master switch for every new behavior, satisfying the house
  default-off-flag rule. Off is the pause of TBD's authority to act — not a
  mode, and not a shift boundary (design §3); until slice 2 builds a shift
  there is nothing for it to pause, so the distinction costs nothing early.
  The Channels delivery adapter additionally gets its own default-off flag
  (§4, slice 4).
- **One column, and every number compiled.** Supervision adds exactly one
  database column, the switch (design §7). Every threshold the new behavior
  needs ships as a compiled constant (design §13): 40-minute idle, 60-second
  re-check, two sends before anomaly, desk recycle preferred at 50% of the
  effective context window, flush nudges at 50/60/70% fullness, a labeled 200k
  assumption where the window is unknown, a 60-minute dead-man deadline, a
  reroll budget of two consecutive stalled desks per project, 30 turns and 90
  no-commit minutes for runaway, 10 minutes of heartbeat staleness. A slice
  that wants one of these as a config column is amending design §7 and says so
  in its PR.
- **Migrations are append-only.** `nightwatch_mode` is never dropped; code
  stops reading it at deletion time and the column stays as a harmless orphan
  (precedent: the `v61_remote_backends` comment convention after `v60`).
- **House rules that bite here**: the third-party organization name never
  re-enters this tree (use `acme` placeholders; extraction work that handles
  the real strings happens outside TBD's tree), and the two banned words stay
  out of everything.
- **Scoped out: relocating worktree lifecycle hooks to `.agents/hooks/`.** The
  design's ideal state puts them there (design §5), but that move touches the
  whole existing hook system and every repo that ships hooks today. Parity
  requires only `supervision.md` resolution through the three tiers, with
  `.agents/` added as a resolver level (slice 4). The hooks relocation is its
  own future project and blocks nothing here.

## 2. Disposition inventory

As of 2026-07-26 on `main`. File names drift — PR #507 already moved the mode
tint out of Nightwatch-named files into the status bar — so the deletion slice
must re-derive the list by grepping `Nightwatch|Daywatch|nightwatch_mode`, not
by trusting this list.

- **`TBDDaemon/Nightwatch/DaywatchRunner.swift` (loop, tick executor)** —
  Superseded by the new daemon cadence (design §4). Delete at §6.
- **`TBDDaemon/Nightwatch/DeskSessionManager.swift`** — Superseded by the new
  supervisor session lifecycle (design §9). Delete at §6.
- **`TBDShared/NightwatchSkillContent.swift` (1528 lines of embedded policy)** —
  Knowledge-extract in slice 0 (§3), then delete. Retires one of the three
  sanctioned TUI scrapers and its two SwiftLint exclusions.
- **`TBDShared/NightwatchDeskPrompts.swift`** — Doctrine-extract in slice 0,
  then delete.
- **`PluginDirWriter.writeNightwatch()` + the on-disk skill dir** — Delete after
  harvest; the boot-time overwrite disappears with it.
- **`nightwatch.setMode` RPC, `RPCRouter+NightwatchHandlers.swift` (16 lines)** —
  Superseded by the `supervision.*` RPC surface. Delete at §6 (stale-CLI hazard:
  §6). Note `nightwatch.report` is already gone, removed with the audit store by
  #509, so only `setMode` remains to delete.
- **`TBDCLI/Commands/NightwatchCommand.swift`** — Superseded by `tbd supervise
  ...`. Delete at §6.
- **`NightwatchMode` in `Models.swift`, `nightwatch_mode` in `ConfigStore`** —
  Code deleted at §6; DB column orphaned in place.
- **App surfaces: `NightwatchModeToggle`, `NightwatchStatusItem`, status-bar
  tint/badge, Settings "Fleet Automation" section,
  `nightwatchExperimentalEnabled` key** — Superseded by the new on/off control
  and the Fleet Supervision settings tab (design §10). Delete at §6.
- **Tests (`DaywatchRunnerTests`, `DeskSessionManagerTests`,
  `NightwatchDeskPromptsTests`, `NightwatchModeTests`,
  `NightwatchModeToggleTests`, `NightwatchExperimentalGateTests`)** — Delete
  with their subjects.
- **Live runtime dir `~/Library/Application
  Support/TBD/plugin/skills/nightwatch/` (`queue/*` and any edited config files
  — note `scripts/handoff.py` is no longer agent-owned here; it was absorbed
  into `NightwatchSkillContent` and is boot-overwritten like every other
  script)** — Harvest in slice 0, snapshot, then delete with
  `writeNightwatch()`.
- **The "◐ Watch Desk" scratch worktree** — Final harvest at cutover, then
  archive by hand.
- **Target repos' `.nightwatch/policy.json`** — Advisory content folds into that
  repo's `.agents/supervision.md`; the file and directory are then removed from
  those repos (their consumer, `MergeGate`, is already gone).
- **`docs/specs/2026-07-03-nightwatch-daywatch-design.md`** — Keep as history;
  gains a superseded-by banner at §6.
- **`docs/nightwatch.md`** — Keep as the historical baseline; its banner already
  records #509.
- **Root `CLAUDE.md` freeze notice** — Removed at §6 — the freeze ends when the
  old system is gone.

## 3. Slice 0 — harvest and extract (no Swift changes)

This slice is the explicit answer to "migrate the built-in policy docs to the
repo they are meant for." It can start immediately and de-risks every later
deletion.

**Step 1 — snapshot.** Copy the entire live skill dir and the desk worktree's
`queue/` to a dated local archive (not committed anywhere). The boot overwrite
already destroys writer-owned edits on every daemon restart; the snapshot is
the last defense for everything else before deletion.

**Step 2 — triage.** Sort every unit of content — each section of the ten
embedded files, each live-dir divergence from the embedded copy, each entry in
the target repos' `.nightwatch/policy.json` — into exactly one bucket:

1. **Mechanism, superseded** — behavior the new design compiles into the
   daemon. Nothing to copy; the disposition log records the supersession.
2. **Generic supervision doctrine** — tool-agnostic operating wisdom that
   seeds the new TBD-shipped supervisor prompt and playbook template.
3. **Repo-specific advisory** — prose that belongs to one repo; lands as a PR
   to *that repo's* `.agents/supervision.md`, authored outside TBD's tree.
4. **Operator-binding** — **nothing lands here.** This bucket would hold rules
   the daemon enforces with no model in the loop, and the new design has **no
   rules of any kind** (design §3). Content of that shape splits two ways, and
   the disposition log records which way each unit went:
   - Anything that reads as *advice* becomes conduct — bucket 2 or 3.
   - Anything **selection-shaped** — an automation-membership mark — is not
     authored content at all. It is an
     operator gesture, applied **by hand** at setup and recorded in the log as
     applied rather than migrated. Selections have no file to carry across.
   The distinction that matters: content moves between files, selections are
   made. Nothing in this bucket becomes something the daemon enforces.
5. **Stale snapshot / person-specific** — discard, with a line in the log.

Expected dispositions per source (verify against content during execution;
citations are to the baseline doc's §5–§6):

- **`skillMd` (playbook)** — Split: escalation etiquette and operating rules →
  doctrine (2); tier tables, sign-off conventions, project slash-commands → repo
  advisory (3); config-file semantics and the opt-in scheduler → superseded (1).
- **`wakePy` (pre-wake verifier)** — **Doctrine (2), not superseded.** There is
  no compiled dispatch-time re-verification for it to be superseded by: P0-8 is
  authored discipline in both halves. What the script knew — derive the facts live
  immediately before composing, trust a stale MERGED and never a stale OPEN,
  fail closed to "verify first" — seeds the shipped playbook's freshness
  universal (design §5) and the shipped reference wake program
  ([wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md)).
  Its per-repo residue is repo advisory (3).
- **`tickPy` (capture-pane sweep)** — Superseded (1) by the hook-fed state model
  and daemon sweep (design §2). This is the scraper retirement. Its context
  read goes with it: the numerator now comes from the transcript tail's `usage`
  records and the denominator from the statusline tee (design §2, slice 1), so
  no pane is read for context anywhere in the new system.
- **`judgePy` (PR gating for one hardcoded repo)** — Repo advisory (3) for the
  review-bot conventions; the mechanism is superseded (1).
- **`handoffPy` (context-ceiling successor relay)** — Superseded (1) by design
  §9's daemon-driven desk recycling, which externalizes to the shift record
  instead of relaying through a script. Agent-authored, later absorbed into the
  binary — worth one line in the disposition log as the clearest instance of the
  change process §5.3 of the baseline objects to, then discard (5).
- **`tickCronSh` / `schedulerSh` (launchd)** — Superseded (1) by the out-of-band
  heartbeat (design §14) — or discarded if the heartbeat is deferred; the
  shipped copy pointed at a dangling path anyway.
- **`prioritiesTxt`** — Stale fleet snapshot → discard (5).
- **`safeWedgesTxt`** — Discard (5), with a log line: prompt auto-approval is
  structurally removed (design §2's prompt-stalls subsection). The entries are
  at most candidates for source-side allow rules — a repo's own settings or the
  operator's per-repo overlay — should an operator ever want them there, and the
  shipped list, which carried a bare `git` prefix, is too broad to have ever
  been ratified. Nothing from it seeds anything in the new design — there are no
  rules for it to seed (design §3).
- **`dontTouchTxt`** — Never-list entries carry the same force in the new
  design that they actually had in the old — conduct the model reads. Each
  surviving entry becomes playbook prose in the owning project's mode ("never
  touch X without a human") via bucket 2 or 3, and the log records which were
  dropped as stale. A mechanical per-session flag is deferred to its own
  design pass (design §15); if it lands, these entries are its first
  candidates. The frozen pane-ID comment →
  discard (5).
- **`NightwatchDeskPrompts`** — Claim-before-apply and escalation batching →
  doctrine (2), where the design has not already compiled them. The 200k
  respawn rule is **superseded (1)**: §9 recycles per desk at a fraction of the
  session's effective window (design §13), and 200k survives only as the
  labeled assumption for a session whose window is unknown (design §2).
  Person-specific wording → discard (5).
- **Live dir: field-learning edits, `queue/for-*.md`** — Learned prose → **repo
  advisory (3)**, folded into that project's `.agents/supervision.md` in the PR
  step 3 already opens — there is no `learnings.md` destination in the new
  design (design §8); queue files are shift history → snapshot only.
  `handoff.py` is no longer a live-dir divergence — it is embedded and
  boot-overwritten (see `handoffPy` above) — but snapshot-first still applies to
  the whole dir, because which files the writer owns has changed once already
  and the snapshot is what makes that harmless.
- **Target repos' `.nightwatch/policy.json`** — `priorities`, `dont_touch`, and
  the old gate conditions → that repo's advisory playbook (3). Nothing can be
  "promoted to binding" — nothing binds — so an entry that reads
  as a standing decision rather than advice takes one of the two paths above:
  written as conduct prose in the project's mode, or applied by hand as a
  selection (automation mark).

**Step 3 — seed the destinations.** Open the `.agents/supervision.md` PR in
the target repo; record the operator's selections in `supervision.json`
(automation-membership marks and default stance, project topology, mode
choices) — selection-shaped units from bucket 4's triage are applied here and
recorded in the disposition log as applied. There is
no learnings
file to append to — durable prose goes in the advisory PR.

**Exit gate**: the disposition log accounts for every file in the inventory and
records, for each selection-shaped unit, whether the operator applied it or
dropped it; the advisory PR exists; and `supervision.json` parses. There is no
rules file to validate and no binding entries to confirm — nothing binds
(above).

## 4. Build slices

Each slice ships independently, compiles, tests both branches of anything it
gates, and lands nothing autonomous while supervision is off. Dependency order
only — no slice needs a later one:

- **Slice 1 — facts** (design §2). Install Claude Code's **`Notification` hook
  event** (fires when a permission prompt is shown, payload carries the
  "needs your permission" message — not `PreToolUse`, which fires before every
  tool call and cannot signal that a prompt is on screen) as an unconditional
  dumb reporter, and run the work-state sweep on the daemon's cadence. Every
  stored state value carries its value, its source, and its observed-at;
  `unknown` is a value with a reason, never an approximation.
  - **The work facts get their three fixes**: PR fetching moves to the daemon's
    clock so it does not stop overnight; a failed fetch records
    `undetermined (cause)` rather than looking like "no PR"; and the persisted
    `PRStatus` is labeled **display-tier** — it carries its observed-at
    wherever it surfaces, and anything that must be *right* about forge state
    derives it live instead of reading the cache. That labeling is the one new
    compiled obligation P0-8 places on TBD (design §2); everything else P0-8
    asks for is authored discipline.
  - **The context fact comes in two halves, and the denominator is the hard
    one.** The numerator is the last assistant record's `usage` block at the
    transcript tail — the same tail read that classifies rate limits. The
    denominator is a **statusline tee**: the per-session settings overlay
    installs a statusline wrapper that writes the stdin JSON where the daemon
    can read it, then execs the operator's statusline or exits quietly when
    there is none, so nothing clobbers a display slot the user owns. Where the
    tee is absent or has not fired, the denominator is **unknown and reported
    as unknown** — raw counts, never a guessed percentage — and anything that
    needs a number anyway uses the labeled 200k assumption (design §13). No
    compiled model-to-window table, ever (design §15).
  - **The degradation path is a deliverable, not a caveat.** Context machinery
    is a capability, not a dependency (design §9): a session with no tee and no
    readable usage records must yield unknown context and break nothing
    downstream — no thresholds, no flush nudges, no fullness-triggered recycle
    — and a desk driven by an agent that exposes neither (a Codex desk, today)
    must run to shift close on the record-reading layers alone. Test both
    branches; the absent-tee branch is the one that keeps §9's claim honest.
  - **No advance corroboration step.** Nothing here checks a pane before a case
    is cut. A process alive at case-creation time can be dead — or a different
    session in a reused pane — by the time a desk acts minutes later, so
    liveness and identity are the transport's synchronous checks at the moment
    of the act (slice 4, design §12, §15).

  Pure observability; safe to ship while the old system runs because it acts on
  nothing.
- **Slice 2 — the switch, the shift, the ledger** (design §3, §6, §7, §9). The
  `supervision_enabled` config column — a **boolean**, not the old tri-state
  posture (migration + record type + Codable model, one commit, per the house
  migration rule) — the compiled interlock with `nightwatch_mode`, the shift
  directory with `ledger.jsonl` and the `account.md` renderer that regenerates
  after every append, and the shift lifecycle. The ledger envelope
  (`id`, `ts`, `shift`, `mode`, `project`, `kind`) is complete from the first
  line: `mode` carries `attended` until slice 3 ships selections, and lines the
  daemon writes on its own behalf carry a null project, which is the accurate
  answer rather than a gap.
  - **Off is a pause; only an explicit close ends a shift** (design §3, §9).
    Turning the switch on with no shift open creates the shift, its directory,
    and the opening line. Turning it off writes a **paused** lifecycle line and
    stops the sweep cutting work orders; the shift stays open and the record
    keeps filling. Turning it back on writes a **resumed** line and hastens a
    tick, so work is cut from current state and never from pre-pause state.
    `tbd supervise shift close` is the only thing that ends a shift; issued
    with the switch still on it finalizes the record and opens a fresh shift in
    the same gesture. Nothing closes a shift automatically — a shift left
    paused for a day renders loudly as paused, because a lingering state
    degrades to loud display and never to autonomous cleanup. Build both
    branches of the switch and test both: off must refuse to end anything, and
    close must not depend on the switch's position.
  - **Enrollment and the roster** (design §6, §8). The opening line's payload
    carries a roster snapshot — one entry per agent already inside the
    perimeter, with the same fields an `enrollment` line carries — and an
    agent entering a supervised project's perimeter mid-shift gets its own
    `enrollment` line: identity, resolved project, spawn source, transcript
    path. Mechanical facts only. The perimeter is the fleet table, and a
    session TBD did not spawn is reported as outside it rather than implied to
    be covered. With nothing declared, project resolution is the implicit
    singleton; slice 3's loader only adds declared groupings on top.
  - **The `lifecycle` kind covers open, pause, resume, close, mode change, and
    desk recycle** — one kind behind every line design §9 describes.
  - **A restart resumes the shift from the record, never forks it** (design §7,
    §9). The active shift is derivable from the ledger alone: the newest shift
    with no closing line. On startup the daemon resumes it in whatever posture
    the switch persists — running if on, paused if off — with the same ID and
    directory, and rebuilds the escalation-queue projection by replaying the
    file. A half-finished teardown resumes idempotently from its durable steps.
    **No timer is persisted**, because everything a timer encodes derives from
    a durable line's timestamp; the overdue-observation half of that replay
    lands with delivery in slice 4.
  - Shift open spawns no desks by design (design §9 — desks are lazy, born on
    their project's first case in slice 4), so this slice's shift opens,
    pauses, resumes, and closes on its own; no slice needs a later one. Shift
    close gains its dispose-every-desk step in slice 4, when there are desks
    to dispose.
  - CLI: `tbd supervise on`, `off`, `shift close`, `status`.
- **Slice 3 — verbs, `supervision.json`, queue** (design §3, §5, §8, §10).
  Nothing here is gated (design §3) — but ungated is not unchecked, and the
  actuation preconditions below are exactly that difference.
  - **The verbs as RPC, none of them gated**: `drive`, `wake`, `pause`,
    `escalate`, `note`. `drive` takes exactly one payload flag per call,
    `--text` or `--keys` (design §3); there is no `answer` verb, no separate
    key-sending verb, and no `learn` verb. The dialog dismissal that makes
    `--text` work is delivery-adapter behavior landing with the adapter in
    slice 4 (design §2). Around each verb the daemon writes the action line
    itself — payload verbatim, active mode, and the state snapshot that
    justified the act — and arms the one-minute re-check. It reads no message
    content: there is no send-time re-verification of a `--text` payload's
    claims, because freshness is the desk's discipline (design §3, §15, P0-8).
    **Do not build a posture check, a rule lookup, a proposal conversion, or a
    content check** — there are none (design §3), and the ledger has **nine**
    kinds: action, outcome, lifecycle, enrollment, escalation, resolution,
    decision, anomaly, note.
  - **The actuation preconditions are this slice's safety deliverable**
    (design §3, §4 step 6). Ungated speaks to conduct; preconditions speak to
    mechanics. Inside every acting verb call — after the desk decided, before
    any keystroke — the daemon rechecks against *current* state: the switch is
    on, a shift is active, the target lies inside the calling desk's project,
    and the target is neither rate-limited nor under a capacity hold. Each is a
    yes/no fact the operator or the machine already owns; none reads the
    payload or judges the act. A failed precondition **types nothing**, returns
    an ordinary CLI error naming the condition, and writes a refusal outcome
    referencing the action line, so the morning shows near-misses and an
    operator learns their controls bind. This is what makes selection real
    rather than advisory: judgment takes minutes, so a work order's facts are
    already stale at act time, and an off flipped at 2:03 must beat a drive
    decided from a 2:02 order and issued at 2:07.
    - Target liveness and identity are deliberately **not** on this list — they
      are the transport's own synchronous checks milliseconds later in the same
      call (design §12, slice 4). One check, one owner.
    - Two arms fill in later and are built as seams now: addressing needs desks
      (slice 4) and the capacity hold needs slice 6. Test every arm on both
      branches, and test that the record verbs bind to less — `escalate` and
      `note` require only an active shift and correct addressing, so a desk
      interrupted mid-judgment by an off flip can still write down what it was
      about to do.
  - **Request-first ordering, and it is a testable property** (design §4
    step 6, §6, §12). The daemon appends the action line **durably first**,
    then rechecks the preconditions, then dispatches. The line's ID is already
    durable when the delivery envelope quotes it, and no crash window can
    produce a real intervention with no record. The adapter's synchronous
    return writes the second rung as an outcome line — *dispatched*, *refused*
    naming the failed condition, or *transport-failed* — and only an
    **observed** outcome (slice 4) may claim a message landed. Kill the daemon
    between the line and the dispatch: the record must show a request with no
    outcome, rendering unconfirmed at query time, and never an act with no
    line.
  - **The `supervision.json` loader**: project topology (declared multi-repo
    projects and their designated policy source; reject a file where any repo
    appears in two projects; resolve every other repo to its implicit
    singleton), automation membership with its default stance at the project
    level, and the per-project **mode selections**. No `rules` array, no scopes,
    no stances. Test the degenerate case explicitly: with an empty `projects`
    object, resolution, membership, and mode lookup must behave exactly as the
    per-repo design did — that collapse is a stated invariant, not an
    implementation detail. Mutations apply on the **next tick**, and any live
    desk whose project definition changed is recycled through the §9 replacement
    path (design §5), so the loader must expose "which projects changed" and not
    just the new state; that recycle lands with desks in slice 4. A mode change
    needs no recycle — conduct arrives with the next work order.
  - **Mode selection and resolution**: `tbd supervise mode <project> <name>`
    writes the selection and a ledger line; `tbd supervise mode <project>`
    shows the active mode and the choices that project's resolved playbook
    defines. Resolving a mode means reading the named section out of that
    playbook (design §3, §5); a selection naming a section the playbook does
    not define is an operator error to report at set time, and at work-order
    time falls back to `attended` with an anomaly line rather than silently
    running unconducted.
  - **The queue**: the escalation projection over the ledger, plus one
    operator command — `tbd supervise queue [--resolved|--all]
    [--project …]` to read and `tbd supervise resolve <id>
    --approve|--reject|--answer` to act (design §10). All three flags construct
    the same `resolution` kind differing only in `result`, so build one RPC
    rather than three near-identical commands. Those two filters are the whole
    surface: **there is no `--type` filter**, because there is no proposal kind
    to filter by (design §6). `--scope` attaches to `resolve` itself, and its
    values are **temporal only** — `this-once|this-shift`, with no per-project
    or per-repo variant (design §10). Every resolution reaches the owning
    desk in its next work order; `--scope this-shift` additionally writes a
    `decision` line, and **work-order composition must carry the shift's
    active decisions** (design §8) — that delivery, not any gate, is what
    satisfies P1-5. Composition itself lands in slice 4, so the obligation is
    recorded here rather than discovered there. `resolve` is operator-only and
    must not be reachable from a desk, which keeps resolutions off the
    self-report path (design §10).
  - **Decisions are shift-lived, and that bounds what gets built.** A decision
    lives in its shift's ledger and nowhere else: no `decisions.jsonl`, no
    durable decision store, no `--scope always`, and no `decisions list` or
    `decisions revoke` commands — a decision ends with the shift, so there is
    nothing to list across shifts and nothing to revoke that outlives one
    (design §8). An answer worth keeping reaches the project's playbook by
    reviewed PR through the capture flow (design §8, slice 4).
  - **Proposals are prose, and this slice builds nothing for them.** No
    `proposal` ledger kind, no approve/reject pipeline, no execution path for
    an approval, no queue filter (design §6, §15). A desk that holds back on
    something consequential writes markdown into
    `~/tbd/shifts/<shift-id>/proposals/<project>.md` and files a one-line
    `note` beside it — "proposal filed: …, see the doc" — which is how the
    morning account knows the doc is worth opening. TBD compiles the file's
    location and, in slice 5, the app showing it with its path; entry
    composition is the project's playbook choice, and acting on a proposal is a
    human act in the world.
- **Slice 4 — supervisors and delivery** (design §4, §5, §9, §12). Wake
  decision from facts, work-order composition **grouped by project**, desks as
  first-class sessions **one per project, spawned lazily on that project's first
  case and all disposed at shift close**, the compiled **desk→project
  addressing check** (a verb whose target is outside the calling desk's project
  is refused as a routing error — correctness, not authority, design §3; this
  is the addressing arm of slice 3's preconditions, testable at last now that a
  calling desk exists),
  `terminal.send` delivery for
  the fleet, the Channels adapter for desks behind its own default-off flag with
  automatic degrade and a **per-desk-spawn handshake** (not per shift), the
  ledger-marker acknowledgement re-check, **per-desk** context recycling
  preferred at **50% of the session's effective window** with staged flush
  nudges at 50/60/70% fullness (design §13), the **project tag on every ledger
  line**, and the playbook
  resolver — three-tier `supervision.md` resolution run **per project** (the
  operator's project-level copy → the project's designated repo file → the
  shipped default), which includes adding `.agents/` as a level to the existing
  resolver. For singleton projects the operator and repo levels are the existing
  per-repo paths, so the resolver's singleton path is the one that must match
  the old design byte for byte.

  **Recycling is an optimization, never the thing standing between a desk and
  its ceiling.** Auto-compaction stays on for desks and bears survival, so a
  desk whose context machinery reports nothing — slice 1's absent-tee
  degradation path, a Codex-driven desk today — simply never recycles and
  nothing breaks (design §9). Its account shows context as unknown rather than
  guessed. What must hold for *every* desk kind reads the record instead of the
  session's internals: the dead-man's switch below, and briefing a replacement
  from the shift record.

  **Shift close becomes a real teardown here** (design §9, and P2-1/P2-2 at the
  parity gate): stop the sweep → make a time-limited request to each live desk
  for a closing note **and, where the shift produced learning-shaped notes, a
  capture suggestion in that project's proposals doc** (spawn an ordinary
  worker worktree to fold them into `.agents/supervision.md` and open a PR —
  design §8) → render the final `account.md` → write the closing lifecycle line
  → dispose of each desk by ending its session and deleting its scratch
  worktree. A dead desk cannot block closing, and neither can three of them.
  The capture suggestion outlives the desk that raised it, because the
  proposals doc is a file in the shift directory.

  **Desk liveness: the dead-man's switch** (design §9). Detecting a stuck desk
  and only *reporting* it would address an operator who is asleep, so detection
  fires a replacement. Two arms, one deadline (60 minutes, design §13): a work
  order delivered at T with **no ledger line from that desk** by T+deadline —
  no drive, wake, pause, escalate, or note — and a desk `working` continuously
  past the same deadline with nothing ledgered. Ledger silence is the
  observation channel; build no new one. Firing writes an anomaly, then runs
  the replacement path with the flush skipped, and queued and unanswered cases
  redeliver to the successor. **Deadlines suspend while the shift is paused and
  rearm on resume** — an order unanswered during a pause is the system's doing,
  not a dead desk — and **work orders themselves do not survive a pause**:
  anything still true reappears in a fresh order derived from current state.
  The **reroll budget bounds the loop**: after two consecutive stalled desks on
  one project the daemon stops, marks that project dark, holds its cases, and
  makes the anomaly the loudest thing in the account; other projects' desks are
  separate sessions and keep working.

  **The overdue-observation scan completes slice 2's restart story** (design
  §7, §12). Timers stay in memory precisely because everything they encode
  derives from a durable line: an action line's timestamp fixes its
  acknowledgement deadline. At startup the daemon replays the ledger, finds
  actions past that deadline with no outcome, and performs the same observation
  late, writing the outcome the timer would have written. Until it runs, those
  actions render as unconfirmed **by construction** — the query-time rule, not
  a repair pass that appends corrections.

  This slice
  also carries the **two event-driven case flows** (design §2, §4). The
  `AskUserQuestion` one: the
  daemon-side fork in the existing `terminal.askUserQuestionPending` handler —
  the hook itself stays an unconditional dumb reporter and is not touched — so
  that a pending question with a shift active and the terminal's project in
  automation becomes a case for that project's desk and hastens an immediate
  mini-tick for that terminal; work
  orders carrying the question payload verbatim out of `PendingQuestionStore`;
  and the store's TTL treated as a GC backstop that must not expire a still-live
  dialog during a shift. **The closing signal is the transcript record, not a
  hook and not the clock**: a dialog resolves when its `tool_result` lands,
  joined to the question by `tool_use_id`. Measured, not assumed — Escape fires
  **no hook event at all**, so a store keyed on hook events strands an entry on
  the single most common user gesture
  (`docs/research/2026-07-31-askuserquestion-dismissal/findings.md`). That
  findings doc is this build's empirical gate: implement against its
  measurements, and re-measure before trusting them across an agent version
  bump.

  The **dialog-dismissing delivery adapter** lands here too, and its sequence
  is one shape for every question (design §2). A `drive --text` whose target
  sits on a dialog gets ESC-then-paste, but **only when the daemon
  machine-knows the dialog** (a pending `AskUserQuestion` in the store); any
  other on-screen state must make the delivery refuse and write an anomaly —
  never a blind ESC. Between the Escape and the paste the adapter **waits for
  the resolution to appear in the transcript** — the buffered `tool_use` and
  its rejection `tool_result` (`is_error`, a generic "User rejected tool use")
  flush together roughly 200 ms after the keystroke — and the wait is
  **bounded**: on expiry the flow sends nothing, writes an undetermined
  anomaly, and leaves the session alone, because nothing may be typed into a
  session that may still have a modal on screen. There is **no per-dialog key
  choreography** anywhere in this path: no option counting, no digit typing, no
  arrowing to a highlight. Three branches to test — machine-known dialog
  answered, unknown on-screen state refused, bound expiry sending nothing.

  The **`Notification` case flow** is the same shape on slice 1's hook: dumb
  reporter → daemon holds the fact → shift active and project in automation →
  case for that project's desk, event-hastened mini-tick. A permission-prompt
  case is *not* an escalation; whether it becomes one is desk judgment (design
  §2), so build no auto-escalate path for it. The **`drive --keys` payload**
  lands here as well: named-key, paced sends, and the action ledger line must
  carry the screen capture the desk read when choosing the keys — that record is
  the variant's integrity requirement — the evidence every screen-informed act
  owes — so a `--keys` action written without it is a bug, not a thin log line.
  Under `attended` the desk files the suggested keys and the screen they aim at
  in the proposals doc instead of sending them, which is playbook prose, not
  machinery to build here. Two non-blocking notes for
  whoever picks this up: pending questions
  have no CLI read surface today (`terminal.transcript` is RPC-only, and the
  work-order carriage is what makes a read surface unnecessary — a
  `tbd`-side reader would be a debugging nicety, not a dependency); and
  subagent-raised questions are deliberately dropped by the payload parser
  (`isSubagentTranscript`), so they never become cases. Whether that stays is a
  policy decision at implementation time — default: keep dropping them, since
  the parent session surfaces its own questions.

  **Dependency: this slice presumes an honest transport, and today it does not
  have one.** `terminal.send` reports success into a dead pane — the send path
  runs `tmux send-keys` and returns (`TmuxManager.sendKeys`/`sendKey`), and
  `handleTerminalSend` guards only that the terminal and worktree rows exist,
  never that the pane is alive. That masked the Watch Desk nudging a dead pane
  for hours on 2026-07-29; #549 patched it for one consumer, and the general
  fix is what this slice needs:
  - **Fix it at the transport layer, before or with this slice.** Detect dead
    panes from tmux metadata — `#{pane_dead}`, window existence (`windowExists`
    already exists) — and **fail loudly**; surface `pane_current_command` in
    `terminal list`/`output`. This is a machine interface, not screen text, so
    it is the sanctioned kind of knowing (design §2). It belongs in the
    transport because `terminal.send` is a *generic* primitive — humans,
    scripts, and hooks all call it — and supervision must not be the only
    consumer that gets honest delivery. Everything in design §12 (the
    ledger-marker acknowledgement, retry-once, anomaly-and-escalate) is built
    on the assumption that a failed send is *reported* as one.
  - **The same act-time check covers issue #384.** Target identity is verified
    inside the send call, milliseconds before the keystroke — pane IDs are
    reused, so a stale coordinate sends a supervisor's message to the wrong
    live session, and the check is identity, not just liveness. It belongs
    there and nowhere earlier: an advance check made when the case was cut is
    stale by the time a desk acts minutes later, and design §15 rejects that
    step outright. **No slice builds a pane check before creating a case.** The
    two failure classes differ in kind: a dead pane can surface as an error
    from inside the send path (checking `#{pane_dead}` deliberately —
    `send-keys` into a `remain-on-exit` pane succeeds silently), while a wrong
    live pane produces no error by any mechanical measure, so identity must be
    a deliberate comparison before typing.

  **Delivery truth is per adapter, and the typing floor's risk gets named in
  the PR.** What holds everywhere is that delivery reaches the one session it
  was addressed to; what never holds is that the call itself says the message
  was received (design §12, requirements "Delivery is assumed").
  `terminal.send` is the floor because older agent versions and future agent
  kinds may never offer a message channel — and typing carries one risk a
  channel makes impossible by construction: a paste-and-submit into a session
  where a human has unsent composer text submits **the human's words together
  with the desk's**, as one message from the human, into an agent that acts
  without asking. Three things bound how often that happens and none of them
  protects that specific session: the sweep only messages stuck-or-idle
  sessions, the off switch stops delivery while the operator works, and the
  subsystem ships default-off. The per-session never-touch flag that *would*
  protect it is deferred to its own design pass (design §15), and the actuation
  preconditions (slice 3) are the seam it binds to when it lands. State the
  risk plainly in this slice's PR description; do not borrow the channel's
  draft safety for a path that does not have it. The desk-side channel is where
  that safety is real, which is why desks get the per-spawn handshake and the
  fleet does not.

  Design §12 pins the claim ladder this slice completes: the action line
  asserts the **request**, the adapter's synchronous return asserts
  **dispatched / refused / transport-failed**, and only the later passive
  sentinel observation (`<tbd-dispatch id="…"/>` found in the target's own
  transcript, no cooperation from the receiving agent) may claim the message
  **landed** — recorded as one of four outcome results, with retry permitted
  only from positive non-delivery and never from *undetermined*. An action with
  no confirming outcome by its deadline renders as unconfirmed at query time,
  which is also the whole restart story.
- **Slice 5 — operator surfaces** (design §10). The Fleet Supervision settings
  tab — the **projects section** (declare a multi-repo project, pick members,
  designate the policy source, and list ungrouped repos as the singletons they
  are), the per-project **modes** section (active mode plus the choices its
  playbook defines; no selection shows `attended` as the default rather than a
  choice), and the per-project membership section — plus the account panel as
  inbox, showing every desk's escalations in
  one project-labeled queue with each project's proposals doc linked beside it
  and shown with its tilde-abbreviated path (design §6, §10). Each escalation
  carries the exact item, the exact command, the recommendation, an answer box,
  and Approve / Reject / Answer buttons over the one `resolve` RPC, with the
  scope choice — this once or this shift — attached to the answer the operator
  is already giving. There is deliberately **no rules-inspection surface**: the
  question it would answer is answered by the account, where every action line
  carries the mode it ran under and the snapshot that justified it.
  - CLI parity for every control — and the whole `tbd supervise` surface is
    pinned as a normative list in design §10, so this slice's exit check is
    that every command in that list exists with that name and shape, and that
    nothing outside it shipped. Present and easy to forget: `shift close` is a
    first-class command, not a side effect of the switch. Absent and easy to
    smuggle back in: no `rules` commands, no `posture`, no `learn`, no
    `approve-a-prompt`, no `decisions list` or `decisions revoke`, no `--type`
    on `queue`, no per-desk lifecycle commands (spawn, recycle, dispose — desks
    are daemon self-maintenance), and no per-project on/off (that is an
    automation mark). Regrouping is
    `project move <repo> --to <project|singleton>` — no add/remove pair,
    because the pair can express states "exactly one project per repo" forbids.
- **Slice 6 — hardening** (design §11, §13, §14). Capacity holds — which also
  fill in the hold arm of slice 3's actuation preconditions, so that seam's
  second branch becomes testable here — runaway detection on compiled global
  counters (30 turns in the window, 90 minutes with no commits; crossing one
  creates a case and never an automatic pause), and the optional heartbeat: a
  `status.json` written in the shift directory on every sweep tick, carrying
  the switch, each project's active mode, and the last-sweep timestamp, with a
  `launchd` watchdog that alerts and never acts. That file is also the public
  status surface the wake program reads to exit quietly when supervision is off
  (design §3). The heartbeat (P3-1) may be deferred past cutover without
  blocking it.

Soak discipline: after slice 4, run real shifts on the new system with projects
on the `attended` mode (the interlock means the old system is off for those
shifts; alternate if the new system disappoints). At least one clean `attended`
shift and one `autonomous` shift — scoped by automation membership to low-stakes
projects — before the parity gate. **At least one of those shifts must exercise a
declared multi-repo project**, and at least one must run with nothing declared at
all: the singleton collapse and the grouped case are different code paths through
the resolver, the addressing check, and desk spawning, and only the first is
covered by every other shift by default. A night in which two projects both had
cases is the cheapest evidence that per-project desks, project addressing, and
the shared queue actually hold.

Three record boundaries want exercising during the soak rather than waiting for
an incident to produce them, because each is cheap to stage and expensive to
discover broken: **a mid-shift pause and resume** (off, then on — the acting
verbs refuse while the record verbs still land, work orders do not survive the
pause, and dead-man deadlines suspend), **a mid-shift daemon restart** (the
same shift resumes in the persisted posture, and overdue observations are
performed from the record), and **an explicit `shift close` while the switch
is still on** (the record finalizes and a fresh shift opens in the same
gesture).

Because modes do not change daemon behavior (design §3), an `autonomous`
soak shift is evidence about *conduct* — did the desk act where the prose told
it to act — not about a code path. Read those shifts' accounts for judgment
quality, which is the thing the trust bet rests on and the only thing that can
falsify it early.

## 5. Cutover

The parity gate is the requirements doc's ID list, checked against evidence
from real shifts, not against code review:

- **Required green**: every P0 (P0-1 … P0-10) and every P1 (P1-1 … P1-7). Five
  of them are evidenced against their current form rather than their original
  wording, and reading the story alone would set the wrong bar:
  - **P0-1 is evidenced against its sharded form.** What must be singular is
    the operator's experience — one switch, one ledger, one account, one
    morning queue — while the judgment layer shards one desk per project. So
    the evidence is a night in which two projects both had cases: two desks,
    one account grouped by project, and a quiet project that cost nothing
    because no desk was ever spawned for it.
  - **P0-2 is evidenced as on/off plus per-project mode selection**, with no
    third posture anywhere: one column, one gesture, one shift, resuming across
    a restart in the posture the switch persists. Off pauses; it never
    closes.
  - **P0-3 is evidenced against its descoped form**: the requirements doc
    records that TBD builds no mode enforcement and no verb gate, so what must
    be green is that a mode's conduct is delivered in every work order, that
    every action line records the mode it ran under, and that the account shows
    an act within seconds of it happening — not that any act was prevented.
  - **P0-8 is evidenced as authored discipline plus one compiled obligation.**
    The daemon re-verifies nothing and inspects no message content, so what
    must be green is the narrow built part: work facts carrying source and
    observed-at into every order, the ledger recording each dispatched message
    verbatim, and display-tier honesty for the persisted `PRStatus` (slice 1).
    A soak account showing fleet agents recurrently acting on stale premises is
    the pre-committed signature that would reopen the question — in the open,
    never as a quiet restoration.
  - **P1-5 is evidenced as *instruction delivery*, and as shift-lived**: a
    `--scope this-shift` resolution must reach later work orders and the desk
    must stop asking, and the answer must be gone when the shift closes, with
    no durable store behind it (design §8).
- **Three properties are checked by deliberate exercise, not by waiting.** Each
  is silent when it works, so none of them will show up in a soak account on
  its own:
  - **The preconditions bind against a stale work order.** Flip the switch off
    at 2:03 and issue a drive decided from a 2:02 order at 2:07: nothing is
    typed, the CLI returns an error naming the condition, and a refusal outcome
    referencing the action line lands in the record (design §3, §4 step 6).
  - **The crash window produces no unrecorded act.** Kill the daemon between
    the action line and the dispatch, and again between dispatch and the
    observation: the first renders as a request with no outcome, the second as
    unconfirmed until the startup scan performs the late observation
    (design §12).
  - **An unidentified dialog is never blind-Escaped.** A `drive --text` at a
    session sitting on something the daemon does not machine-know refuses and
    writes an anomaly; the bounded wait that expires sends nothing (design §2).
- **Expected but not blocking**: P2-1 and P2-2 both land in slice 4's shift
  close — the capture suggestion in the proposals doc for cross-shift learning
  (P2-1, and note there is no learnings file and no `learn` verb to look for),
  and the teardown that disposes every desk the night created (P2-2); P2-4
  lands with slice 6. P2-3 is satisfied mostly
  structurally rather than by implementation — prevention at spawn for
  permission prompts, seeders for config-answerable dialogs, and escalation for
  everything that fails the machine-interface test — with one implemented
  piece, the `AskUserQuestion` case flow and its dialog-dismissing delivery
  adapter in slice 4 (answered through `drive --text`, not a verb of its own).
  What the story actually asked for (an allowlist matched against rendered
  prompts) ships in no slice and never will (design §2).
- **Explicitly not blocking**: P3-1.

Cutover is then an operator act, deliberately boring: set `nightwatch_mode`
off for the last time, harvest the desk worktree once more (final `queue/`
state and any last field learnings), archive it by hand, and run shifts only
on the new system. Nothing in the old system needs to be deleted for cutover
to be complete — deletion is a separate slice so that a disappointing first
week can roll back with three gestures: `supervision_enabled` off,
`tbd supervise shift close` so the record ends cleanly instead of lingering
paused with its desks alive, and `nightwatch_mode` back on. The middle gesture
is not optional — the interlock refuses the third one while a shift is open
(§1).

## 6. Deletion

One slice, after the operator declares the cutover held. Checklist:

- Re-derive the file list by grep (`Nightwatch|Daywatch|nightwatch_mode`),
  then delete the sources and tests in the inventory (§2), including
  `writeNightwatch()` and the app surfaces.
- Remove the two SwiftLint exclusions for `NightwatchSkillContent.swift`
  (`no_tui_scraping_literals`, `capture_pane_allowlist`) and confirm
  `swiftlint --strict` passes — the scraper count drops from three to two.
- Remove the `nightwatch.*` RPC methods. **Stale-CLI hazard**: hooks run `tbd`
  from `PATH` and `restart.sh` does not refresh the `~/.local/bin/tbd` hard
  link; reinstall the CLI as part of this slice so no stale binary calls a
  method the daemon no longer serves.
- Do **not** add a migration; `nightwatch_mode` stays orphaned with a comment
  in the vicinity of the next migration explaining why (the `v60`/`v61`
  precedent).
- Delete the on-disk skill dir (snapshot from §3 already exists).
- Verify no out-of-tree babysitter survives on the machine that runs shifts:
  `~/.fleet/babysitter_daemon.py`, `daemon_watchdog.sh`, and any related
  `launchd` jobs. The embedded skill text pointed operators at installing one,
  so its absence is not implied by deleting TBD's code. Checked absent on the
  dev machine 2026-07-27.
- Add a superseded-by banner to `docs/specs/2026-07-03-nightwatch-daywatch-design.md`
  pointing at the new design; `docs/nightwatch.md` keeps its historical-record
  banner.
- Remove the freeze notice from the root `CLAUDE.md` and update its quick
  reference to the `tbd supervise` surface.

Exit: `grep -ri nightwatch Sources Tests` returns nothing, the lint and test
suites pass, and a daemon restarted from `main` neither writes the old skill
dir nor answers the old RPC methods.
