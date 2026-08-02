import Foundation

/// Canonical content for the `nightwatch` skill — a quota-lean TBD-fleet
/// babysitter bundled into the TBD Claude plugin. Repo-agnostic core; each
/// child repo plugs in policy via <repo>/.nightwatch/policy.json. The scheduler
/// (scheduler.sh / tick-cron.sh) ships but is opt-in — never auto-loaded.
/// Single source of truth, written by PluginDirWriter. Generated from the skill files.
public enum NightwatchSkillContent {

    /// Every script the daemon installs into `<skillDir>/scripts/`, in install
    /// order. `PluginDirWriter.writeNightwatch` iterates this rather than
    /// carrying its own list, so the set is visible to TBDShared tests — which
    /// is what lets `NightwatchDeskPromptsTests` assert that every script a desk
    /// prompt tells a session to run is actually shipped.
    ///
    /// That cross-check exists because the two drifted once: the judge prompt
    /// spent five days naming `tbd terminal close --all` (a command that never
    /// existed), and its replacement initially named `scripts/handoff.py` while
    /// the writer shipped only five scripts, none of them that one. A prompt
    /// naming an uninstalled path is the same defect wearing a different hat.
    public static let scripts: [(name: String, body: String)] = [
        ("tick.py", tickPy),
        ("wake.py", wakePy),
        ("judge.py", judgePy),
        ("handoff.py", handoffPy),
        ("tick-cron.sh", tickCronSh),
        ("scheduler.sh", schedulerSh)
    ]

