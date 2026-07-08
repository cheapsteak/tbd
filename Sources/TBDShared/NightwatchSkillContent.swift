import Foundation

/// Canonical content for the `nightwatch` skill — a quota-lean TBD-fleet
/// babysitter bundled into the TBD Claude plugin. Repo-agnostic core; each
/// child repo plugs in policy via <repo>/.nightwatch/policy.json. The scheduler
/// (scheduler.sh / tick-cron.sh) ships but is opt-in — never auto-loaded.
/// Single source of truth, written by PluginDirWriter. Generated from the skill files.
public enum NightwatchSkillContent {

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
| **0** | `scripts/tick.py` — pure Python, $0 | sweep all panes (every tmux server), daemon health + fleet capacity, classify every agent, split into auto/judgment/human, write `queue/tick-report.json` |
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
- `queue/tick-report.json` — full structured state (daemon, capacity, every agent, auto_actions, judgment_queue)
- `queue/decisions.jsonl` — append-only judgment items (decisions to resolve, maybe-archive)
- `queue/for-adam.md` — human-only items

**Capacity-aware backoff is built in:** there is no shared proxy pool anymore (better-ccflare was removed 2026-07-01 — every session talks to Anthropic directly over its own OAuth), so capacity exhaustion is a *per-account* event that shows up per-agent as a rate-limited pane. tick.py counts those and, when `RATE_SATURATION_MIN` (3) or more agents are capped at once — a genuine cohort-wide crunch — *holds* all nudges (piling onto capped accounts only adds contention) and says so. Individual rate-limited agents are never nudged either (a retry just re-hits the cap). This is the rule I otherwise have to notice by hand.

## When paged (Tier 2 — Opus drains the queue)

Only when `tick.py` exits 10 (or on the 2-hour deep-review window): read `queue/decisions.jsonl`, resolve each genuine decision (what Adam would decide; sensitive/personal/access → `for-adam.md`, don't auto-fire), then clear the drained lines. This is the only step that should consume Opus.

## The gate (never automate past this)

A PR may only be enqueued when **claude-review = APPROVED on the current SHA + checks clean**. Human approval never substitutes. `gh pr merge` is NOT a safe-wedge — it always escalates. nightwatch's job is to get PRs *ready*; the human merges.

## Config (`config/`)
- `priorities.txt` — must-keep-moving worktrees (flagged ★, reported first)
- `safe_wedges.txt` — permission-wedge prefixes the daemon may auto-approve (never `gh pr merge`)
- `dont_touch.txt` — panes/names nightwatch must never nudge (human-driven, e.g. Adam's own session)

## The durable spine (already on launchd, model-free)
- `scripts/daemon.py` (babysitter) — auto-approves safe wedges, escalates real ones
- `scripts/watchdog.sh` — restarts the daemon if its log goes >12min stale (hang/sleep)
These keep the critical safety net running even when Opus is fully capped. (Currently live as `~/.fleet/babysitter_daemon.py` + `daemon_watchdog.sh`; copy in for a self-contained skill.)

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

    public static let tickPy: String = #"""
#!/usr/bin/env python3
"""
nightwatch tick — Tier-0 orchestrator. NO model in the hot path.

Reads the whole TBD fleet across all tmux servers, the babysitter daemon health,
and fleet-derived capacity, classifies every agent deterministically, and emits:
  - a structured tick-report.json  (machine-readable)
  - a short human summary to stdout
  - queue/decisions.jsonl   (items that need Tier-2 / Opus judgment)
  - queue/for-adam.md       (items only a human should do)

Exit code 0 = nothing needs Opus (silent-ok).  Exit code 10 = judgment items queued.
Run with --prs to also gate open PRs (makes gh calls — skip during GitHub rate crunch).
"""
import subprocess, os, re, json, time, sys, fcntl

HOME = os.path.expanduser("~")
DB = f"{HOME}/tbd/state.db"
SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUEUE = f"{SKILL}/queue"
CFG = f"{SKILL}/config"
DAEMON_LOG = "/tmp/babysitter.log"

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

def classify(cap):
    """Return state for a captured pane: WORKING / DECISION / RATE / ERROR / STRANDED / DONE / IDLE."""
    lines = [x for x in cap.splitlines() if x.strip()]
    if not lines: return "EMPTY", ""
    tail = "\n".join(lines[-18:])
    if "esc to interrupt" in tail: return "WORKING", _lastmeaning(lines)
    if DECISION_PAT.search(tail): return "DECISION", _lastmeaning(lines)
    comp = _composer(lines)
    if RATE_PAT.search(tail): return "RATE", comp or _lastmeaning(lines)
    if ERR_PAT.search(tail): return "ERROR", comp or _lastmeaning(lines)
    if DONE_PAT.search(tail): return "DONE", _lastmeaning(lines)
    if comp: return "STRANDED", comp
    return "IDLE", ""

def _lastmeaning(lines):
    for x in reversed(lines):
        s = x.strip()
        if any(k in s for k in ("bypass permissions","esc to interrupt","context used","auto-compact","/model")): continue
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

def _composer(lines):
    for i, x in enumerate(lines):
        if "bypass permissions" in x and i > 0:
            for j in range(i-1, -1, -1):
                s = lines[j].strip()
                if s.startswith("❯"): return s[1:].strip()[:120]
                if s.startswith("─"): continue
            break
    return ""

def daemon_health():
    if not os.path.exists(DAEMON_LOG): return {"ok": False, "age_s": None, "reason": "log-missing"}
    age = int(time.time() - os.path.getmtime(DAEMON_LOG))
    return {"ok": age <= 720, "age_s": age, "reason": ("stale" if age > 720 else "fresh")}

def fleet():
    rows = sh(["sqlite3","-separator","\t",DB,
      "SELECT t.tmuxPaneID, w.displayName, w.tmuxServer, t.id, w.repoID "
      "FROM worktree w JOIN terminal t ON t.worktreeID=w.id AND t.kind='claude' AND t.suspendedAt IS NULL "
      "WHERE w.status='active' ORDER BY w.tmuxServer, w.displayName;"])
    out = []
    for l in rows.splitlines():
        p = l.split("\t")
        if len(p) < 5: continue
        pane, name, srv, tid, rid = p
        cap = sh(["tmux","-L",srv,"capture-pane","-p","-t",pane])
        state, note = classify(cap)
        ctx_pct, is_1m, burn = burn_risk(cap)
        hook = POLICIES.get(rid, {})
        pol = hook.get("policy", {})
        # priorities/dont-touch are the UNION of global config + the repo's own hook
        prio = (any(s.lower() in name.lower() for s in PRIORITIES)
                or any(s.lower() in name.lower() for s in pol.get("priorities", [])))
        protect = (any(d in pane or d.lower() in name.lower() for d in DONT_TOUCH)
                   or any(d.lower() in name.lower() for d in pol.get("dont_touch", [])))
        out.append({"pane": pane, "name": name, "server": srv, "tid": tid,
                    "state": state, "note": note, "priority": prio, "protected": protect,
                    "repo": hook.get("name"), "gate": pol.get("gate", {}).get("ready_when"),
                    "advance_skill": pol.get("advance_skill"), "deploy_skill": pol.get("deploy_skill"),
                    "ctx_pct": ctx_pct, "is_1m": is_1m, "burn_risk": burn})
    return out

def main():
    # Prevent concurrent tick runs (e.g. DaywatchRunner loop + launchd scheduler both active).
    # Acquire an exclusive lock on a lock file; if already held, another tick is running — exit silently.
    lock_path = f"{SKILL}/queue/tick.lock"
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
    d, c = rep["daemon"], capacity
    print(f"=== nightwatch tick @ {time.strftime('%H:%M:%S')} ===")
    if rep["hooks"]:
        print("hooks: " + " · ".join(f"{n}[gate={h['gate'] or '-'},advance={h['advance_skill'] or '-'}]"
                                      for n,h in rep["hooks"].items()))
    else:
        print("hooks: (none — repos can ship .nightwatch/policy.json)")
    print(f"daemon: {d['reason']} ({d['age_s']}s)   "
          f"capacity: {c['status']} (rate-limited {c['rate_limited']}/{len(rep['agents'])})"
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
import subprocess, os, json, time, sys

HOME = os.path.expanduser("~")
DB = f"{HOME}/tbd/state.db"
SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUEUE = f"{SKILL}/queue"
REPO = "longeye-ai/monorepo"

def sh(args, t=20):
    try: return subprocess.run(args, capture_output=True, text=True, timeout=t).stdout
    except Exception: return ""

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
                 "JOIN terminal t ON t.worktreeID=w.id AND t.kind='claude' AND t.suspendedAt IS NULL "
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
                for_adam.append(f"READY — #{pr}: claude-APPROVED + clean. Human merge.")
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
