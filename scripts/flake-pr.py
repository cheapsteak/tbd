#!/usr/bin/env python3
"""The flake PR driver's text and state half (spec §4.4, §6.5, §7).

`scripts/flake-pr.sh` is the entry point: it pushes, opens the PR, and calls
this file for every piece of text it posts and for the attempt record. Reads
and writes go through `flake-ledger.py`'s `gh` helpers, so a write refuses to
run without the App token in FLAKE_WRITE_TOKEN, exactly as the ledger's do.

    body --attempt-dir A --repo R --commits F [--replayed OLD NEW] --out F
        the draft PR's body (the template's bug-fix variant).
    status --attempt-dir A [--replayed OLD NEW]
        `<state>\\t<description>` for the `flakefix/stress` commit status.
        --replayed names the `main` the candidate was stress-checked on and
        the `main` it was replayed onto (§7); both texts then say so.
    issue-comment --attempt-dir A --kind failed|no-diff|push-refused|aborted
                  [--pr N] [--detail F] --out F
        the visible comment an attempt posts on its issue.
    entry --pick-dir P --attempt-dir A --outcome O [--pr N] [--reason TEXT]
          [--session-failed | --publish-raced] --out F
        the attempt entry, as flake_lib.Attempt JSON.
    record --repo R --issue N --entry F
        appends the entry to the issue's attempt comment, or creates it. A
        re-run of the same `fix` run replaces its own entry instead of adding
        a second. Only a comment the bot wrote is ever edited.
    comment --repo R --issue N --body F
        posts one issue comment.
    promote-resolve --repo R --sha S
        prints the branch of the one open flakefix/issue-<N> PR from R whose
        head is S, or nothing. Reads only.
    promote-facts --repo R --branch B --sha S --trigger test-run|status
                  [--conclusion C --event E --run-id ID --run-created-at T] --out F
        reads what promotion is decided on: the open PR on B, the commit
        statuses on S, the `test.yml` runs on S, the PR's draft conversions,
        and its changed files. C, E, ID and T describe the Test run that
        started a test-run promote. Reads only.
    promote-decide --facts F
        pure: prints `PROMOTE`, `PROMOTE label` (promote, adding the weak
        label first), or `SKIP <reason>`.

ONLY THE BOT'S OWN COMMENTS ARE STATE. The attempt comment is found by its
sentinel AND its author (`flake_lib.trusted_author`); a forged sentinel is left
alone and a new comment is created beside it.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, fields
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import flake_lib as fl  # noqa: E402


ledger = fl.load_ledger()
fenced = fl.fenced

STATUS_CONTEXT = "flakefix/stress"
STATUS_MAX = 140  # GitHub's limit on a commit status description
# The weak-evidence clause in a success status; promote reads it back (§6.5).
WEAK_CLAUSE = "weak evidence"
WEAK_LABEL = "flakefix-weak-evidence"
WEAK_LABEL_COLOR = "FBCA04"
WEAK_LABEL_DESCRIPTION = "Flake fix whose stress evidence is weak: weigh it against the diff"
# A candidate that renamed, moved or retired its target test (§6.4): the PR
# stays a draft, and promote never readies one carrying this label (§7).
NEEDS_HUMAN_LABEL = "flakefix-needs-human"
NEEDS_HUMAN_LABEL_COLOR = "D93F0B"
NEEDS_HUMAN_LABEL_DESCRIPTION = "Flake fix that renamed or retired its target test: a human must judge coverage"
LABELS = {
    "weak": (WEAK_LABEL, WEAK_LABEL_COLOR, WEAK_LABEL_DESCRIPTION),
    "needs-human": (NEEDS_HUMAN_LABEL, NEEDS_HUMAN_LABEL_COLOR, NEEDS_HUMAN_LABEL_DESCRIPTION),
}
COVERAGE_NOTE = "a human must judge whether coverage is preserved"
FAILING_LINES_IN_COMMENT = 60
NOTES_IN_BODY = 20000


class Malformed(Exception):
    pass


# --- reading an attempt --------------------------------------------------------------


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise Malformed(f"{path}: {error}") from error
    if not isinstance(value, dict):
        raise Malformed(f"{path}: not a JSON object")
    return value


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def sanitize(text: str) -> str:
    """Session- or candidate-written text, made safe to post. It cannot open an
    HTML comment (and so cannot hide text or spell a state sentinel), `@login`
    notifies no one, and `#123` or an issue URL is no reference, so a closing
    keyword in it ("fixes #519") closes nothing when the PR merges."""
    zw = "\u200b"
    text = text.replace("<!--", "&lt;!--").replace("@", "@" + zw)
    text = re.sub(r"#(?=\d)", "#" + zw, text)
    return re.sub(r"/(issues|pull)/(?=\d)", lambda m: f"/{m.group(1)}/{zw}", text)


def pct(x: float) -> str:
    # One decimal: rounding 4.85% to "5%" would read as the weak threshold.
    return f"{x * 100:.1f}%"


# --- the status ------------------------------------------------------------------------


def replay_note(replayed: tuple[str, str] | None) -> str:
    """Spec §7: the verdict was measured on one `main`, the PR carries the
    candidate replayed onto a later one."""
    if not replayed:
        return ""
    old, new = replayed
    return (f"stress-checked on {old[:7]}; replayed onto main {new[:7]} "
            "because main's workflow files changed during the run")


def fit(text: str) -> str:
    return text if len(text) <= STATUS_MAX else text[: STATUS_MAX - 1] + "…"


def status(verdict: dict, replayed: tuple[str, str] | None = None) -> tuple[str, str]:
    """Spec §6.5, §7. Success says what was observed, never "fixed". A replay
    note goes after the verdict's own text, so a cut falls on the note and
    never on the weak-evidence clause promote reads back."""
    state, text = _status(verdict)
    note = replay_note(replayed)
    return state, fit(f"{text}; {note}" if note else text)


def target_change(verdict: dict) -> dict | None:
    """The verdict's honored change to the target (§6.4), or None."""
    change = verdict.get("target_change")
    if isinstance(change, dict) and change.get("kind") in ("renamed", "retired"):
        return change
    return None


