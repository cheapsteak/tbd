#!/usr/bin/env python3
"""The flake ledger: one GitHub issue per flaky test (spec §4).

docs/specs/2026-10-07-flake-autofix-design.md is the design. The ledger reads
per-test results from two sources and keeps each test's failure history: on
the test's own issue, in one comment, once the test qualifies (two distinct
places) or already has an issue; until then, as one entry on the single
`flake-watchlist` issue, whose bot comments hold every such test's history.
The sources:

- **The nightly stress loop** – every failing `<testcase>` in a nightly run's
  `nightly-xunit` artifact.
- **Rerun-erased CI failures** – attempt 1's `xunit-results` from a `test.yml`
  run whose attempt 1 failed and a later attempt passed, plus every
  `passedOnRetry` record in any attempt's `retry-metrics`.

It is deterministic and runs no model. Subcommands:

    fetch    --work-dir D --repo R [--root DIR] [--now ISO]
        reads GitHub (through `$FLAKE_GH_CMD`, default `gh`) into D. Reads only.
    analyze  --work-dir D [--out plan.json]
        pure: reads only D, writes the plan. Exit 2 on a gap in D.
    report   --plan plan.json
        the job-summary markdown (spec §4.5).
    apply    --plan plan.json --repo R
        performs the plan's writes, with `$FLAKE_WRITE_TOKEN` (the App token).
    run      --repo R [--work-dir D] [--root DIR] [--write]
        fetch, analyze, report (to `$GITHUB_STEP_SUMMARY` when set), and,
        only with --write, apply. Without --write it makes no write call.
    previous-ledger-conclusion --repo R --run-id ID
        `success`, `failure`, or `none`: the `ledger` job's conclusion in the
        most recent earlier run of this workflow that ran it (spec §8).
    report-red-run --repo R --run-id ID --issue N [--run-attempt K] [--job-token]
        the tracking-issue comment for the first red `ledger` run after a
        green one (spec §8), written with `$FLAKE_WRITE_TOKEN`.

FAIL CLOSED. Any `gh` failure raises and the command exits 2 having written
nothing more. A read failure is never treated as "nothing there", because an
empty answer would plan the wrong writes. Two answers are the exception,
because they are definite rather than missing: GitHub saying (HTTP 404) that
an issue a `.flaky(issue:)` trait names does not exist, or that a commit a
compare call names does not exist (HTTP 410 for a deleted issue counts too).
The first gives a test whose trait names that issue an issue of its own; the
second, when the missing commit is the failure's own head rather than the fix,
leaves out that one failure. The summary lists each. The writes go watchlist
first, then per issue, each one idempotent. A failed watchlist write stops the
run there; a failed issue write is listed and the run goes on to the next
issue, then exits 2 once every write was tried. Either way the next run
converges.

ONLY THE BOT'S OWN COMMENTS ARE STATE. A ledger or attempt comment counts only
when the App's bot account wrote it (`flake_lib.trusted_author`). A sentinel
under any other author is never parsed and never edited; the report lists it.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import time
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import flake_lib as fl  # noqa: E402

GH_CMD = os.environ.get("FLAKE_GH_CMD", "gh")

# Read windows, one per artifact retention (spec §4.4). `xunit-results` and
# `nightly-xunit` keep 7 days; `retry-metrics` keeps the repository default but
# is read over the same window as `xunit-results`, so a run's two sources are
# always read together.
TEST_RUN_WINDOW_DAYS = 7
NIGHTLY_RUN_WINDOW_DAYS = 7

TEST_WORKFLOW = "test.yml"
NIGHTLY_WORKFLOW = "nightly.yml"
THIS_WORKFLOW = "flake-fixer.yml"
XUNIT_ARTIFACT = "xunit-results"
RETRY_ARTIFACT = "retry-metrics"
NIGHTLY_ARTIFACT = "nightly-xunit"
LEDGER_JOB = "ledger"
# GitHub returns at most this many runs for a filtered workflow-run listing.
RUN_LISTING_CAP = 1000

# Runs on the bot's own branches describe its candidate, not the suite.
FLAKEFIX_PREFIX = "flakefix/"

# The labels the ledger creates if missing: name -> (color, description).
LABELS = {
    fl.FLAKY_LABEL: ("B60205", "One flaky test, tracked by the flake ledger"),
    fl.WATCHLIST_LABEL: ("C5DEF5", "The flake ledger's one watchlist of tests below the threshold"),
}

# GitHub's search API allows about 30 requests a minute; title lookups pause
# between calls so a first run with many new tests stays under it.
SEARCH_PAUSE_S = float(os.environ.get("FLAKE_SEARCH_PAUSE_S", "2.5"))
# GitHub's secondary limit on content creation is about 80 writes a minute.
# The first enabled run may create many issues at once, so it writes one issue
# (up to four writes) every three seconds.
WRITE_PAUSE_S = float(os.environ.get("FLAKE_WRITE_PAUSE_S", "3"))

# A nightly xunit file is `<target>-<iteration>.xml` or its `-swift-testing`
# twin (`nightly-flake-stress.sh --xunit-dir`).
NIGHTLY_FILE = re.compile(r"^(?P<target>.+?)-\d+(?:-swift-testing)?\.xml$")
HTTP_STATUS = re.compile(r"\(HTTP (\d{3})\)")
# GitHub's search returns at most this many results for one query, and
# rejects a query longer than 256 characters; the phrase is capped below that,
# leaving room for the `repo:` and `in:` qualifiers.
SEARCH_RESULT_CAP = 1000
SEARCH_PHRASE_MAX = 200


class GhError(Exception):
    """A failed `gh` call. `status` is the HTTP status `gh` reported on stderr
    (`gh: Not Found (HTTP 404)`), or None when it reported none."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


# The answers that say a thing does not exist, as opposed to "could not ask".
# Only these let one lookup be skipped; every other failure fails the run.
ISSUE_GONE_STATUSES = (404, 410)  # 410: the issue was deleted
COMPARE_GONE_STATUSES = (404,)  # a commit GitHub no longer has


class AnalysisError(Exception):
    pass


# --- time ---------------------------------------------------------------------------


