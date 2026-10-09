#!/usr/bin/env python3
"""The flake picker: tonight's target for the fixer, or none (spec §5).

docs/specs/2026-10-07-flake-autofix-design.md is the design. The picker reads
the `flaky` issues' ledger and attempt comments and the bot's `flakefix/*`
PRs, and chooses at most one test. Deterministic; no model.

    fetch --repo R --out-dir D [--issue N]
        writes D/issues.json (every open `flaky` issue, the only kind the picker
        can choose, with its sentinel comments and their authors; plus issue N
        when given, open or not, so a refusal can name its state) and
        D/prs.json (every PR whose head is `flakefix/issue-*`). Reads only.
        Exit 2 on any `gh` failure: a read failure is never "nothing there".
    pick --issues F --prs F --repo R --out-dir D [--issue N] [--root DIR]
        pure. With a target: D/target.json and D/brief.md, exit 0. With no
        eligible test: D/none, exit 3. A refused dispatch (--issue) or an
        unreadable input: exit 2, naming the condition.
    run --repo R --out-dir D [--issue N] [--root DIR]
        fetch, then pick.
    compose-prompt --template F --brief F --baseline F --notes-path P
                   [--prior-try F] --out F
        substitutes {{BRIEF}}, {{BASELINE}}, {{PRIOR_TRY}} and {{NOTES_PATH}} in
        ONE pass, so a placeholder spelled inside a substituted value is never
        expanded again.

ONLY THE BOT'S OWN COMMENTS ARE STATE (spec §4.4, §5). Issues are loaded by
`flake-ledger.py`'s own reader, which accepts a ledger or attempt comment only
from `flake_lib.BOT_LOGIN`. The brief is built from that structured state
alone: no issue title or body, no human comment, no PR body ever reaches it,
because the session that reads it runs with a shell.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import flake_lib as fl  # noqa: E402

# The ledger's own issue reader and `gh` helpers, so the picker and the ledger
# cannot disagree on which comments are state.
ledger = fl.load_ledger()
fenced = fl.fenced

BRANCH_PREFIX = "flakefix/issue-"
SKIP_LABEL = "flakefix-skip"
# Attempt outcomes after which the test waits for a failure newer than the
# attempt (spec §5). `closed-unmerged` is a PR outcome the ledger records.
RETRY_AFTER_NEW_FAILURE = ("aborted", "no-diff", "push-refused", "closed-unmerged")
# The brief quotes the session notes of only this many most recent attempts.
BRIEF_NOTES_ATTEMPTS = 3
# A PR listing this full may be cut short; fail closed rather than miss an open PR.
PR_LISTING_LIMIT = 500


class Refused(Exception):
    """A condition that ends the job red, named for the summary."""


# --- fetch ---------------------------------------------------------------------------


def fetch(repo: str, out: Path, issue: int | None) -> None:
    out.mkdir(parents=True, exist_ok=True)
    raws = {
        int(i["number"]): i
        for i in ledger.gh_lines(
            "api", "--paginate", f"repos/{repo}/issues?labels={fl.FLAKY_LABEL}&state=open&per_page=100",
            "--jq", ".[] | select(.pull_request == null)",
        )
    }
    if issue is not None and issue not in raws:
        raw = ledger.gh_json("api", f"repos/{repo}/issues/{issue}")
        if raw.get("pull_request") is None:
            raws[issue] = raw
    issues = [ledger._fetch_issue(repo, raws[n]) for n in sorted(raws)]
    (out / "issues.json").write_text(json.dumps(issues, indent=1) + "\n")
    listed = ledger.gh_json(
        "pr", "list", "--repo", repo, "--state", "all", "--search", "head:flakefix/",
        "--json", "number,headRefName,state,closedAt", "--limit", str(PR_LISTING_LIMIT),
    )
    if len(listed) >= PR_LISTING_LIMIT:
        raise ledger.GhError(f"{len(listed)} bot PRs reaches the listing limit; an open one could be missed")
    prs = [
        {"number": p["number"], "head": p["headRefName"], "state": p["state"], "closed_at": p.get("closedAt")}
        for p in listed
        if p.get("headRefName", "").startswith(BRANCH_PREFIX)
    ]
    (out / "prs.json").write_text(json.dumps(prs, indent=1) + "\n")


# --- eligibility -----------------------------------------------------------------------


def latest_failure_at(state: fl.State) -> str:
    times = [f.at for f in fl.current_failures(state)]
    times += [f.last for f in state.folded if f.episode == state.episode and not f.pre_fix]
    return max(times, default="")


def pr_outcome(state: fl.State, number: int | None) -> str | None:
    for p in state.prs:
        if p.get("number") == number:
            return p.get("outcome")
    return None


def told_nothing(attempt) -> bool:
    """An abort that says nothing about the test (spec §5): a fixer session
    that failed before committing anything, or a verified candidate that
    `publish` lost to `main` moving during the run."""
    return attempt.outcome == "aborted" and bool(attempt.session_failed or attempt.publish_raced)


def last_attempt_allows(view, state: fl.State) -> tuple[bool, str]:
    """Spec §5: the last attempt in the current episode, by its recorded
    outcome, allows another, or there is none."""
    mine = [a for a in view.attempts if a.episode == state.episode]
    if not mine:
        return True, "no attempt in this episode"
    ordered = sorted(mine, key=lambda a: (a.started_at, a.run_id))
    last = ordered[-1]
    outcome = last.outcome
    if outcome == "pr-opened":
        outcome = pr_outcome(state, last.pr) or "pr-opened"
    if outcome == "merged":
        return False, f"PR #{last.pr} merged in this episode"
    if outcome == "pr-opened":
        return False, f"PR #{last.pr} has no recorded close"
    if told_nothing(last):
        # A session that failed without a commit (an outage, an expired
        # token, a crash), or a publish that lost its candidate to `main`
        # moving during the run, told us nothing about the test, so the next
        # night may try again on the same evidence – once: a second such abort
        # in a row, with no failure of the test between them, waits for a new
        # one like any other abort. That also bounds a session that keeps
        # running out of turns or time on this test: it cannot hold every
        # night's slot.
        prev = ordered[-2] if len(ordered) > 1 else None
        repeated = (prev is not None and told_nothing(prev)
                    and latest_failure_at(state) <= prev.started_at)
        if not repeated:
            if last.publish_raced:
                return True, "the last attempt's candidate was lost to main moving during the run"
            return True, "the last attempt's session failed before trying anything"
    if outcome in RETRY_AFTER_NEW_FAILURE:
        if latest_failure_at(state) > last.started_at:
            return True, f"failed again after the {outcome} attempt"
        return False, f"no failure since the {outcome} attempt of {last.started_at}"
    return False, f"unknown attempt outcome {outcome!r}"


def open_bot_pr(number: int, prs: list[dict]) -> int | None:
    for p in prs:
        if p.get("head") == f"{BRANCH_PREFIX}{number}" and p.get("state") == "OPEN":
            return int(p["number"])
    return None


def eligible(view, prs: list[dict]) -> tuple[bool, str]:
    state = view.ledger
    if fl.WATCHLIST_LABEL in view.labels:
        # The watchlist holds many tests' histories, none of them a target.
        return False, "the flake watchlist"
    if view.unreadable:
        # The bot's own comment does not parse: its attempts are unknown, and
        # the ledger leaves such an issue alone too.
        return False, "a bot comment does not parse"
    if state is None:
        return False, "no ledger state"
    if not fl.qualifies(state):
        return False, "below the threshold"
    if view.state != "OPEN":
        return False, "issue closed"
    pr = open_bot_pr(view.number, prs)
    if pr is not None:
        return False, f"open bot PR #{pr}"
    if SKIP_LABEL in view.labels:
        return False, f"labelled {SKIP_LABEL}"
    return last_attempt_allows(view, state)


def rank_key(view) -> tuple:
    """Most failures, then most recent failure, then lowest issue number."""
    state = view.ledger
    latest = latest_failure_at(state)
    # Negate the timestamp's sort order by sorting on its complement.
    return (-fl.current_count(state), _desc(latest), view.number)


def _desc(text: str) -> tuple:
    return tuple(-ord(c) for c in text)


def check_dispatch(views: dict, number: int, prs: list[dict]):
    """Spec §5: a dispatched issue skips the ranking, the threshold and the
    re-eligibility rule, and must still pass each of these."""
    view = views.get(number)
    if view is None:
        raise Refused(f"issue #{number} does not exist or could not be read")
    if view.state != "OPEN":
        raise Refused(f"issue #{number} is not open")
    if fl.FLAKY_LABEL not in view.labels:
        raise Refused(f"issue #{number} is not labelled {fl.FLAKY_LABEL}")
    if fl.WATCHLIST_LABEL in view.labels:
        raise Refused(f"issue #{number} is the flake watchlist, not one test's issue")
    if view.unreadable:
        raise Refused(f"issue #{number} has a bot comment that does not parse; its attempt history is unknown")
    if view.ledger is None:
        raise Refused(f"issue #{number} has no ledger comment from {fl.BOT_LOGIN} whose JSON block parses and names a test ID")
    pr = open_bot_pr(number, prs)
    if pr is not None:
        raise Refused(f"issue #{number} already has an open bot PR, #{pr}")
    return view


# --- the brief ---------------------------------------------------------------------------


def locate(state: fl.State, root: Path) -> tuple[str | None, int | None]:
    """The test's file and line: the newest `ci-retry` record's, else the one
    `func <name>(` under its module's tests, else unknown."""
    retry = [f for f in state.failures if f.source == "ci-retry" and f.file]
    if retry:
        newest = max(retry, key=lambda f: f.at)
        return newest.file, newest.line
    module = state.test_id.split("/", 1)[0].split(".", 1)[0]
    name = fl.function_name(state.test_id)
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", module):
        return None, None
    proc = subprocess.run(
        ["git", "grep", "-n", "-E", f"func {name}\\(", "--", f"Tests/{module}/"],
        cwd=root, capture_output=True, text=True, check=False,
    )
    hits = [line for line in proc.stdout.splitlines() if line.strip()]
    if proc.returncode != 0 or len(hits) != 1:
        return None, None
    path, line, _ = hits[0].split(":", 2)
    return path, int(line)