def _status(verdict: dict) -> tuple[str, str]:
    v = verdict.get("verdict")
    change = target_change(verdict)
    if v == "ineligible" and change:
        if change["kind"] == "renamed":
            part = f"target test renamed; no failure observed in {verdict['iterations']} runs under its new ID"
        else:
            part = "target test retired; nothing was stress-run"
        parts = [part] + (["touches " + ", ".join(verdict["protected"])] if verdict.get("protected") else [])
        return "failure", "not eligible for ready, a human must judge: " + "; ".join(parts)
    if v == "pass":
        text = f"no failure observed in {verdict['iterations']} runs"
        if verdict.get("weak"):
            if verdict.get("false_pass") is None:
                text += f"; {WEAK_CLAUSE}: bound unknown"
            else:
                text += f"; {WEAK_CLAUSE}: a no-op would pass {pct(verdict['false_pass'])} of the time"
        return "success", text
    if v == "ineligible":
        text = "not eligible for ready, a human must judge: touches " + ", ".join(verdict.get("protected") or [])
        return "failure", text
    reasons = verdict.get("reasons") or ["the stress run failed"]
    text = f"stress failed: target failed in {verdict.get('target_failures', 0)} of {verdict.get('iterations')} runs; {reasons[0]}"
    return "failure", text


# --- the PR body -------------------------------------------------------------------------