def parse_time(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- run rules (spec §4.1) ------------------------------------------------------------


def eligible_run(run: dict, repo: str) -> bool:
    """Same-repository runs only, and none on the bot's own branches. A nightly
    counts only on `main`: one dispatched on a branch tests unmerged code, and a
    failure there may be a real regression rather than a flake."""
    if run.get("head_repo") != repo:
        return False
    if run.get("workflow") == "nightly" and run.get("head_branch") != "main":
        return False
    return not (run.get("head_branch") or "").startswith(FLAKEFIX_PREFIX)


def in_window(run: dict, now: datetime) -> bool:
    days = NIGHTLY_RUN_WINDOW_DAYS if run["workflow"] == "nightly" else TEST_RUN_WINDOW_DAYS
    return parse_time(run["created_at"]) >= now - timedelta(days=days)


def attempt_for_artifact(attempts: list[dict], created_at: str) -> int | None:
    """The attempt whose window holds the artifact: attempt n's window runs from
    its start to attempt n+1's. GitHub lists every attempt's artifacts under the
    same name and does not label them, so time is the only way to tell them
    apart. An artifact older than attempt 1 belongs to none."""
    moment = parse_time(created_at)
    chosen = None
    for attempt in sorted(attempts, key=lambda a: a["attempt"]):
        if parse_time(attempt["started_at"]) <= moment:
            chosen = attempt["attempt"]
        else:
            break
    return chosen


def rerun_erased(run: dict) -> bool:
    """Attempt 1 failed and a later attempt on the same run passed: the same
    commit failed, then passed. That is a flake, and the signal a rerun erases."""
    ordered = sorted(run["attempts"], key=lambda a: a["attempt"])
    if not ordered or ordered[0]["attempt"] != 1 or ordered[0]["conclusion"] != "failure":
        return False
    return any(a["conclusion"] == "success" for a in ordered[1:])


def wanted_artifacts(run: dict) -> list[dict]:
    """Every artifact of a kind the analysis reads from one run, expired or
    not: the one selector both `needed_artifacts` and `artifact_gaps` use."""
    artifacts = run.get("artifacts", [])
    if run["workflow"] == "nightly":
        return [a for a in artifacts if a["name"] == NIGHTLY_ARTIFACT]
    wanted = [a for a in artifacts if a["name"] == RETRY_ARTIFACT]
    if rerun_erased(run):
        wanted += [
            a
            for a in artifacts
            if a["name"] == XUNIT_ARTIFACT and attempt_for_artifact(run["attempts"], a["created_at"]) == 1
        ]
    return wanted


def needed_artifacts(run: dict) -> list[dict]:
    """The artifacts the analysis reads from one run, unexpired only. What
    expired or was never uploaded is listed by `artifact_gaps`."""
    return [a for a in wanted_artifacts(run) if not a.get("expired")]


def artifact_gaps(run: dict) -> list[str]:
    """What the analysis would have read from this run but cannot: an expired
    artifact of a kind it reads, attempt 1's `xunit-results` absent from a
    rerun-erased run, or a nightly with no `nightly-xunit` (which a nightly
    whose build failed legitimately leaves). Missing `retry-metrics` is not
    listed: an attempt cancelled before its tests ran has none."""
    rid = run["run_id"]
    wanted = wanted_artifacts(run)
    gaps = []
    if run["workflow"] == "nightly":
        if not wanted:
            gaps.append(f"nightly run {rid}: no `{NIGHTLY_ARTIFACT}` artifact")
    elif rerun_erased(run) and not any(a["name"] == XUNIT_ARTIFACT for a in wanted):
        gaps.append(f"run {rid}: attempt 1 failed and a rerun passed, but it has no attempt-1 `{XUNIT_ARTIFACT}` artifact (expected unless attempt 1 failed before its tests ran)")
    for artifact in wanted:
        if artifact.get("expired"):
            gaps.append(f"run {rid}: `{artifact['name']}` artifact {artifact['id']} has expired")
    return gaps


@dataclass
class Notes:
    unreadable: list[str] = field(default_factory=list)
    unavailable: list[str] = field(default_factory=list)
    gone: list[str] = field(default_factory=list)
    dropped: list[str] = field(default_factory=list)
    inventory_skipped: list[str] = field(default_factory=list)
    forged: list[str] = field(default_factory=list)
    duplicates: list[str] = field(default_factory=list)
    aged: list[str] = field(default_factory=list)


def _artifact_dir(work: Path, artifact: dict) -> Path:
    path = work / "artifacts" / str(artifact["id"])
    if not path.is_dir():
        raise AnalysisError(f"artifact {artifact['id']} ({artifact['name']}) was not fetched into {path}")
    return path


def failures_from_run(run: dict, work: Path, notes: Notes, files: dict[str, tuple[str, int | None]], targets: dict[str, int]) -> list[tuple[str, fl.Failure]]:
    """Every failure one eligible run contributes. Also records, in `files`,
    each test's source file from its retry-metrics records (any outcome), which
    is how an inventory row is matched to a test (spec §4.4)."""
    starts = {a["attempt"]: a["started_at"] for a in run["attempts"]}
    found: list[tuple[str, fl.Failure]] = []
    for artifact in needed_artifacts(run):
        attempt = attempt_for_artifact(run["attempts"], artifact["created_at"])
        if attempt is None:
            continue
        at = starts[attempt]
        directory = _artifact_dir(work, artifact)
        if artifact["name"] == RETRY_ARTIFACT:
            for path in sorted(directory.rglob("*.jsonl")):
                try:
                    records = fl.retry_records(path)
                except fl.MalformedRecords as error:
                    notes.unreadable.append(f"run {run['run_id']} attempt {attempt}: {error}")
                    continue
                for record in records:
                    test_id = fl.from_retry_metrics_id(record["testID"])
                    if isinstance(record.get("file"), str):
                        files.setdefault(test_id, (record["file"], record.get("line")))
                    if record.get("outcome") != "passedOnRetry" or test_id == fl.EXCLUDED_TEST_ID:
                        continue
                    found.append((
                        test_id,
                        fl.Failure(
                            key=f"{run['run_id']}:{attempt}:retry-metrics",
                            run_id=run["run_id"],
                            attempt=attempt,
                            occurrence=fl.occurrence_key("ci-retry", run["head_branch"], at),
                            at=at,
                            source="ci-retry",
                            signature=f"passed on retry ({record.get('attempts', '?')} attempts)",
                            head_sha=run["head_sha"],
                            file=record.get("file"),
                            line=record.get("line"),
                        ),
                    ))
            continue
        # `needed_artifacts` already limited xunit-results to attempt 1 of a
        # rerun-erased run.
        source = "nightly" if run["workflow"] == "nightly" else "ci-xunit"
        for path in fl.xunit_files(directory):
            relative = path.relative_to(directory).as_posix()
            try:
                cases = fl.cases_in(path)
            except fl.MalformedXunit as error:
                notes.unreadable.append(f"run {run['run_id']} attempt {attempt}: {error}")
                continue
            suite_issue = None
            if source == "nightly":
                match = NIGHTLY_FILE.match(path.name)
                suite_issue = targets.get(match.group("target")) if match else None
            for case in cases:
                if case.outcome != "failed" or case.test_id == fl.EXCLUDED_TEST_ID:
                    continue
                found.append((
                    case.test_id,
                    fl.Failure(
                        key=f"{run['run_id']}:{attempt}:{relative}",
                        run_id=run["run_id"],
                        attempt=attempt,
                        occurrence=fl.occurrence_key(source, run["head_branch"], at),
                        at=at,
                        source=source,
                        signature=fl.signature(case.message),
                        head_sha=run["head_sha"],
                        suite_issue=suite_issue,
                    ),
                ))
    return found


def collect_failures(work: Path, repo: str, now: datetime, notes: Notes, targets: dict[str, int]) -> tuple[dict[str, list[fl.Failure]], dict[str, tuple[str, int | None]]]:
    runs = _require_json(work / "runs.json")
    by_test: dict[str, list[fl.Failure]] = {}
    files: dict[str, tuple[str, int | None]] = {}
    seen: set[tuple[str, str]] = set()
    for run in runs:
        if not eligible_run(run, repo) or not in_window(run, now):
            continue
        notes.unavailable.extend(artifact_gaps(run))
        for test_id, failure in failures_from_run(run, work, notes, files, targets):
            # A parameterized test fails once per case under one ID: one failure.
            if (test_id, failure.key) in seen:
                continue
            seen.add((test_id, failure.key))
            by_test.setdefault(test_id, []).append(failure)
    return by_test, files


# --- issues ----------------------------------------------------------------------------


@dataclass
class IssueView:
    number: int
    title: str
    state: str  # "OPEN" | "CLOSED"
    labels: list[str]
    closed_reason: str | None  # "completed" | "not_planned" | None
    closing_fix: dict | None  # {"sha", "at", "pr"}: the latest close event's closer
    ledger: fl.State | None = None
    ledger_comment_id: int | None = None
    ledger_body: str | None = None
    attempts: list[fl.Attempt] = field(default_factory=list)
    # A bot comment on this issue does not parse (a hand edit, say). The issue
    # is left untouched and listed, rather than stopping every other test.
    unreadable: bool = False


def load_issues(raw: list[dict], notes: Notes) -> dict[int, IssueView]:
    issues: dict[int, IssueView] = {}
    for item in raw:
        view = IssueView(
            number=int(item["number"]),
            title=item["title"],
            state=item["state"].upper(),
            labels=list(item.get("labels", [])),
            closed_reason=item.get("closed_reason"),
            closing_fix=item.get("closing_fix"),
        )
        for comment in sorted(item.get("comments", []), key=lambda c: c["id"]):
            body, login, kind = comment.get("body") or "", comment.get("login"), comment.get("type")
            is_ledger = body.startswith(fl.SENTINEL)
            is_attempts = body.startswith(fl.ATTEMPTS_SENTINEL)
            if not (is_ledger or is_attempts):
                continue
            if not fl.trusted_author(login, kind):
                what = "ledger" if is_ledger else "attempt"
                notes.forged.append(f"#{view.number} comment {comment['id']}: a {what} sentinel by `{login}` ({kind}), ignored")
                continue
            if is_ledger:
                state = fl.parse_comment(body, login, kind)
                if state is None:
                    notes.unreadable.append(f"#{view.number} comment {comment['id']}: the bot's own ledger comment does not parse; the issue is left untouched")
                    view.unreadable = True
                    continue
                if view.ledger is not None:
                    notes.duplicates.append(f"#{view.number}: a second bot ledger comment {comment['id']}, ignored")
                    continue
                view.ledger, view.ledger_comment_id, view.ledger_body = state, int(comment["id"]), body
            else:
                attempts = fl.parse_attempts(body, login, kind)
                if attempts is None:
                    notes.unreadable.append(f"#{view.number} comment {comment['id']}: the bot's own attempt comment does not parse; the issue is left untouched")
                    view.unreadable = True
                    continue
                view.attempts.extend(attempts)
        issues[view.number] = view
    return issues


@dataclass
class Watchlist:
    """The one watchlist issue (spec §4.4), as `fetch` read it. `slots` are its
    bot comments that parsed, oldest first, each with the tests it holds. A
    bot comment that does not parse is skipped: it is no slot, so it is never
    written, and stays as it is for a human to read."""

    number: int | None = None
    slots: list[tuple[int, list[str], str]] = field(default_factory=list)  # (comment id, tests, body)
    entries: dict[str, fl.State] = field(default_factory=dict)
    # The watchlist was found by title, its label gone: the label is restored.
    add_label: bool = False


def _absorb(keep: fl.State, other: fl.State) -> fl.State:
    """`keep` plus `other`'s failures that `keep` does not hold. Both copies
    descend from one history, so a failure no newer than the last one `keep`
    folded into a count is already counted there, even once its merge key
    has aged out of `folded_keys`; only newer ones are added, by merge key."""
    cutoff = max((f.last for f in keep.folded), default="")
    merged, _ = fl.merge(keep, [f for f in other.failures if f.at > cutoff])
    return merged


def _holds(ledger: fl.State, watched: fl.State) -> bool:
    """Whether an issue's ledger, as read, already holds every failure of the
    test's watchlist entry, so dropping the entry loses nothing."""
    return {f.key for f in _absorb(ledger, watched).failures} == {f.key for f in ledger.failures}


def _merge_entries(first: fl.State, second: fl.State) -> fl.State:
    """One test found in two watchlist comments: a run that died between
    writing a test's new comment and its old one. Keep the fuller entry and
    add the other's failures it lacks (`_absorb`)."""
    keep, other = (first, second) if fl.failure_count(first) >= fl.failure_count(second) else (second, first)
    return _absorb(keep, other)


def load_watchlist(raw: list[dict], notes: Notes) -> Watchlist:
    """The watchlist is the oldest issue labelled `flake-watchlist` that the
    bot opened. An issue under that label opened by anyone else is not the
    watchlist; a second bot-opened one is listed and left alone."""
    mine = []
    for item in raw:
        if fl.trusted_author(item.get("login"), item.get("type")):
            mine.append(item)
        else:
            notes.forged.append(f"#{item['number']}: labelled `{fl.WATCHLIST_LABEL}` but opened by `{item.get('login')}` ({item.get('type')}), not the watchlist")
    if not mine:
        return Watchlist()
    mine.sort(key=lambda i: (i.get("created_at") or "", int(i["number"])))
    chosen = mine[0]
    if len(mine) > 1:
        notes.duplicates.append(
            f"watchlist issues {', '.join('#' + str(i['number']) for i in mine)}; using the oldest, #{chosen['number']}, and leaving the others unread"
        )
    watch = Watchlist(number=int(chosen["number"]), add_label=fl.WATCHLIST_LABEL not in chosen.get("labels", [fl.WATCHLIST_LABEL]))
    for comment in sorted(chosen.get("comments", []), key=lambda c: c["id"]):
        body, login, kind = comment.get("body") or "", comment.get("login"), comment.get("type")
        if not body.startswith(fl.WATCHLIST_SENTINEL):
            continue
        if not fl.trusted_author(login, kind):
            notes.forged.append(f"#{watch.number} comment {comment['id']}: a watchlist sentinel by `{login}` ({kind}), ignored")
            continue
        states = fl.parse_watchlist(body, login, kind)
        if states is None:
            notes.unreadable.append(
                f"#{watch.number} comment {comment['id']}: the bot's own watchlist comment does not parse; it is skipped "
                "and left as it is, and a test whose history only it holds starts a fresh entry"
            )
            continue
        for state in states:
            if state.test_id in watch.entries:
                notes.duplicates.append(f"`{state.test_id}`: in two watchlist comments; merged")
                state = _merge_entries(watch.entries[state.test_id], state)
            watch.entries[state.test_id] = state
        watch.slots.append((int(comment["id"]), [s.test_id for s in states], body))
    return watch


def map_tests_to_issues(issues: dict[int, IssueView], tests: set[str], notes: Notes) -> dict[str, int]:
    """A test's issue: the one whose bot ledger comment names it, else the one
    whose title is exactly `Flaky test: <id>`, open or closed (spec §4.4)."""
    by_state: dict[str, list[int]] = {}
    by_title: dict[str, list[int]] = {}
    for view in issues.values():
        if view.ledger is not None:
            by_state.setdefault(view.ledger.test_id, []).append(view.number)
        if view.title.startswith(fl.TITLE_PREFIX):
            by_title.setdefault(view.title[len(fl.TITLE_PREFIX) :], []).append(view.number)
    mapping: dict[str, int] = {}
    for test in sorted(tests | set(by_state)):
        candidates = sorted(by_state.get(test, [])) or sorted(
            n for n in by_title.get(test, []) if issues[n].ledger is None or issues[n].ledger.test_id == test
        )
        if not candidates:
            continue
        if len(candidates) > 1:
            notes.duplicates.append(f"`{test}`: issues {', '.join(f'#{n}' for n in candidates)}; using #{candidates[0]}")
        mapping[test] = candidates[0]
    return mapping


def read_inventory(work: Path) -> list[tuple[str, str, int]]:
    rows = []
    path = work / "inventory.tsv"
    if not path.exists():
        raise AnalysisError(f"{path} is missing")
    for line in path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[2].isdigit():
            rows.append((parts[0], parts[1], int(parts[2])))
    return rows


def read_targets(work: Path) -> dict[str, int]:
    path = work / "targets.tsv"
    if not path.exists():
        raise AnalysisError(f"{path} is missing")
    targets = {}
    for line in path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].isdigit():
            targets[parts[0]] = int(parts[1])
    return targets