    public static let skillMd: String = #"""
---
name: nightwatch
description: Autonomous TBD-fleet babysitter that runs mostly on scripts + a local model, paging Opus only for genuine judgment. Use to keep ~40 agent worktrees unblocked/gated overnight at a fraction of the Opus quota. Triggers — "babysit the fleet", "nightwatch tick", "drain the decision queue", "keep agents unblocked".
---

# nightwatch — quota-lean fleet babysitter

Keep a fleet of TBD agent worktrees unblocked, productive, and gated while the human sleeps — and do it **without burning Opus on mechanical work**. Most ticks touch no model at all.

## The tier policy (the whole point)

| Tier | Runs on | Does |
|---|---|---|
| **0** | `scripts/tick.py` — pure Python, $0 | sweep all panes (every tmux server), fleet capacity, classify every agent, split into auto/judgment/human, write `queue/tick-report.json` |
| **1** | local model (Ollama) or Haiku — *future* | classify ambiguous panes, triage escalations, draft routine nudges. Off the Opus quota. |
| **2** | **Opus — rare** | resolve genuinely ambiguous decisions, the deep review, any prod/security/CJI/access call. Wakes only when `queue/decisions.jsonl` has items. |
| **Human** | Adam | merge PRs, proxy/IAM/prod restarts, Slack pings, access, the capacity (Bedrock) lever. |

**Opus is the exception handler, not the runtime.**

## How a tick runs (cron/launchd calls this — no model)

```
python3 scripts/tick.py        # exit 0 = silent-ok · exit 10 = judgment queued
python3 scripts/tick.py --prs  # also gate open PRs (wraps loop_perfect_sweep.py; skip during GitHub-rate crunch)
```

`tick.py` prints a short human summary AND writes:
- `queue/tick-report.json` — full structured state (capacity, every agent, auto_actions, judgment_queue)
- `queue/decisions.jsonl` — append-only judgment items (decisions to resolve, maybe-archive)
- `queue/for-adam.md` — human-only items

**Capacity-aware backoff is built in:** there is no shared proxy pool anymore (better-ccflare was removed 2026-07-01 — every session talks to Anthropic directly over its own OAuth), so capacity exhaustion is a *per-account* event that shows up per-agent as a rate-limited pane. tick.py counts those and, when `RATE_SATURATION_MIN` (3) or more agents are capped at once — a genuine cohort-wide crunch — *holds* all nudges (piling onto capped accounts only adds contention) and says so. Individual rate-limited agents are never nudged either (a retry just re-hits the cap). This is the rule I otherwise have to notice by hand.

## When paged (Tier 2 — Opus drains the queue)

Only when `tick.py` exits 10 (or on the 2-hour deep-review window): read `queue/decisions.jsonl`, resolve each genuine decision (what Adam would decide; sensitive/personal/access → `for-adam.md`, don't auto-fire), then clear the drained lines. This is the only step that should consume Opus.

## Waking hibernated terminals (wake.py — never compose wake premises by hand)

A hibernated terminal's snapshot/reason describes the world at hibernation time; PRs merge,
checks go green, and branches land while it sleeps. Composing a wake prompt from that
snapshot ships a stale premise (2026-07-13: a session was woken to "fix FAILING checks" on
a PR that had merged three days earlier). **Every wake goes through the verifier:**

```
python3 scripts/wake.py            # dry-run: live-verified wake plan for all hibernated terminals
python3 scripts/wake.py --act      # dispatch: `tbd terminal wake --prompt <text>` — the wake text
                                   # rides `claude --resume` as an argv, atomic with the respawn.
                                   # An already-awake terminal (raced a human wake) reports
                                   # woken:false and receives NOTHING. Never `terminal send` for
                                   # wakes: it pastes into whatever the pane currently runs (bare
                                   # post-hibernation shell, or a live human session).
python3 scripts/wake.py --tid ID   # one terminal · --no-fetch during a GitHub-rate crunch
```

Per terminal it re-derives truth AT WAKE TIME — live PR state for any PR number in the
hibernation context (`hibernateReason` is a closed enum; the narrative, including "fix PR #N"
premises, lives in the `suspendedSnapshot` pane text, which wake.py scans ANSI-stripped;
MERGED/CLOSED never yields a "fix your PR" wake), the checked-out branch's actual open PR +
failing checks, and unmerged-commit state vs origin/main — then classifies
(DONE → report-and-stop · RESUME_FAILING/OPEN · UNSUBMITTED_WORK · UNVERIFIED → neutral "verify
first" prompt) and writes `queue/wake-plan.json`. First real sweep: 24/24 hibernated
terminals verified DONE — every hand-composed "resume" wake would have been stale.

## The gate (never automate past this)

A PR may only be enqueued when **claude-review = APPROVED on the current SHA + checks clean**. Human approval never substitutes for the bot verdict.

**Merging (revised 2026-07-29 — this replaces the older "the human merges" rule).** The
**nightwatch** judge MAY enqueue a **loop-perfect PR authored by `zionts`**, and only those.
Daywatch does not merge: it runs while a human is around, so it *reports* a loop-perfect PR and
stops. Loop-perfect means all three hold at once, re-read in the same tool call as the merge:

- `mergeable_state` is `clean`
- `claude-review` = APPROVED **on the current head SHA** (a verdict on an older SHA is not a verdict)
- every required status context is green — currently **10** on `longeye-ai/monorepo`; the 11th,
  `Merge Queue Result`, is reported from *inside* the queue and cannot be green beforehand

**Never `--admin`.** Never anyone else's PR — not a teammate's, not a bot's. A judge never merges
*toward* green: anything short of loop-perfect goes back to its owner, or to the human. Auto-approving
a `gh pr merge` permission wedge is still forbidden (see `config/safe_wedges.txt`) — a merge is a
deliberate act after the three checks above, never a rubber-stamped prompt.

`main` sits behind a **merge queue**, so `gh pr merge <N>` *enqueues*; it does not merge. GitHub runs
the queue's own checks and merges when they pass. The line
`! The merge strategy for main is set by the merge queue` is a **warning, not a failure** — the
enqueue succeeded. Do not retry it, do not bolt on `--squash`/`--merge` to "fix" it, and do not
report it as a blocked merge.

**Send-time verification — the wake.py rule applies to EVERY PR-state message, not just wakes.**
Before dispatching any message that asserts PR state (a gate denial, a "checks failing" nudge, a
"needs review" ping), re-read live state *in the same breath as the send*: `gh pr view N --json
state,headRefOid,mergeStateStatus`. If `state` is MERGED/CLOSED, or the head SHA moved since the
sweep, drop or recompose the message — never dispatch a fact older than the current tool call.
(2026-07-13: two gate denials landed in a session's inbox describing PRs that had already merged
or were already sitting in the merge queue — same stale-premise class the wake verifier was built
for.) And phrase gate outcomes honestly: nightwatch cannot deny a GitHub enqueue; its gate is
*stricter than the org's required checks* (AI Review is advisory until the ADR-0013 apply), so a
bot-verdict shortfall on a human-approved PR is an **advisory heads-up**, not a "denied".

## Standing rules (set by Chang — these override the tick prompt)

**NEVER trigger `/closeout`.** Not on a DONE pane, not on a "candidate for /closeout"
self-report, not because the composer already suggests it. A worktree that looks finished
is an *archive question for the human*, not a harvest to fire. Report it and move on.
(The tick prompt and older judge-summary passes treat `/closeout` as a small_safe action —
they are wrong; this rule wins.)

**Hand off at the context ceiling — never push through it.** A judge session that runs past
~600k tokens starts truncating its own shift. (The ceiling was 200k until 2026-07-29; on a
1000k Opus window that forced a relay roughly every two hours, so the desk spent its shift
handing off instead of judging. `handoff.py --check` is the authority — don't eyeball it.)
Do not "flag for respawn" and keep working, and
do NOT use `tbd terminal close --all` — **that command does not exist**. The relay uses
the supported single-terminal `tbd terminal close --terminal <id>`, which preserves
Closed Terminals history and never touches independently spawned child work.
The working relay is `scripts/handoff.py`:

```
python3 scripts/handoff.py --check                       # exit 0 under · exit 10 OVER (reads
                                                         # your own transcript's usage records)
python3 scripts/handoff.py --act --notes-file notes.md   # writes queue/handoff-<ts>.md (+ the
                                                         # HANDOFF-LATEST.md pointer) and spawns
                                                         # a successor in THIS worktree on Opus,
                                                         # briefed with the doc + this same rule
python3 scripts/handoff.py --close-predecessor <tid>     # the SUCCESSOR runs this
```

**The predecessor never closes itself.** It writes notes → spawns → goes idle; the successor
reads the doc and *then* kills the old terminal. If the spawn fails the script says so and
stays alive — a half-completed relay must never leave the desk with nobody on it. The rule is
recursive: the spawn prompt hands the successor the same ceiling instruction, so the relay
continues without a human in the loop.

*Tab caveat:* TBD has no "restart the session in this tab" command. `handoff.py` uses
`tbd terminal create` on the **same worktree**, so the desk survives but the successor is a new
tab; the old tab disappears when the successor closes it.

## Operating rules (hard-won via incidents)

**REBALANCE FIRST on saturation** — A capacity crunch is usually too many sessions piled on ONE rate-capped account, not global scarcity. Swap stuck (STRANDED/RATE/ERROR) sessions onto an emptier account via `tbd terminal swap-profile --terminal <tid> --profile <name>` (parked=cold/cheap, awake=respawn). Passive holding just freezes them. *(Incident 2026-07-10: 14 of 19 stuck sessions were piled on one account; the watcher held instead of rebalancing and the whole fleet stalled overnight until rebalanced.)*

**READ context before nudging** — Capture the worker's actual conversation (`tbd terminal conversation --terminal <tid>` or the pane) and give a SPECIFIC next step, not a blanket "continue" (which just makes agents re-idle).

**FOLLOW UP in ~90s** — After nudging (background sleep), re-check in ~90 seconds rather than waiting for the next tick. Catches agents mid-action at confirm/permission prompts that would otherwise hang the whole cycle.

**ALWAYS SIGN commits** — Never use `gpgsign=false`; some repos (longeye-ai/monorepo) silently reject unsigned commits.

## Config (`config/`)
- `priorities.txt` — must-keep-moving worktrees (flagged ★, reported first)
- `safe_wedges.txt` — permission-wedge prefixes a daemon may auto-approve (never `gh pr merge`: the
  nightwatch judge merges deliberately, after the three gate checks — never by rubber-stamping a prompt)
- `dont_touch.txt` — panes/names nightwatch must never nudge (human-driven, e.g. Adam's own session)

## The babysitter daemon is machine-local — this skill does not ship one

**This skill installs no daemon.** There is no `scripts/daemon.py` and no `scripts/watchdog.sh`
in `NightwatchSkillContent.scripts`, so on a fresh install nothing auto-approves wedges and
`tick.py`'s `daemon_health()` is a stub. `config/safe_wedges.txt` is the allowlist a daemon
*would* consult, kept for that reason; without one, wedges route through judge ticks.

**But "there is no babysitter daemon anywhere" is false, and a judge must not reason from it.**
An operator can install one out-of-band, and on this fleet's box one is live: LaunchAgents
`com.fleet-babysitter` (KeepAlive, running `~/.fleet/babysitter_daemon.py`) and
`com.fleet-babysitter-watchdog` (StartInterval 300, kickstarting it when its log goes stale
past 30 min of *awake* time). Both plists date to 2026-06-23. It auto-approves a narrow
read-only wedge allowlist across live panes and appends everything else to an escalation file.
A 2026-07-25 edit to this section asserted none of it had ever existed; that was wrong, and it
propagated into the desk prompts as "nothing will restart you" — see the handoff rule above for
what actually keeps a shift alive.

Two things that daemon does **not** do, so don't wait on them: it does not restart the *desk
session* (only `handoff.py --act` does that, and only because you ran it), and it never merges —
`gh pr merge` is deliberately excluded from its allowlist, because a merge is a judged act, not a
rubber-stamped prompt.

If you build one: it types into ~96 live panes, so it MUST use the composer ghost-guard in
`_composer()` — before that guard existed the dispatch path would have fired dim suggestions and
raw mouse escape sequences as if a human had typed them.

## TBD integration
- **Read:** `~/tbd/state.db` (worktrees/terminals/`tmuxServer` per pane — pane IDs collide across servers, always read the server, never hardcode)
- **Act:** `tbd terminal send --submit` (nudge/resolve) · `tbd worktree archive` (prune) · `tbd worktree create` (spawn)

## Durable scheduling (opt-in — never auto-runs)

The skill ships a model-free heartbeat but **does not start it**. Enable it deliberately:

```
scripts/scheduler.sh enable [interval_seconds]   # default 900 (15m); launchd runs tick.py
scripts/scheduler.sh disable
scripts/scheduler.sh status
```

When enabled, launchd runs `tick.py` on the interval ($0, no model), stays silent on exit 0,
and on exit 10 (judgment queued) records a marker + fires `tbd notify`. This is the durable,
quota-free replacement for waking Opus on a timer. It is intentionally NOT loaded by the
plugin installer — you turn it on only where you want a fleet babysat.
"""#

    public static let wakePy: String = #"""
#!/usr/bin/env python3
"""
nightwatch wake — pre-wake verifier for hibernated terminals. NO model, NO stale state.

The 2026-07-13 lesson: wake prompts composed from hibernation-time snapshots carry
stale premises (a session was woken to "fix FAILING checks" on a PR that had merged
three days earlier). This script makes the wake premise DETERMINISTIC and LIVE:
for every hibernated terminal it re-derives the truth from git + gh AT WAKE TIME,
classifies the work, and composes the wake prompt from verified facts only.

Rules it enforces:
  - A PR named in a wake premise is checked live (`gh pr view --json state`);
    MERGED/CLOSED PRs never produce a "fix your PR" wake — they produce a done-report
wake. No wake ever tells a session to run /closeout; archiving is the human's call.
  - A local branch name is NOT evidence of unfinished work: if the branch has no
    unmerged commits vs origin/main (or its PR merged), the work is DONE.
  - Anything unverifiable (gh failure, no repo, detached head) wakes NEUTRAL —
    "verify live state first" — never with an asserted premise.

Usage:
  wake.py               # dry-run: verified wake plan for ALL hibernated terminals
  wake.py --tid <ID>    # limit to one terminal
  wake.py --act         # dispatch: `tbd terminal wake --prompt <text>` — the wake
                        # text rides the respawned `claude --resume` as an argv,
                        # atomic with the wake. An already-awake terminal (raced a
                        # human wake) reports woken:false and receives NOTHING.
                        # Never `terminal send`: it pastes into whatever the pane
                        # currently runs (bare shell, or a live human session).
  wake.py --selftest    # offline classification-matrix test (monkeypatched git/gh)
  wake.py --no-fetch    # skip `git fetch` (offline / GitHub rate crunch)

Exit 0 always (a wake plan is informational); per-item status is in the output
and queue/wake-plan.json.
"""
import subprocess, os, re, json, time, sys, glob

HOME = os.path.expanduser("~")
DB = f"{HOME}/tbd/state.db"
SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUEUE = f"{SKILL}/queue"

STANDING_RULE = ("If the task is complete, SAY SO AND STOP — do not run /closeout. "
                 "A finished-looking worktree is an archive question for the human, "
                 "not a harvest to fire. Resume only if genuinely unfinished. "
                 "Do NOT merge your own PR — the nightwatch judge or the human does that.")


def sh(args, t=20, cwd=None):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=t, cwd=cwd)
        return r.stdout.strip(), r.returncode
    except Exception:
        return "", 1


def gh(args, t=25, cwd=None):
    # gh transits the cache proxy via the shell function, not env — plain exec is direct.
    return sh(["gh", *args], t=t, cwd=cwd)


def lease_credential_file(tid):
    root = os.environ.get("TBD_HOME") or os.path.expanduser("~/tbd")
    matches = glob.glob(os.path.join(
        root, "runtime", "nightwatch-leases", f"{tid}-*.json"))
    if len(matches) != 1:
        sys.exit(f"refusing mutation: expected one capability file, found {len(matches)}")
    return matches[0]


def require_judge_lease():
    """Renew exact desk authority immediately before one mutable wake."""
    tid, wid = os.environ.get("TBD_TERMINAL_ID"), os.environ.get("TBD_WORKTREE_ID")
    if not tid or not wid:
        sys.exit("refusing wake: missing TBD terminal/worktree identity")
    status, rc = sh(["tbd", "nightwatch", "lease", "status", "--worktree", wid])
    try:
        lease = (json.loads(status) or {}).get("lease") if rc == 0 else None
    except Exception:
        lease = None
    if not lease or not lease.get("valid") or lease.get("terminalID") != tid:
        sys.exit("refusing wake: this terminal does not hold the valid judge lease")
    credential = lease_credential_file(tid)
    _, rc = sh([
        "tbd", "nightwatch", "lease", "renew", "--credential-file", credential,
    ])
    if rc != 0:
        sys.exit("refusing wake: judge lease renewal failed")


ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def hibernated(only_tid=None):
    # hibernateReason is a closed enum (auto/manual/recovery/merged) — the narrative
    # context (what the session was doing, PR numbers) lives in suspendedSnapshot.
    # JSON output mode: suspendedSnapshot is multi-line, so -separator parsing breaks.
    q = ("SELECT t.id AS tid, w.displayName AS name, w.path AS path, "
         "w.branch AS db_branch, t.hibernatedAt AS hib_at, "
         "COALESCE(t.hibernateReason,'') AS reason, "
         "COALESCE(t.suspendedSnapshot,'') AS snapshot FROM terminal t "
         "JOIN worktree w ON w.id=t.worktreeID "
         # Parked = hibernatedAt OR legacy suspendedAt — mirrors the daemon's
         # Terminal.isParked, so legacy-parked rows can't bypass the verifier.
         "WHERE w.status='active' AND t.kind='claude' "
         "AND (t.hibernatedAt IS NOT NULL OR t.suspendedAt IS NOT NULL)")
    out, rc = sh(["sqlite3", "-json", DB, q + ";"])
    if rc != 0:
        return []
    try:
        rows = json.loads(out) if out else []
    except Exception:
        return []
    items = []
    for r in rows:
        if only_tid and r["tid"] != only_tid: continue
        # Strip ANSI, keep the tail — the most recent (most relevant) pane state.
        snapshot = ANSI.sub("", r.get("snapshot") or "")[-4000:]
        items.append({"tid": r["tid"], "name": r["name"], "path": r["path"],
                      "db_branch": r["db_branch"], "hibernated_at": r["hib_at"],
                      "reason": r["reason"], "snapshot": snapshot})
    return items


def verify(item, fetch=True):
    """Re-derive live truth for one hibernated terminal. Returns a verdict dict."""
    path = item["path"]
    facts: list = []
    v = {"tid": item["tid"], "name": item["name"], "path": path,
         "classification": "UNVERIFIED", "facts": facts, "pr": None}
    if not os.path.isdir(path):
        facts.append("worktree path missing on disk")
        return v

    branch, rc = sh(["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
    if rc != 0 or not branch or branch == "HEAD":
        facts.append("no branch (detached or not a repo)")
        return v
    v["branch"] = branch
    if fetch:
        sh(["git", "-C", path, "fetch", "origin", "main"], t=30)

    dirty, _ = sh(["git", "-C", path, "status", "--porcelain"])
    v["dirty"] = bool(dirty)

    # Unmerged commits vs origin/main — patch-id match (`git cherry`). NOT fully
    # squash-aware: N commits squashed into one won't match; DONE detection also
    # leans on merged-PR state below. A cherry failure means merge state is
    # UNVERIFIABLE — record it and never let it default to DONE.
    cherry, rc = sh(["git", "-C", path, "cherry", "origin/main"])
    unmerged = [l for l in cherry.splitlines() if l.startswith("+")] if rc == 0 else None
    v["unmerged_commits"] = len(unmerged) if unmerged is not None else None
    if unmerged is None:
        facts.append("unmerged-commit state NOT verified (git cherry failed)")

    # THE core check: any PR number in the hibernation context is verified LIVE.
    # hibernateReason is a closed enum and never names a PR — the snapshot (pane
    # text at hibernation) is where a "fix PR #N" premise survives.
    mentioned = re.findall(r"#(\d{3,6})", item["reason"] + " " + item.get("snapshot", ""))
    stale_prs = []
    for num in list(dict.fromkeys(mentioned))[:8]:
        out, rc = gh(["pr", "view", num, "--json", "state,headRefName"], cwd=path)
        # Silent continue is deliberate: snapshot text also mentions ISSUE
        # numbers, which `gh pr view` rejects — a per-mention "NOT verified"
        # fact would be constant noise. This loop only ADDS informational
        # stale-premise callouts; the classification below fails closed on
        # its own gh errors, so nothing safety-relevant is lost here.
        if rc != 0: continue
        try: j = json.loads(out)
        except Exception: continue
        if j.get("state") != "OPEN" or j.get("headRefName") != branch:
            stale_prs.append(f"#{num} is {j.get('state')} (head {j.get('headRefName')}) "
                             f"— hibernate-time premise is stale")
    facts.extend(stale_prs)

    # Live PR for the ACTUAL checked-out branch (any state).
    out, rc = gh(["pr", "list", "--head", branch, "--state", "all",
                  "--json", "number,state,title", "--limit", "5"], cwd=path)
    prs = []
    if rc != 0:
        facts.append("gh unavailable — PR state NOT verified")
        return v
    if out:
        try: prs = json.loads(out)
        except Exception:
            facts.append("gh output unparseable — PR state NOT verified")
            return v
    open_pr = next((p for p in prs if p["state"] == "OPEN"), None)
    merged_pr = next((p for p in prs if p["state"] == "MERGED"), None)

    if open_pr:
        v["pr"] = open_pr["number"]
        checks, checks_rc = gh(["pr", "checks", str(open_pr["number"])], cwd=path)
        # `gh pr checks` exits non-zero when checks are failing OR pending, so
        # rc alone doesn't mean the command failed — empty output with rc!=0
        # does. In that case the checks state is UNVERIFIED: say so, never
        # assert "checks not failing" on data we don't have.
        if checks_rc != 0 and not checks:
            v["failing_checks"] = None
            v["classification"] = "RESUME_OPEN"
            facts.append(f"open PR #{open_pr['number']}, failing-checks state "
                         f"NOT verified (gh pr checks failed)")
        else:
            failing = [l.split("\t")[0] for l in checks.splitlines()
                       if "\tfail" in l or "\tfailure" in l]
            v["failing_checks"] = failing
            v["classification"] = "RESUME_FAILING" if failing else "RESUME_OPEN"
            facts.append(f"open PR #{open_pr['number']}"
                         + (f", failing: {', '.join(failing[:4])}" if failing else ", checks not failing"))
    elif merged_pr or unmerged is not None and not unmerged:
        v["classification"] = "DONE"
        facts.append(f"PR #{merged_pr['number']} MERGED" if merged_pr
                     else "no unmerged commits vs origin/main")
    elif unmerged:
        v["classification"] = "UNSUBMITTED_WORK"
        facts.append(f"{len(unmerged)} commit(s) not in origin/main, no PR")
    else:
        # unmerged is None here (cherry failed, fact already recorded) — merge
        # state is unverifiable, so NEVER default to DONE: that would assert the
        # exact kind of unverified premise this script exists to eliminate.
        if v["dirty"]: facts.append("dirty working tree, merge state unknown")
    if v["dirty"] and v["classification"] == "DONE":
        facts.append("note: dirty working tree — needs triage before any archive decision")
    return v


def compose(v):
    """Wake prompt from verified facts ONLY. Never assert a premise wake-time data disproves."""
    facts = "; ".join(v["facts"]) or "no live facts derivable"
    c = v["classification"]
    if c == "DONE":
        return (f"Nightwatch wake (state verified live): your work here appears COMPLETE "
                f"({facts}). Report that in one line and stop. {STANDING_RULE}")
    if c == "RESUME_FAILING":
        return (f"Nightwatch wake (state verified live): PR #{v['pr']} on branch {v.get('branch')} "
                f"has failing checks ({facts}). Diagnose, fix, push, drive to checks-green + "
                f"claude-review approved on the current SHA. {STANDING_RULE}")
    if c == "RESUME_OPEN":
        return (f"Nightwatch wake (state verified live): PR #{v['pr']} on branch {v.get('branch')} "
                f"is open ({facts}). Drive it to ready (checks green + claude-review approved); "
                f"if it is actually done, say so and stop. {STANDING_RULE}")
    if c == "UNSUBMITTED_WORK":
        return (f"Nightwatch wake (state verified live): branch {v.get('branch')} has {facts}. "
                f"Decide: finish and open a PR, or report it to the human as an "
                f"abandon candidate. {STANDING_RULE}")
    return (f"Nightwatch wake: live state could NOT be verified ({facts}). Before doing anything, "
            f"verify with git/gh what is actually outstanding — do not trust any earlier premise. "
            f"{STANDING_RULE}")


def selftest():
    """Offline classification-matrix test. Monkeypatches sh/gh so no git, gh,
    sqlite3, or tbd binary is ever invoked — safe anywhere (CI runs it via
    PluginDirWriterTests). Covers the fail-closed guarantees the docstring
    promises: unverifiable state NEVER classifies DONE or asserts a premise."""
    g = globals()
    real_sh, real_gh = g["sh"], g["gh"]
    item = {"tid": "T", "name": "t", "path": os.getcwd(), "db_branch": "b",
            "hibernated_at": "x", "reason": "auto", "snapshot": ""}

    def run(git, ghmap, snapshot=""):
        def fake_sh(args, t=20, cwd=None):
            assert args[0] == "git", f"unexpected non-git sh() in verify: {args}"
            return git.get(args[3], ("", 1))
        def fake_gh(args, t=25, cwd=None):
            return ghmap.get(args[1], ("", 1))
        g["sh"], g["gh"] = fake_sh, fake_gh
        try:
            return verify({**item, "snapshot": snapshot}, fetch=False)
        finally:
            g["sh"], g["gh"] = real_sh, real_gh

    git_ok = {"rev-parse": ("feat", 0), "status": ("", 0), "cherry": ("", 0)}
    open_pr = ('[{"number": 7, "state": "OPEN", "title": "t"}]', 0)

    # 1. Clean tree, no unmerged commits, no PR → DONE.
    v = run(git_ok, {"list": ("[]", 0)})
    assert v["classification"] == "DONE", v
    # 2. `git cherry` failure NEVER defaults to DONE — fail closed.
    v = run({**git_ok, "cherry": ("", 1)}, {"list": ("[]", 0)})
    assert v["classification"] == "UNVERIFIED", v
    assert any("git cherry failed" in f for f in v["facts"]), v
    # 3. gh failure → UNVERIFIED, premise explicitly not asserted.
    v = run(git_ok, {"list": ("", 1)})
    assert v["classification"] == "UNVERIFIED", v
    assert any("gh unavailable" in f for f in v["facts"]), v
    # 4. Unparseable gh output ≠ "no PR" → UNVERIFIED.
    v = run(git_ok, {"list": ("gh: flaked mid-stream", 0)})
    assert v["classification"] == "UNVERIFIED", v
    assert any("unparseable" in f for f in v["facts"]), v
    # 5. Open PR, `gh pr checks` dies (empty + rc!=0) → never "checks not failing".
    v = run(git_ok, {"list": open_pr, "checks": ("", 1)})
    assert v["classification"] == "RESUME_OPEN", v
    assert any("NOT verified" in f for f in v["facts"]), v
    assert "checks not failing" not in compose(v), compose(v)
    # 6. Open PR with failing checks (rc!=0 WITH output = checks failing, not gh failing).
    v = run(git_ok, {"list": open_pr, "checks": ("CI\tfail\t1m\turl", 1)})
    assert v["classification"] == "RESUME_FAILING", v
    # 7. Unmerged commits, no PR → UNSUBMITTED_WORK.
    v = run({**git_ok, "cherry": ("+ abc123", 0)}, {"list": ("[]", 0)})
    assert v["classification"] == "UNSUBMITTED_WORK", v
    # 8. PR number in the SNAPSHOT (not reason — that's a closed enum) that is
    #    MERGED → stale-premise fact; classification still independent (DONE).
    v = run(git_ok, {"list": ("[]", 0),
                     "view": ('{"state": "MERGED", "headRefName": "other"}', 0)},
            snapshot="fix PR #14203 FAILING checks")
    assert any("stale" in f for f in v["facts"]), v
    assert v["classification"] == "DONE", v
    # 9. NO composed wake ever tells a session to run /closeout, in ANY branch.
    #    These prompts are dispatched by `wake.py --act` with no human in the
    #    loop, so a "Run /closeout now" is a harvest fired on the human's behalf.
    #    Chang's standing rule: a finished-looking worktree is an archive
    #    QUESTION for the human. Asserted on the composed output rather than on
    #    the source text, so a future rephrasing that reintroduces the
    #    instruction through STANDING_RULE or a new branch is still caught.
    #    Whitelist the one permitted context rather than blacklisting imperative
    #    phrasings: a blacklist is defeated from BOTH sides, since the sentence
    #    that forbids "run /closeout" contains "run /closeout". Every mention of
    #    /closeout in a dispatched prompt must be the prohibition itself.
    PERMITTED = "do not run "
    for classification in ("DONE", "RESUME_FAILING", "RESUME_OPEN",
                           "UNSUBMITTED_WORK", "UNVERIFIED"):
        prompt = compose({"classification": classification, "facts": ["f"],
                          "pr": 1, "branch": "b"})
        low, mentions = prompt.lower(), 0
        i = low.find("/closeout")
        while i != -1:
            mentions += 1
            assert low[max(0, i - len(PERMITTED)):i] == PERMITTED, \
                f"{classification} wake mentions /closeout outside the prohibition: {prompt}"
            i = low.find("/closeout", i + 1)
        assert mentions == 1, f"{classification} wake lost the rule: {prompt}"
    print("selftest: 9/9 classification scenarios passed")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return
    act = "--act" in sys.argv
    fetch = "--no-fetch" not in sys.argv
    tid = None
    if "--tid" in sys.argv:
        i = sys.argv.index("--tid")
        tid = sys.argv[i + 1] if i + 1 < len(sys.argv) else None
    items = hibernated(tid)
    # BEFORE the loop: --act appends to queue/acted.jsonl per terminal, and a
    # missing queue/ would crash mid-dispatch — after real side effects fired
    # but before they were logged. (tick.py/judge.py order it the same way.)
    os.makedirs(QUEUE, exist_ok=True)
    print(f"=== nightwatch wake @ {time.strftime('%H:%M:%S')} "
          f"{'[ACT]' if act else '[dry-run]'} — {len(items)} hibernated ===")
    plan = []
    for it in items:
        v = verify(it, fetch=fetch)
        v["wake_text"] = compose(v)
        plan.append(v)
        print(f"  ▸ {it['name']} ({it['tid'][:8]}): {v['classification']} — "
              + ("; ".join(v["facts"])[:110] or "-"))
        if act:
            require_judge_lease()
            # The wake text rides `tbd terminal wake --prompt` as an argv to
            # `claude --resume` — atomic with the respawn. NEVER `terminal
            # send`: send pastes into whatever the pane currently runs (a bare
            # shell after hibernation, or a LIVE human session if someone woke
            # this terminal between our DB snapshot and now). On the idempotent
            # no-op paths (already awake / wake in flight) the daemon reports
            # woken:false and the prompt is not delivered anywhere. An old tbd
            # binary without --prompt exits non-zero → fail closed, no dispatch.
            out, wake_rc = sh(["tbd", "terminal", "wake", "--terminal", it["tid"],
                               "--prompt", v["wake_text"], "--json"], t=60)
            woken = False
            if wake_rc == 0:
                try: woken = bool(json.loads(out).get("woken"))
                except Exception: woken = False
            v["dispatched"] = woken
            if not woken:
                print("    ✗ not dispatched — " +
                      ("terminal no longer parked (raced a live wake) — prompt withheld"
                       if wake_rc == 0 else "wake failed or tbd binary lacks --prompt"))
            with open(f"{QUEUE}/acted.jsonl", "a") as f:
                f.write(json.dumps({"kind": "wake-dispatch", "tid": it["tid"],
                                    "name": it["name"], "classification": v["classification"],
                                    "ok": v["dispatched"], "ts": int(time.time())}) + "\n")
    json.dump({"ts": int(time.time()), "plan": plan},
              open(f"{QUEUE}/wake-plan.json", "w"), indent=2)
    done = sum(1 for v in plan if v["classification"] == "DONE")
    print(f"\n→ {done}/{len(plan)} verified DONE (would have been stale 'resume' wakes without "
          f"verification). Plan: queue/wake-plan.json")


if __name__ == "__main__":
    main()
"""#

    public static let tickPy: String = #"""
#!/usr/bin/env python3
"""
nightwatch tick — Tier-0 orchestrator. NO model in the hot path.

Reads the whole TBD fleet across all tmux servers and fleet-derived capacity,
classifies every agent deterministically, and emits:
  - a structured tick-report.json  (machine-readable)
  - a short human summary to stdout
  - queue/decisions.jsonl   (items that need Tier-2 / Opus judgment)
  - queue/for-adam.md       (items only a human should do)

Exit code 0 = nothing needs Opus (silent-ok).  Exit code 10 = judgment items queued.
Run with --prs to also gate open PRs (makes gh calls — skip during GitHub rate crunch).
Run with --selftest for the offline classifier matrix (no DB, no tmux, no lock).
"""
import subprocess, os, re, json, time, sys, fcntl

HOME = os.path.expanduser("~")
DB = f"{HOME}/tbd/state.db"
SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUEUE = f"{SKILL}/queue"
CFG = f"{SKILL}/config"

# Fleet-wide backoff threshold. Post-ccflare (proxy removed 2026-07-01) there is no
# shared account pool to saturate: every session talks to Anthropic directly over its
# own OAuth, so capacity exhaustion is a PER-ACCOUNT event that surfaces per-agent as a
# rate-limited pane. We only hold nudges during a genuine COHORT-wide crunch — when this
# many agents are simultaneously rate-limited, more nudges just pile onto capped accounts.
RATE_SATURATION_MIN = 3

def sh(args, t=8):
    try: return subprocess.run(args, capture_output=True, text=True, timeout=t).stdout
    except Exception: return ""

def load_list(fname):
    p = f"{CFG}/{fname}"
    if not os.path.exists(p): return []
    return [l.strip() for l in open(p) if l.strip() and not l.startswith("#")]

PRIORITIES = load_list("priorities.txt")          # display-name substrings, must-keep-moving
SAFE_WEDGES = load_list("safe_wedges.txt")         # allowlist prefixes (informational here)
DONT_TOUCH = load_list("dont_touch.txt")           # panes/names nightwatch must never nudge

def load_policies():
    """Per-repo HOOKS. Each child repo may ship <repo_root>/.nightwatch/policy.json
    declaring its own gate, priorities, safe/escalate rules, and SKILL BINDINGS
    (which of the repo's own skills to invoke to advance/deploy work). nightwatch
    core stays repo-agnostic and defers repo-specifics to the hook.
    Returns {repoID: {"name":..., "policy":{...}}}."""
    out = {}
    rows = sh(["sqlite3","-separator","\t",DB,"SELECT id,displayName,path FROM repo WHERE status='ok';"])
    for l in rows.splitlines():
        p = l.split("\t")
        if len(p) < 3: continue
        rid, name, path = p
        hook = f"{path}/.nightwatch/policy.json"
        if os.path.exists(hook):
            try: out[rid] = {"name": name, "policy": json.load(open(hook))}
            except Exception as e: out[rid] = {"name": name, "policy": {}, "err": str(e)[:50]}
    return out

POLICIES = load_policies()

DECISION_PAT = re.compile(r"Enter to select|❯ 1\.|Ready to submit|Tab/Arrow keys to navigate|Do you want to proceed")
# RATE = genuine capacity exhaustion (per-account limit hit). Nudging these is pointless —
# the retry just re-hits the cap — AND their count is the fleet's saturation signal.
RATE_PAT = re.compile(r"rate.?limit|overloaded|usage limit|weekly limit|reset[s]? at|upgrade to increase|All accounts.*unavailable|529", re.I)
# ERROR = transient/network faults worth a nudge (a resend usually clears them).
ERR_PAT = re.compile(r"API error|503|ECONNRESET|inference gateway", re.I)
DONE_PAT = re.compile(r"ready to archive|you're done|nothing (?:open|left)|winding down|wind down|/closeout|all merged", re.I)

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
# Claude Code renders its OWN suggestions in the composer as dim (ESC[2m) ghost text.
# KNOWN, ACCEPTED GAP: this requires `2` to be the LAST parameter of the SGR
# sequence, so a compound escape like ESC[2;3m (dim+italic) would not match and
# that ghost would be read as typed input. Not observed from Claude Code, and the
# pattern was validated against the live fleet (STRANDED 14 -> 5, all five
# survivors genuinely typed). Check here first if phantom strands ever return.
DIM_RE = re.compile(r"\x1b\[(?:[0-9;]*;)?2m")
# SGR mouse reports ("<65;61;31M") land in the composer on a stray click. Never input.
MOUSE_RE = re.compile(r"^<\d+;\d+;\d+[Mm]$")
# The TBD statusline ("Opus 5(high)  494k/1000k  5h(65% →20:00)  7d(21% →Thu 8pm)") is chrome,
# not something an agent said — it must never be reported as a pane's last meaningful line.
STATUS_RE = re.compile(r"\d+k/\d+k|\d+%\s*→|bypass permissions|Jump to bottom|^⧉ ")

def classify(cap, cap_raw=None):
    """Return state for a captured pane: WORKING / DECISION / RATE / ERROR / STRANDED / DONE / IDLE.

    cap is ANSI-stripped; cap_raw (optional) keeps the escapes so the composer can tell
    real typed input from dim ghost suggestions. Without cap_raw the ghost check degrades
    to the mouse-sequence filter only.
    """
    lines = [x for x in cap.splitlines() if x.strip()]
    if not lines: return "EMPTY", ""
    raw_lines = None
    if cap_raw is not None:
        raw_lines = [x for x in cap_raw.splitlines() if ANSI_RE.sub("", x).strip()]
        # Indices must line up 1:1 with `lines` or the dim lookup reads the wrong row.
        if len(raw_lines) != len(lines): raw_lines = None
    tail = "\n".join(lines[-18:])
    if "esc to interrupt" in tail: return "WORKING", _lastmeaning(lines)
    if DECISION_PAT.search(tail): return "DECISION", _lastmeaning(lines)
    comp = _composer(lines, raw_lines)
    if RATE_PAT.search(tail): return "RATE", comp or _lastmeaning(lines)
    if ERR_PAT.search(tail): return "ERROR", comp or _lastmeaning(lines)
    if DONE_PAT.search(tail): return "DONE", _lastmeaning(lines)
    if comp: return "STRANDED", comp
    return "IDLE", ""

def _lastmeaning(lines):
    for x in reversed(lines):
        s = x.strip()
        if any(k in s for k in ("bypass permissions","esc to interrupt","context used","auto-compact","/model")): continue
        if STATUS_RE.search(s): continue
        if s.startswith(("─","✻","✳","✶","⏺","◯")): continue
        if not s or s == "❯": continue
        return s[:90]
    return ""

CTX_PAT = re.compile(r"(\d+)%\s*context used")
COMPACT_PAT = re.compile(r"(\d+)%\s*until auto-compact")
def burn_risk(cap):
    """The dominant quota driver is token WEIGHT per request: a session dragging a
    near-full context window (esp. 1M Opus) sends up to ~1M input tokens EVERY request.
    Flag agents at high context — they incinerate the weekly cap fastest. Returns
    (pct:int|None, is_1m:bool, risk:bool)."""
    pct = None
    m = CTX_PAT.search(cap)
    if m: pct = int(m.group(1))
    else:
        c = COMPACT_PAT.search(cap)
        if c: pct = 100 - int(c.group(1))
    is_1m = "opus[1m]" in cap or "[1m]" in cap
    risk = pct is not None and pct >= 85
    return pct, is_1m, risk

def _composer(lines, raw_lines=None):
    """Text a HUMAN actually left in the composer, or "" if there's nothing real there.

    This feeds STRANDED, and STRANDED feeds the daemon's auto-dispatch — whatever
    this returns gets typed into a live session as if a person had written it. So
    two impostors are rejected:
      · dim (ESC[2m) ghost text — Claude Code's own suggestion, identical to typed
        input once ANSI is stripped. Dispatching one makes the agent "obey" a
        suggestion nobody chose.
      · SGR mouse reports from a stray click in the pane.
    Rejecting is the safe direction: a missed nudge costs one tick, a bad dispatch
    corrupts a session.
    """
    for i, x in enumerate(lines):
        if "bypass permissions" in x and i > 0:
            for j in range(i-1, -1, -1):
                s = lines[j].strip()
                if s.startswith("❯"):
                    text = s[1:].strip()[:120]
                    if not text or MOUSE_RE.match(text): return ""
                    if raw_lines and DIM_RE.search(raw_lines[j]): return ""
                    return text
                if s.startswith("─"): continue
            break
    return ""

def daemon_health():
    """Deliberately unwired: this skill ships no babysitter daemon.

    Retired as a live check 2026-07-25 (Chang's call), because it probed a
    `scripts/daemon.py` this skill has never installed and reported
    `daemon: log-missing` every tick as if a live service had fallen over —
    judge sessions then escalated a *restart* for software with no install to
    restore. The fleet ran fine without it.

    The stub is NOT an assertion that no daemon exists anywhere. An operator may
    run one out-of-band, and this fleet does (SKILL.md, "The babysitter daemon is
    machine-local"). It stays unwired because a machine-local install is not this
    skill's to health-check, and a shipped probe would go back to crying wolf on
    every box that has none. Returns absent=True so anything reading
    tick-report.json["daemon"] gets a shape instead of a KeyError.
    """
    return {"ok": True, "absent": True, "age_s": None,
            "reason": "not-checked (this skill ships no daemon; a machine-local one may exist)"}

def codex_state(activity):
    """Classify Codex from TBD's hook-backed machine state, never its TUI."""
    return {
        "working": ("WORKING", "Codex hook state: working"),
        "waiting_for_user": ("DECISION", "Codex is waiting for user input"),
        "idle": ("IDLE", "Codex hook state: idle"),
        "unknown": ("IDLE", "Codex activity is not known yet"),
    }.get(activity or "unknown", ("IDLE", f"Codex hook state: {activity}"))

def fleet():
    rows = sh(["sqlite3","-separator","\t",DB,
      "SELECT t.tmuxPaneID, w.displayName, w.tmuxServer, t.id, w.repoID, t.kind, "
      "COALESCE(t.activityState,'unknown') "
      "FROM worktree w JOIN terminal t ON t.worktreeID=w.id "
      "AND t.kind IN ('claude','codex') AND t.suspendedAt IS NULL AND t.hibernatedAt IS NULL "
      "WHERE w.status='active' ORDER BY w.tmuxServer, w.displayName;"])
    out = []
    for l in rows.splitlines():
        p = l.split("\t")
        if len(p) < 7: continue
        pane, name, srv, tid, rid, kind, activity = p
        if kind == "codex":
            # Codex installs TBD hooks that publish activityState. Its rendered
            # terminal is not Claude's UI and must not be interpreted with the
            # grandfathered Claude-only screen classifier.
            state, note = codex_state(activity)
            ctx_pct, is_1m, burn = None, False, False
        else:
            # -e keeps the escapes: dimness is the only thing distinguishing a ghost
            # suggestion from typed input, and it's gone by the time tmux strips ANSI.
            cap_raw = sh(["tmux","-L",srv,"capture-pane","-p","-e","-t",pane])
            cap = ANSI_RE.sub("", cap_raw)
            state, note = classify(cap, cap_raw)
            ctx_pct, is_1m, burn = burn_risk(cap)
        hook = POLICIES.get(rid, {})
        pol = hook.get("policy", {})
        # priorities/dont-touch are the UNION of global config + the repo's own hook
        prio = (any(s.lower() in name.lower() for s in PRIORITIES)
                or any(s.lower() in name.lower() for s in pol.get("priorities", [])))
        protect = (any(d in pane or d.lower() in name.lower() for d in DONT_TOUCH)
                   or any(d.lower() in name.lower() for d in pol.get("dont_touch", [])))
        out.append({"pane": pane, "name": name, "server": srv, "tid": tid,
                    "kind": kind, "state": state, "note": note,
                    "priority": prio, "protected": protect,
                    "repo": hook.get("name"), "gate": pol.get("gate", {}).get("ready_when"),
                    "advance_skill": pol.get("advance_skill"), "deploy_skill": pol.get("deploy_skill"),
                    "ctx_pct": ctx_pct, "is_1m": is_1m, "burn_risk": burn})
    return out

def _pane(*lines):
    """Synthetic capture-pane output."""
    return "\n".join(lines) + "\n"


DIM, RESET = "\x1b[2m", "\x1b[0m"


def selftest():
    """Offline matrix for the composer ghost-guard. No DB, no tmux, no lock.

    This guards the path that TYPES INTO LIVE PANES: whatever _composer()
    returns is dispatched as though a human had written it, so every impostor
    gets an explicit scenario rather than a string-presence check on the source.
    Run from Swift by Tests/TBDDaemonTests/PluginDirWriterTests.swift.
    """
    n = 0

    def check(label, got, want):
        nonlocal n
        assert got == want, f"{label}: got {got!r}, want {want!r}"
        n += 1

    def nonempty(text):
        return [x for x in text.splitlines() if x.strip()]

    def raws(text):
        return [x for x in text.splitlines() if ANSI_RE.sub("", x).strip()]

    # A genuinely typed line is the ONLY thing that may strand a pane.
    typed = _pane("⏺ ran the build", "───────", "❯ please retry the deploy",
                  "───────", "  bypass permissions on")
    check("typed input strands", classify(typed, typed),
          ("STRANDED", "please retry the deploy"))

    # Claude Code's own suggestion: byte-identical to the above once ANSI is
    # stripped. Dimness in the raw capture is the only thing telling them apart.
    ghost_raw = _pane("⏺ ran the build", "───────",
                      DIM + "❯ please retry the deploy" + RESET,
                      "───────", "  bypass permissions on")
    ghost = ANSI_RE.sub("", ghost_raw)
    check("ghost text is not composer input",
          _composer(nonempty(ghost), raws(ghost_raw)), "")
    check("ghost text does not strand", classify(ghost, ghost_raw), ("IDLE", ""))

    # An SGR mouse report from a stray click in the pane.
    mouse = _pane("⏺ ran the build", "───────", "❯ <65;61;31M",
                  "───────", "  bypass permissions on")
    check("mouse report is not input", classify(mouse, mouse), ("IDLE", ""))

    # Index alignment is load-bearing: raw_lines[j] must describe lines[j]. When
    # the two filters disagree the lookup is abandoned rather than read off the
    # wrong row — which FAILS OPEN (the ghost is treated as typed). Pinned here
    # deliberately: a missed nudge costs a tick, but silently reading dimness
    # from an unrelated row would suppress real input at random.
    misaligned = ghost_raw + "an extra raw-only line\n"
    check("misaligned raw capture is abandoned, not misread",
          classify(ghost, misaligned)[0], "STRANDED")

    # Same degrade when the caller passes no raw capture at all: the dim check
    # is unavailable, but the mouse filter still holds.
    check("no raw capture still filters mouse", classify(mouse)[0], "IDLE")
    check("no raw capture cannot see dimness", classify(ghost)[0], "STRANDED")

    # The TBD statusline is chrome, never a pane's last meaningful line.
    check("statusline skipped",
          _lastmeaning(["waiting on your call", "Opus 5(high)  494k/1000k  5h(65% →20:00)"]),
          "waiting on your call")
    check("bare prompt glyph skipped",
          _lastmeaning(["waiting on your call", "❯"]), "waiting on your call")

    # Precedence: an in-flight turn outranks whatever sits in the composer.
    working = _pane("⏺ thinking", "❯ please retry the deploy",
                    "  bypass permissions on", "esc to interrupt")
    check("working outranks composer", classify(working, working)[0], "WORKING")
    check("empty pane", classify("", ""), ("EMPTY", ""))

    check("codex working comes from hook state",
          codex_state("working"), ("WORKING", "Codex hook state: working"))
    check("codex waiting is judgment, not scraped composer input",
          codex_state("waiting_for_user"), ("DECISION", "Codex is waiting for user input"))
    check("codex unknown fails quiet",
          codex_state("unknown"), ("IDLE", "Codex activity is not known yet"))

    print(f"selftest: {n}/{n} agent-state scenarios passed")


def main():
    # --selftest must short-circuit BEFORE the machine-global lock below: a live
    # tick holding it would otherwise make the selftest exit 0 silently, i.e.
    # pass without running a single scenario.
    if "--selftest" in sys.argv:
        selftest()
        return

    # Prevent concurrent tick runs across BOTH schedulers — the in-daemon DaywatchRunner
    # loop and the launchd scheduler.sh heartbeat. They execute DIFFERENT tick.py copies
    # from different install trees (AppSupport plugin dir vs ~/.claude), so a lock under
    # each copy's own queue/ dir would never contend. Use a single machine-global lock path
    # that every copy computes identically; /tmp always exists, so no bootstrap dir is needed.
    lock_path = "/tmp/nightwatch-tick.lock"
    try:
        lock_file = open(lock_path, 'w')
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (IOError, OSError):
        # Lock is already held by another tick — exit 0 silently (another instance is active).
        sys.exit(0)

    rep = {
        "ts": int(time.time()),
        "daemon": daemon_health(),
        "hooks": {v["name"]: {"gate": v["policy"].get("gate",{}).get("ready_when"),
                              "advance_skill": v["policy"].get("advance_skill"),
                              "deploy_skill": v["policy"].get("deploy_skill")}
                  for v in POLICIES.values()},
        "agents": fleet(),
    }
    # ---- deterministic triage (Tier 0): split into auto / judgment / human ----
    decisions, stranded, errors, rate, done, working, idle = ([] for _ in range(7))
    for a in rep["agents"]:
        s = a["state"]
        if s == "WORKING": working.append(a)
        elif s == "DECISION": decisions.append(a)
        elif s == "STRANDED": stranded.append(a)
        elif s == "RATE": rate.append(a)
        elif s == "ERROR": errors.append(a)
        elif s == "DONE": done.append(a)
        else: idle.append(a)

    # ---- fleet-derived capacity (post-ccflare: no shared pool to poll) ----
    # Saturation is now a cohort-wide rate-limit event. A single capped session no longer
    # implies a starved fleet (each has its own OAuth account), so hold nudges only when
    # RATE_SATURATION_MIN+ agents are rate-limited at once — that's a real crunch.
    saturated = len(rate) >= RATE_SATURATION_MIN
    capacity = {
        "status": "saturated" if saturated else "ok",
        "rate_limited": len(rate),
        "active": len(rep["agents"]) - len(idle),
        "reason": (f"{len(rate)} agents rate-limited (cohort crunch)" if saturated
                   else "direct-oauth: per-account limits, no shared pool"),
    }
    rep["capacity"] = capacity

    rep["summary"] = {
        "working": len(working), "idle": len(idle), "decisions": len(decisions),
        "stranded": len(stranded), "errors": len(errors), "rate_limited": len(rate),
        "done_maybe": len(done), "saturated": saturated,
    }
    # Judgment queue = DECISIONS (a model/human must pick) + DONE (archive judgement)
    judgment = [{"kind":"decision","pane":a["pane"],"server":a["server"],"name":a["name"],
                 "tid":a["tid"],"note":a["note"]} for a in decisions]
    judgment += [{"kind":"maybe-archive","pane":a["pane"],"name":a["name"],"note":a["note"]} for a in done]
    # Auto-handleable (Tier 0/1) = STRANDED + ERROR, BUT suppress when saturated (nudging adds contention)
    auto = []
    if not saturated:
        for a in stranded:
            if a["protected"]: continue
            auto.append({"kind":"dispatch","pane":a["pane"],"server":a["server"],"tid":a["tid"],
                         "name":a["name"],"text":a["note"]})
        for a in errors:
            if a["protected"]: continue
            auto.append({"kind":"nudge-transient","pane":a["pane"],"server":a["server"],"tid":a["tid"],
                         "name":a["name"]})
    rep["auto_actions"] = auto
    rep["judgment_queue"] = judgment

    os.makedirs(QUEUE, exist_ok=True)
    json.dump(rep, open(f"{QUEUE}/tick-report.json","w"), indent=2)
    if judgment:
        with open(f"{QUEUE}/decisions.jsonl","a") as f:
            for j in judgment: f.write(json.dumps({**j,"ts":rep["ts"]})+"\n")

    # ---- human-readable summary ----
    c = capacity
    print(f"=== nightwatch tick @ {time.strftime('%H:%M:%S')} ===")
    if rep["hooks"]:
        print("hooks: " + " · ".join(f"{n}[gate={h['gate'] or '-'},advance={h['advance_skill'] or '-'}]"
                                      for n,h in rep["hooks"].items()))
    else:
        print("hooks: (none — repos can ship .nightwatch/policy.json)")
    print(f"capacity: {c['status']} (rate-limited {c['rate_limited']}/{len(rep['agents'])})"
          f"{' ⚠ SATURATED — backoff, no nudging' if saturated else ''}")
    sm = rep["summary"]
    print(f"agents: {len(rep['agents'])}  working={sm['working']} idle={sm['idle']} "
          f"decisions={sm['decisions']} stranded={sm['stranded']} errors={sm['errors']} "
          f"rate-limited={sm['rate_limited']} done?={sm['done_maybe']}")
    for a in working:
        if a["priority"]: print(f"  ★ PRIORITY {a['name']} ({a['pane']}): WORKING ✓")
    pr = [a for a in rep["agents"] if a["priority"] and a["state"]!="WORKING"]
    for a in pr: print(f"  ★ PRIORITY {a['name']} ({a['pane']}): {a['state']} — {a['note'][:60]}")
    if decisions:
        print("DECISIONS (need judgment → queued):")
        for a in decisions: print(f"  ▸ {a['name']} ({a['server']} {a['pane']}): {a['note'][:70]}")
    if rate:
        print(f"RATE-LIMITED ({len(rate)} — per-account cap, NOT nudged; a retry just re-hits it):")
        for a in rate: print(f"  · {a['name']} ({a['pane']}): {a['note'][:60]}")
    burners = sorted([a for a in rep["agents"] if a.get("burn_risk")],
                     key=lambda a: -(a.get("ctx_pct") or 0))
    if burners:
        print(f"🔥 BURN-RISK ({len(burners)} at ctx≥85% — top quota drivers, weight not count):")
        for a in burners[:8]:
            print(f"  · {a['name']} ({a['pane']}): {a['ctx_pct']}% ctx{' [1M]' if a['is_1m'] else ''}"
                  f" — {'compact/clear' if a['ctx_pct']>=95 else 'watch'}")
    if auto:
        print(f"AUTO (Tier-0 safe, {len(auto)}):")
        for x in auto: print(f"  · {x['kind']}: {x['name']} ({x['pane']})")
    elif saturated and (stranded or errors):
        print(f"HELD (cohort rate-crunch, {len(rate)} capped): {len(stranded)} stranded + {len(errors)} errors "
              f"— NOT nudging (would pile onto capped accounts)")
    needs_opus = bool(judgment)
    print(f"\n→ {'JUDGMENT ITEMS QUEUED — page Opus (nightwatch judge)' if needs_opus else 'nothing needs Opus — silent-ok'}")
    sys.exit(10 if needs_opus else 0)

if __name__ == "__main__":
    main()
"""#

    /// Context-ceiling relay for long-running desk sessions. A judge session past
    /// its ceiling writes a handoff doc, spawns a successor in the same worktree,
    /// and the SUCCESSOR closes the predecessor — never the reverse, so a failed
    /// spawn leaves the desk still watched.
    ///
    /// Delimited with `##"""` because the script embeds `"""#` (an f-string opening
    /// a markdown heading), which would otherwise close a `#"""` literal.
    public static let handoffPy: String = ##"""
#!/usr/bin/env python3
"""Context-ceiling handoff for long-running desk sessions.

A judge/watch session that runs past its context ceiling starts truncating its
own history mid-shift ("I kept getting cut off"). The fix is a relay: the tiring
session writes a handoff, spawns a fresh Opus session in the same worktree, and
the SUCCESSOR closes the predecessor once it has actually read the handoff.

  handoff.py --check                      # exit 0 = under ceiling, 10 = over
  handoff.py --act --notes-file notes.md  # write handoff + spawn successor
  handoff.py --close-predecessor <tid>    # successor calls this when it's ready
  handoff.py --selftest                   # offline ceiling / fail-closed test

Ordering matters: the predecessor NEVER closes itself. If the spawn fails or the
successor dies on boot, the old session is still there and the shift survives.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

QUEUE = pathlib.Path(__file__).resolve().parent.parent / "queue"
LATEST = QUEUE / "HANDOFF-LATEST.md"
# 600k of a 1000k Opus window. Raised from 200k on 2026-07-29: at 200k a desk
# session hit the ceiling roughly every two hours and spent the shift relaying
# instead of judging, while the model it runs on had 800k of headroom left.
# 600k still leaves ~400k of slack for the handoff write + the successor's boot.
DEFAULT_THRESHOLD = 600_000
SUCCESSOR_MODEL = "opus"


def lease_credential_file(tid):
    root = pathlib.Path(os.environ.get("TBD_HOME") or os.path.expanduser("~/tbd"))
    matches = list((root / "runtime" / "nightwatch-leases").glob(f"{tid}-*.json"))
    if len(matches) != 1:
        sys.exit(f"refusing mutation: expected one capability file, found {len(matches)}")
    return str(matches[0])


def _run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def terminal_row(terminal_id, worktree_id):
    """Live TBD record for a terminal (pane/window ids, transcript path)."""
    r = _run(["tbd", "terminal", "list", worktree_id, "--json"])
    if r.returncode != 0:
        return {}
    for row in json.loads(r.stdout or "[]"):
        if row.get("id") == terminal_id:
            return row
    return {}


def tmux_server():
    """Server name from $TMUX — pane ids collide across servers, never guess."""
    tmux = os.environ.get("TMUX", "")
    return pathlib.PurePath(tmux.split(",")[0]).name if tmux else ""


def context_tokens(transcript_path):
    """Current context size, read off the transcript's own usage records.

    Claude Code stamps every assistant message with the usage that produced it;
    input + both cache buckets is what the statusline renders as `NNNk/1000k`.
    Returns None when the transcript can't be read rather than guessing zero —
    a bogus low reading would silently disable the ceiling.
    """
    try:
        with open(transcript_path, "rb") as fh:
            tail = fh.readlines()[-400:]
    except OSError:
        return None
    best = None
    for raw in tail:
        try:
            u = json.loads(raw).get("message", {}).get("usage") or {}
        except (json.JSONDecodeError, AttributeError):
            continue
        total = (
            u.get("input_tokens", 0)
            + u.get("cache_creation_input_tokens", 0)
            + u.get("cache_read_input_tokens", 0)
        )
        if total and (best is None or total > best):
            best = total
    return best


def resolve_self():
    tid = os.environ.get("TBD_TERMINAL_ID")
    wid = os.environ.get("TBD_WORKTREE_ID")
    if not tid or not wid:
        sys.exit("not inside a TBD terminal (TBD_TERMINAL_ID/TBD_WORKTREE_ID unset)")
    return tid, wid, terminal_row(tid, wid)


def cmd_check(args):
    """Exit 0 = under the ceiling · 10 = OVER (or unknowable).

    FAILS CLOSED. An unreadable transcript, a `tbd terminal list` that errored,
    or a row without a transcriptPath all report OVER. context_tokens() already
    refuses to guess 0 because "a bogus low reading would silently disable the
    ceiling" -- mapping its None to exit 0 here would have reinstated exactly
    that, and the caller is told to trust "exit 0 = under the ceiling". The
    asymmetry is decisive: a spurious handoff costs one relay cycle, a missed
    one costs the shift to truncation, which is the failure this script exists
    to prevent.
    """
    *_, row = resolve_self()
    transcript = row.get("transcriptPath") or ""
    used = context_tokens(transcript) if transcript else None
    if used is None:
        why = "no transcriptPath on the terminal row" if not transcript else "transcript unreadable"
        print(f"context: UNKNOWN ({why}) — failing closed, treat as OVER")
        return 10
    over = used >= args.threshold
    print(f"context: {used:,} / ceiling {args.threshold:,} — {'OVER' if over else 'ok'}")
    return 10 if over else 0


def successor_prompt(doc_path, pred_tid, pred_window, server, threshold):
    return f"""You are the successor Nightwatch/Daywatch judge session for this desk.
The previous session hit its context ceiling ({threshold:,} tokens) and handed off
to you rather than getting truncated mid-shift.

FIRST, before anything else:
1. Read the handoff document: {doc_path}
2. WAIT until the daemon-issued capability both exists AND renews. The file is
   prepared before the database transfer, so existence alone is not authority;
   this bounded loop covers that small commit race and also works if the
   predecessor's follow-up message never arrives:
     python3 - <<'PY'
     import glob, os, subprocess, time
     root = os.environ.get("TBD_HOME") or os.path.expanduser("~/tbd")
     ok = False
     for _ in range(60):
         paths = glob.glob(os.path.join(root, "runtime", "nightwatch-leases", os.environ["TBD_TERMINAL_ID"] + "-*.json"))
         if len(paths) == 1 and subprocess.call(["tbd", "nightwatch", "lease", "renew", "--credential-file", paths[0]]) == 0:
             ok = True
             break
         time.sleep(1)
     raise SystemExit(0 if ok else 2)
     PY
   Do not merge, apply, archive, wake/nudge, spawn, or close the predecessor
   before that command passes.
3. Close the predecessor — it is idle and waiting for you to do this:
     python3 "{pathlib.Path(__file__).resolve()}" --close-predecessor {pred_tid}
   (predecessor terminal {pred_tid}, tmux window {pred_window} on server {server})
4. Confirm in your first message what you picked up and what you closed.

STANDING INSTRUCTION — this applies to YOU now, and to every session you spawn:
When your own context passes {threshold:,} tokens, do not push through it. Run
  python3 "{pathlib.Path(__file__).resolve()}" --check
and when it reports OVER, write your own handoff notes to a file and run
  python3 "{pathlib.Path(__file__).resolve()}" --act --notes-file <your-notes.md>
That spawns your replacement on {SUCCESSOR_MODEL} in this same worktree with this
same instruction, and your replacement closes you. Never close yourself first —
if the spawn fails, you are still the only thing keeping the shift alive.

Then continue the shift from the handoff.
"""


def cmd_act(args):
    tid, wid, row = resolve_self()
    server = tmux_server()
    used = context_tokens(row.get("transcriptPath", ""))
    ts = int(time.time())

    credential = lease_credential_file(tid)
    lease_status = _run(["tbd", "nightwatch", "lease", "status", "--worktree", wid])
    if lease_status.returncode != 0:
        sys.exit(f"cannot verify judge lease before handoff: {lease_status.stderr.strip()}")
    try:
        current_lease = (json.loads(lease_status.stdout) or {}).get("lease") or {}
    except json.JSONDecodeError:
        sys.exit("cannot verify judge lease before handoff: unparseable status")
    if not current_lease.get("valid") or current_lease.get("terminalID") != tid:
        sys.exit("refusing handoff: this terminal does not hold the valid judge lease")
    renewal = _run([
        "tbd", "nightwatch", "lease", "renew", "--credential-file", credential,
    ])
    if renewal.returncode != 0:
        sys.exit(f"refusing handoff: judge lease renewal failed: {renewal.stderr.strip()}")

    notes = pathlib.Path(args.notes_file).read_text() if args.notes_file else ""
    if not notes.strip():
        sys.exit("refusing to hand off with empty notes — write the handoff first")

    doc = QUEUE / f"handoff-{ts}.md"
    QUEUE.mkdir(parents=True, exist_ok=True)
    doc.write_text(
        f"""# Desk handoff — {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(ts))}

Predecessor terminal: {tid} (pane {row.get('tmuxPaneID')}, window
{row.get('tmuxWindowID')}, server {server})
Context at handoff: {f'{used:,}' if used else 'unknown'} tokens
Worktree: {wid}
Transcript: {row.get('transcriptPath')}

---

{notes.strip()}
"""
    )
    if LATEST.exists() or LATEST.is_symlink():
        LATEST.unlink()
    LATEST.symlink_to(doc.name)

    prompt = successor_prompt(doc, tid, row.get("tmuxWindowID"), server, args.threshold)
    spawn = _run(
        [
            "tbd", "terminal", "create", wid,
            "--type", "claude",
            "--claude-settings", json.dumps({"model": SUCCESSOR_MODEL}),
            "--prompt-file", "-",
            "--json",
        ],
        input=prompt,
    )
    if spawn.returncode != 0:
        sys.exit(f"spawn FAILED, staying alive: {spawn.stderr.strip()}")

    try:
        new_id = json.loads(spawn.stdout).get("id", "?")
    except json.JSONDecodeError:
        new_id = spawn.stdout.strip() or "?"

    transfer = _run([
        "tbd", "nightwatch", "lease", "transfer",
        "--credential-file", credential,
        "--to-terminal", new_id,
    ])
    if transfer.returncode != 0:
        sys.exit(f"lease transfer FAILED; predecessor remains authoritative and successor must stay read-only: {transfer.stderr.strip()}")
    try:
        transfer_result = json.loads(transfer.stdout)
        successor_lease = transfer_result["lease"]
        successor_credential = transfer_result["credentialFile"]
    except json.JSONDecodeError:
        sys.exit("lease transferred but response was unparseable; both sessions must stop mutating")

    renew = f"tbd nightwatch lease renew --credential-file {successor_credential}"
    delivery = _run([
        "tbd", "terminal", "send", "--terminal", new_id, "--submit", "--text",
        "Exclusive judge lease transferred to you. Before every mutable action run: " + renew,
    ])
    if delivery.returncode != 0:
        print("warning: successor notification failed; its prewritten capability file remains recoverable", file=sys.stderr)

    print(f"handoff written: {doc}")
    print(f"successor spawned: {new_id} (model={SUCCESSOR_MODEL})")
    print(f"judge lease transferred: generation {successor_lease['generation']}")
    print("go idle now — the successor closes this terminal once it has read the doc.")
    return 0


def cmd_close(args):
    """Close one predecessor through TBD so transcript/history are preserved."""
    target = args.close_predecessor
    r = _run(["tbd", "terminal", "list", os.environ.get("TBD_WORKTREE_ID", ""), "--json"])
    # A FAILED lookup is not an absent terminal. Collapsing the two would report
    # "already closed" for a predecessor that is still running and still holding
    # the desk -- the same treat-unknown-as-benign shape as the old cmd_check.
    if r.returncode != 0:
        sys.exit(f"cannot verify terminal {target}: `tbd terminal list` failed: {r.stderr.strip()}")
    try:
        rows = json.loads(r.stdout or "[]")
    except json.JSONDecodeError:
        sys.exit(f"cannot verify terminal {target}: unparseable `tbd terminal list` output")
    row = next((c for c in rows if c.get("id") == target), {})
    if not row:
        print(f"terminal {target} not found — already closed, nothing to do")
        return 0
    if target == os.environ.get("TBD_TERMINAL_ID"):
        sys.exit("refusing to close myself — pass the PREDECESSOR's terminal id")

    # Closing a terminal is a mutable desk action too. The successor must prove
    # it owns the transferred capability before force-closing its predecessor.
    self_tid = os.environ.get("TBD_TERMINAL_ID", "")
    credential = lease_credential_file(self_tid)
    renewal = _run([
        "tbd", "nightwatch", "lease", "renew", "--credential-file", credential,
    ])
    if renewal.returncode != 0:
        sys.exit("refusing to close predecessor: this terminal does not hold the judge lease")

    close = _run([
        "tbd", "terminal", "close", "--terminal", target, "--force", "--json",
    ])
    if close.returncode != 0:
        sys.exit(f"terminal close failed: {close.stderr.strip()}")
    print(f"closed predecessor {target} through TBD (history preserved)")
    return 0


def selftest():
    """Offline test of the ceiling arithmetic and the fail-closed paths.

    No subprocesses, no tbd, no tmux, no transcript on disk. Covers the two
    behaviours that decide whether a shift survives: context_tokens() picking
    the largest usage record, and cmd_check refusing to report "under" when it
    cannot actually tell.
    """
    import tempfile
    n = 0

    def check(label, got, want):
        nonlocal n
        assert got == want, f"{label}: got {got!r}, want {want!r}"
        n += 1

    class Args:
        threshold = DEFAULT_THRESHOLD

    def with_row(row):
        """Run cmd_check against a fixed terminal row, no tbd/env involved."""
        g = globals()
        real = g["resolve_self"]
        g["resolve_self"] = lambda: ("T", "W", row)
        try:
            return cmd_check(Args())
        finally:
            g["resolve_self"] = real

    # context_tokens: the reported figure is input + BOTH cache buckets, and the
    # largest record in the tail wins (the tail holds smaller earlier turns).
    # Derived from DEFAULT_THRESHOLD, never a literal: the 2026-07-29 raise to
    # 600k silently turned a hardcoded 250_000 "over" fixture into an "under"
    # one, so the selftest would have kept passing while asserting the opposite
    # of its own label.
    over_total = DEFAULT_THRESHOLD + 50_000
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        for total in (10_000, over_total, 40_000):
            fh.write(json.dumps({"message": {"usage": {
                "input_tokens": total - 30, "cache_creation_input_tokens": 20,
                "cache_read_input_tokens": 10}}}) + "\n")
        fh.write("not json at all\n")          # tolerated, not fatal
        fh.write(json.dumps({"message": {}}) + "\n")   # no usage block
        path = fh.name
    check("largest usage record wins", context_tokens(path), over_total)
    check("over ceiling exits 10", with_row({"transcriptPath": path}), 10)

    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        fh.write(json.dumps({"message": {"usage": {"input_tokens": 1_000}}}) + "\n")
        small = fh.name
    check("under ceiling exits 0", with_row({"transcriptPath": small}), 0)

    # FAIL CLOSED. Each of these once returned 0 ("under ceiling"), which is how
    # a session runs past its ceiling with nobody ever telling it to hand off.
    check("unreadable transcript fails closed",
          with_row({"transcriptPath": "/nonexistent/transcript.jsonl"}), 10)
    check("missing transcriptPath fails closed", with_row({}), 10)
    check("empty transcriptPath fails closed", with_row({"transcriptPath": ""}), 10)
    check("no usage records fails closed", context_tokens(os.devnull), None)

    os.unlink(path)
    os.unlink(small)
    print(f"selftest: {n}/{n} handoff ceiling scenarios passed")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return 0
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true", help="report context vs ceiling (exit 10 = over)")
    g.add_argument("--act", action="store_true", help="write handoff + spawn successor")
    g.add_argument("--close-predecessor", metavar="TID", help="successor closes the old session")
    g.add_argument("--selftest", action="store_true", help="offline ceiling/fail-closed test")
    p.add_argument("--notes-file", help="markdown file holding the handoff body (required with --act)")
    p.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD)
    args = p.parse_args()

    if args.check:
        return cmd_check(args)
    if args.act:
        return cmd_act(args)
    return cmd_close(args)


if __name__ == "__main__":
    sys.exit(main())
"""##

    public static let judgePy: String = #"""
#!/usr/bin/env python3
"""
nightwatch judge — the Tier-2 step. Reads what `tick.py` queued + the live fleet
and ROUTES each item through the owning repo's HOOK (.nightwatch/policy.json):
  - a not-ready PR  -> dispatch that repo's `advance_skill` to the owner
  - a deploy        -> that repo's `deploy_skill` (always human-gated)
  - a stuck menu / archive call -> HUMAN (no hook auto-resolves judgment)

nightwatch core never hardcodes a gate or a drive command — it asks the repo.

Capacity-aware: with `--act` it dispatches via `tbd terminal send`, but REFUSES to
act during a cohort-wide rate crunch (driving into capped accounts only adds contention).
Default is dry-run (prints the plan, touches nothing). `--prs` also gates open PRs
(makes gh calls — skip during a GitHub-rate crunch). Dedupes + clears the queue on a
successful --act drain.
"""
import subprocess, os, json, time, sys, glob

HOME = os.path.expanduser("~")
DB = f"{HOME}/tbd/state.db"
SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUEUE = f"{SKILL}/queue"
REPO = "longeye-ai/monorepo"

def sh(args, t=20):
    try: return subprocess.run(args, capture_output=True, text=True, timeout=t).stdout
    except Exception: return ""

def lease_credential_file(tid):
    root = os.environ.get("TBD_HOME") or os.path.expanduser("~/tbd")
    matches = glob.glob(os.path.join(
        root, "runtime", "nightwatch-leases", f"{tid}-*.json"))
    if len(matches) != 1:
        sys.exit(f"refusing mutation: expected one capability file, found {len(matches)}")
    return matches[0]


def require_judge_lease():
    """Renew exact desk authority immediately before one mutable dispatch."""
    tid, wid = os.environ.get("TBD_TERMINAL_ID"), os.environ.get("TBD_WORKTREE_ID")
    if not tid or not wid:
        sys.exit("refusing dispatch: missing TBD terminal/worktree identity")
    try:
        status = subprocess.run(
            ["tbd", "nightwatch", "lease", "status", "--worktree", wid],
            capture_output=True, text=True, timeout=20)
        lease = (json.loads(status.stdout) or {}).get("lease") if status.returncode == 0 else None
    except Exception:
        lease = None
    if not lease or not lease.get("valid") or lease.get("terminalID") != tid:
        sys.exit("refusing dispatch: this terminal does not hold the valid judge lease")
    credential = lease_credential_file(tid)
    renewal = subprocess.run([
        "tbd", "nightwatch", "lease", "renew", "--credential-file", credential,
    ], capture_output=True, text=True, timeout=20)
    if renewal.returncode != 0:
        sys.exit("refusing dispatch: judge lease renewal failed")

def gh(*a, t=20):
    for k in ("HTTPS_PROXY","HTTP_PROXY","https_proxy","http_proxy"): os.environ.pop(k, None)
    return sh(["gh", *a], t)

def load_report():
    p = f"{QUEUE}/tick-report.json"
    return json.load(open(p)) if os.path.exists(p) else None

def saturated(rep):
    # tick.py writes an authoritative fleet-derived flag (cohort-wide rate crunch, post-ccflare).
    # Prefer it; fall back to the capacity status for older reports.
    s = (rep or {}).get("summary", {})
    if "saturated" in s: return bool(s["saturated"])
    return (rep or {}).get("capacity", {}).get("status") not in ("ok",)

def dispatch(tid, text, act):
    """Run the repo's bound skill in the owner's terminal (or describe it in dry-run)."""
    if not act or not tid: return False
    require_judge_lease()
    sh(["tbd", "terminal", "send", "--terminal", tid, "--submit", "--text", text])
    return True

def main():
    act = "--act" in sys.argv
    do_prs = "--prs" in sys.argv
    rep = load_report()
    if not rep:
        print("no tick-report.json — run `nightwatch tick` first"); sys.exit(1)
    sat = saturated(rep)
    agents = {a["pane"]: a for a in rep.get("agents", [])}
    # branch -> owning agent, for PR routing
    by_branch = {}
    for l in sh(["sqlite3","-separator","\t",DB,
                 "SELECT w.branch,t.tmuxPaneID,t.id,r.displayName FROM worktree w "
                 "JOIN terminal t ON t.worktreeID=w.id "
                 "AND t.kind IN ('claude','codex') AND t.suspendedAt IS NULL AND t.hibernatedAt IS NULL "
                 "JOIN repo r ON w.repoID=r.id WHERE w.status='active';"]).splitlines():
        p = l.split("\t")
        if len(p) >= 4: by_branch[p[0]] = {"pane": p[1], "tid": p[2], "repo": p[3]}

    print(f"=== nightwatch judge @ {time.strftime('%H:%M:%S')} {'[ACT]' if act else '[dry-run]'} ===")
    print(f"capacity: {'⚠ SATURATED — will not dispatch (would add contention)' if sat else 'ok'}")
    hooks = rep.get("hooks", {})
    print("hooks: " + (" · ".join(f"{n}[gate={h['gate']},advance={h['advance_skill'] or '-'}]"
                                   for n, h in hooks.items()) or "(none)"))

    plan, for_adam, acted = [], [], 0

    # ---- 1. route the queued judgment items through hooks ----
    qf = f"{QUEUE}/decisions.jsonl"
    items, seen = [], set()
    if os.path.exists(qf):
        for l in open(qf):
            l = l.strip()
            if not l: continue
            try: it = json.loads(l)
            except Exception: continue
            k = (it.get("kind"), it.get("pane"))
            if k in seen: continue
            seen.add(k); items.append(it)
    for it in items:
        pane, name = it.get("pane"), it.get("name", "")
        a = agents.get(pane, {})
        if it["kind"] == "decision":
            for_adam.append(f"DECISION — {name} ({pane}, repo={a.get('repo')}): sitting on a multi-choice prompt. "
                            "No hook auto-resolves a menu — resolve in TBD (or Opus).")
            plan.append(f"  ▸ decision {name} ({pane}) → HUMAN/Opus")
        elif it["kind"] == "maybe-archive":
            for_adam.append(f"ARCHIVE? — {name} ({pane}): looks done. Verify no open PR, then `tbd worktree archive`.")
            plan.append(f"  ▸ archive? {name} ({pane}) → HUMAN (judgment)")

    # ---- 2. (optional) gate open PRs through each repo's hook, drive via advance_skill ----
    if do_prs:
        nums = sorted(int(x) for x in gh("api", f"repos/{REPO}/pulls?state=open&per_page=100",
                      "--jq", '.[]|select(.user.login=="zionts")|.number').split() or [])
        for pr in nums[:40]:
            j = gh("api", f"repos/{REPO}/pulls/{pr}",
                   "--jq", r'"\(.head.ref)\t\(.mergeable_state)\t\(.draft)"').strip().split("\t")
            if len(j) < 2 or j[2:3] == ["true"]: continue
            branch, mstate = j[0], j[1]
            verdict = gh("api", f"repos/{REPO}/pulls/{pr}/reviews",
                         "--jq", '[.[]|select(.user.login=="longeye-claude-reviewer[bot]")|.state]|last//"NONE"').strip().strip('"')
            owner = by_branch.get(branch)
            a = agents.get(owner["pane"], {}) if owner else {}
            adv = a.get("advance_skill")
            ready = (verdict == "APPROVED" and mstate == "clean")
            if ready:
                # Reported, never merged here: this script has no head-SHA or
                # required-context check, and the gate wants all three re-read in
                # the same tool call as the enqueue. The judge does that itself.
                for_adam.append(f"READY — #{pr}: claude-APPROVED + clean. Judge may enqueue "
                                f"(`gh pr merge {pr}`) after re-reading head SHA + required contexts.")
            elif owner and adv and a.get("state") != "WORKING":
                txt = f"nightwatch: PR #{pr} not yet claude-APPROVED ({verdict}). Run `/{adv}` to drive it to APPROVED on the current SHA. Do NOT merge."
                if not sat and dispatch(owner["tid"], txt, act): acted += 1; tag = "DISPATCHED"
                else: tag = "would dispatch" + (" (saturated-held)" if sat else " (dry-run)")
                plan.append(f"  ▸ #{pr} not-ready ({verdict}) → {tag}: `/{adv}` to {owner['pane']}")
            elif not owner:
                for_adam.append(f"ORPHAN — #{pr} ({verdict}): no live owner. Spawn one or merge.")

    for p in plan: print(p)
    os.makedirs(QUEUE, exist_ok=True)
    with open(f"{QUEUE}/for-adam.md", "w") as f:
        f.write(f"# nightwatch — for Adam ({time.strftime('%Y-%m-%d %H:%M')})\n\n")
        for x in for_adam: f.write(f"- {x}\n")
    print(f"\nactions dispatched: {acted}   human items → queue/for-adam.md ({len(for_adam)})")
    if act and not sat:
        require_judge_lease()
        open(qf, "w").close(); print("drained decisions.jsonl")
    else:
        print("(dry-run or saturated — queue left intact)")

if __name__ == "__main__":
    main()
"""#

    public static let tickCronSh: String = #"""
#!/bin/bash
# nightwatch heartbeat — runs the Tier-0 tick ($0, no model). Silent on exit 0;
# on exit 10 (judgment queued) it records a marker so Opus/human is paged on exception.
LOG=/tmp/nightwatch-tick.log
TICK="$HOME/.claude/skills/nightwatch/scripts/tick.py"
out=$(/usr/bin/env python3 "$TICK" 2>&1); rc=$?
ts=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$ts] exit=$rc" >> "$LOG"
if [ "$rc" = "10" ]; then
  echo "$out" | grep -E "BURN-RISK|DECISIONS|PRIORITY|SATURATED" >> "$LOG"
  echo "[$ts] >> JUDGMENT NEEDED — run: nightwatch judge" >> "$LOG"
  command -v tbd >/dev/null && tbd notify --title "nightwatch" --message "judgment items queued" >/dev/null 2>&1 || true
fi

"""#

    public static let schedulerSh: String = #"""
#!/bin/bash
# nightwatch scheduler — INTENTIONAL enable/disable of the model-free heartbeat.
#
# Nothing here auto-runs. The skill ships this script but never loads it; you opt
# in deliberately. When enabled, a launchd job runs `tick.py` (Tier-0, $0, no model)
# on an interval, silent on exit 0, paging you (marker + `tbd notify`) only on exit 10.
#
#   scheduler.sh enable [interval_seconds]   # default 900 (15m)
#   scheduler.sh disable
#   scheduler.sh status
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"            # .../skills/nightwatch/scripts
LABEL="com.nightwatch-tick"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

case "${1:-}" in
  enable)
    INTERVAL="${2:-900}"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$DIR/tick-cron.sh</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>/tmp/nightwatch-tick.err</string>
</dict></plist>
PL
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "nightwatch scheduler ENABLED — every ${INTERVAL}s, model-free. Disable: $0 disable"
    ;;
  disable)
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "nightwatch scheduler DISABLED"
    ;;
  status)
    if launchctl list | grep -q "$LABEL"; then
      echo "ENABLED:"; launchctl list | grep "$LABEL"
      tail -3 /tmp/nightwatch-tick.log 2>/dev/null
    else
      echo "DISABLED (not loaded)"
    fi
    ;;
  *)
    echo "usage: $0 enable [interval_seconds] | disable | status"; exit 1 ;;
esac

"""#

    public static let prioritiesTxt: String = #"""
# Must-keep-moving worktrees (display-name substrings, case-insensitive).
# tick.py flags these ★ and reports their state first every tick.
Fix CSV Row Truncation

"""#

    public static let safeWedgesTxt: String = #"""
# Permission-wedge command prefixes the daemon may AUTO-APPROVE. NEVER include "gh pr merge".
gh api
git
gh pr comment
gh pr edit
gh pr review
gh pr ready
gh issue

"""#

    public static let dontTouchTxt: String = #"""
# Panes or name-substrings nightwatch must NEVER nudge/dispatch (human-driven).
# %352 = Adam's own monitoring session.
Find Monitor Corrections Issues

"""#
}