def numbers_line(verdict: dict) -> str:
    """The evidence in one line: scope, baseline, p, N, cap, false-pass."""
    p = verdict.get("p")
    if verdict.get("false_pass") is None:
        bound = "false-pass probability unknown"
    else:
        bound = f"false-pass probability {pct(verdict['false_pass'])}"
    return (
        f"scope {verdict.get('scope')}, baseline {verdict.get('baseline', 'see below')}, "
        f"p = {p if p is not None else 'not measured'}, N = {verdict.get('n')}, cap {verdict.get('cap')}, {bound}"
    )


def body(pick: Path, attempt: Path, repo: str, commits: str, replayed: tuple[str, str] | None = None) -> str:
    # The target comes from the pick, uploaded before any session ran.
    target = read_json(pick / "target.json")
    verdict = read_json(attempt / "verify" / "verdict.json")
    baseline_dir = attempt / "baseline"
    f, v = read_text(baseline_dir / "f").strip(), read_text(baseline_dir / "v").strip()
    if f and v:
        verdict["baseline"] = f"{f} of {v}"
    notes = sanitize(read_text(attempt / "flakefix-notes.md").strip())[:NOTES_IN_BODY]
    test = target["test_id"]
    change = target_change(verdict)
    out = []
    if change:
        # §6.4, §7: first, above everything, so no reviewer misses it.
        if change["kind"] == "renamed":
            what = f"`{test}` is now `{change['to']}`, and the stress run below is for the new ID."
        else:
            what = (f"`{test}` is gone, so nothing was stress-run and no stress verdict is claimed. "
                    f"The session's reason: {sanitize(change.get('reason') or 'none given')}")
        out += [f"> **The target test was {change['kind']}; {COVERAGE_NOTE}.** {what} "
                f"This PR stays a draft that the bot never marks ready, labelled `{NEEDS_HUMAN_LABEL}`.", ""]
    if verdict.get("weak"):
        out += [
            f"> **Weak evidence.** {numbers_line(verdict)}. A clean run here says little on its own; "
            "weigh it against the diff.",
            "",
        ]
    out += [
        "## What's broken",
        "",
        f"`{test}` is flaky: the flake ledger recorded {target.get('failures')} failures in its current episode, "
        f"across {len(target.get('places') or [])} distinct places ({', '.join(f'`{p}`' for p in target.get('places') or [])}). "
        "Its history is on the issue.",
        "",
        f"Fixes #{target['issue']}",
        "",
        "## Why it happens",
        "",
        "From the fixer session's notes. They are session-reported: the verifier below did not consult them.",
        "",
        notes or "_The session wrote no notes._",
        "",
        "## What this PR does",
        "",
        "Commits by the flake fixer (docs/specs/2026-10-07-flake-autofix-design.md):",
        "",
        fenced(commits.strip() or "(none listed)"),
        "",
        "## Evidence & verification",
        "",
    ]
    if replayed:
        out += [
            f"**Replayed.** The candidate was {replay_note(replayed)}: GitHub refuses the bot's push of a branch "
            "whose workflow files differ from `main`'s. The verdict below is for the candidate on "
            f"`{replayed[0][:12]}`; this PR's own CI runs on the replayed commits, and promotion waits for it.",
            "",
        ]
    if not verdict.get("weak") and not (change and change["kind"] == "retired"):
        out += [f"Numbers: {numbers_line(verdict)}.", ""]
    out += [sanitize(read_text(attempt / "verify" / "verdict.md").strip()), ""]
    run_url = read_text(attempt / "run_url").strip()
    if run_url:
        out += [f"Fix run: {run_url}"]
    return "\n".join(out).rstrip() + "\n"


# --- issue comments -------------------------------------------------------------------------


