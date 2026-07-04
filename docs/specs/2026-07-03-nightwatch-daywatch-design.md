# Nightwatch / Daywatch — an "Away / Back" mode for the fleet — design

Status: **exploration / design** (no implementation). Written 2026-07-03.

This is a design doc, not an implementation plan. It restates the vision precisely,
grounds it in live evidence from a real ~40-worktree babysitting night, locates the
integration seams in TBD with `file:line` citations, and ranks candidate shapes with
tradeoffs. It ends with Assumptions, Counter-evidence, Source-quality, and the open
forks that need Adam.

> Fleet/PR numbers in the live evidence are from the night of 2026-07-03. The findings
> are independent of which repo they came from; Longeye is named only where its
> prod-auto-deploy property is load-bearing.

---

## 1. The vision, restated precisely

A **TBD "Away / Back" toggle**. Adam hits **Away** (a few hours, or overnight,
indeterminate) and wants everything to keep advancing without him. He hits **Back** and
gets reoriented, not dumped on.

Two modes of one underlying thing:

- **Nightwatch** (gone indefinitely) → maximize forward progress, go on without him,
  escalate ONLY genuinely hard calls. Held decisions must feel like *"glad you waited on
  these,"* never *"obviously the recommended path — why didn't you just pick it."*
  Nightwatch **can** have an interactive pre-flight at initiation (he's present when he
  hits the button).