def trait_issue_for(test: str, inventory: list[tuple[str, str, int]], files: dict[str, tuple[str, int | None]]) -> int | None:
    """The issue a `.flaky(issue:)` trait on this test names, or None. A row
    matches a test when the row's file is the test's file (from its
    retry-metrics records) and the row's function is the ID's name up to `(`;
    a row that matches two recorded tests says nothing about either."""
    if test not in files:
        return None
    mine = [row for row in inventory if row[0] == files[test][0] and row[1] == fl.function_name(test)]
    for row in mine:
        matched = [t for t, (file, _) in files.items() if file == row[0] and fl.function_name(t) == row[1]]
        if len(matched) == 1:
            return row[2]
    return None


def note_inventory_rows(inventory: list[tuple[str, str, int]], files: dict[str, tuple[str, int | None]], notes: Notes) -> None:
    for file, func, issue in inventory:
        matched = [t for t, (f, _) in files.items() if f == file and fl.function_name(t) == func]
        if len(matched) != 1:
            why = "no recorded test" if not matched else f"{len(matched)} recorded tests"
            notes.inventory_skipped.append(f"`{file}` `{func}` (#{issue}): matches {why}; skipped")


def issue_serves_test_alone(number: int, test: str, inventory: list[tuple[str, str, int]], targets: dict[str, int], issues: dict[int, IssueView]) -> bool:
    """Spec §4.4: exactly one inventory row names the issue, it is not a
    nightly stress target's suite-level issue, and it carries no bot ledger
    comment, or title, for a different test."""
    if sum(1 for row in inventory if row[2] == number) != 1:
        return False
    if number in targets.values():
        return False
    view = issues.get(number)
    if view is None or view.unreadable or fl.WATCHLIST_LABEL in view.labels:
        return False
    if view.ledger is not None and view.ledger.test_id != test:
        return False
    if view.title.startswith(fl.TITLE_PREFIX) and view.title != fl.issue_title(test):
        return False
    return True


# --- the per-test plan ------------------------------------------------------------------------


@dataclass
class Context:
    repo: str
    issues: dict[int, IssueView]
    inventory: list[tuple[str, str, int]]
    targets: dict[str, int]
    files: dict[str, tuple[str, int | None]]
    pr_states: dict[str, dict]
    ancestry: dict[str, bool]
    collect_missing: bool
    # `.flaky(issue:)` numbers GitHub says do not exist, with the status it
    # gave, and fix..head pairs whose failing head GitHub no longer has (both
    # from `fetch`).
    gone_issues: dict[int, int] = field(default_factory=dict)
    unresolved: set[str] = field(default_factory=set)
    # Failures left out of this run's plan, for the summary.
    dropped: list[str] = field(default_factory=list)
    missing: set[str] = field(default_factory=set)


def record_pr_outcomes(state: fl.State, view: IssueView | None, ctx: Context) -> tuple[fl.State, list[dict]]:
    """Spec §4.4: for each `pr-opened` attempt whose PR the ledger has not yet
    seen close, GitHub's PR state decides. An outcome is recorded once."""
    if view is None:
        return state, []
    recorded = {p["number"] for p in state.prs}
    prs = list(state.prs)
    fixes = []
    for attempt in view.attempts:
        if attempt.outcome != "pr-opened" or attempt.pr is None or attempt.pr in recorded:
            continue
        pr_state = ctx.pr_states.get(str(attempt.pr))
        if pr_state is None:
            raise AnalysisError(f"#{view.number}: no PR state fetched for PR #{attempt.pr}")
        if pr_state["state"] == "MERGED":
            prs.append({"number": attempt.pr, "outcome": "merged", "merge_sha": pr_state["merge_sha"], "episode": attempt.episode})
            fixes.append({"sha": pr_state["merge_sha"], "at": pr_state["merged_at"], "pr": attempt.pr})
        elif pr_state["state"] == "CLOSED":
            prs.append({"number": attempt.pr, "outcome": "closed-unmerged", "merge_sha": None, "episode": attempt.episode})
        else:
            continue
        recorded.add(attempt.pr)
    return replace(state, prs=prs), fixes


def add_fixes(state: fl.State, candidates: list[dict]) -> fl.State:
    known = {f["sha"] for f in state.fixes}
    fixes = list(state.fixes)
    for fix in candidates:
        if fix["sha"] and fix["sha"] not in known:
            fixes.append({"sha": fix["sha"], "at": fix["at"], "episode": state.episode, "pr": fix.get("pr")})
            known.add(fix["sha"])
    return replace(state, fixes=fixes)


def classify(state: fl.State, new: list[fl.Failure], ctx: Context) -> tuple[fl.State, list[tuple[fl.Failure, dict]]]:
    """Place each new failure in an episode (spec §4.4), by the latest fix that
    landed before it, whatever episode that fix belongs to:

    - no fix before it – episode 1 (index 0), the time before any fix;
    - a commit without that fix – `pre-fix`: recorded, never counted;
    - a commit with the current episode's fix – a recurrence: a new episode;
    - a commit with an older episode's fix – the episode that fix's
      recurrence started. A run read late, after a recurrence already bumped
      the episode, lands where it happened instead of inflating the new one.
    """
    known = {f.key for f in state.failures} | {k for k, _ in state.folded_keys}
    recurrences = []
    placed = []
    for failure in sorted((f for f in new if f.key not in known), key=lambda f: (f.at, f.key)):
        moment = parse_time(failure.at)
        prior = [fix for fix in state.fixes if parse_time(fix["at"]) < moment]
        if not prior:
            placed.append(replace(failure, episode=0))
            continue
        fix = max(prior, key=lambda f: parse_time(f["at"]))
        pair = f"{fix['sha']}..{failure.head_sha}"
        contains = ctx.ancestry.get(pair)
        if contains is None and pair in ctx.unresolved:
            # Only this failure is unplaceable; the test's others still are.
            # Its head commit is gone (`fetch_ancestry` fails the run when the
            # fix commit is), so no later run can place it either.
            ctx.dropped.append(
                f"`{state.test_id}`: failure {failure.key} not recorded: its commit "
                f"{failure.head_sha[:12]} no longer exists, so it cannot be compared with the fix (HTTP 404)"
            )
            continue
        if contains is None:
            if not ctx.collect_missing:
                raise AnalysisError(f"no ancestry fetched for {pair}")
            ctx.missing.add(pair)
            contains = False
        if not contains:
            failure = replace(failure, episode=fix["episode"], pre_fix=True)
        elif fix["episode"] == state.episode:
            # Fixes that landed after this failure belong to the episode it
            # opens, so a later failure containing one of them is that fix's
            # own recurrence rather than more of this one.
            new_episode = state.episode + 1
            fixes = [dict(f, episode=new_episode) if parse_time(f["at"]) > moment else f for f in state.fixes]
            state = replace(state, episode=new_episode, fixes=fixes)
            failure = replace(failure, episode=new_episode)
            recurrences.append((failure, fix))
        else:
            failure = replace(failure, episode=fix["episode"] + 1)
        placed.append(failure)
    merged, _ = fl.merge(state, placed)
    return merged, recurrences


