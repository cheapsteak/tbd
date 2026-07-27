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
loop, posture gate, ledger, and delivery layer are fresh builds; the old code's
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
   flag — superseded by the posture column, orphaned in place (§6).
4. **The desk worktree** — harvested, then archived by hand (§5).

So the plan is: **build new alongside, carry those four across, cut over,
delete.**

### Ground rules

- **Coexistence** (operator decision, 2026-07-26): the frozen System B keeps
  running until the new system passes the parity gate (§5). Something must
  keep working throughout; the freeze notice in the root `CLAUDE.md` keeps the
  old system bug-fix-only meanwhile.
- **Mutual exclusion, compiled**: the daemon refuses to set the new posture
  to anything but off while `nightwatch_mode ≠ off`, and vice versa, with an
  error naming the other switch. Two supervisors driving one fleet is never
  valid, and operator discipline is not a mechanism.
- **Default-off throughout**: the posture column ships defaulting to off and
  is the master gate for every new behavior, satisfying the house
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
by trusting this table.

| Artifact (post-#509 `main`) | Disposition |
|---|---|
| `TBDDaemon/Nightwatch/DaywatchRunner.swift` (loop, tick executor) | Superseded by the new daemon cadence (design §4). Delete at §6. |
| `TBDDaemon/Nightwatch/DeskSessionManager.swift` | Superseded by the new supervisor session lifecycle (design §9). Delete at §6. |
| `TBDShared/NightwatchSkillContent.swift` (1528 lines of embedded policy) | Knowledge-extract in slice 0 (§3), then delete. Retires one of the three sanctioned TUI scrapers and its two SwiftLint exclusions. |
| `TBDShared/NightwatchDeskPrompts.swift` | Doctrine-extract in slice 0, then delete. |
| `PluginDirWriter.writeNightwatch()` + the on-disk skill dir | Delete after harvest; the boot-time overwrite disappears with it. |
| `nightwatch.setMode` / `nightwatch.report` RPC, `RPCRouter+NightwatchHandlers.swift` | Superseded by `supervision.*` RPC surface. Delete at §6 (stale-CLI hazard: §6). |
| `TBDCLI/Commands/NightwatchCommand.swift` | Superseded by `tbd supervise ...`. Delete at §6. |
| `NightwatchMode` in `Models.swift`, `nightwatch_mode` in `ConfigStore` | Code deleted at §6; DB column orphaned in place. |
| App surfaces: `NightwatchModeToggle`, `NightwatchStatusItem`, status-bar tint/badge, Settings "Fleet Automation" section, `nightwatchExperimentalEnabled` key | Superseded by the new posture control and the Fleet Supervision settings tab (design §10). Delete at §6. |
| Tests (`DaywatchRunnerTests`, `DeskSessionManagerTests`, `NightwatchDeskPromptsTests`, `NightwatchModeTests`, `NightwatchModeToggleTests`, `NightwatchExperimentalGateTests`) | Delete with their subjects. |
| Live runtime dir `~/Library/Application Support/TBD/plugin/skills/nightwatch/` (`queue/*` and any edited config files — note `scripts/handoff.py` is no longer agent-owned here; it was absorbed into `NightwatchSkillContent` and is boot-overwritten like every other script) | Harvest in slice 0, snapshot, then delete with `writeNightwatch()`. |
| The "◐ Watch Desk" scratch worktree | Final harvest at cutover, then archive by hand. |
| Target repos' `.nightwatch/policy.json` | Advisory content folds into that repo's `.agents/supervision.md`; the file and directory are then removed from those repos (their consumer, `MergeGate`, is already gone). |
| `docs/specs/2026-07-03-nightwatch-daywatch-design.md` | Keep as history; gains a superseded-by banner at §6. |
| `docs/nightwatch.md` | Keep as the historical baseline; its banner already records #509. |
| Root `CLAUDE.md` freeze notice | Removed at §6 — the freeze ends when the old system is gone. |

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
4. **Operator-binding** — rules the daemon must enforce with no model in the
   loop; seed `~/tbd/supervision/standing-rules.json`, each entry individually
   confirmed by the operator ("repos advise; operators bind").
5. **Stale snapshot / person-specific** — discard, with a line in the log.

Expected dispositions per source (verify against content during execution;
citations are to the baseline doc's §5–§6):

| Source | Expected buckets |
|---|---|
| `skillMd` (playbook) | Split: escalation etiquette and operating rules → doctrine (2); tier tables, sign-off conventions, project slash-commands → repo advisory (3); config-file semantics and the opt-in scheduler → superseded (1). |
| `wakePy` (pre-wake verifier) | Superseded (1) by compiled dispatch-time re-verification (design §4, P0-8). |
| `tickPy` (capture-pane sweep) | Superseded (1) by the hook-fed state model and daemon sweep (design §2). This is the scraper retirement. |
| `judgePy` (PR gating for one hardcoded repo) | Repo advisory (3) for the review-bot conventions; the mechanism is superseded (1). |
| `handoffPy` (context-ceiling successor relay) | Superseded (1) by design §9's daemon-driven desk recycling, which externalizes to the shift record instead of relaying through a script. Agent-authored, later absorbed into the binary — worth one line in the disposition log as the clearest instance of the change process §5.3 of the baseline objects to, then discard (5). |
| `tickCronSh` / `schedulerSh` (launchd) | Superseded (1) by the out-of-band heartbeat (design §14) — or discarded if the heartbeat is deferred; the shipped copy pointed at a dangling path anyway. |
| `prioritiesTxt` | Stale fleet snapshot → discard (5). |
| `safeWedgesTxt` | Discard (5), with a log line: prompt auto-approval is structurally removed (design §2's prompt-stalls subsection). The entries are at most candidates for source-side allow rules — a repo's own settings or the operator's per-repo overlay — should an operator ever want them there, and the shipped list, which carried a bare `git` prefix, is too broad to have ever been ratified. Nothing from it seeds standing rules. |
| `dontTouchTxt` | Never-list entries → operator-binding (4); the frozen pane-ID comment → discard (5). |
| `NightwatchDeskPrompts` | Claim-before-apply, escalation batching, the 200k respawn rule → doctrine (2), where the design has not already compiled them (§9 recycles context mechanically); person-specific wording → discard (5). |
| Live dir: field-learning edits, `queue/for-*.md` | Learned prose → **repo advisory (3)**, folded into that project's `.agents/supervision.md` in the PR step 3 already opens — there is no `learnings.md` destination in the new design (design §8); queue files are shift history → snapshot only. `handoff.py` is no longer a live-dir divergence — it is embedded and boot-overwritten (see `handoffPy` above) — but snapshot-first still applies to the whole dir, because which files the writer owns has changed once already and the snapshot is what makes that harmless. |
| Target repos' `.nightwatch/policy.json` | `priorities`, `dont_touch`, gate conditions → that repo's advisory playbook (3), except entries the operator promotes to binding (4). |

**Step 3 — seed the destinations.** Open the `.agents/supervision.md` PR in
the target repo; write the confirmed standing rules (never-entries, the
automation-membership marks and default stance). There is no learnings file to
append to — durable prose goes in the advisory PR.

**Exit gate**: the disposition log accounts for every file in the inventory;
the advisory PR exists; the rules file parses and the operator has confirmed
every binding entry.

## 4. Build slices

Each slice ships independently, compiles, tests both branches of anything it
gates, and lands nothing autonomous outside the posture gate. Dependency order
only — no slice needs a later one:

- **Slice 1 — facts** (design §2). Install the Notification hook, add
  verify-before-intervene, run the work-state sweep on the daemon's cadence,
  derive the context-load fact from the transcript tail. Pure observability;
  safe to ship while the old system runs because it acts on nothing.
- **Slice 2 — posture, shift, ledger** (design §3, §7, §9). The
  `supervision_posture` config column (migration + record type + Codable
  model, one commit, per the house migration rule), the compiled interlock
  with `nightwatch_mode`, the shift directory with `ledger.jsonl` and the
  `account.md` renderer, shift open/close bound to the posture switch. Shift
  open spawns no desks by design (design §9 — desks are lazy, born on their
  project's first case in slice 4), so this slice's shift opens, writes its
  ledger, and closes on its own; no slice needs a later one. Shift close gains
  its dispose-every-desk step in slice 4, when there are desks to dispose.
- **Slice 3 — verb gate, standing rules, queue** (design §5, §8). The
  supervision verbs as RPC behind the gate — **three gated** (`intervene`,
  `wake`, `pause`) and **two ungated** (`escalate`, `note`). There is no
  `answer` verb: replying to an agent's question is `intervene`, and the dialog
  dismissal that makes it work is delivery-adapter behavior landing with the
  adapter in slice 4 (design §2). There is no `learn` verb and no
  `learnings.md` plumbing either — the machine-appended memory tier was removed
  in favor of notes plus a reviewed playbook PR (design §8), so this slice
  builds neither, and the ledger has **nine** kinds, not ten. The standing-rules loader including automation
  membership and the default stance; the proposal queue as a ledger projection.
  The operator's queue surface is **one command**, `tbd supervise queue
  [--resolved|--all] [--type …] [--project …]` to read and
  `tbd supervise resolve <id> --approve|--reject|--answer` to act (design §10) — all three flags construct the same `resolution` ledger kind, differing
  only in `result`, so build it as one RPC with flag validation that teaches
  ("that's a proposal — `--approve` or `--reject` it") rather than three
  near-identical commands. `--scope` attaches to `resolve` itself, not to
  individual flags. `resolve` is operator-only and must not be reachable from a
  desk, which is what keeps resolutions off the self-report path (design §10).
  The loader in this slice also owns the **`projects` object** (design §5, §8):
  parse declared multi-repo projects and their designated policy source, reject
  a file where any repo appears in two projects, and resolve every other repo to
  its implicit singleton. Standing-rule `scope` gains the `{ "project": … }`
  shape alongside `{}`/`{ "repo": … }`/`{ "worktree": … }`, and automation
  membership moves to the project level with singletons keyed by their repo's
  implicit name. Test the degenerate case explicitly: with an empty `projects`
  object, resolution, membership, and scoping must behave exactly as the
  per-repo design did — that collapse is a stated invariant, not an
  implementation detail. Mutations apply on the **next tick**, and any live desk
  whose project definition changed is recycled through the §9 replacement path
  (design §5) — so the loader must expose "which projects changed" and not just
  the new state; that recycle lands with desks in slice 4.
- **Slice 4 — supervisors and delivery** (design §4, §5, §9, §12). Wake
  decision from facts, work-order composition **grouped by project**, desks as
  first-class sessions **one per project, spawned lazily on that project's first
  case and all disposed at shift close**, the compiled **desk→project gate
  binding** (a verb whose target is outside the calling desk's project is
  refused before posture and rules are consulted), `terminal.send` delivery for
  the fleet, the Channels adapter for desks behind its own default-off flag with
  automatic degrade and a **per-desk-spawn handshake** (not per shift), the
  ledger-marker acknowledgement re-check, **per-desk** context recycling at the
  250k threshold, the **project tag on every ledger line**, and the playbook
  resolver — three-tier `supervision.md` resolution run **per project** (the
  operator's project-level copy → the project's designated repo file → the
  shipped default), which includes adding `.agents/` as a level to the existing
  resolver. For singleton projects the operator and repo levels are the existing
  per-repo paths, so the resolver's singleton path is the one that must match
  the old design byte for byte. This slice
  also carries the **`AskUserQuestion` case flow** (design §2, §4): the
  daemon-side fork in the existing `terminal.askUserQuestionPending` handler —
  the hook itself stays an unconditional dumb reporter and is not touched — so
  that a pending question with a shift active and the terminal's project in
  automation becomes a case for that project's desk and hastens an immediate
  mini-tick for that terminal; work
  orders carrying the question payload verbatim out of `PendingQuestionStore`;
  and the store's TTL treated as a GC backstop that must not expire a still-live
  dialog during a shift (resolution comes from the `PostToolUse` clear, not the
  clock). The **dialog-dismissing delivery adapter** lands here too: an
  `intervene` whose target sits on a dialog gets ESC-then-paste, but **only when
  the daemon machine-knows the dialog** (a pending `AskUserQuestion` in the
  store). Any other on-screen state must make the delivery refuse and write an
  anomaly — never a blind ESC. Test both branches; the refusal is the branch that
  keeps the machine-interface test honest (design §2). Two non-blocking notes for
  whoever picks this up: pending questions
  have no CLI read surface today (`terminal.transcript` is RPC-only, and the
  work-order carriage is what makes a read surface unnecessary — a
  `tbd`-side reader would be a debugging nicety, not a dependency); and
  subagent-raised questions are deliberately dropped by the payload parser
  (`isSubagentTranscript`), so they never become cases. Whether that stays is a
  policy decision at implementation time — default: keep dropping them, since
  the parent session surfaces its own questions.
- **Slice 5 — operator surfaces** (design §10). The Fleet Supervision settings
  tab — the **projects section** (declare a multi-repo project, pick members,
  designate the policy source, and list ungrouped repos as the singletons they
  are), the per-project membership section, and standing-rules inspection — plus
  the account panel as inbox, showing every desk's proposals and escalations in
  one project-labeled queue. CLI parity for every control — and the whole
  `tbd supervise` surface is pinned as a normative table in design §10, so this
  slice's exit check is that every command in that table exists with that name
  and shape, and that nothing outside it shipped. Regrouping is
  `project move <repo> --to <project|singleton>` — no add/remove pair, because
  the pair can express states "exactly one project per repo" forbids.
- **Slice 6 — hardening** (design §11, §13, §14). Capacity holds, runaway
  detection, the optional heartbeat. The heartbeat (P3-1) may be deferred past
  cutover without blocking it.

Soak discipline: after slice 4, run real shifts on the new system in
attended posture (the interlock means the old system is off for those
shifts; alternate if the new system disappoints). At least one clean
attended shift and one autonomous shift — scoped by automation membership to
low-stakes projects — before the parity gate. **At least one of those shifts
must exercise a declared multi-repo project**, and at least one must run with
nothing declared at all: the singleton collapse and the grouped case are
different code paths through the resolver, the gate binding, and desk spawning,
and only the first is covered by every other shift by default. A night in which
two projects both had cases is the cheapest evidence that per-project desks,
the gate binding, and the shared queue actually hold.

## 5. Cutover

The parity gate is the requirements doc's ID list, checked against evidence
from real shifts, not against code review:

- **Required green**: every P0 (P0-1 … P0-10) and every P1 (P1-1 … P1-7).
- **Expected but not blocking**: P2-1, P2-2 (both are in the design and the
  slices above); P2-4 lands with slice 6. P2-3 is satisfied mostly
  structurally rather than by implementation — prevention at spawn for
  permission prompts, seeders for config-answerable dialogs, and escalation for
  everything that fails the machine-interface test — with one implemented
  piece, the `AskUserQuestion` case flow and its dialog-dismissing delivery
  adapter in slice 4 (answered through `intervene`, not a verb of its own).
  What the story actually asked for (an allowlist matched against rendered
  prompts) ships in no slice and never will (design §2).
- **Explicitly not blocking**: P3-1.

Cutover is then an operator act, deliberately boring: set `nightwatch_mode`
off for the last time, harvest the desk worktree once more (final `queue/`
state and any last field learnings), archive it by hand, and run shifts only
on the new system. Nothing in the old system needs to be deleted for cutover
to be complete — deletion is a separate slice so that a disappointing first
week can roll back by flipping two switches.

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