def issue_comment(attempt: Path, kind: str, pr: str | None, detail: str) -> str:
    notes = sanitize(read_text(attempt / "flakefix-notes.md").strip())
    run_url = read_text(attempt / "run_url").strip()
    head = {
        "failed": f"### Flake fix attempt: not eligible for ready\n\nThe verifier failed the candidate, it touches a file the verdict "
                  f"depends on, or it renamed or retired the target test. Draft PR #{pr} stays open for a human to read, finish, or close.",
        "no-diff": "### Flake fix attempt: no change\n\nThe fixer session made no commits, so no PR was opened.",
        "push-refused": "### Flake fix attempt: the push was refused\n\nNo PR was opened.",
    }[kind]
    out = [head, ""]
    if detail.strip():
        out += [fenced(sanitize(detail.strip())), ""]
    out += ["**Session notes** (session-reported):", "", notes or "_None._", ""]
    if run_url:
        out.append(f"Fix run: {run_url}")
    return "\n".join(out).rstrip() + "\n"


# --- the attempt entry and comment -------------------------------------------------------------


def entry(pick: Path, attempt: Path, outcome: str, pr: int | None, reason: str,
          session_failed: bool = False, publish_raced: bool = False) -> dict:
    target = read_json(pick / "target.json")
    notes = read_text(attempt / "flakefix-notes.md").strip() if attempt.is_dir() else ""
    if reason:
        notes = f"{reason}\n\n{notes}".strip()
    record = fl.Attempt(
        run_id=int(read_text(pick / "run_id").strip()),
        started_at=read_text(pick / "started_at").strip(),
        main_sha=read_text(pick / "base_sha").strip(),
        episode=int(target.get("episode", 0)),
        outcome=outcome,
        notes=notes[: fl.ATTEMPT_NOTES_CHARS],
        session_failed=True if outcome == "aborted" and session_failed else None,
        publish_raced=True if outcome == "aborted" and publish_raced else None,
    )
    if outcome == "pr-opened":
        verdict = read_json(attempt / "verify" / "verdict.json")
        change = target_change(verdict)
        stressed = not (change and change["kind"] == "retired" and verdict.get("verdict") != "fail")
        record = fl.Attempt(
            **{**asdict(record), "pr": pr, "scope": verdict.get("scope"), "n": verdict.get("n"),
               "false_pass": verdict.get("false_pass"), "weak": bool(verdict.get("weak")),
               "protected_touched": list(verdict.get("protected") or []),
               # The stress verdict; a protected file and a renamed or retired
               # target are recorded beside it. A retirement ran nothing.
               "verdict": ("fail" if verdict.get("verdict") == "fail" else "pass") if stressed else None,
               "target_change": change["kind"] if change else None,
               "renamed_to": change["to"] if change and change["kind"] == "renamed" else None}
        )
    return asdict(record)


def record(repo: str, issue: int, new: dict) -> None:
    known = {f.name for f in fields(fl.Attempt)}
    if set(new) - known or new.get("outcome") not in fl.ATTEMPT_OUTCOMES:
        raise Malformed(f"not an attempt entry: {sorted(set(new) - known)} {new.get('outcome')!r}")
    comments = ledger.gh_lines("api", "--paginate", f"repos/{repo}/issues/{issue}/comments?per_page=100", "--jq", ".[]")
    mine = None
    for c in sorted(comments, key=lambda c: c["id"]):
        text = c.get("body") or ""
        user = c.get("user") or {}
        if not text.startswith(fl.ATTEMPTS_SENTINEL):
            continue
        if not fl.trusted_author(user.get("login"), user.get("type")):
            print(f"flake-pr: ignoring an attempt sentinel by {user.get('login')!r} on #{issue}", file=sys.stderr)
            continue
        attempts = fl.parse_attempts(text, user.get("login"), user.get("type"))
        if attempts is None:
            # Fail closed: overwriting an unreadable record would lose history.
            raise Malformed(f"#{issue}: the bot's own attempt comment {c['id']} does not parse")
        mine = (int(c["id"]), attempts)
        break
    attempt = fl.Attempt(**new)
    if mine is None:
        ledger.gh_write("api", "-X", "POST", f"repos/{repo}/issues/{issue}/comments",
                        payload={"body": fl.render_attempts([attempt], repo)})
        return
    comment_id, attempts = mine
    attempts = [a for a in attempts if a.run_id != attempt.run_id] + [attempt]
    ledger.gh_write("api", "-X", "PATCH", f"repos/{repo}/issues/comments/{comment_id}",
                    payload={"body": render_bounded(attempts, repo)})