def reopen_body(test: str, recurrences: list[tuple[fl.Failure, dict]], repo: str) -> str:
    failure, fix = recurrences[-1]
    via = f"#{fix['pr']}" if fix.get("pr") else "a commit"
    return (
        f"Reopened by the flake ledger: {fl.code_span(test)} failed again in "
        f"[run {failure.run_id}, attempt {failure.attempt}]({fl.run_url(repo, failure.run_id, failure.attempt)}) "
        f"on `{failure.head_sha[:12]}`, a commit that contains the fix `{fix['sha'][:12]}` ({via}). "
        f"The fix did not hold; this starts episode {failure.episode + 1}."
    )


def creation_body(test: str, links: list[int]) -> str:
    lines = [
        f"Tracks the flaky test {fl.code_span(test)}: one issue per test (docs/specs/2026-10-07-flake-autofix-design.md).",
        "",
        "The flake ledger keeps this test's failure history in its comment below and edits it in place each run.",
    ]
    if links:
        refs = ", ".join(f"#{n}" for n in links)
        lines += ["", f"This test's `.flaky(issue:)` trait names {refs}, which is shared with other tests or covers a whole suite."]
    return "\n".join(lines)


def _same_body(rendered: str, existing: str | None) -> bool:
    """GitHub may hand a body back with CRLF line ends or without a trailing
    newline; neither is a change worth a write."""
    if existing is None:
        return False
    return rendered.replace("\r\n", "\n").rstrip() == existing.replace("\r\n", "\n").rstrip()


def plan_for_test(test: str, issue_number: int | None, new: list[fl.Failure], ctx: Context, notes: Notes, watched: fl.State | None = None) -> tuple[dict | None, dict | None, fl.State | None]:
    """One test's plan: `(action, summary, watch)`. `action` is its issue's
    writes, or None; `watch` is its watchlist entry when it stays on the
    watchlist – no issue of its own and below the threshold, or promoted off
    it but not yet confirmed on its issue – else None. A
    summary of None means the test was skipped, and its watchlist entry, if
    any, stays as it is."""
    view = ctx.issues.get(issue_number) if issue_number is not None else None
    create = None
    add_label = False
    links: list[int] = []
    if view is None:
        trait = trait_issue_for(test, ctx.inventory, ctx.files)
        if trait is not None and trait in ctx.gone_issues:
            # Nothing to adopt or link: the test gets an issue of its own. A
            # mistyped number then shows up as a new public issue beside the
            # real one, where skipping the test would hide it.
            trait = None
        if trait is not None and trait in ctx.issues and ctx.issues[trait].unreadable:
            # It may hold this test's own history; a second issue would split it.
            notes.unreadable.append(f"`{test}`: its trait's issue #{trait} has an unparsable bot comment; skipped")
            return None, None, None
        if trait is not None and issue_serves_test_alone(trait, test, ctx.inventory, ctx.targets, ctx.issues):
            view = ctx.issues[trait]
        elif trait is not None:
            links = [trait]
    if view is not None and view.ledger is not None:
        state = view.ledger
        if watched is not None:
            # A run that seeded the issue from the watchlist died before
            # taking the test off it: the issue already holds this history.
            state = _absorb(state, watched)
    elif watched is not None:
        # The watchlist holds the test's history: it seeds a new issue, or
        # an issue found without a ledger comment yet (one a run created and
        # then died before commenting on, or a human's).
        state = replace(watched, links=watched.links or links)
    else:
        state = fl.State(test_id=test, links=links)
    known = len(state.failures)
    state, pr_fixes = record_pr_outcomes(state, view, ctx)
    # The latest close event's fix is on record whether or not the issue is
    # still closed: an issue the ledger reopened, or a human reopened, keeps the
    # fix it was closed with. Only a closed issue is reopened, though.
    closer = []
    if view is not None and view.closed_reason == "completed" and view.closing_fix:
        closer = [view.closing_fix]
    state = add_fixes(state, pr_fixes + closer)
    state, recurrences = classify(state, new, ctx)
    reopen = bool(recurrences) and view is not None and view.state == "CLOSED" and bool(closer)
    summary = {
        "test_id": test,
        "issue": view.number if view else None,
        "issue_state": view.state if view else None,
        "create": False,
        "watch": False,
        "from_watchlist": watched is not None,
        "links": state.links,
        "failures": fl.failure_count(state),
        "new_failures": len(state.failures) - known,
        "distinct": sorted(fl.distinct_occurrences(state)),
        "episode": state.episode,
        "qualifies": fl.qualifies(state),
        "reopen": reopen,
    }
    if view is None and not summary["qualifies"]:
        # Spec §4.4: below the threshold with no issue of its own, the test
        # is kept on the watchlist rather than given a public issue.
        summary["watch"] = True
        return None, summary, state

    # Spec §4.4, leaving the watchlist: the watchlist is written before any
    # issue, so a test promoted off it keeps its entry, updated, until a run
    # reads its issue's ledger comment already holding that history. Only
    # then is dropping the entry safe whatever this run's issue writes do.
    pending = watched is not None and not (view is not None and view.ledger is not None and _holds(view.ledger, watched))
    keep = state if pending else None
    summary["leaves_watchlist_next_run"] = pending
    if view is None:
        create = {"title": fl.issue_title(test), "body": creation_body(test, state.links)}
        summary["create"] = True
    elif fl.FLAKY_LABEL not in view.labels:
        add_label = True
    body = fl.render_comment(state, ctx.repo)
    existing = view.ledger_body if view is not None else None
    if create is None and not add_label and not reopen and _same_body(body, existing):
        return None, summary, keep
    action = {
        "test_id": test,
        "issue": view.number if view else None,
        "create": create,
        "add_label": add_label,
        "reopen": reopen,
        "reopen_body": reopen_body(test, recurrences, ctx.repo) if reopen else None,
        "comment_id": view.ledger_comment_id if view else None,
        "comment_body": body,
        "qualifies": summary["qualifies"],
    }
    return action, summary, keep


def plan_watchlist(watch: Watchlist, entries: dict[str, fl.State], repo: str) -> dict:
    """The watchlist's writes (spec §4.4). Each test keeps the comment it is
    in – the last one, if a run that died midway left it in two. A test new
    to the watchlist joins the first comment with room for it, else the last.
    A comment over the body limit hands its last tests, in test-ID order, to
    the next comment, and the last overflows into a new one, so tests only
    ever move forward. The writes go new comments first, then the existing
    ones last first: every moved test is written to its new comment before
    its old one drops it, so a run that dies midway leaves it in two comments
    (merged on the next read, and kept in the later one), never in none. A
    comment left empty is edited to say so and reused, never deleted.

    Each entry is first degraded as a ledger comment is (`fl.fit`), to a
    budget that lets it fit in a comment alone."""
    fitted = {t: fl.fit(s, repo, fl.WATCHLIST_ENTRY_CHARS)[0] for t, s in entries.items()}
    home = {t: i for i, (_, tests, _) in enumerate(watch.slots) for t in tests}
    groups = [[t for t in tests if t in fitted and home[t] == i] for i, (_, tests, _) in enumerate(watch.slots)]
    if not groups:
        groups = [[]]

    def body_of(group: list[str]) -> str:
        return fl.render_watchlist([fitted[t] for t in group], repo)

    for test in sorted(set(fitted) - set(home)):
        room = next((g for g in groups if len(body_of(g + [test])) <= fl.MAX_COMMENT_CHARS), groups[-1])
        room.append(test)

    i = 0
    while i < len(groups):
        groups[i].sort()
        while len(groups[i]) > 1 and len(body_of(groups[i])) > fl.MAX_COMMENT_CHARS:
            if i + 1 == len(groups):
                groups.append([])
            groups[i + 1].insert(0, groups[i].pop())
        if len(body_of(groups[i])) > fl.MAX_COMMENT_CHARS:
            raise AnalysisError(f"watchlist entry `{groups[i][0]}` does not fit in one comment")
        i += 1

    writes = []
    for index, group in enumerate(groups):
        comment_id, existing = (watch.slots[index][0], watch.slots[index][2]) if index < len(watch.slots) else (None, None)
        if comment_id is None and not group:
            continue
        body = body_of(group)
        if _same_body(body, existing):
            continue
        writes.append({"index": index, "comment_id": comment_id, "body": body, "tests": len(group)})
    # New comments first, in order, so comment IDs keep the comments' order;
    # they only gain tests. Then existing ones, last first.
    writes.sort(key=lambda w: (w["comment_id"] is not None, w["index"] if w["comment_id"] is None else -w["index"]))
    create = None
    if watch.number is None and writes:
        create = {"title": fl.WATCHLIST_TITLE, "body": watchlist_issue_body()}
    before = set(watch.entries)
    return {
        "issue": watch.number,
        "create": create,
        "add_label": watch.add_label,
        "writes": writes,
        "tests": len(fitted),
        "added": len(set(fitted) - before),
        "removed": len(before - set(fitted)),
        "comments": sum(1 for g in groups if g),
    }