def flaky_list(views: dict, target: int) -> list[tuple[str, int]]:
    """(test ID, issue) for every other open `flaky` issue with a ledger the
    bot wrote: the tests a coverage claim may not lean on (spec §5, §6.1).
    Structured state only, like the rest of the brief."""
    out = []
    for view in views.values():
        if view.number == target or view.state != "OPEN" or view.ledger is None or view.unreadable:
            continue
        if fl.FLAKY_LABEL not in view.labels or fl.WATCHLIST_LABEL in view.labels:
            continue
        out.append((view.ledger.test_id, view.number))
    return sorted(out)


def brief(view, repo: str, root: Path, views: dict | None = None) -> tuple[dict, str]:
    state = view.ledger
    file, line = locate(state, root)
    current = sorted(fl.current_failures(state), key=lambda f: (f.at, f.key))
    places = sorted(fl.distinct_occurrences(state))
    target = {
        "issue": view.number,
        "test_id": state.test_id,
        "filter_id": fl.filter_id(state.test_id),
        "file": file,
        "line": line,
        "episode": state.episode,
        "failures": fl.current_count(state),
        "places": places,
    }
    location = f"{file}:{line}" if file else "unknown"
    out = [
        "## Target",
        "",
        f"- Test (xunit form): `{state.test_id}`",
        f"- Filter form, for `scripts/test.sh --filter`: `{fl.filter_id(state.test_id)}`",
        f"- Source: {location}",
        f"- Issue: #{view.number}",
        f"- Episode {state.episode + 1}: {fl.current_count(state)} failures across {len(places)} distinct places "
        f"({fl.failure_count(state)} recorded in all)",
        "",
        "## Failures in this episode",
        "",
    ]
    for f in current:
        out.append(f"- {f.at}, {f.occurrence}, {f.source}: {fl.run_url(repo, f.run_id, f.attempt)}")
    folded = [f for f in state.folded if f.episode == state.episode and not f.pre_fix]
    for f in folded:
        out.append(f"- {f.count} older failures at {f.occurrence}, {f.first} to {f.last} (counts only)")
    signatures = []
    for f in reversed(current):
        if f.signature and f.signature not in signatures:
            signatures.append(f.signature)
    out += ["", "## Failure signatures (xunit messages, newest first)", ""]
    if signatures:
        for s in signatures:
            out += [fenced(s), ""]
    else:
        out += ["None recorded.", ""]
    out += ["## Prior attempts and fixes", ""]
    prior = False
    for fix in state.fixes:
        # A fix whose episode is older than the current one was followed by a
        # recurrence (spec §4.4): it did not hold.
        held = "A prior fix that did not hold" if fix.get("episode", 0) < state.episode else "A fix on record"
        via = f"PR https://github.com/{repo}/pull/{fix['pr']}" if fix.get("pr") else "a commit"
        out.append(f"- {held}: {via} (commit {fix['sha'][:12]}, episode {fix.get('episode', 0) + 1}).")
        prior = True
    ordered = sorted(view.attempts, key=lambda a: (a.started_at, a.run_id))
    # Every attempt is listed; only the newest few carry their notes, so the
    # prompt stays bounded however often a test is retried.
    with_notes = {(a.run_id, a.started_at) for a in ordered[-BRIEF_NOTES_ATTEMPTS:]}
    for a in ordered:
        outcome = a.outcome
        if a.outcome == "pr-opened":
            outcome = pr_outcome(state, a.pr) or "pr-opened, still open"
        line = f"- Attempt of {a.started_at} (episode {a.episode + 1}) on `{a.main_sha[:12]}`: {outcome}"
        if a.pr:
            line += f", PR https://github.com/{repo}/pull/{a.pr}"
            if a.verdict:
                line += f", verifier verdict {a.verdict}"
            if a.target_change == "renamed":
                line += f", renamed the target to `{a.renamed_to}`"
            elif a.target_change == "retired":
                line += ", retired the target"
        if outcome == "merged" and a.episode < state.episode:
            line += ". A prior fix that did not hold."
        out.append(line)
        if a.notes and (a.run_id, a.started_at) in with_notes:
            out += ["", "  Session notes from that attempt (the bot's own earlier session):", "", fenced(a.notes, "markdown"), ""]
        prior = True
    if not prior:
        out.append("None.")
    out += ["", "## Tests on the flaky list", "",
            "Every other test with an open `flaky` issue. None of them counts as coverage another test can lean on.", ""]
    listed = flaky_list(views or {}, view.number)
    out += [f"- `{test}` (#{number})" for test, number in listed] or ["None."]
    return target, "\n".join(out).rstrip() + "\n"