def render_bounded(attempts: list[fl.Attempt], repo: str) -> str:
    """The attempt comment, kept under GitHub's body limit. Every entry is
    state the picker reads, so none is dropped; the oldest entries' notes are
    blanked first, which leaves room for a couple of hundred attempts."""
    ordered = sorted(attempts, key=lambda a: (a.started_at, a.run_id))
    body = fl.render_attempts(ordered, repo)
    if len(body) <= fl.MAX_COMMENT_CHARS:
        return body
    bare = [fl.Attempt(**{**asdict(a), "notes": ""}) for a in ordered]
    room = fl.MAX_COMMENT_CHARS - len(fl.render_attempts(bare, repo))
    if room < 0:
        raise Malformed(f"{len(ordered)} attempts do not fit in one comment even without notes")
    # Keep the newest notes that fit, sized as the JSON block will escape them;
    # one render to size, one to check.
    keep = len(ordered)
    for i in range(len(ordered) - 1, -1, -1):
        cost = len(json.dumps(ordered[i].notes, ensure_ascii=False)) - 2
        if cost > room:
            break
        room -= cost
        keep = i
    while True:
        trimmed = bare[:keep] + ordered[keep:]
        body = fl.render_attempts(trimmed, repo)
        if len(body) <= fl.MAX_COMMENT_CHARS:
            return body
        keep += 1


def ensure_label(repo: str, pr: int, which: str) -> None:
    """Puts one of the bot's PR labels on PR, creating it if it is missing."""
    name, color, description = LABELS[which]
    names = [label["name"] for label in ledger.gh_lines("api", "--paginate", f"repos/{repo}/labels?per_page=100", "--jq", ".[] | {name}")]
    if name not in names:
        ledger.gh_write("api", "-X", "POST", f"repos/{repo}/labels",
                        payload={"name": name, "color": color, "description": description})
    ledger.gh_write("api", "-X", "POST", f"repos/{repo}/issues/{pr}/labels", payload={"labels": [name]})


# --- promotion (spec §6.5, §7) -------------------------------------------------------------

PROMOTE_BRANCH = re.compile(r"flakefix/issue-[0-9]+")
PROMOTE_EVENT = "pull_request"
# What can start a promote: a Test run's completion, or the bot's stress status.
PROMOTE_TRIGGERS = ("test-run", "status")
TEST_WORKFLOW = ".github/workflows/test.yml"
# GitHub's pull-request files endpoint lists at most this many files.
PR_FILES_LISTED_MAX = 3000


def resolve_branch(pulls: list, repo: str, sha: str) -> str:
    """The branch of the one open flakefix/issue-<N> PR from `repo` whose head
    is `sha`, or "" when there is none or more than one. A status names a
    commit, not a PR; promote-facts then reads that PR again by its branch."""
    if not isinstance(pulls, list):
        raise Malformed("the commit's pulls listing is not a list")
    branches = set()
    for p in pulls:
        head = p.get("head") or {}
        if p.get("state") == "open" and head.get("sha") == sha \
                and (head.get("repo") or {}).get("full_name") == repo \
                and PROMOTE_BRANCH.fullmatch(head.get("ref") or ""):
            branches.add(head["ref"])
    return branches.pop() if len(branches) == 1 else ""


def promote_resolve(repo: str, sha: str) -> str:
    return resolve_branch(ledger.gh_json("api", f"repos/{repo}/commits/{sha}/pulls?per_page=100"), repo, sha)