def watchlist_issue_body() -> str:
    return "\n".join([
        f"The flake ledger's watchlist: every test that has failed in fewer than {fl.QUALIFY_DISTINCT_OCCURRENCES} "
        "distinct places and has no issue of its own (docs/specs/2026-10-07-flake-autofix-design.md, §4.4).",
        "",
        "Its history lives in the bot's comments below, edited in place each run, because CI keeps the test "
        "results for only 7 days. A test that fails in a second place gets its own `flaky` issue, seeded with "
        "that history, and leaves this list. This issue is never a fix target.",
    ])


def age_out(entries: dict[str, fl.State], mapping: dict[str, int], now: datetime, notes: Notes) -> dict[str, fl.State]:
    """Spec §4.4: the watchlist entries that stay, every one whose newest
    failure, folded counts included, is under `WATCHLIST_AGE_OUT_DAYS` old. A
    test with an issue of its own is not aged: its entry is waiting to be
    confirmed on that issue (`plan_for_test`). An aged-out test that fails
    again, this run or later, starts a fresh entry."""
    cutoff = now - timedelta(days=fl.WATCHLIST_AGE_OUT_DAYS)
    kept = {}
    for test, state in entries.items():
        newest = fl.newest_failure_at(state)
        if test not in mapping and (not newest or parse_time(newest) < cutoff):
            notes.aged.append(f"`{test}`: no failure since {newest or 'ever'}; off the watchlist")
            continue
        kept[test] = state
    return kept


def analyze(work: Path, collect_missing: bool = False) -> dict:
    meta = _read_json(work / "meta.json", None)
    if not meta:
        raise AnalysisError(f"{work}/meta.json is missing")
    repo, now = meta["repo"], parse_time(meta["now"])
    notes = Notes()
    targets = read_targets(work)
    inventory = read_inventory(work)
    by_test, files = collect_failures(work, repo, now, notes, targets)
    issues = load_issues(_require_json(work / "issues.json"), notes)
    # A test's file is also known from its own history, so a trait on a test
    # that has not run a `.flaky` record this week still matches.
    for view in issues.values():
        if view.ledger is not None:
            for failure in view.ledger.failures:
                if failure.file:
                    files.setdefault(view.ledger.test_id, (failure.file, failure.line))
    watch = load_watchlist(_require_json(work / "watchlist.json"), notes)
    for state in watch.entries.values():
        for failure in state.failures:
            if failure.file:
                files.setdefault(state.test_id, (failure.file, failure.line))
    note_inventory_rows(inventory, files, notes)
    gone_issues = {int(n): int(status) for n, status in _read_json(work / "fetch_notes.json", {}).get("gone_issues", {}).items()}
    for number, status in sorted(gone_issues.items()):
        notes.gone.append(f"#{number} (HTTP {status}): a failing test whose trait names it gets an issue of its own; check the trait's number")
    mapping = map_tests_to_issues(issues, set(by_test) | set(watch.entries), notes)
    ctx = Context(
        repo=repo,
        issues=issues,
        inventory=inventory,
        targets=targets,
        files=files,
        pr_states=_read_json(work / "pr_states.json", {}),
        ancestry=_read_json(work / "ancestry.json", {}),
        collect_missing=collect_missing,
        gone_issues=gone_issues,
        unresolved=set(_read_json(work / "ancestry_unresolved.json", [])),
    )
    actions, tests = [], []
    entries = age_out(watch.entries, mapping, now, notes)
    # A watchlist entry with no new failure and no issue carries over as it
    # is; so does one whose test was skipped below.
    on_watch = {t: s for t, s in entries.items() if t not in by_test and t not in mapping}
    for test in sorted(set(by_test) | set(mapping)):
        watched = entries.get(test)
        if test in mapping and issues[mapping[test]].unreadable:
            if watched is not None:
                on_watch[test] = watched
            continue
        action, summary, stays = plan_for_test(test, mapping.get(test), by_test.get(test, []), ctx, notes, watched)
        if summary is None:
            if watched is not None:
                on_watch[test] = watched
            continue
        if stays is not None:
            on_watch[test] = stays
        tests.append(summary)
        if action is not None:
            actions.append(action)
    notes.dropped.extend(ctx.dropped)
    return {
        "repo": repo,
        "actions": actions,
        "watchlist": plan_watchlist(watch, on_watch, repo),
        "tests": tests,
        "notes": notes.__dict__,
        "missing_ancestry": sorted(ctx.missing),
    }


# --- report ------------------------------------------------------------------------------


def report(plan: dict, write: bool) -> str:
    mode = "writing issues" if write else "report-only: FLAKE_LEDGER_ENABLED is not 'true', so nothing was written"
    lines = [f"## Flake ledger ({mode})", ""]
    tests = plan["tests"]
    if not tests:
        lines.append("No flaky-test failures in the read window, and no issue to update.")
    watch = plan.get("watchlist") or {"issue": None, "create": None, "writes": [], "tests": 0, "added": 0, "removed": 0, "comments": 0}
    opening = [t for t in tests if t["create"]]
    promoted = sum(1 for t in opening if t.get("from_watchlist"))
    if watch["issue"] is not None:
        home = f"#{watch['issue']}"
    elif watch["create"]:
        home = "a new issue"
    else:
        home = "none yet"
    lines += [
        f"**Per-test issues to open: {len(opening)}** ({promoted} promoted from the watchlist). "
        f"**Tests on the watchlist: {watch['tests']}** ({watch['added']} new, {watch['removed']} leaving it), "
        f"in {watch['comments']} comment(s); the watchlist issue: {home}.",
        "",
    ]
    for t in sorted(tests, key=lambda t: (-t["failures"], t["test_id"])):
        if t.get("watch"):
            where = "the watchlist"
        elif t["create"]:
            where = "a new issue" + (f", linking #{t['links'][0]}" if t["links"] else "")
            if t.get("from_watchlist"):
                where += ", seeded from the watchlist"
        else:
            where = f"#{t['issue']} ({t['issue_state'].lower()})"
        if t.get("leaves_watchlist_next_run"):
            where += "; kept on the watchlist until a run reads this history on the issue"
        extra = "; reopens it as a recurrence" if t["reopen"] else ""
        lines.append(
            f"- **`{t['test_id']}`** – {t['failures']} failures ({t['new_failures']} new), "
            f"{len(t['distinct'])} distinct places in episode {t['episode'] + 1}, "
            f"qualifies: {'yes' if t['qualifies'] else 'no'}; {where}{extra}"
        )
    watch_writes = len(watch["writes"]) + (1 if watch["create"] else 0)
    lines += ["", f"Planned issue writes: {len(plan['actions'])} per-test issue(s), and {watch_writes} on the watchlist."]
    for title, key in (
        ("Unreadable artifacts", "unreadable"),
        ("Artifacts not read (expired, or never uploaded)", "unavailable"),
        ("`.flaky(issue:)` numbers GitHub says do not exist", "gone"),
        ("Failures not recorded this run", "dropped"),
        ("Inventory rows skipped", "inventory_skipped"),
        ("Sentinel comments not written by the bot (ignored)", "forged"),
        ("Duplicates", "duplicates"),
        (f"Aged off the watchlist (no failure in {fl.WATCHLIST_AGE_OUT_DAYS} days)", "aged"),
    ):
        entries = plan["notes"].get(key, [])
        if entries:
            lines += ["", f"**{title}:**"]
            lines += [f"- {e}" for e in entries]
    return "\n".join(lines) + "\n"


# --- GitHub I/O ------------------------------------------------------------------------------


def gh(*args: str, input: bytes | None = None, write: bool = False) -> bytes:
    """One `gh` call. Raises GhError on a non-zero exit. stderr is passed
    through for the log; the only thing read from it is the HTTP status, so a
    definite 404 or 410 can be told apart from a failure to ask. A write uses FLAKE_WRITE_TOKEN: the
    App token, so issues and comments are authored by the bot, except for
    `report-red-run --job-token`, whose one comment uses the job token."""
    env = dict(os.environ)
    if write:
        token = os.environ.get("FLAKE_WRITE_TOKEN", "")
        if not token:
            raise GhError("refusing to write without FLAKE_WRITE_TOKEN (the tbd-flake-fixer App token)")
        env["GH_TOKEN"] = token
    proc = subprocess.run([GH_CMD, *args], input=input, capture_output=True, env=env, check=False)
    if proc.returncode != 0:
        err = proc.stderr.decode(errors="replace")
        sys.stderr.write(err)
        # `gh api` ends its error line with `(HTTP <status>)`. The status is
        # the one thing read from stderr, to tell "does not exist" apart.
        found = HTTP_STATUS.findall(err)
        raise GhError(f"gh {' '.join(args[:4])} exited {proc.returncode}", int(found[-1]) if found else None)
    return proc.stdout


def gh_json(*args: str):
    out = gh(*args)
    try:
        return json.loads(out)
    except json.JSONDecodeError as error:
        raise GhError(f"gh {' '.join(args[:4])}: not JSON ({error})") from error


def gh_lines(*args: str) -> list:
    """`gh api --paginate ... --jq '.x[]'` prints one JSON value per line."""
    out = gh(*args)
    try:
        return [json.loads(line) for line in out.decode().splitlines() if line.strip()]
    except json.JSONDecodeError as error:
        raise GhError(f"gh {' '.join(args[:4])}: not JSON lines ({error})") from error