# --- pick ----------------------------------------------------------------------------------


def _read(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise Refused(f"cannot read {path}: {error}") from error


def pick(issues_file: Path, prs_file: Path, repo: str, out: Path, issue: int | None, root: Path) -> int:
    raw_issues, prs = _read(issues_file), _read(prs_file)
    if not isinstance(raw_issues, list) or not isinstance(prs, list):
        raise Refused("issues.json and prs.json must each hold a list")
    notes = ledger.Notes()
    views = ledger.load_issues(raw_issues, notes)
    out.mkdir(parents=True, exist_ok=True)
    if issue is not None:
        chosen = check_dispatch(views, issue, prs)
        why = "dispatched by hand"
    else:
        candidates = []
        for view in views.values():
            ok, reason = eligible(view, prs)
            print(f"#{view.number}: {'eligible' if ok else 'skipped'} ({reason})", file=sys.stderr)
            if ok:
                candidates.append(view)
        if not candidates:
            (out / "none").write_text("no eligible test\n")
            return 3
        chosen = min(candidates, key=rank_key)
        why = "ranked first"
    target, text = brief(chosen, repo, root, views)
    target["why"] = why
    (out / "target.json").write_text(json.dumps(target, indent=1) + "\n")
    (out / "brief.md").write_text(text)
    print(f"picked #{chosen.number}: {chosen.ledger.test_id} ({why})", file=sys.stderr)
    return 0


# --- the session prompt --------------------------------------------------------------------

PLACEHOLDER = re.compile(r"\{\{(BRIEF|BASELINE|PRIOR_TRY|NOTES_PATH)\}\}")
FIRST_TRY = "This is the first try; there is no earlier verifier run."


def compose_prompt(template: Path, values: dict[str, str]) -> str:
    text = template.read_text()
    missing = {"BRIEF", "BASELINE", "PRIOR_TRY", "NOTES_PATH"} - set(PLACEHOLDER.findall(text))
    if missing:
        raise Refused(f"{template} lacks the placeholders {sorted(missing)}")
    return PLACEHOLDER.sub(lambda m: values[m.group(1)], text)


# --- CLI -------------------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="flake-pick.py")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("fetch")
    p.add_argument("--repo", required=True)
    p.add_argument("--out-dir", type=Path, required=True)
    p.add_argument("--issue", type=int)
    p = sub.add_parser("pick")
    p.add_argument("--issues", type=Path, required=True)
    p.add_argument("--prs", type=Path, required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--out-dir", type=Path, required=True)
    p.add_argument("--issue", type=int)
    p.add_argument("--root", type=Path, default=Path("."))
    p = sub.add_parser("run")
    p.add_argument("--repo", required=True)
    p.add_argument("--out-dir", type=Path, required=True)
    p.add_argument("--issue", type=int)
    p.add_argument("--root", type=Path, default=Path("."))
    p = sub.add_parser("compose-prompt")
    p.add_argument("--template", type=Path, required=True)
    p.add_argument("--brief", type=Path, required=True)
    p.add_argument("--baseline", type=Path, required=True)
    p.add_argument("--notes-path", required=True)
    p.add_argument("--prior-try", type=Path)
    p.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command in ("fetch", "run"):
            fetch(args.repo, args.out_dir, args.issue)
            if args.command == "fetch":
                return 0
            return pick(args.out_dir / "issues.json", args.out_dir / "prs.json", args.repo, args.out_dir, args.issue, args.root)
        if args.command == "pick":
            return pick(args.issues, args.prs, args.repo, args.out_dir, args.issue, args.root)
        values = {
            "BRIEF": args.brief.read_text().rstrip(),
            "BASELINE": args.baseline.read_text().rstrip(),
            "PRIOR_TRY": args.prior_try.read_text().rstrip() if args.prior_try else FIRST_TRY,
            "NOTES_PATH": args.notes_path,
        }
        args.out.write_text(compose_prompt(args.template, values))
        return 0
    except ledger.GhError as error:
        print(f"flake-pick: {error}", file=sys.stderr)
        return 2
    except Refused as error:
        print(f"flake-pick: refused: {error}", file=sys.stderr)
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a") as handle:
                handle.write(f"The flake picker refused: {error}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