def promote_facts(repo: str, branch: str, sha: str, trigger: str, conclusion: str | None, event: str | None,
                  run_id: int | None = None, run_created_at: str | None = None) -> dict:
    """Everything promote-decide reads, from GitHub. A failed read raises, so
    the PR stays a draft (fail closed)."""
    owner = repo.split("/", 1)[0]
    raw = ledger.gh_json("api", f"repos/{repo}/pulls?head={owner}:{branch}&state=open&per_page=100")
    if not isinstance(raw, list):
        raise Malformed("the pulls listing is not a list")
    prs = [{
        "number": int(p["number"]),
        "state": p.get("state"),
        "draft": p.get("draft"),
        "head_sha": (p.get("head") or {}).get("sha"),
        "head_ref": (p.get("head") or {}).get("ref"),
        "head_repo": ((p.get("head") or {}).get("repo") or {}).get("full_name"),
        "author": (p.get("user") or {}).get("login"),
        "author_type": (p.get("user") or {}).get("type"),
        "labels": [label.get("name") for label in p.get("labels") or []],
        "changed_files": None,
    } for p in raw]
    facts = {"repo": repo, "branch": branch, "trigger": trigger, "run_conclusion": conclusion,
             "run_event": event, "run_id": run_id, "run_created_at": run_created_at, "run_head_sha": sha, "prs": prs, "statuses": [], "test_runs": [],
             "drafted": [], "files": []}
    if len(prs) != 1:
        return facts
    number = prs[0]["number"]
    # The list endpoint omits changed_files; the single-PR one carries it.
    one = ledger.gh_json("api", f"repos/{repo}/pulls/{number}")
    prs[0]["changed_files"] = one.get("changed_files") if isinstance(one, dict) else None
    facts["statuses"] = ledger.gh_lines(
        "api", "--paginate", f"repos/{repo}/commits/{sha}/statuses?per_page=100", "--jq",
        ".[] | {context, state, description, creator: .creator.login, creator_type: .creator.type, created_at, id}")
    facts["test_runs"] = ledger.gh_lines(
        "api", "--paginate",
        f"repos/{repo}/actions/workflows/test.yml/runs?head_sha={sha}&event={PROMOTE_EVENT}&per_page=100",
        "--jq", ".workflow_runs[] | {id, event, path, status, conclusion, head_sha, head_branch,"
        " head_repo: .head_repository.full_name, created_at}")
    # Every return to draft: the bot's own (promote's undo) and a human's hold.
    facts["drafted"] = ledger.gh_lines(
        "api", "--paginate", f"repos/{repo}/issues/{number}/timeline?per_page=100", "--jq",
        '.[] | select(.event == "convert_to_draft") | {actor: .actor.login, actor_type: .actor.type, created_at}')
    facts["files"] = ledger.gh_lines(
        "api", "--paginate", f"repos/{repo}/pulls/{number}/files?per_page=100", "--jq",
        ".[] | {filename, previous_filename}")
    return facts