def gh_write(*args: str, payload: dict):
    out = gh(*args, "--input", "-", input=json.dumps(payload).encode(), write=True)
    return json.loads(out) if out.strip() else None


def _normalize_run(raw: dict, workflow: str) -> dict:
    return {
        "run_id": int(raw["id"]),
        "workflow": workflow,
        "event": raw.get("event"),
        "head_branch": raw.get("head_branch") or "",
        "head_sha": raw.get("head_sha") or "",
        "head_repo": (raw.get("head_repository") or {}).get("full_name"),
        "created_at": raw["created_at"],
        "run_attempt": int(raw.get("run_attempt") or 1),
        "run_started_at": raw.get("run_started_at") or raw["created_at"],
        "conclusion": raw.get("conclusion"),
    }


def _fetch_attempts(repo: str, run: dict) -> list[dict]:
    if run["run_attempt"] <= 1:
        return [{"attempt": 1, "started_at": run["run_started_at"], "conclusion": run["conclusion"]}]
    attempts = []
    for n in range(1, run["run_attempt"] + 1):
        raw = gh_json("api", f"repos/{repo}/actions/runs/{run['run_id']}/attempts/{n}")
        attempts.append({"attempt": n, "started_at": raw["run_started_at"], "conclusion": raw.get("conclusion")})
    return attempts


def _download(repo: str, artifact_id: int, dest: Path) -> None:
    data = gh("api", f"repos/{repo}/actions/artifacts/{artifact_id}/zip")
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as error:
        raise GhError(f"artifact {artifact_id}: not a zip ({error})") from error
    dest.mkdir(parents=True, exist_ok=True)
    for member in archive.infolist():
        if member.is_dir():
            continue
        parts = PurePosixPath(member.filename).parts
        # Artifact contents are data from CI runs; never let a name escape dest.
        if not parts or member.filename.startswith("/") or ".." in parts:
            raise GhError(f"artifact {artifact_id}: refusing member {member.filename!r}")
        target = dest.joinpath(*parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(archive.read(member))


CLOSE_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      timelineItems(itemTypes: [CLOSED_EVENT], last: 1) {
        nodes {
          ... on ClosedEvent {
            createdAt
            stateReason
            closer {
              __typename
              ... on Commit { oid }
              ... on PullRequest { number merged mergedAt mergeCommit { oid } }
            }
          }
        }
      }
    }
  }
}
"""


def _close_info(repo: str, number: int) -> tuple[str | None, dict | None]:
    """The latest ClosedEvent's reason and its fix, if it has one: the closer
    commit, or the closer PR's merge commit (spec §4.4)."""
    owner, name = repo.split("/", 1)
    data = gh_json("api", "graphql", "-f", f"query={CLOSE_QUERY}", "-f", f"owner={owner}", "-f", f"name={name}", "-F", f"number={number}")
    nodes = (((data.get("data") or {}).get("repository") or {}).get("issue") or {}).get("timelineItems", {}).get("nodes")
    if nodes is None:
        raise GhError(f"#{number}: no timeline in the GraphQL answer")
    if not nodes:
        return None, None
    event = nodes[-1]
    reason = {"COMPLETED": "completed", "NOT_PLANNED": "not_planned"}.get(event.get("stateReason") or "", None)
    if (event.get("stateReason") or "") == "DUPLICATE":
        reason = "not_planned"
    closer = event.get("closer") or {}
    fix = None
    if closer.get("__typename") == "Commit" and closer.get("oid"):
        fix = {"sha": closer["oid"], "at": event["createdAt"], "pr": None}
    elif closer.get("__typename") == "PullRequest" and closer.get("merged") and closer.get("mergeCommit"):
        fix = {"sha": closer["mergeCommit"]["oid"], "at": closer.get("mergedAt") or event["createdAt"], "pr": closer.get("number")}
    return reason, fix


def _sentinel_comments(repo: str, number: int, sentinels: tuple[str, ...]) -> list[dict]:
    """Every comment on one issue that starts with one of `sentinels`, with
    its author: the reader decides which authors count."""
    comments = []
    for c in gh_lines("api", "--paginate", f"repos/{repo}/issues/{number}/comments?per_page=100", "--jq", ".[]"):
        body = c.get("body") or ""
        if body.startswith(sentinels):
            user = c.get("user") or {}
            comments.append({"id": c["id"], "login": user.get("login"), "type": user.get("type"), "body": body})
    return comments


def _fetch_watchlist(repo: str) -> list[dict]:
    """Every issue labelled `flake-watchlist`, open or closed, with its author;
    the comments only of those the bot opened, the only ones `analyze` reads."""
    raws = gh_lines("api", "--paginate", f"repos/{repo}/issues?labels={fl.WATCHLIST_LABEL}&state=all&per_page=100", "--jq", ".[] | select(.pull_request == null)")
    if not any(fl.trusted_author((r.get("user") or {}).get("login"), (r.get("user") or {}).get("type")) for r in raws):
        # Its label removed by hand: found by its exact title and the bot's
        # authorship, so its history is not abandoned for a fresh one.
        raws += [
            hit for hit in _search_title(repo, fl.WATCHLIST_TITLE)
            if hit.get("title") == fl.WATCHLIST_TITLE and hit.get("pull_request") is None
        ]
    found = []
    for raw in {int(r["number"]): r for r in raws}.values():
        user = raw.get("user") or {}
        item = {
            "number": int(raw["number"]),
            "title": raw.get("title") or "",
            "state": (raw.get("state") or "").upper(),
            "login": user.get("login"),
            "type": user.get("type"),
            "created_at": raw.get("created_at") or "",
            "labels": [label["name"] if isinstance(label, dict) else label for label in raw.get("labels", [])],
            "comments": [],
        }
        if fl.trusted_author(item["login"], item["type"]):
            item["comments"] = _sentinel_comments(repo, item["number"], (fl.WATCHLIST_SENTINEL,))
        found.append(item)
    return sorted(found, key=lambda i: i["number"])


def _fetch_issue(repo: str, raw: dict) -> dict:
    number = int(raw["number"])
    comments = _sentinel_comments(repo, number, (fl.SENTINEL, fl.ATTEMPTS_SENTINEL))
    state = (raw.get("state") or "").upper()
    # Read for open issues too: one that was closed by a fix and reopened keeps
    # that fix on record, which is what lets a run that died between the reopen
    # and the ledger write converge on the next one.
    reason, fix = _close_info(repo, number)
    return {
        "number": number,
        "title": raw.get("title") or "",
        "state": state,
        "labels": [label["name"] if isinstance(label, dict) else label for label in raw.get("labels", [])],
        "comments": comments,
        "closed_reason": reason,
        "closing_fix": fix,
    }


def _inventory(root: Path, out: Path) -> None:
    proc = subprocess.run(
        ["bash", str(root / "scripts/nightly-quarantine-audit.sh"), "inventory", "--out", str(out), "--root", str(root)],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode(errors="replace"))
        raise GhError("the quarantine inventory failed")


def _targets(root: Path, out: Path) -> None:
    script = root / "scripts/nightly-flake-stress.sh"
    proc = subprocess.run(
        ["bash", "-c", 'source "$1" && for t in "${TARGETS[@]}"; do IFS="|" read -r n _ _ i _ <<< "$t"; printf "%s\\t%s\\n" "$n" "$i"; done', "targets", str(script)],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode(errors="replace"))
        raise GhError("reading the stress targets failed")
    out.write_bytes(proc.stdout)