- **Daywatch** (present but distracted — deep work, a meeting) → orchestrate across trees,
  tell him where to pay attention, be an orchestrator he can *talk to*. Act only on the
  **obvious**; **batch** everything else for one sweep when he surfaces — do NOT
  hold-and-escalate each item or notify per decision. Daywatch **cannot** have an
  at-initiation interactive pre-flight (he's mid-task when it starts).

**Away spawns a Nightwatch orchestrator** that can spawn **children as needed** — a PR
babysitter, a closeout babysitter, a machine-health watcher — and those can spawn their
own. The tree grows to match load, within caps.

**Back triggers a wrap-up mode** (not a hard stop — keep maintaining in the background
until told to stop): a status report (what happened + reorientation of what he was working
on, because he'll have forgotten + a SMALL batch of held decisions). Then sessions run
`/closeout` on themselves, feed the **knowledge tree**, and archive.

---

## 2. The one framing that makes this buildable: mechanism in the daemon, policy in the agent layer

The single most important architectural decision — the one that determines whether this is
a good feature or a liability — is **where the line sits between compiled TBD code and the
editable agent/skill layer.**

The judgment this feature encodes ("is this PR safe to merge?", "should I spawn a child
now?", "is this worktree really done?") is **fast-moving, model-dependent, and will change
monthly** as new edge cases surface. Compiling that into a Swift daemon behind DB
migrations is the wrong place for it (see §12, Counter-evidence #3): every tweak becomes a
rebuild + `restart.sh` + possibly a migration, and a bug in it runs in-process against the
whole fleet with no canary.

So the design splits cleanly:

| Layer | Owns | Changes how |
|---|---|---|
| **TBD daemon/app (compiled)** | **Mechanism, state, audit, and a non-negotiable safety floor.** The mode flag; PR metadata enrichment; the SHA-pinned clearance ledger; a spawn RPC with lineage + caps; the host-resource probe; the notification/HTML surfaces; the audit log. And the *hard holds* that policy can never override. | Slowly, deliberately, with tests + migrations. |
| **Nightwatch skill + repo `policy.json` (editable)** | **Policy and judgment.** The tick classification, "is this small+safe," when to spawn a child, what to nudge, how to draft the wrap-up. | Instantly — edit a file, next tick picks it up. No rebuild. Already how `~/.claude/skills/nightwatch/` works (`d98c2cc` bundled it into the plugin). |

The daemon **executes** the mechanism policy asks for and **enforces** the safety floor as
a compiled invariant. Concretely, the daemon will refuse — regardless of what any agent or
policy file requests — to auto-merge a PR unless *all* of: claude-review APPROVED **on the
current head SHA**, required checks clean, no sensitive path touched, no active test-hold,
and a valid SHA-pinned clearance exists (§7). Policy can only ever make the gate *more*
conservative, never less.

This resolves the "native TBD vs. keep it a skill" tension: it is **both**, on purpose. The
toggle, the surfaces, the resource signals, and the audit trail are native (they need to
live where the state and the UI are). The judgment stays a skill (it needs to iterate at
model speed). Everything below is written to that seam.

---

## 3. Live evidence from the night of 2026-07-03 (T1 — real incidents)

These are the incidents the design must answer to. All observed during a real Opus
babysitting session over the fleet.

- **Toe-stepping is real and has a cost.** PR #13781 was owned by BOTH the dedicated
  babysitter and a separate `rebase-13781` worktree. The babysitter detected the overlap
  and correctly skipped — but *detection is the cost*, and the miss window is where two
  agents force-push over each other. (Babysitter log, 15:33: "already owned by another
  agent (worktree rebase-13781). Left for human/owner; not chasing.")
- **The DONE heuristic misfires.** Worktrees `%69` (asr-translate-cleanup) and `%12` (Fix
  Null Hash Investigator Leak) were classified archive-ready while they still had **open
  PRs** (#14030/#14038 and #14018/#14035), **staged-but-unsubmitted composer text** (`send
  the nudge`, `keep watching 14018`), and **pending questions**. A queued "Run /closeout"
  task is NOT a done-signal. (nightman-log, 15:20: "caught misclassification — %69 + %12
  NOT archive-ready.")
- **Approval does not survive a force-push, silently.** #13781 used the sensitive-path
  infra bypass and the agent itself flagged "the approval may not have survived the
  force-push." A pre-clear pinned to an old SHA is not a clearance for the new one.
- **Capacity + host memory are first-class backpressure.** The nightman *held all
  auto-nudges* because a capacity proxy read saturated (`MIN_ROUTABLE=2`,
  `tick.py:175–177`), and separately watched machine swap climb **87% → 93.6%** over 30
  minutes as sessions accumulated, holding new spawns. (for-adam.md, "Machine health — ⚠
  trending worse.")
- **Archive is not a leaf operation.** `tbd worktree archive` on a worktree with children
  fails "Archive nested worktrees first." The lifecycle has tree structure; wrap-up must
  archive leaves-up.
- **The mode split is already load-bearing.** The prototype's `queue/mode.txt` already
  distinguishes `daywatch` ("act on the OBVIOUS only, BATCH the rest") from nightwatch
  ("maximize forward progress, escalate only the hard calls"). This design formalizes what
  the night already ran by hand.
- **Merges ship to prod.** Every merge to Longeye's `main` auto-deploys to production. The
  babysitter merged nothing all night by design — it drove PRs to *ready* and left the
  merge press to the human (`ready = APPROVED && clean`, `judge.py:110`). The new feature's
  central change is letting a *bounded, audited* set of merges happen while away.

---

## 4. The worktree lifecycle — the real axis

The night's key insight: **"dedicated babysitter vs. workers self-babysitting" is the
wrong axis. The right axis is LIFECYCLE STAGE.**

```
   plan / orchestrate  →  get PRs in  →  closeout + wrap-up  →  archive
        (live)             (live)          (handoff)           (leaf)
```

(Steps are optional and apply to *several* worktrees, not all.)

The rule that falls out:

- While a worker is **live + has intended next steps** → it babysits its **own** PRs. A
  dedicated babysitter must not touch them — doing so steps on toes (#13781) and discards
  the worker's in-flight intentions (the staged composer text on `%69`/`%12`).
- **Closeout is the handoff boundary** *and* the mechanism that prevents losing intended
  next steps: the worker harvests its next-steps + learnings into the knowledge tree before
  it is considered done. Nothing is "done" until it has closed out.
- The **dedicated babysitter services only the long tail** — PRs whose worker has closed
  out or gone dead. Lean fresh context, one session for many orphans.

**So the babysitter's missing guard is: skip any PR whose authoring worktree is still
live + working — not just sensitive-path ones.** This is a new gate the design adds.

### 4.1 Deriving lifecycle stage from signals TBD already has

TBD does **not** need a new "lifecycle stage" column. It can be derived (seam report §2):

| Stage | Derivation from existing signals |
|---|---|
| **live + intended** | Any terminal in the worktree is `.working` or `.waitingForUser` (`TerminalActivityState`, `Models.swift:185–190`, set via the `terminal-activity` hook → `handleTerminalActivityEvent`, `RPCRouter+TerminalHandlers.swift:1082`), **or** staged/unsubmitted composer text is present. |
| **idle-but-not-done** | All terminals `.idle`/`.unknown` **but** the worktree still has open PRs it authored, OR a pending `ask-user-question`, OR staged composer text. **This is the state the DONE heuristic wrongly collapsed** — it must be its own stage, never archive-ready. |
| **closed-out** | Ran `/closeout`, harvested to the knowledge tree. Candidate for babysitter long-tail servicing + archive. |
| **dead** | Session gone (pane dead / process reaped — see `reaping-orphaned-agents-design.md`). Babysitter services its orphan PRs; archive when safe. |

The one genuinely new signal needed is a reliable **"has staged composer text"** read (the
night showed it's decisive and Tier-0 `tick.py` already parses it via `_composer`,
`tick.py:101`). Everything else is a derivation over existing state.

---

## 5. The Away / Back toggle — UX and state

### 5.1 State

A single global mode on the `Config` row (seam §1): `nightwatchMode ∈ {off, nightwatch,
daywatch}`. Add `nightwatch_mode` in a new `v32` migration
(`Database.swift:504–543` pattern), a field on `Config` (`Models.swift:409–439`), and a
`setNightwatchMode` RPC modeled on `handleSetClaudeSpawnPreferences`
(`RPCRouter+ClaudePreferencesHandlers.swift:8–12`), in a new
`RPCRouter+NightwatchHandlers.swift`. Per CLAUDE.md's migration rule, the Codable model
field must be optional/defaulted so existing rows decode.

### 5.2 Nightwatch initiation — the interactive HTML pre-flight

Adam is present when he hits Away→Nightwatch, so we get one interactive moment. The vision:
sweep the fleet's open PRs into **clear / hold / test-hold** *fast*, without typing an
exhaustive list. This is the pre-flight.

- Render it in TBD's existing **webview pane** — `PaneContent.webview(id, url)`
  (`PaneContent.swift:5–21`) via `WebviewPaneView` (`WebviewPaneView.swift:40–56`), which
  loads a local `file://` HTML. A new `NightwatchHTMLRenderer` writes
  `~/tbd/runtime/nightwatch-preflight-<uuid>.html` listing every open PR with its enriched
  metadata (paths, size, approval, checks, authoring-worktree-live?).
- The human triages with three buttons per PR: **Clear** (may auto-merge when green),
  **Hold** (never while away), **Test-hold** (I want to personally test first). Bulk
  actions ("clear all non-sensitive under N lines").
- Button clicks post back to the app (WKWebView `MessageEvent`, available but not yet
  wired — seam §8) which writes rows into the **clearance ledger** (§7.3), each **pinned to
  the PR's current head SHA**.
- This replaces the prototype's flat `cleared-to-merge.txt` / `test-hold.txt` with a
  structured, SHA-pinned, audited store.

The pre-flight is **optional** — skip it and Away runs with only the auto-clear rule and
in-channel grants (a strictly smaller merge set). It is a fast-path for "I know these five
are fine," not a gate.

### 5.3 Daywatch initiation

No pre-flight (he's distracted). Daywatch starts silently and runs the batch-not-escalate
policy. It is an **orchestrator he can talk to**: he can open the nightwatch session and
ask "where should I look?" and it answers from the live tick report.

### 5.4 Back — wrap-up, not stop

Hitting Back sets mode `off` but does **not** hard-stop the watch. It:
1. Freezes new auto-merges and new spawns.
2. Generates the **wrap-up report** (§9) and surfaces it (notification →
   webview tab, seam §5/§8).
3. Lets in-flight children finish and keep maintaining in the background until Adam
   explicitly says stop.

---

## 6. The watch-tree spawn model + backpressure

### 6.1 Shape: a bounded tree, biased flat

The external research is unambiguous (§13): flat supervisor → parallel workers beats deep
trees; documented failure modes (context loss at handoff, coordinator cost blowup, "lost
intentions") set in past **depth ≈ 3** and fan-out ≈ 8–10. Counter-evidence #2 adds the
compounding-error and runaway-spawn risks.

So the tree is **allowed but capped and shallow**:

- **Depth cap = 2** by default (Nightwatch → child; a child may spawn its own workers only
  up to total depth 3, and only past a backpressure check). Configurable in policy, but the
  daemon enforces a hard ceiling.
- **Fan-out + total caps.** Max concurrent children per parent, and a **fleet-wide total
  live-agent cap**. The daemon refuses a spawn RPC past the cap (compiled backstop against
  the "40 PRs × 3 agent types = 120 agents" runaway in Counter #2).
- **Lineage accounting.** Every spawned child carries `parentWorktreeID`
  (`Models.swift:129`, v23), so the tree is inspectable and archive can walk it leaves-up.
- **Parent-premise re-verification (stress-test, Claim 3).** Caps stop *count* runaway but
  not *semantic* error-compounding: a child that inherits a wrong parent premise (parent
  misread one PR timeout as "CI broken") cascades that mistake deterministically through the
  whole allowed subtree — a bad-root tree is *worse* than a flat fleet. Lineage is post-hoc
  visibility, not prevention. So: **a child never inherits its parent's belief; it re-fetches
  fresh state and re-verifies the premise before any consequential action.** Concretely the
  spawn returns a short-lived **parent-state token**; the child must re-present it on any
  parent-dependent action (a merge, a further spawn), the daemon validates freshness, and on
  a stale token the child **escalates and dies gracefully** rather than proceeding. And a
  clearance void (§7.3) **propagates to children**: any child holding a clearance for the
  voided PR is auto-escalated, not left retrying.

### 6.2 The spawn mechanism

**Verified correction (stress-test).** The seam report's "the daemon can't spawn without a
subprocess or new RPC" is **wrong**: `beginCreateWorktree` / `completeCreateWorktree` /
`createWorktree` are already **public methods on the daemon-side `WorktreeLifecycle`**
(`WorktreeLifecycle+Create.swift:29, 50, 157`) — the RPC handler is just one caller. So a
daemon-resident `NightwatchCoordinator` **calls the lifecycle methods directly**, in-process:

| Option | How | Tradeoff |
|---|---|---|
| **A. Direct in-process call** ★ | Coordinator calls `beginCreateWorktree` + `completeCreateWorktree` with `parentWorktreeID`/`initialPrompt`. | Zero subprocess, zero new RPC surface, reuses the exact tested two-phase path. Avoids the subprocess-reconnects-to-own-socket reentrancy/deadlock the arch review flagged. |
| **B. Subprocess `tbd worktree create`** | Shell out with `--parent`/`--prompt-file`. | Matches how the *skill* acts today, but reconnects to the same daemon socket — reentrancy risk; only needed if spawn must originate from the skill rather than the daemon. |

**Recommended: A.** Because create is two-phase async, the coordinator (or the skill, via a
status RPC) must **wait for `status == .active`** before assigning the child work — a child
handed a PR before Phase-2 completes may reference a worktree that fails `git worktree add`
(arch review). The *decision* to spawn stays policy (editable skill requesting it); the
*act* is the daemon calling its own tested lifecycle method.

### 6.3 Backpressure — a first-class input, not an afterthought

The night held nudges on capacity and held spawns on host memory *by hand*. Make both
signals native (seam §6):

- **Model capacity**: reuse `ClaudeUsagePoller` (`Daemon.swift:327–337`) + the proxy's
  routable-account count (the prototype's `MIN_ROUTABLE=2` rule, `tick.py:175`).
- **Host memory/swap**: genuinely new. Add a `HostResourceProbe` (macOS `host_statistics()`
  / `vm_stat`) sampling swap + physical-memory pressure. The night's 87%→94% swap climb is
  exactly the signal that should pause spawns.

Backpressure policy (editable) consumes these; the daemon just exposes them. When either
crosses threshold: **pause spawns and pause auto-nudges; keep the tick running; surface the
condition.** Optionally pause a babysitter child. This is the prototype's
capacity-aware-backoff generalized to include the host.

**Fail the probe closed (stress-test, pre-mortem #5).** A probe that silently returns 0 /
hangs / can't read (the unbundled `host_statistics()` is an untested assumption, §12) would
read as "green" and let spawns run into a 95%-swap OOM. So: after N consecutive probe
failures, **assume worst-case (at-threshold) and halt spawns until the probe recovers**, and
log every failure — never treat an unreadable probe as healthy.

---

## 7. The merge gate — the crux

Today: nightwatch **never merges** (`judge.py`), drives PRs to ready, human presses merge.
The new feature lets a **bounded, audited, reversible** set of merges happen while away.
This is the most contested surface (Counter #1, #4) and gets the most guardrails.

### 7.1 What may merge — a UNION, minus HARD HOLDS

A PR is auto-mergeable **iff** it clears the safety floor AND at least one clearance path
authorizes it AND no hard hold applies:

```
auto_mergeable(PR) =
     SAFETY_FLOOR(PR)                       # compiled invariant, non-negotiable
 AND ( pre_cleared(PR)                       # (a) HTML pre-flight clearance, SHA-pinned
       OR small_and_safe(PR)                 # (b) auto-clear rule (editable policy)
       OR in_channel_grant(PR) )             # (c) human told an agent, in its channel
 AND NOT hard_hold(PR)                        # sensitive path OR test-hold — always wins
```

**SAFETY_FLOOR (compiled, enforced by the daemon):** claude-review APPROVED **on current
head SHA** + all required checks clean + PR not draft. This is the prototype's existing
`ready = (verdict=="APPROVED" and mstate=="clean")` (`judge.py:110`), promoted to an
invariant the daemon checks itself before any auto-merge, so no policy bug can bypass it.
Three properties the floor must have (plan-review, security):
- **Fail closed.** If *any* read errors (GitHub API failure, stale-cache detected,
  unexpected state), assume not-safe and escalate — never merge on a partial check.
- **Re-fetch at merge time, not from cache.** Re-read review state + checks from GitHub
  *inside* the gate immediately before `gh pr merge`, and compare against the head SHA
  GitHub returns (not the DB's). Closes the check-passed-then-regressed race and the
  stale-approval-under-old-code race. **This re-fetch MUST bypass the `gh-cache-proxy`**
  (stress-test, pre-mortem #4): that proxy serves `304`s from cached ETags, so a naive
  "fresh" read can hand back a stale SHA and merge unapproved code. Send `Cache-Control:
  no-cache` (confirm the skip-header with the proxy) — the merge-time SHA/checks read is the
  one place cache-correctness is load-bearing.
- **Refuse on zero required checks.** A repo with an empty required-status-checks list reads
  "green" because nothing ran. Read the *required* set from branch-protection config and
  fail closed if it's empty (misconfiguration ≠ safe).
- **Compiled size-ceiling; policy may only tighten (stress-test, atk_gate Vector 3).** The
  small+safe *size bounds* live in editable policy — but a bad or over-eager policy edit that
  widens them isn't gated with a compiled change's rigor, silently expanding the merge set.
  So the daemon enforces an absolute maximum (e.g. ≤ 50 changed lines, non-runtime paths) as
  a compiled ceiling: policy can subset it, never superset it. And the nightwatch policy
  files themselves (`.nightwatch/policy.json`) are a **sensitive path** — widening the gate
  requires a human-reviewed change like any other sensitive edit.

**HARD HOLDS (always win over any clearance):**
- **Sensitive paths** — `infrastructure/`, `atlantis.yaml`, `db/migrations`,
  `paradedb_migrations`, `functions/`, `.github/`, `.claude/`, `scripts/ci/`,
  `backend/app/middleware/`, `shared/longeye_shared/`, anything auth. Org ruleset requires
  a devs-team human review on head; the daemon refuses regardless of clearance. **Do not
  hardcode this list** (plan-review, arch + security): it drifts from the org's source of
  truth (a new sensitive dir added upstream would merge unchecked). Instead **derive** it —
  sync the org CODEOWNERS / branch-protection rules into a native **sensitive-paths config
  store** (a DB table the daemon enforces membership against) at Nightwatch startup, and
  re-verify per merge. Membership edits without a rebuild; enforcement stays compiled. Use a
  real glob/CODEOWNERS matcher, not string prefixes (guard against rename/symlink evasion).
- **Self-modifying CI** — any PR touching `.github/workflows/`, `atlantis.yaml`, or CI
  config is a hard hold regardless of size/safety (a PR that skips its own failing test
  reads "clean"). This is a subset of sensitive paths, called out because it defeats the
  check-based floor directly.
- **Test-holds** — anything Adam flagged to personally test.
- **Authoring worktree still live + working** (§4's new guard) — don't merge out from under
  an active author.

### 7.2 The three clearance paths, each with its guardrail

| Path | Guardrail (the thing that makes it safe) |
|---|---|
| **(a) Pre-clear** (HTML pre-flight) | Clearance is **pinned to the head SHA at clear time.** If the head advances (rebase, new commit), the clearance is void until re-verified that claude-approval survived on the new head. Directly answers the #13781 "approval didn't survive the force-push" incident. |
| **(b) Small + safe** | Non-sensitive path + SAFETY_FLOOR + **size bound** (diff/commit count) + no "large-decision" or "wanted-to-test" marker + authoring-worktree-not-live. Default posture **conservative** (because small still ships to prod, §3); the path list + size bounds live in **editable policy**, not compiled, so "safe" can evolve without a rebuild (answers Counter #3's decaying-heuristic point). |
| **(c) In-channel grant** | The riskiest. Made safe by **capturing the grant as a structured token at utterance time, not re-derived later from scrollback.** When the human types "you can merge #14030" in an agent's channel, the agent registers a clearance via `tbd` **scoped to that exact PR number**, SHA-pinned, immediately. If an agent cannot pin a grant to a specific PR number, it **escalates instead of merging** — never a free-text "I believe I was told." Still subject to SAFETY_FLOOR + hard holds. This is the direct guard against Counter #1's "Slack message misread as a deploy signal." **Two authz additions (plan-review, security):** (1) **who may grant** — only an allowlisted human (Adam, by Slack user-id); a grant from anyone else escalates, never clears. (2) **the grant must be a fresh, timestamped ledger entry registered at utterance time** — the gate refuses any merge whose clearance was reconstructed from scrollback (no matching timestamped row → escalate). Optionally the agent **echoes back** ("I'll auto-merge #14030 when green — registered") so a misread is caught before it's load-bearing (§15, fork 2). |

### 7.3 The clearance ledger (native)

A new DB table (SHA-pinned, append-only, audited): `(id, pr_number, repo,
cleared_when_sha, pr_state_at_clear, clearance_kind ∈ {preclear, small_safe, in_channel},
granted_by, granted_at, void_reason?)`. The daemon writes it; the wrap-up reads it. This
replaces `cleared-to-merge.txt` / `test-hold.txt` with structured state and gives every
auto-merge a provenance record. Plan-review refinements:
- **Only a trusted service identity may write clearance rows** — not any process on the
  daemon socket (else a compromised agent forges a clearance). Gate the write RPC on
  worktree-id/service identity.
- **Store `cleared_when_sha` + `pr_state_at_clear`.** On re-check the daemon compares BOTH
  against current head SHA and PR state; on mismatch it **voids with a reason**
  (`sha_mismatch`, `rebased`, `pr_draft`, `checks_failed`, `reopened`). The `void_reason`
  makes failure legible: the wrap-up surfaces "3 merges completed, 2 clearances voided
  (rebased)," and the skill's next tick queries voided rows to avoid re-clearing a stale PR.
- **Conservative default: any SHA change voids the clearance.** A `rebase_safety` policy
  flag (in the editable skill, not the daemon) may later auto-re-clear a rebase-onto-main
  whose new diff is a subset of the old — but that judgment stays out of the compiled floor.
- **Clearances are PR-scoped, not worktree-scoped** — they outlive an archived child and
  stay immutable/auditable; archive (§9.3) does not touch the ledger.
- **Human intent can reverse — support supersede/revoke (stress-test, pre-mortem #3).** A
  grant captured at 23:47 is *sticky*: if Adam later says "actually hold #14030," the
  immutable ledger would still merge it. So a later **`supersede` entry** (the human types
  "ignore/revoke the grant for #14030" in the channel, or clicks it in the wrap-up) writes a
  new row voiding the prior clearance by id; the daemon refuses any clearance with a
  later-timestamped supersede. Newer human intent always wins over an older grant.

### 7.4 Reversibility + audit (answering "it ships to prod")

Because every merge auto-deploys:

- Every auto-merge writes an **audit record**: which clearance authorized it, the SHA, the
  changed paths, the checks state, and the **merge commit** (so a one-click revert is
  possible from the wrap-up). Concretely a native `audit_log` table (new migration) +
  mirrored `os.Logger` line per action (plan-review, data): the DB is the source of truth
  the wrap-up reads; the log is the incident-review safety net if the DB is recreated. (No
  `print()` in `Sources/` — CLAUDE.md.)
- The wrap-up (§9) leads with "**merged while you slept**" — each with its provenance and a
  revert affordance. The posture is *conservative + fully reversible + fully audited*, not
  *maximize merges*.
- **"Reversible" is not free** (plan-review, security). A revert is itself a prod deploy, so
  it must pass the **same safety floor** (approval/checks) before auto-reverting — not a
  fast-path bypass. The wrap-up must also report whether each merge is **cleanly
  revertible** (dry-run `merge --no-commit` detects conflicts) and whether a **later merge
  depends on it** (a revert cascade); a merge that can't be cleanly reverted was a
  higher-blast-radius action that should have been held more carefully.

### 7.5 PR metadata the gate needs (new)

Seam §4: `PRStatusManager` fetches number/url/state/checks/reviewDecision today, but **not**
changed paths, size, or author — all three are required by the gate. Extend
`PRStatusManager.refresh()` to also fetch `gh pr view --json files,commits,author` and add
those fields to `PRStatus` (`Models.swift:560–572`). This is the one unavoidable native PR
extension.

---

## 8. Daywatch vs. Nightwatch — the differences, precisely

| Dimension | **Nightwatch** (gone indefinitely) | **Daywatch** (present, distracted) |
|---|---|---|
| Goal | Maximize forward progress; go on without him | Orchestrate; point him at what matters |
| Initiation | Interactive HTML pre-flight (he's present) | Silent (he's mid-task) — no pre-flight |
| Held decisions | Escalate only genuinely hard calls; each must feel "glad you waited" | **Batch** into one sweep for when he surfaces; do NOT notify per decision |
| Auto-actions | Act on obvious + drive PRs + bounded auto-merge | Act on the **obvious only**; queue the rest |
| Interruption | Async — he's asleep | Synchronous — he can open it and *talk to it* |
| Notifications | Rare, high-signal, hard-call only | Near-silent; a single batched surface on demand |
| Ends by | Back → wrap-up | Back → batched sweep |

The two share all mechanism (§2–§7); they differ only in the **policy** layer's escalation
and notification thresholds — which is exactly why policy lives in the editable skill.

---

## 9. The wrap-up / closeout / archive flow

Triggered by **Back**. Three phases, in order.

### 9.1 The status report (reorientation is the product)

External research (§13) maps this to standup-generators + incident-timelines. The report,
rendered to a webview tab, has three parts:

1. **What happened while you were gone** — merges (with provenance + revert, §7.4), PRs
   advanced to ready, children spawned/retired, nudges fired, backpressure events.
2. **Reorientation of what *you* were working on** — because he'll have forgotten. For each
   worktree he was driving before Away: where it is now, what moved, what's blocked. This
   is the highest-value, least-obvious part.
3. **A SMALL batch of held decisions** — the "glad you waited on these" set. Small is a
   feature: if the batch is large, the escalation threshold was too low.

**The report is the product — specify it, don't hand-wave it (stress-test, pre-mortem #1,
the highest-likelihood failure).** If the reorientation is a wall of text or an
under-summarized JSON dump, Adam closes it in 90 seconds and stops trusting the feature. The
renderer works off an explicit content schema — roughly:
`{ merges:[{pr, sha, clearance_kind, changed_paths, revert_link, revertable?, merged_at}],
advanced_prs:[…], children:[{id, status, spawned_at, retired_at}], reorientation:{
user_worktrees:[{id, before→after, whats_new_vs_known_blocker}] }, held_decisions:[…],
backpressure_events:[…], duration }` — with a **"what's news vs. what you already knew"**
distinction on each reorientation item (the hard part), and the held-decisions batch derived
from the policy's escalation threshold. Read-only first; inline Clear/Revert/supersede
buttons are a later enhancement gated on the same message-back wiring as the pre-flight (§16).

### 9.2 Self-closeout → the knowledge tree

Sessions that learned a lot run `/closeout` **on themselves**, harvesting next-steps +
learnings into the knowledge tree *before* being considered done (§4 — closeout is the
handoff that prevents losing intentions). **Never auto-closeout on the DONE heuristic
alone** (§3: the queued "Run /closeout" task fooled Tier-0). Gate closeout on the real
done-signal: no open authored PRs unresolved, no staged composer text, no pending question.

**Enforce it with a real field, not a principle (stress-test, pre-mortem #2 — the top
pre-ship fix).** The §3 %69/%12 misclassification is a *recurrence* risk: a stated principle
with no mechanism will misfire again. Add an explicit `Worktree.closeoutState ∈ {live,
idleButNotDone, closedOut, dead}` (new field, v32-family migration + Codable default per
CLAUDE.md), set to `closedOut` only when `/closeout` **completes** (a queued task is not a
completion) and to `dead` by session-death detection (the reaper design). **Archive refuses
unless `closeoutState ∈ {closedOut, dead}`** — a compiled hard-gate in
`WorktreeLifecycle+Archive.swift`, cheap and decisive, that makes losing-work-before-closeout
structurally impossible rather than heuristically unlikely.

### 9.3 Archive — leaves-up

Archive respects tree structure (§3: "Archive nested worktrees first"). Walk the lineage
(`parentWorktreeID`) and archive **leaves first, parents last**. Reuse the existing
two-phase archive (`WorktreeLifecycle+Archive.swift`), which already preserves resumable
session IDs. Never archive a worktree still in *live+intended* or *idle-but-not-done*.

---

## 10. Token / cost mechanics — getting the story right

The vision's framing had one imprecision the external research corrected; here is the
reconciled, correct version (all Anthropic numbers T1, live-fetched 2026-07-03):

- **Sessions are stateless** — each *model turn* re-sends the full prefix. TRUE.
- **Prompt caching** discounts the unchanged prefix: cache **write ≈ 1.25× base, read ≈
  0.1× base (90% off)**, **5-minute default TTL** (1-hour option exists). T1.
- **A *script* poll is not a model turn.** The vision's claim — a bash loop / `poll_pr.py`
  polling GitHub costs zero model tokens — is **correct**. The external agent's "polling is
  a turn" is true only for a *model* doing the polling. The reconciliation: **do the polling
  at Tier-0 (script), not with a model.** This is exactly what `tick.py` is (model-free
  sweep) — and it's why the tier architecture is the right shape, not an accident.
- **So "self-babysitting re-sends the whole context every poll" is FALSE** at the tier the
  prototype actually polls (Tier-0, no model).
- **The real burn driver** is a session taking **many model turns while carrying a large
  (ctx ≥ 85%) context** — each such turn re-sends the big prefix (partly cache-discounted
  within the 5-min TTL). TRUE, and it's why `d98c2cc` added the ctx≥85% burn-risk detector.
  The dedicated-babysitter's token win is **lean fresh context + one session for many
  orphans**, NOT "avoids per-poll resend."

Design consequences: (1) keep the model-free Tier-0 tick as the runtime; page a model only
for judgment. (2) Prefer **parallel fan-out over serial chains** for any model work
(external: 10–15× cheaper). (3) The dedicated babysitter should run **lean** context and be
recycled before it bloats past the burn threshold.

> Cost figure to hold loosely: external modeled ~$540/mo (cached) vs ~$5,400/mo (uncached)
> for a 40-agent fleet. **Modeled, not measured** — treat as order-of-magnitude, not a
> budget.

---

## 11. Candidate shapes (ranked)

### Shape 1 — Native mechanism + skill policy, conservative auto-merge  ★ recommended
Native: mode flag, PR-metadata enrichment, SHA-pinned clearance ledger + audit,
`HostResourceProbe`, spawn-via-subprocess with caps, notification/HTML surfaces, the
compiled SAFETY_FLOOR + hard holds. Policy stays in the nightwatch skill/`policy.json`.
Auto-merge default **conservative + reversible**.
- **Pros**: answers all four counter-findings; iterates at model speed; blast radius bounded
  by the compiled floor; reuses maximal existing surface.
- **Cons**: two-layer system (daemon + skill) to keep coherent; the HTML message-back wiring
  is new; `HostResourceProbe` + PR-metadata are net-new native code.

### Shape 2 — Fully native policy engine
Compile the classification, gate, and spawn policy into the daemon.
- **Pros**: one system; strong typing; testable in one place.
- **Cons**: exactly Counter #3 — every heuristic change is rebuild+restart+migration; a bug
  runs in-process fleet-wide; policy iteration crawls. **Rejected** as the primary shape.

### Shape 3 — Stay a pure skill, add only the toggle
Native contributes only the Away/Back button + mode flag; everything else stays scripts.
- **Pros**: minimal native change; fastest to ship.
- **Cons**: no native clearance ledger/audit → the merge gate stays as unsafe as flat
  text files; no host-resource signal; no structured wrap-up surface. **Under-delivers**
  the safety the prod-auto-deploy reality demands. Good **Phase 0**, not the destination.

**Recommended path: Shape 3 as Phase 0, then Shape 1 incrementally.** Each phase is
independently shippable and demo-able; auto-merge stays **off by default** and is gated
behind Phase 1.5 with very conservative size bounds, flipped on per-repo only once proven
(plan-review, arch):

| Phase | Lands | Auto-merge |
|---|---|---|
| **0** | Away/Back toggle + `nightwatch_mode` flag; keep the skill as-is | dark |
| **1** | PR-metadata enrichment (paths/size/author) + clearance ledger + audit_log + the compiled SAFETY_FLOOR & hard holds; daemon *evaluates* the gate but merges nothing | off |
| **1.5** | small+safe clearance **policy** (in `policy.json`, no UI); skill writes clearance rows, daemon honors them → first auto-merge path, conservative default | **off by default**, per-repo opt-in |
| **2** | in-channel grants (agent registers on utterance, with authz) | as 1.5 |
| **3** | `HostResourceProbe` + spawn caps + backpressure | — |
| **4** | HTML pre-flight + wrap-up/reorientation surfaces | — |

In Phases 0–1 an in-channel grant or a pre-clear simply drives the PR to *ready + escalate*
(today's behavior), never merges.

---

## 12. Assumptions (flagged where unverified)

1. **The safety floor is genuinely sufficient to gate prod deploys.** APPROVED-on-head +
   clean-checks + non-sensitive + size-bound + reversible. *Unverified that this catches
   the classes Counter #1 raises* (logic bugs, perf regressions CI misses). Mitigation is
   reversibility + conservative default, not perfect detection. **Load-bearing — stress-test
   this.**
2. **Changed-path + size metadata is cheaply available** via `gh pr view --json
   files,commits`. *Verified the fields exist; not verified at 40-PR GraphQL cost/rate.*
3. **In-channel grants can be reliably captured at utterance time** (the agent registers a
   PR-scoped clearance when told). *Depends on the agent doing so; if it reconstructs from
   scrollback instead, the guardrail is void.* **Load-bearing.**
4. **Host swap/memory is readable without a bundle-id** (`host_statistics()`/`vm_stat`).
   *Consistent with the unbundled-executable constraints; not yet prototyped.*
5. **Depth-2/3 tree is enough** for the real load (PR babysitter, closeout, health). *The
   night ran effectively depth-1; deeper is speculative.*
6. **WKWebView message-back can drive the pre-flight** without a bundle. *The API exists
   (seam §8); not wired; the unbundled constraint (CLAUDE.md) may bite.* **Verify early.**

---

## 13. Counter-evidence (the strongest case against — from a blind reviewer)

A fresh reviewer, not shown the design's rationale, built this case. Summarized honestly,
with where the design answers it and where the concern stands.

1. **Auto-merge to a prod-deploying main while asleep, esp. the in-channel-grant path.** An
   agent misreads a channel ("that PR is sketchy, keep it in mind") as a merge instruction →
   prod bug, no human to catch it. **Design answer:** grants are captured **at utterance
   time, PR-number-scoped, SHA-pinned** (§7.2c) — never reconstructed; unpinnable grants
   escalate. Plus SAFETY_FLOOR + hard holds + reversibility. **Residual risk stands:**
   claude-review + green checks don't catch logic/perf bugs; the mitigation is
   conservative-default + one-click revert, not detection. → **primary stress-test target.**
2. **Recursive spawning compounds errors + risks runaway.** **Design answer:** depth cap,
   fan-out + fleet-total caps enforced by the daemon (§6.1), lineage accounting, bias-flat.
   The external research independently sets the same depth≈3 / fan-out≈8–10 ceilings. Concern
   largely answered by caps.
3. **Don't compile fast-moving judgment into the Swift daemon.** **Design answer:** this is
   §2 — the entire mechanism/policy split exists to honor exactly this. Judgment stays in
   the editable skill; only mechanism + the safety floor are compiled. **Concern adopted as
   a design principle, not rejected.**
4. **The human bottleneck is a feature; you return to a 12-hours-moved codebase.**
   **Design answer:** this is why wrap-up/reorientation is framed as *the product* (§9.1),
   why auto-merge is conservative + reversible, and why held decisions are a *small* batch.
   **Concern partially stands** — it is a genuine philosophical cost of the feature, and the
   design's honest position is: bound the blast radius and make the morning legible, don't
   pretend the cost is zero.

The reviewer's overall stance ("auto-merge is a category error — don't") is **not adopted**:
Adam has decided he wants a bounded merging gate. But every guardrail above exists because
of this critique, and #1's residual risk is the thing stress-test-plan must hammer.

---

## 14. Source quality

- **T1 (authoritative):** Anthropic prompt-caching docs (live-fetched 2026-07-03: 5-min TTL,
  1.25× write / 0.1× read); the TBD codebase itself (all `file:line` seams); the live night
  evidence (`~/.claude/skills/nightwatch/queue/*` — babysitter-log, for-adam, decisions.jsonl,
  mode.txt); the prototype scripts (`tick.py`, `judge.py`); LangGraph human-in-the-loop and
  GitHub branch-protection/auto-merge official docs.
- **T2 (reputable secondary):** multi-agent orchestration writeups (supervisor vs.
  hierarchical), OpenAI Agents/Swarm handoff docs, Mergify/merge-queue practice.
- **T3–T4:** the depth≈3 / fan-out≈8–10 thresholds and the ~$540/mo cost model are
  **modeled/practitioner-level**, not measured here — flagged as order-of-magnitude.

The load-bearing safety claims (§7 gate) rest on **T1** (the codebase + the org ruleset +
the night's incidents). The cost/scale numbers rest on **T3** and are labelled as such.

---

## 15. Open questions / forks for Adam

1. **Auto-merge default posture.** Ship with auto-merge **off** (drive-to-ready only, like
   today) until the ledger + floor + audit are proven, then flip on per-repo? Or enable the
   small+safe path from day one for non-sensitive PRs? (Recommendation: off first.)
2. **In-channel grants — how much to trust.** Require the agent to *echo back* the grant for
   confirmation ("I'll auto-merge #14030 when green — registered"), or accept silent capture?
   The echo costs a turn but closes the misread risk further.
3. **Tree depth.** Is depth-2 (Nightwatch → children, no grandchildren) enough, or is the
   PR-babysitter-spawns-per-PR-workers pattern needed (depth-3)? The night ran depth-1.
4. **Spawn mechanism.** Subprocess `tbd` (Shape 1-A, zero new RPC) vs. daemon-private
   `watchtree.spawn` RPC (1-B)? Recommendation: subprocess first.
5. **Where the knowledge tree lives** — is it the existing `docs/knowledge/INDEX.md`
   pattern seen in the night's #13944 rebase, or a new native store? (Out of scope for this
   doc; flag for the closeout design.)
6. **Wrap-up interactivity.** Is the reorientation report read-only, or should its held-
   decision batch have inline Clear/Revert buttons (message-back wiring, seam §8)?

---

## 16. Plan-review enrichments (design-time specialist annotations)

Three specialists (architecture, security, data-model/concurrency) reviewed this doc in
design-mode. Their load-bearing gotchas are threaded inline above (§7 fail-closed floor +
derived sensitive-paths + revert blast-radius; §7.2c grant authz; §7.3 void-reason
lifecycle; §11 phasing graph). The remaining implementation-shaping notes:

**Schema (data).** Per CLAUDE.md's three-changes-in-one-commit rule (migration + GRDB
Record + optional/defaulted Codable model): `v32` = `nightwatch_mode TEXT DEFAULT 'off'` on
`config`; `v33` = `clearance` table (new `ClearanceStore` under
`Sources/TBDDaemon/Database/`); `v34` = `audit_log` table; new `PRStatus` fields
(`files`, `commits`, `authorWorktreeID`) all optional so old rows decode. Sensitive-paths
config store is its own table synced from CODEOWNERS.

**Two-layer contract (arch).** The skill must *request* a merge and the daemon must
*re-verify + execute or refuse* — a plain text file the daemon acts on is unsafe. Define an
RPC where the skill submits `(pr, repo, expected_sha, clearance_id)` and the daemon runs the
floor itself before merging, returning executed / refused-with-reason. The skill never
merges; the daemon never trusts the skill's view of PR state (TOCTOU).

**Spawn reentrancy (arch + data).** The daemon shelling out to `tbd worktree create`
(§6.2-A) reconnects to the *same* daemon socket → verify the RPC handler is truly async and
does not block in `Process.run()` (deadlock risk), and have the spawn return a **token the
skill polls until `status == .active`**, since create is two-phase (a child assigned work
before Phase-2 completes may reference a worktree that fails `git worktree add`). Reentrancy
here manifests as retry-safe policy failures, not data corruption (Phase-1 and Phase-2 touch
different rows) — but the skill must wait for `.active`.

**PR-metadata cost (arch + data).** Fetch `files,commits,author` **lazy + cached with a
TTL** rather than for all ~40 PRs every tick; re-fetch fresh inside the gate at merge time
(§7.1). Verify the `gh pr view --json files,commits` cost at 40-PR scale against the
gh-cache-proxy's rate-limit pooling before committing to a cadence.

**NIO + host probe (data).** The watch loop is a standard `Task { while !isCancelled }`
(`Daemon.start()` pattern); it may touch GRDB freely (own queue) but any state-delta
broadcast must be wrapped in `context.eventLoop.execute { }` and must never pre-check
`context.channel.isActive` off the loop (CLAUDE.md NIO rule). `HostResourceProbe`
(`host_statistics()`/`vm_stat`) is an O(1) BSD syscall needing no bundle id (~1–2ms;
sample ~10s, broadcast threshold crossings only) — safe for the unbundled executable.

**Testability (data).** Every gate branch needs a test (CLAUDE.md): mode on/off, each
clearance path, each hard hold, each spawn cap, each backpressure gate. Prefer **injection
seams** — a `MergeGate(policy:)` and `Spawner(tree:, caps:)` unit-testable with no
`~/tbd` — over `setenv`. Clearance-ledger integration tests that need a real DB must live
**only under `TBDHomeSerialized`** (the setenv-races-every-suite rule).

**Verify-early (arch + data).** The WKWebView message-back path (§5.2 pre-flight) is the
riskiest unknown under the unbundled-executable constraint — build a minimal
webview-click-→-RPC spike before the full pre-flight; fallback is wiring clicks through the
app socket rather than `WKScriptMessageHandler`.

---

## 17. Stress-test verdicts + the must-address gate

The enriched doc was adversarially stress-tested — attacker/defender debate on the judgment
calls, a fact-verifier, a pre-mortem, and a **separate blind judge** (not the author) issuing
calibrated verdicts. The three load-bearing claims each **SURVIVE — with conditions**; none
was refuted, and none is unconditionally safe. Verdicts (basis tagged):

| Claim | Verdict | Basis | The condition that carries it |
|---|---|---|---|
| **1 — the layered merge gate is acceptably safe for prod-auto-deploy while away** | SURVIVES-WITH-CONDITIONS | code-grounded | The conceded residual (a subtly-wrong PR — feature-interaction between two individually-safe PRs, or a claude-review miss on a semantic bug — ships to prod for N hours) is **acceptable-bounded, not a show-stopper**, *only* given: off-by-default + per-repo opt-in, an extremely conservative default (≤~50 lines, non-runtime paths), full audit + provenance + reversibility, wrap-up-leads-with-merges, and merge-time re-fetch that bypasses the cache. Remove any of those and it tips to show-stopper. |
| **2 — mechanism/policy split keeps judgment out of the compiled daemon** | SURVIVES-WITH-CONDITIONS | code-grounded | Holds only if sensitive paths are **derived from CODEOWNERS** (not hardcoded) and the daemon/skill boundary is defended as a standing constraint — any new *hard hold* needs a design review/ADR, not just a code change, or judgment silently re-accretes in the daemon. |
| **3 — depth caps prevent error-compounding & runaway** | SURVIVES-WITH-CONDITIONS | argument-only | Caps stop *count* runaway (code-enforceable) but **not** semantic cascade; carries only with the §6.1 parent-premise token + void-propagation. Note: argument-only, not a proven fact. |

**Must-address before implementation** (ranked; folded into the sections cited — this is the
gate the plan-review/stress-test cycle produced):

1. **Child parent-premise re-verification** (design-gap → §6.1) — fresh state + parent-state
   token; stale ⇒ escalate. *The most serious architecture gap.*
2. **In-channel grant capture + authz** (design-gap → §7.2c) — utterance-time, PR-scoped,
   SHA-pinned, Slack-user-id allowlisted; no scrollback reconstruction.
3. **Sensitive paths derived from CODEOWNERS** (design-gap → §7.1) — synced native store, not
   a compiled list; glob/CODEOWNERS matcher.
4. **Enforced `closeoutState` archive gate** (design-gap → §9.2) — archive refuses unless
   `closedOut`/`dead`. *Highest-damage lifecycle fix; the %69/%12 recurrence.*
5. **Wrap-up output schema + "what's news"** (design-gap → §9.1) — *highest-likelihood*
   failure if left unspecified.
6. **Merge-time re-fetch bypasses `gh-cache-proxy`** (impl-risk → §7.1) — else a 304 merges a
   stale SHA.
7. **Grant supersede/revoke** (design-gap → §7.3) — newer human intent wins.
8. **Backpressure probe fails closed** (impl-risk → §6.3) — unreadable ≠ healthy.
9. **PR-metadata lazy-fetch + TTL, cost-checked at 40-PR scale** (impl-risk → §16).
10. **WKWebView message-back spike early; socket fallback** (impl-risk → §5.2/§16).
11. **Revert blast-radius/cascade detection** (impl-risk → §7.4) — dry-run + dependency check.

The bar this clears: nothing in the design is *refuted*, but auto-merge (Phase 1.5+) must not
ship until items 1–8 are built. Phases 0–1 (toggle, metadata, ledger, audit, the evaluated-
but-merges-nothing floor) are safe to build now and are how items 3/4/6 get exercised before
any merge is live.