def promote_decision(facts: dict) -> str:
    """Spec §7: ready only when the PR's own CI passed on the head the verifier
    passed. A Test completion and the bot's stress status each start a promote,
    so whichever lands last promotes; both are judged on the same facts. Every
    condition is required; the first that fails names the skip."""
    try:
        trigger = facts["trigger"]
        if trigger not in PROMOTE_TRIGGERS:
            raise Malformed(f"unknown promote trigger {trigger!r}")
        if trigger == "test-run":
            if facts["run_event"] != PROMOTE_EVENT:
                return f"SKIP the run was a {facts['run_event']} run, not the PR's own CI"
        if not PROMOTE_BRANCH.fullmatch(facts["branch"] or ""):
            return "SKIP not a flakefix/issue-<N> branch"
        prs = facts["prs"]
        if len(prs) != 1:
            return f"SKIP {len(prs)} open PRs use the branch, not one"
        pr = prs[0]
        if pr["state"] != "open":
            return "SKIP the PR is not open"
        if pr["draft"] is not True:
            return "SKIP the PR is not a draft"
        if pr["head_ref"] != facts["branch"]:
            return "SKIP the PR's head is another branch"
        if pr["head_repo"] != facts["repo"]:
            return "SKIP the PR's head is in another repository"
        if not fl.trusted_author(pr["author"], pr["author_type"]):
            return f"SKIP the PR was opened by {pr['author']}, not the bot"
        # A renamed or retired target (§6.4): only a human marks it ready.
        if NEEDS_HUMAN_LABEL in pr["labels"]:
            return f"SKIP the PR is labelled {NEEDS_HUMAN_LABEL}: its target test was renamed or retired, and {COVERAGE_NOTE}"
        # A human who returns the PR to draft is holding it; the bot never
        # overrides that. Only a human marking it ready releases the hold.
        held = [d for d in facts["drafted"] if not fl.trusted_author(d["actor"], d["actor_type"])]
        if held:
            return (f"SKIP {held[0]['actor'] or 'an unknown account'}, not the bot, returned the PR to draft"
                    " (a hold); only a human marks it ready now")
        if pr["head_sha"] != facts["run_head_sha"]:
            return "SKIP the PR's head is no longer the commit this promote was started for (a push the verifier never judged)"
        runs = [r for r in facts["test_runs"]
                if r["event"] == PROMOTE_EVENT and r["path"].split("@", 1)[0] == TEST_WORKFLOW
                and r["head_sha"] == facts["run_head_sha"] and r["head_branch"] == facts["branch"]
                and r["head_repo"] == facts["repo"]]
        if trigger != "status":
            # The run that started this promote is known from its own event:
            # the listing may not show it completed yet, so its entry is the
            # event's, not the listing's. A newer run in the listing still wins.
            runs = [r for r in runs if int(r["id"]) != int(facts["run_id"])] + [{
                "id": int(facts["run_id"]), "created_at": facts["run_created_at"],
                "status": "completed", "conclusion": facts["run_conclusion"]}]
        if not runs:
            return "SKIP the PR's own Test run has not run on the head"
        latest = max(runs, key=lambda r: (r["created_at"], int(r["id"])))
        if latest["status"] != "completed" or latest["conclusion"] != "success":
            return f"SKIP the PR's newest Test run on the head is {latest['status']}, {latest['conclusion']}"
        mine = [s for s in facts["statuses"]
                if s["context"] == STATUS_CONTEXT and fl.trusted_author(s["creator"], s["creator_type"])]
        if not mine:
            return f"SKIP no {STATUS_CONTEXT} status from the bot on the head"
        newest = max(mine, key=lambda s: (s["created_at"], int(s["id"])))
        if newest["state"] != "success":
            return f"SKIP {STATUS_CONTEXT} is {newest['state']}"
        listed = facts["files"]
        if not isinstance(pr["changed_files"], int) or pr["changed_files"] != len(listed) \
                or len(listed) >= PR_FILES_LISTED_MAX:
            return "SKIP the PR's changed files could not all be listed"
        protected = facts["protected_touched"]
        if protected:
            return "SKIP the PR touches protected files: " + ", ".join(protected)
        if WEAK_CLAUSE in (newest.get("description") or "") and WEAK_LABEL not in pr["labels"]:
            return "PROMOTE label"
        return "PROMOTE"
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        raise Malformed(f"malformed promotion facts: {error!r}") from error