def fetch(work: Path, repo: str, root: Path, now: datetime) -> None:
    """Everything `analyze` reads, except the ancestry answers (`fetch_ancestry`),
    which depend on the analysis."""
    work.mkdir(parents=True, exist_ok=True)
    _write_json(work / "meta.json", {"now": iso(now), "repo": repo})
    since = (now - timedelta(days=max(TEST_RUN_WINDOW_DAYS, NIGHTLY_RUN_WINDOW_DAYS))).date().isoformat()
    runs = []
    for workflow, file in (("test", TEST_WORKFLOW), ("nightly", NIGHTLY_WORKFLOW)):
        listed = gh_lines("api", "--paginate", f"repos/{repo}/actions/workflows/{file}/runs?created=>={since}&status=completed&per_page=100", "--jq", ".workflow_runs[]")
        # A filtered run listing stops at 1,000 results without saying so. A
        # window that full would be read short, so fail closed instead.
        if len(listed) >= RUN_LISTING_CAP:
            raise GhError(f"{file}: {len(listed)} runs in the window reaches GitHub's listing cap; the window would be read short")
        for raw in listed:
            run = _normalize_run(raw, workflow)
            # Fork and flakefix/* runs are excluded before any further read.
            if not eligible_run(run, repo) or not in_window(run, now):
                continue
            run["attempts"] = _fetch_attempts(repo, run)
            run["artifacts"] = gh_lines(
                "api", "--paginate", f"repos/{repo}/actions/runs/{run['run_id']}/artifacts?per_page=100",
                "--jq", ".artifacts[] | {id, name, created_at, expired}",
            )
            for artifact in needed_artifacts(run):
                _download(repo, artifact["id"], work / "artifacts" / str(artifact["id"]))
            runs.append(run)
    _write_json(work / "runs.json", runs)
    _inventory(root, work / "inventory.tsv")
    _targets(root, work / "targets.tsv")

    raw_issues = {
        int(i["number"]): i
        for i in gh_lines("api", "--paginate", f"repos/{repo}/issues?labels={fl.FLAKY_LABEL}&state=all&per_page=100", "--jq", ".[] | select(.pull_request == null)")
    }
    issues = {n: _fetch_issue(repo, raw) for n, raw in raw_issues.items()}
    watchlist = _fetch_watchlist(repo)
    _write_json(work / "watchlist.json", watchlist)

    # Issues outside the label that the lookup may need: each issue a trait
    # names, and an exact-title match for each failing test not yet mapped.
    gone_issues: dict[str, int] = {}
    for _, _, number in read_inventory(work):
        if number in issues or str(number) in gone_issues:
            continue
        try:
            raw = gh_json("api", f"repos/{repo}/issues/{number}")
        except GhError as error:
            # A number GitHub says does not exist skips only the tests whose
            # trait names it (`analyze`); any other failure fails the run.
            if error.status not in ISSUE_GONE_STATUSES:
                raise
            gone_issues[str(number)] = error.status
            continue
        # A trait naming a pull request names no issue to adopt; the test then
        # gets its own issue linking the number.
        if raw.get("pull_request") is None:
            issues[number] = _fetch_issue(repo, raw)
    _write_json(work / "fetch_notes.json", {"gone_issues": gone_issues})
    notes = Notes()
    by_test, _ = collect_failures(work, repo, now, notes, read_targets(work))
    entries = load_watchlist(watchlist, Notes()).entries
    mapping = map_tests_to_issues(load_issues(list(issues.values()), Notes()), set(by_test) | set(entries), Notes())
    for test in sorted(set(by_test) - set(mapping)):
        if test in entries and not _may_qualify(entries[test], by_test[test]):
            # Searched when it first failed, and again only once it may
            # qualify: a test that stays on the watchlist creates nothing.
            continue
        title = fl.issue_title(test)
        for hit in _search_title(repo, title):
            if hit.get("title") == title and int(hit["number"]) not in issues:
                issues[int(hit["number"])] = _fetch_issue(repo, hit)
        if SEARCH_PAUSE_S > 0:
            time.sleep(SEARCH_PAUSE_S)
    _write_json(work / "issues.json", sorted(issues.values(), key=lambda i: i["number"]))

    pr_states = {}
    for view in load_issues(list(issues.values()), Notes()).values():
        recorded = {p["number"] for p in (view.ledger.prs if view.ledger else [])}
        for attempt in view.attempts:
            if attempt.outcome == "pr-opened" and attempt.pr is not None and attempt.pr not in recorded:
                raw = gh_json("api", f"repos/{repo}/pulls/{attempt.pr}")
                state = "MERGED" if raw.get("merged") else (raw.get("state") or "").upper()
                pr_states[str(attempt.pr)] = {"state": state, "merge_sha": raw.get("merge_commit_sha") if raw.get("merged") else None, "merged_at": raw.get("merged_at")}
    _write_json(work / "pr_states.json", pr_states)
    # Answers are re-asked each run: a reused work dir keeps no stale 404.
    _write_json(work / "ancestry_unresolved.json", [])
    if not (work / "ancestry.json").exists():
        _write_json(work / "ancestry.json", {})


def _may_qualify(watched: fl.State, new: list[fl.Failure]) -> bool:
    """Whether a watchlisted test may qualify this run: an over-estimate
    (every failure counted, whatever its episode), so a test that does
    qualify is always searched for before its issue is created."""
    places = {f.occurrence for f in watched.failures} | {f.occurrence for f in watched.folded} | {f.occurrence for f in new}
    return len(places) >= fl.QUALIFY_DISTINCT_OCCURRENCES or watched.episode > 0


def _search_title(repo: str, title: str) -> list[dict]:
    """Every issue the search returns for an exact-title phrase, all pages. The
    caller keeps only exact title matches, so the query may over-match but
    must not miss: a missed issue would be created a second time.

    GitHub's search has no escape for a `"` inside a quoted phrase and drops
    punctuation when it tokenizes, so a `"` in the title becomes a space
    rather than ending the phrase early. A title too long for the query is
    searched by a whole-word prefix. A page GitHub marks incomplete (the
    search timed out) or a match count past the result cap fails closed."""
    phrase = title.replace('"', " ")
    if len(phrase) > SEARCH_PHRASE_MAX:
        # GitHub rejects a query longer than 256 characters (HTTP 422). A
        # prefix ending on a whole word still matches the full title.
        phrase = re.sub(r"\w*$", "", phrase[:SEARCH_PHRASE_MAX]).rstrip()
    pages = gh_lines(
        "api", "--paginate", "-X", "GET", "search/issues",
        "-f", f'q=repo:{repo} is:issue in:title "{phrase}"', "-f", "per_page=100",
        "--jq", "{incomplete: .incomplete_results, total: .total_count, items: .items}",
    )
    hits = []
    for page in pages:
        if page.get("incomplete"):
            raise GhError(f"the title search for {title!r} came back incomplete")
        if int(page.get("total") or 0) > SEARCH_RESULT_CAP:
            raise GhError(f"the title search for {title!r} matched more issues than GitHub returns")
        hits.extend(page.get("items") or [])
    return hits


def fetch_ancestry(work: Path, repo: str, pairs: list[str]) -> None:
    """Whether each fix commit is an ancestor of each failing head, from the
    compare API: `ahead` or `identical` means it is, `behind` or `diverged`
    means it is not. On a 404 the fix commit is looked up on its own: if it
    exists, the failing head is the commit GitHub no longer has, the pair goes
    into `ancestry_unresolved.json`, and `analyze` leaves that one failure out
    of the plan. If the fix commit is gone, every later failure of the test
    would be unplaceable, so the run fails closed, as it does on any other
    failure or answer."""
    ancestry = _read_json(work / "ancestry.json", {})
    unresolved = set(_read_json(work / "ancestry_unresolved.json", []))
    for pair in pairs:
        base, head = pair.split("..", 1)
        try:
            status = gh("api", f"repos/{repo}/compare/{base}...{head}", "--jq", ".status").decode().strip()
        except GhError as error:
            if error.status not in COMPARE_GONE_STATUSES:
                raise
            try:
                gh("api", f"repos/{repo}/commits/{base}", "--jq", ".sha")
            except GhError as probe:
                if probe.status in COMPARE_GONE_STATUSES:
                    raise GhError(f"compare {pair}: the fix commit {base} no longer exists; every later failure of its test would be unplaceable") from probe
                raise
            unresolved.add(pair)
            continue
        if status in ("ahead", "identical"):
            ancestry[pair] = True
        elif status in ("behind", "diverged"):
            ancestry[pair] = False
        else:
            raise GhError(f"compare {pair}: unexpected status {status!r}")
    _write_json(work / "ancestry.json", ancestry)
    _write_json(work / "ancestry_unresolved.json", sorted(unresolved))


def _ensure_labels(repo: str, wanted: set[str]) -> None:
    # `--jq` prints a bare string unquoted, so ask for objects, which it prints as JSON.
    names = {label["name"] for label in gh_lines("api", "--paginate", f"repos/{repo}/labels?per_page=100", "--jq", ".[] | {name}")}
    for name in sorted(wanted - names):
        color, description = LABELS[name]
        gh_write("api", "-X", "POST", f"repos/{repo}/labels", payload={"name": name, "color": color, "description": description})


def _pause() -> None:
    if WRITE_PAUSE_S > 0:
        time.sleep(WRITE_PAUSE_S)


def apply(plan: dict, repo: str) -> list[str]:
    """The watchlist's writes first, then each action: one issue's writes –
    the issue, its label, a reopen, then the ledger comment. Returns the
    actions that failed, each described; empty when every write landed.

    The watchlist goes first and fails closed: a failed label or watchlist
    write raises before any issue is touched, because the watchlist is the
    only record of a sub-threshold test's history. A test promoted off it
    this run is still on it (`plan_for_test`) – it leaves only once a later
    run reads its issue's ledger comment holding that history – so writing
    the watchlist first never drops a history its issue does not hold yet.

    A failed issue write is listed and skipped, and the run goes on to the
    next issue; the caller ends the run red once every write was tried. The
    next run converges from whatever landed: an issue created without its
    comment is found again by title and seeded from the watchlist again, and
    a reopened issue keeps its closing fix on record (`_fetch_issue`), so the
    recurrence is classified again and written. The one write a failure can
    lose is the reopen comment, whose content the ledger comment repeats."""
    actions = plan["actions"]
    watch = plan.get("watchlist") or {"create": None, "writes": [], "issue": None}
    labels = set()
    if any(a["create"] or a["add_label"] for a in actions):
        labels.add(fl.FLAKY_LABEL)
    if watch["create"] or watch.get("add_label"):
        labels.add(fl.WATCHLIST_LABEL)
    if labels:
        _ensure_labels(repo, labels)
    number = watch["issue"]
    if watch.get("add_label"):
        gh_write("api", "-X", "POST", f"repos/{repo}/issues/{number}/labels", payload={"labels": [fl.WATCHLIST_LABEL]})
    if watch["create"]:
        created = gh_write("api", "-X", "POST", f"repos/{repo}/issues", payload={**watch["create"], "labels": [fl.WATCHLIST_LABEL]})
        number = int(created["number"])
        _pause()
    # Already ordered last comment first (`plan_watchlist`).
    for write in watch["writes"]:
        if write["comment_id"]:
            gh_write("api", "-X", "PATCH", f"repos/{repo}/issues/comments/{write['comment_id']}", payload={"body": write["body"]})
        else:
            gh_write("api", "-X", "POST", f"repos/{repo}/issues/{number}/comments", payload={"body": write["body"]})
        _pause()
    failed = []
    for action in actions:
        try:
            _apply_action(action, repo)
        except (GhError, KeyError, TypeError, ValueError) as error:
            where = f"#{action['issue']}" if action["issue"] else "a new issue"
            failed.append(f"`{action['test_id']}` ({where}): {error}")
        _pause()
    return failed


