#!/usr/bin/env python3
"""The flake PR driver's text and state half (spec §4.4, §6.5, §7).

`scripts/flake-pr.sh` is the entry point: it pushes, opens the PR, and calls
this file for every piece of text it posts and for the attempt record. Reads
and writes go through `flake-ledger.py`'s `gh` helpers, so a write refuses to
run without the App token in FLAKE_WRITE_TOKEN, exactly as the ledger's do.

    body --attempt-dir A --repo R --commits F --out F
        the draft PR's body (the template's bug-fix variant).
    status --attempt-dir A
        `<state>\\t<description>` for the `flakefix/stress` commit status.
    issue-comment --attempt-dir A --kind failed|no-diff|push-refused|aborted
                  [--pr N] [--detail F] --out F
        the visible comment an attempt posts on its issue.
    entry --pick-dir P --attempt-dir A --outcome O [--pr N] [--reason TEXT] --out F
        the attempt entry, as flake_lib.Attempt JSON.
    record --repo R --issue N --entry F
        appends the entry to the issue's attempt comment, or creates it. A
        re-run of the same `fix` run replaces its own entry instead of adding
        a second. Only a comment the bot wrote is ever edited.
    comment --repo R --issue N --body F
        posts one issue comment.

ONLY THE BOT'S OWN COMMENTS ARE STATE. The attempt comment is found by its
sentinel AND its author (`flake_lib.trusted_author`); a forged sentinel is left
alone and a new comment is created beside it.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, fields
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import flake_lib as fl  # noqa: E402


ledger = fl.load_ledger()
fenced = fl.fenced

STATUS_CONTEXT = "flakefix/stress"
STATUS_MAX = 140  # GitHub's limit on a commit status description
WEAK_LABEL = "flakefix-weak-evidence"
WEAK_LABEL_COLOR = "FBCA04"
WEAK_LABEL_DESCRIPTION = "Flake fix whose stress evidence is weak: weigh it against the diff"
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
    """Session-written text, made safe to post: it cannot open an HTML comment
    (and so cannot hide text or spell a state sentinel), and `@login` does not
    notify anyone."""
    return text.replace("<!--", "&lt;!--").replace("@", "@​")


def pct(x: float) -> str:
    # One decimal: rounding 4.85% to "5%" would read as the weak threshold.
    return f"{x * 100:.1f}%"


# --- the status ------------------------------------------------------------------------


def status(verdict: dict) -> tuple[str, str]:
    """Spec §6.5, §7. Success says what was observed, never "fixed"."""
    v = verdict.get("verdict")
    if v == "pass":
        text = f"no failure observed in {verdict['iterations']} runs"
        if verdict.get("weak"):
            if verdict.get("false_pass") is None:
                text += "; weak evidence: bound unknown"
            else:
                text += f"; weak evidence: a no-op would pass {pct(verdict['false_pass'])} of the time"
        return "success", text[:STATUS_MAX]
    if v == "ineligible":
        text = "not eligible for ready, a human must judge: touches " + ", ".join(verdict.get("protected") or [])
        return "failure", (text if len(text) <= STATUS_MAX else text[: STATUS_MAX - 1] + "…")
    reasons = verdict.get("reasons") or ["the stress run failed"]
    text = f"stress failed: target failed in {verdict.get('target_failures', 0)} of {verdict.get('iterations')} runs; {reasons[0]}"
    return "failure", (text if len(text) <= STATUS_MAX else text[: STATUS_MAX - 1] + "…")


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


def body(pick: Path, attempt: Path, repo: str, commits: str) -> str:
    # The target comes from the pick, uploaded before any session ran.
    target = read_json(pick / "target.json")
    verdict = read_json(attempt / "verify" / "verdict.json")
    baseline_dir = attempt / "baseline"
    f, v = read_text(baseline_dir / "f").strip(), read_text(baseline_dir / "v").strip()
    if f and v:
        verdict["baseline"] = f"{f} of {v}"
    notes = sanitize(read_text(attempt / "flakefix-notes.md").strip())[:NOTES_IN_BODY]
    test = target["test_id"]
    out = []
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
    if not verdict.get("weak"):
        out += [f"Numbers: {numbers_line(verdict)}.", ""]
    out += [read_text(attempt / "verify" / "verdict.md").strip(), ""]
    run_url = read_text(attempt / "run_url").strip()
    if run_url:
        out += [f"Fix run: {run_url}"]
    return "\n".join(out).rstrip() + "\n"


# --- issue comments -------------------------------------------------------------------------


def issue_comment(attempt: Path, kind: str, pr: str | None, detail: str) -> str:
    notes = sanitize(read_text(attempt / "flakefix-notes.md").strip())
    run_url = read_text(attempt / "run_url").strip()
    head = {
        "failed": f"### Flake fix attempt: not eligible for ready\n\nThe verifier failed the candidate, or it touches a file the verdict depends on. "
                  f"Draft PR #{pr} stays open for a human to read, finish, or close.",
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


def entry(pick: Path, attempt: Path, outcome: str, pr: int | None, reason: str) -> dict:
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
    )
    if outcome == "pr-opened":
        verdict = read_json(attempt / "verify" / "verdict.json")
        record = fl.Attempt(
            **{**asdict(record), "pr": pr, "scope": verdict.get("scope"), "n": verdict.get("n"),
               "false_pass": verdict.get("false_pass"), "weak": bool(verdict.get("weak")),
               "protected_touched": list(verdict.get("protected") or []),
               # The stress verdict; a protected file is recorded beside it.
               "verdict": "fail" if verdict.get("verdict") == "fail" else "pass"}
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


def ensure_weak_label(repo: str, pr: int) -> None:
    names = [label["name"] for label in ledger.gh_lines("api", "--paginate", f"repos/{repo}/labels?per_page=100", "--jq", ".[] | {name}")]
    if WEAK_LABEL not in names:
        ledger.gh_write("api", "-X", "POST", f"repos/{repo}/labels",
                        payload={"name": WEAK_LABEL, "color": WEAK_LABEL_COLOR, "description": WEAK_LABEL_DESCRIPTION})
    ledger.gh_write("api", "-X", "POST", f"repos/{repo}/issues/{pr}/labels", payload={"labels": [WEAK_LABEL]})


# --- CLI -------------------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="flake-pr.py")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("body")
    p.add_argument("--pick-dir", type=Path, required=True)
    p.add_argument("--attempt-dir", type=Path, required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--commits", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p = sub.add_parser("status")
    p.add_argument("--attempt-dir", type=Path, required=True)
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
    p.add_argument("--out", type=Path, required=True)
    p = sub.add_parser("record")
    p.add_argument("--repo", required=True)
    p.add_argument("--issue", type=int, required=True)
    p.add_argument("--entry", type=Path, required=True)
    p = sub.add_parser("weak-label")
    p.add_argument("--repo", required=True)
    p.add_argument("--pr", type=int, required=True)
    p = sub.add_parser("comment")
    p.add_argument("--repo", required=True)
    p.add_argument("--issue", type=int, required=True)
    p.add_argument("--body", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "body":
            args.out.write_text(body(args.pick_dir, args.attempt_dir, args.repo, read_text(args.commits)))
        elif args.command == "status":
            state, text = status(read_json(args.attempt_dir / "verify" / "verdict.json"))
            print(f"{state}\t{text}")
        elif args.command == "issue-comment":
            detail = read_text(args.detail) if args.detail else ""
            args.out.write_text(issue_comment(args.attempt_dir, args.kind, args.pr, detail))
        elif args.command == "entry":
            args.out.write_text(json.dumps(entry(args.pick_dir, args.attempt_dir, args.outcome, args.pr, args.reason)) + "\n")
        elif args.command == "record":
            record(args.repo, args.issue, read_json(args.entry))
        elif args.command == "weak-label":
            ensure_weak_label(args.repo, args.pr)
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