# --- CLI -------------------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="flake-pr.py")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("body")
    p.add_argument("--pick-dir", type=Path, required=True)
    p.add_argument("--attempt-dir", type=Path, required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--commits", type=Path, required=True)
    p.add_argument("--replayed", nargs=2, metavar=("OLD", "NEW"))
    p.add_argument("--out", type=Path, required=True)
    p = sub.add_parser("status")
    p.add_argument("--attempt-dir", type=Path, required=True)
    p.add_argument("--replayed", nargs=2, metavar=("OLD", "NEW"))
    p = sub.add_parser("issue-comment")
    p.add_argument("--attempt-dir", type=Path, required=True)
    p.add_argument("--kind", choices=("failed", "no-diff", "push-refused"), required=True)
    p.add_argument("--pr")
    p.add_argument("--detail", type=Path)
    p.add_argument("--out", type=Path, required=True)
    p = sub.add_parser("entry")
    p.add_argument("--pick-dir", type=Path, required=True)
    p.add_argument("--attempt-dir", type=Path, required=True)
    p.add_argument("--outcome", choices=fl.ATTEMPT_OUTCOMES, required=True)
    p.add_argument("--pr", type=int)
    p.add_argument("--reason", default="")
    kind = p.add_mutually_exclusive_group()
    kind.add_argument("--session-failed", action="store_true")
    kind.add_argument("--publish-raced", action="store_true")
    p.add_argument("--out", type=Path, required=True)
    p = sub.add_parser("record")
    p.add_argument("--repo", required=True)
    p.add_argument("--issue", type=int, required=True)
    p.add_argument("--entry", type=Path, required=True)
    p = sub.add_parser("label")
    p.add_argument("--repo", required=True)
    p.add_argument("--pr", type=int, required=True)
    p.add_argument("--which", choices=sorted(LABELS), required=True)
    p = sub.add_parser("comment")
    p.add_argument("--repo", required=True)
    p.add_argument("--issue", type=int, required=True)
    p.add_argument("--body", type=Path, required=True)
    p = sub.add_parser("promote-resolve")
    p.add_argument("--repo", required=True)
    p.add_argument("--sha", required=True)
    p = sub.add_parser("promote-facts")
    p.add_argument("--repo", required=True)
    p.add_argument("--branch", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--trigger", choices=PROMOTE_TRIGGERS, required=True)
    p.add_argument("--conclusion")
    p.add_argument("--event")
    p.add_argument("--run-id", type=int)
    p.add_argument("--run-created-at")
    p.add_argument("--out", type=Path, required=True)
    p = sub.add_parser("promote-decide")
    p.add_argument("--facts", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "body":
            replayed = tuple(args.replayed) if args.replayed else None
            args.out.write_text(body(args.pick_dir, args.attempt_dir, args.repo, read_text(args.commits), replayed))
        elif args.command == "status":
            replayed = tuple(args.replayed) if args.replayed else None
            state, text = status(read_json(args.attempt_dir / "verify" / "verdict.json"), replayed)
            print(f"{state}\t{text}")
        elif args.command == "issue-comment":
            detail = read_text(args.detail) if args.detail else ""
            args.out.write_text(issue_comment(args.attempt_dir, args.kind, args.pr, detail))
        elif args.command == "entry":
            args.out.write_text(json.dumps(entry(args.pick_dir, args.attempt_dir, args.outcome, args.pr, args.reason,
                                              args.session_failed, args.publish_raced)) + "\n")
        elif args.command == "record":
            record(args.repo, args.issue, read_json(args.entry))
        elif args.command == "promote-facts":
            facts = promote_facts(args.repo, args.branch, args.sha, args.trigger, args.conclusion, args.event,
                                  args.run_id, args.run_created_at)
            args.out.write_text(json.dumps(facts) + "\n")
        elif args.command == "promote-resolve":
            print(promote_resolve(args.repo, args.sha))
        elif args.command == "promote-decide":
            print(promote_decision(read_json(args.facts)))
        elif args.command == "label":
            ensure_label(args.repo, args.pr, args.which)
        else:
            ledger.gh_write("api", "-X", "POST", f"repos/{args.repo}/issues/{args.issue}/comments",
                            payload={"body": read_text(args.body)})
        return 0
    except ledger.GhError as error:
        print(f"flake-pr: {error}", file=sys.stderr)
        return 2
    except (Malformed, ValueError, KeyError, TypeError) as error:
        print(f"flake-pr: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
