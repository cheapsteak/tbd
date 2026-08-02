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
  valid, and operator discipline is not a mechanism.
- **Default-off throughout**: the supervision column ships defaulting to off and
  is the master switch for every new behavior, satisfying the house
  default-off-flag rule. The Channels delivery adapter additionally gets its
  own default-off flag (§4, slice 4).
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
  and daemon sweep (design §2). This is the scraper retirement.
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
- **`NightwatchDeskPrompts`** — Claim-before-apply, escalation batching, the
  200k respawn rule → doctrine (2), where the design has not already compiled
  them (§9 recycles context mechanically); person-specific wording → discard
  (5).
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
  tool call and cannot signal that a prompt is on screen), add
  verify-before-acting, run the work-state sweep on the daemon's cadence,
  derive the context-load fact from the transcript tail. Pure observability;
  safe to ship while the old system runs because it acts on nothing. The fact
  snapshot's output shape is a documented public contract from this slice on —
  it is what the project-authored sweep program reads
  ([sweep-program sub-document](2026-08-01-fleet-supervision-sweep-program-design.md)
  §3).
- **Slice 2 — the switch, shift, ledger** (design §3, §7, §9). The
  `supervision_enabled` config column — a **boolean**, not the old tri-state
  posture (migration + record type + Codable model, one commit, per the house
  migration rule) — the compiled interlock with `nightwatch_mode`, the shift
  directory with `ledger.jsonl` and the `account.md` renderer, shift open/close
  bound to that switch. The ledger envelope carries `mode` per line from the
  start, even though mode selection lands in slice 3; a shift with no selections
  records `attended`. Shift
  open spawns no desks by design (design §9 — hosted desks are lazy, born on
  their
  project's first case in slice 4), so this slice's shift opens, writes its
  ledger, and closes on its own; no slice needs a later one. Shift close gains
  its dispose-every-hosted-desk step in slice 4, when there are desks to
  dispose.
- **Slice 3 — verbs and `supervision.json`** (design §3, §5, §8, §10).
  Nothing here is gated (design §3), which keeps the slice small and simple.
  - **The verbs as RPC, none of them gated**: `drive`, `wake`, `pause`,
    `note`. `drive` takes exactly one payload flag per call,
    `--text` or `--keys` (design §3); there is no `answer` verb, no separate
    key-sending verb, no `learn` verb, and no `escalate` verb — raising a
    question to a human is conduct on the playbook-named question route, not
    a record kind (design §8). The dialog dismissal that makes
    `--text` work is delivery-adapter behavior landing with the adapter in
    slice 4 (design §2). Around each verb the daemon does two things and no
    more: the daemon-written action line carrying the payload verbatim, the
    active mode, and the state snapshot, and the one-minute re-check. The
    acting verbs' preconditions include the in-flight-intervention and
    pending-re-check refusals (design §3) — checked at the act, never at the
    brief pipe. There is
    no third thing — in particular no send-time re-verification of a `--text`
    payload's claims: freshness is the desk's discipline and the daemon reads no
    message content (design §3, P0-8). **Do not build a posture check, a rule
    lookup, a proposal
    conversion, or a content check** — there are none (design §3), and the
    ledger has **seven** kinds (design §6): action, outcome, delivery,
    lifecycle, enrollment, anomaly, note. There is no escalation queue, no
    `resolution` or `decision` kind, and no `resolve` command — the record
    attests acts only (design §8).
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
    needs no recycle — the next briefing's header names the new selection.
  - **Mode selection**: `tbd supervise mode <project> <name>`
    writes the selection and a ledger line. Selection is validated against
    the declared mode list in `supervision.json` (design §8) — TBD never
    parses the playbook; a declared name the playbook says nothing about is
    playbook silence, handled by the desk like all silence.
  - **Nothing queue-shaped ships in this slice or any other.** There is no
    escalation projection, no `queue` or `resolve` command, no `decision`
    store or projection into briefings: questions and answers ride the
    playbook-named route and the sweep program's own files, with P1-5 and the
    consent half of P1-7 classified Enabled (requirements doc, design §8).
    The `note` verb's pointer discipline is playbook content, not machinery.
- **Slice 4 — supervisors and delivery** (design §4, §5, §9, §12, and the
  [sweep-program sub-document](2026-08-01-fleet-supervision-sweep-program-design.md)).
  The case-detection surface: the **three public sweep surfaces** — the
  `supervise readout` query, the `supervise brief` pipe (text on stdin, the
  identity-blind per-project rate limit, the pinned paused exit code, empty
  submission as quiet contact), and the `supervise ledger` query — plus the
  daemon's default tick running the shipped reference sweep program (with
  the `sweep.script` override and the "Customize sweep…" copy-once gesture),
  and the contact-window watchdog with its anomaly lines and its
  operator notification on persistent silence, armed only while supervision
  is on and a shift is open. Desk briefing: the playbook installed
  as standing conduct at desk launch through the agent-kind adapter — a
  supervisor-capability requirement, with no embed fallback of any kind
  (design §9, sub-document §8) — the compiled header on every delivered
  briefing carrying the active mode's name and any superseding conduct delta
  on mid-shift edits, and the `delivery` ledger line with delivered-text and
  conduct hashes. Then per-project briefing delivery, supervisors as
  first-class sessions **one per project** — the hosted desk spawned lazily
  on that project's first case and disposed at shift close, or the operator's
  appointed session where a binding stands (design §9) — the compiled
  **desk→project
  addressing check** (a verb whose target is outside the calling desk's project
  is refused as a routing error — correctness, not authority, design §3; the
  check reads the project name injected into the desk's spawn environment,
  or into the appointment relaunch's environment,
  design §5), the **appoint/relieve gestures** (design §9, §10): the
  supervisor-capability qualification check refusing unqualified agent kinds
  at the gesture with the reason, the idle-waiting relaunch that resumes the
  same conversation with the layer installed and `TBD_PROJECT` injected, the
  symmetric relief, the `supervisors` binding in `supervision.json` (design
  §8) with lifecycle ledger lines for both gestures, the hosted default
  standing down while a binding stands, and the forked dead-man remediation
  (hosted: replacement within the reroll budget; appointed: operator
  notification only, never an automatic restart; a dangling binding: loud
  anomaly, no silent takeover),
  `terminal.send` delivery for
  the fleet, the Channels adapter for desks behind its own default-off flag with
  automatic degrade and a **per-desk-spawn handshake** (not per shift), the
  ledger-marker acknowledgement re-check, **per-desk** context recycling at
  the design's fractional thresholds (50% of the effective window, flush
  nudges at 50/60/70% — design §9, hosted desks only), the **project tag on
  every ledger line**, and the playbook
  resolver — three-tier `supervision.md` resolution run **per project** (the
  operator's project-level copy → the project's designated repo file → the
  shipped default), which includes adding `.agents/` as a level to the existing
  resolver. For singleton projects the operator and repo levels are the existing
  per-repo paths, so the resolver's singleton path is the one that must match
  the old design byte for byte. This slice
  also carries the **two event-driven case flows** (design §2, §4). The
  `AskUserQuestion` one: the
  daemon-side fork in the existing `terminal.askUserQuestionPending` handler —
  the hook itself stays an unconditional dumb reporter and is not touched — so
  that a pending question with a shift active and the terminal's project in
  automation becomes a case for that project's desk and hastens an immediate
  mini-tick for that terminal; the prompt-case delivery carrying the question
  payload verbatim out of `PendingQuestionStore`;
  and the store's TTL treated as a GC backstop that must not expire a still-live
  dialog during a shift (resolution comes from the `PostToolUse` clear, not the
  clock). The **dialog-dismissing delivery adapter** lands here too: an
  `drive --text` whose target sits on a dialog gets ESC-then-paste, but **only when
  the daemon machine-knows the dialog** (a pending `AskUserQuestion` in the
  store). Any other on-screen state must make the delivery refuse and write an
  anomaly — never a blind ESC. Test both branches; the refusal is the branch that
  keeps the machine-interface test honest (design §2).

  The **`Notification` case flow** is the same shape on slice 1's hook: dumb
  reporter → daemon holds the fact → shift active and project in automation →
  case for that project's desk, event-hastened mini-tick. A permission-prompt
  case is *not* an escalation; whether it becomes one is desk judgment (design
  §2), so build no auto-escalate path for it. The **`drive --keys` payload**
  lands here as well: named-key, paced sends, and the action ledger line must
  carry the screen capture the desk read when choosing the keys — that record is
  the variant's integrity requirement — the evidence every screen-informed act
  owes — so a `--keys` action written without it is a bug, not a thin log line. Two non-blocking notes for
  whoever picks this up: pending questions
  have no CLI read surface today (`terminal.transcript` is RPC-only, and the
  briefing carriage is what makes a read surface unnecessary — a
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
    ledger-marker acknowledgement, retry-once, the loud anomaly on repeated
    silence) is built
    on the assumption that a failed send is *reported* as one.
  - **The same fact-corroboration step already covers issue #384.** Verifying
    pane identity before acting (design §2, "verify before acting") is what
    stops a stale pane coordinate from sending a supervisor's message to the
    wrong session — pane IDs are reused, so the check is identity, not just
    liveness. Note the two classes differ: a dead pane can surface as an error
    from inside the send path (checking `#{pane_dead}` deliberately —
    `send-keys` into a `remain-on-exit` pane succeeds silently), while a wrong
    live pane produces no error by any mechanical measure, so identity must be
    a deliberate comparison before typing.

  Design §12 pins the semantics this slice builds on:
  action lines assert dispatch, never delivery; receipt is a passive sentinel
  observation (`<tbd-dispatch id="…"/>` in the target's transcript) recorded
  as one of four outcome results, with retry permitted only from positive
  non-delivery; and an action with no confirming outcome renders as
  unconfirmed at query time, which is also the whole restart story.
- **Slice 5 — operator surfaces** (design §10). For v1 the operator surface
  is `supervision.json` itself plus its CLI twins — app presentation of the
  selections is deliberately deferred to its own design pass, so this slice
  ships **no settings screens**. What it does ship: the account panel
  rendering the live `account.md` with each project's proposals doc linked
  beside it (design §6, §10), and CLI completeness — the whole
  `tbd supervise` surface is pinned as a normative list in design §10, so this
  slice's exit check is that every command in that list exists with that name
  and shape, and that nothing outside it shipped — in particular no `rules`
  commands, no `posture` command, and no `queue`, `resolve`, `escalate`, or
  `approve` commands. Regrouping is
  `project move <repo> --to <project|singleton>` — no add/remove pair, because
  the pair can express states "exactly one project per repo" forbids.
- **Slice 6 — hardening** (design §11, §13, §14). Capacity holds, runaway
  detection, the optional heartbeat. The heartbeat (P3-1) may be deferred past
  cutover without blocking it.

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
the shared record actually hold.

Because modes do not change daemon behavior (design §3), an `autonomous`
soak shift is evidence about *conduct* — did the desk act where the prose told
it to act — not about a code path. Read those shifts' accounts for judgment
quality, which is the thing the trust bet rests on and the only thing that can
falsify it early.

## 5. Cutover

The parity gate is the requirements doc's ID list, checked against evidence
from real shifts, not against code review:

- **Required green**: every P0 (P0-1 … P0-10) and every P1 (P1-1 … P1-7),
  each against the form the requirements doc records for it. **P0-3 is
  evidenced against its descoped form**: the
  requirements doc records that TBD builds no mode enforcement and no verb
  gate, so what must be green is that the playbook stands as the desk's
  spawn-time conduct layer with the active mode named on every briefing, that
  every action line records the mode it ran
  under, and that the account shows an act within seconds of it happening — not
  that any act was prevented. **P1-5 and the consent half of P1-7 are
  evidenced against their Enabled form**: an operator answer written on the
  project's question route demonstrably reaches later briefings through the
  sweep program, and the desk stops asking (design §8) — no queue, resolve
  machinery, or decision projection exists to evidence.
- **Expected but not blocking**: P2-1, P2-2 (both are in the design and the
  slices above); P2-4 lands with slice 6. P2-3 is satisfied mostly
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
week can roll back by three gestures: **close the new system's shift**
(`tbd supervise shift close` — off is a pause, not an ending, and a
merely-paused shift still owns an open record; flipping the old system on
under it would put two supervisors on one fleet with the record of the
second still open), then `supervision_enabled` off, then `nightwatch_mode`
back on.

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