def _apply_action(action: dict, repo: str) -> None:
    number = action["issue"]
    if action["create"]:
        created = gh_write("api", "-X", "POST", f"repos/{repo}/issues", payload={**action["create"], "labels": [fl.FLAKY_LABEL]})
        number = int(created["number"])
    elif action["add_label"]:
        gh_write("api", "-X", "POST", f"repos/{repo}/issues/{number}/labels", payload={"labels": [fl.FLAKY_LABEL]})
    if action["reopen"]:
        gh_write("api", "-X", "PATCH", f"repos/{repo}/issues/{number}", payload={"state": "open"})
        gh_write("api", "-X", "POST", f"repos/{repo}/issues/{number}/comments", payload={"body": action["reopen_body"]})
    if action["comment_id"]:
        gh_write("api", "-X", "PATCH", f"repos/{repo}/issues/comments/{action['comment_id']}", payload={"body": action["comment_body"]})
    else:
        gh_write("api", "-X", "POST", f"repos/{repo}/issues/{number}/comments", payload={"body": action["comment_body"]})


def failed_writes_report(failed: list[str]) -> str:
    head = f"**Issue writes that failed: {len(failed)}.** Every other write was tried; the run ends red, and the next run retries these."
    return "\n".join(["", head] + [f"- {f}" for f in failed]) + "\n"


def previous_ledger_conclusion(repo: str, run_id: int, now: datetime, max_runs: int, days: int, run_attempt: int = 1) -> str:
    """Spec §8: the conclusion of the `ledger` job in the most recent earlier
    run of this workflow whose `ledger` job finished. Runs whose `ledger` job
    was skipped – every run another job's trigger started – or has not
    finished are passed over. A re-run attempt's previous attempt of the same
    run comes first: a red one there already posted for this streak."""
    if run_attempt > 1:
        for job in gh_lines("api", "--paginate", f"repos/{repo}/actions/runs/{run_id}/attempts/{run_attempt - 1}/jobs?per_page=100", "--jq", ".jobs[]"):
            if job.get("name") == LEDGER_JOB and job.get("conclusion") in ("success", "failure"):
                return job["conclusion"]
    seen = 0
    page = 1
    horizon = now - timedelta(days=days)
    while seen < max_runs:
        runs = gh_json("api", f"repos/{repo}/actions/workflows/{THIS_WORKFLOW}/runs?per_page=100&page={page}").get("workflow_runs", [])
        if not runs:
            return "none"
        for run in runs:
            # Only runs before this one. An earlier run need not be completed:
            # its `ledger` job may have failed while its own `ledger-notice`
            # job still runs, and that red must still count.
            if int(run["id"]) >= run_id:
                continue
            if parse_time(run["created_at"]) < horizon:
                return "none"
            # Only a run of an event that can start `ledger` counts toward the
            # bound: every commit status in the repository starts a run of
            # this workflow (`promote`'s trigger), and those must not use it
            # up. They are still paged past, inside the horizon. Test
            # completions arrive as `workflow_run` too and still count, as
            # they always did.
            if run.get("event") not in ("workflow_run", "workflow_dispatch"):
                continue
            seen += 1
            if seen > max_runs:
                return "none"
            for job in gh_lines("api", "--paginate", f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100", "--jq", ".jobs[]"):
                if job.get("name") == LEDGER_JOB and job.get("conclusion") in ("success", "failure"):
                    return job["conclusion"]
        page += 1
    return "none"


def report_red_run(repo: str, run_id: int, issue: int, now: datetime, job_token: bool = False, run_attempt: int = 1) -> str:
    """Spec §8: one comment on the tracking issue for the first red `ledger`
    run after a green one, and nothing for later consecutive reds. "After a
    green one" is read from GitHub, not from stored state.

    The comment is written with `$FLAKE_WRITE_TOKEN`: the App token when the
    workflow has one whose login checked out, otherwise the workflow's job
    token (`job_token`) – in report-only mode, or when minting the App token
    failed. This comment is the only issue write the job token makes."""
    previous = previous_ledger_conclusion(repo, run_id, now, max_runs=300, days=8, run_attempt=run_attempt)
    if previous == "failure":
        return "the previous ledger run was also red; not commenting again"
    url = f"https://github.com/{repo}/actions/runs/{run_id}"
    body = (
        f"The flake ledger's `ledger` job failed: {url}. It wrote nothing after the failure, "
        "and the next green run converges. Later consecutive red runs post nothing here."
    )
    if job_token:
        body += (
            " Posted with the workflow's job token: the ledger is in report-only mode, "
            "or the tbd-flake-fixer App token could not be minted or failed its login check."
        )
    gh_write("api", "-X", "POST", f"repos/{repo}/issues/{issue}/comments", payload={"body": body})
    return f"posted to #{issue} (previous ledger run: {previous})"


# --- plumbing -------------------------------------------------------------------------------


def _read_json(path: Path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text())


def _require_json(path: Path):
    """A file `fetch` always writes. Missing means fetch did not finish, and
    reading it as empty would plan duplicate issues."""
    if not path.exists():
        raise AnalysisError(f"{path} is missing; fetch did not finish")
    return json.loads(path.read_text())


def _write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=1, sort_keys=True) + "\n")


def _now(text: str | None) -> datetime:
    return parse_time(text) if text else datetime.now(timezone.utc)


def _run(args) -> int:
    if args.write and not os.environ.get("FLAKE_WRITE_TOKEN"):
        print("flake-ledger: --write needs FLAKE_WRITE_TOKEN, the tbd-flake-fixer App token", file=sys.stderr)
        return 2
    work = Path(args.work_dir) if args.work_dir else Path(tempfile.mkdtemp(prefix="flake-ledger."))
    root = Path(args.root) if args.root else Path(__file__).resolve().parent.parent
    fetch(work, args.repo, root, _now(args.now))
    missing = analyze(work, collect_missing=True)["missing_ancestry"]
    if missing:
        fetch_ancestry(work, args.repo, missing)
    plan = analyze(work)
    _write_json(work / "plan.json", plan)
    _summarize(report(plan, args.write))
    if args.write:
        return _finish_apply(plan, args.repo)
    return 0


def _summarize(text: str) -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)


def _finish_apply(plan: dict, repo: str) -> int:
    """`apply`, then the failed issue writes, if any, listed in the summary and
    the log, and the run red."""
    failed = apply(plan, repo)
    if not failed:
        return 0
    text = failed_writes_report(failed)
    _summarize(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        sys.stderr.write(text)
    return 2


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="flake-ledger.py")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("fetch")
    p.add_argument("--work-dir", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--root")
    p.add_argument("--now")
    p = sub.add_parser("analyze")
    p.add_argument("--work-dir", required=True)
    p.add_argument("--out")
    p = sub.add_parser("report")
    p.add_argument("--plan", required=True)
    p.add_argument("--write", action="store_true")
    p = sub.add_parser("apply")
    p.add_argument("--plan", required=True)
    p.add_argument("--repo", required=True)
    p = sub.add_parser("run")
    p.add_argument("--repo", required=True)
    p.add_argument("--work-dir")
    p.add_argument("--root")
    p.add_argument("--now")
    p.add_argument("--write", action="store_true")
    p = sub.add_parser("previous-ledger-conclusion")
    p.add_argument("--repo", required=True)
    p.add_argument("--run-id", required=True, type=int)
    p.add_argument("--max-runs", type=int, default=300)
    p.add_argument("--days", type=int, default=8)
    p.add_argument("--run-attempt", type=int, default=1)
    p.add_argument("--now")
    p = sub.add_parser("report-red-run")
    p.add_argument("--repo", required=True)
    p.add_argument("--run-id", required=True, type=int)
    p.add_argument("--issue", required=True, type=int)
    p.add_argument("--now")
    p.add_argument("--job-token", action="store_true", help="FLAKE_WRITE_TOKEN is the workflow's job token, not the App's")
    p.add_argument("--run-attempt", type=int, default=1)
    args = parser.parse_args(argv)
    try:
        if args.command == "fetch":
            root = Path(args.root) if args.root else Path(__file__).resolve().parent.parent
            fetch(Path(args.work_dir), args.repo, root, _now(args.now))
        elif args.command == "analyze":
            plan = analyze(Path(args.work_dir))
            text = json.dumps(plan, indent=1, sort_keys=True) + "\n"
            if args.out:
                Path(args.out).write_text(text)
            else:
                sys.stdout.write(text)
        elif args.command == "report":
            sys.stdout.write(report(json.loads(Path(args.plan).read_text()), args.write))
        elif args.command == "apply":
            if not os.environ.get("FLAKE_WRITE_TOKEN"):
                print("flake-ledger: apply needs FLAKE_WRITE_TOKEN, the tbd-flake-fixer App token", file=sys.stderr)
                return 2
            return _finish_apply(json.loads(Path(args.plan).read_text()), args.repo)
        elif args.command == "run":
            return _run(args)
        elif args.command == "previous-ledger-conclusion":
            print(previous_ledger_conclusion(args.repo, args.run_id, _now(args.now), args.max_runs, args.days, args.run_attempt))
        elif args.command == "report-red-run":
            print(report_red_run(args.repo, args.run_id, args.issue, _now(args.now), args.job_token, args.run_attempt))
    except (GhError, AnalysisError) as error:
        print(f"flake-ledger: {error}", file=sys.stderr)
        return 2
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        # An answer or file in a shape this script does not expect (bad JSON
        # included: JSONDecodeError is a ValueError) fails closed the same way.
        print(f"flake-ledger: unexpected data: {type(error).__name__}: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
