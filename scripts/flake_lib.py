"""Shared pure functions for the flake bot.

docs/specs/2026-10-07-flake-autofix-design.md is the design. This module holds
what more than one of the bot's scripts must agree on, so that agreement lives
in one place:

- **Test identity** (spec §4.2). The ledger's key is the xunit form,
  `<classname>/<name>`. `retry-metrics` records spell a nested suite with `/`
  (`RetryMetrics.stableID`), and SwiftPM's `--filter` matches that same form, so
  both conversions live here and round-trip.
- **xunit outcomes.** A reader that keeps passing and skipped cases as well as
  failed ones, because the verifier needs "the target executed and passed", not
  only "nothing failed". Like `scripts/remote_verify.py` it uses `html.parser`
  rather than `xml.etree`, whose `pyexpat` dependency is not always loadable,
  and like it, it treats a truncated file as an error rather than a clean one.
- **The ledger comment's state** (spec §4.3, §4.4): failures, occurrence keys,
  episodes, the threshold, and the comment's rendered form and its JSON block.
- **Comment trust** (spec §4.4). A comment is state only when it carries the
  sentinel AND its author is the bot's App account, `BOT_LOGIN` with user type
  `Bot`. GitHub reserves the `[bot]` suffix for Apps, so nobody else can author
  a comment under that login; anyone can type the sentinel.

Stdlib only, Python 3.12 (ubuntu-latest's `python3`).

CLI, for bash callers:

    python3 scripts/flake_lib.py cases FILE...
        one TSV row per <testcase>: test_id, outcome, file, first message line.
        Exit 2 on a truncated or unreadable file.
    python3 scripts/flake_lib.py retry-records --test ID FILE...
        for every retry-metrics record whose normalized ID is ID: file, outcome.
        Exit 2 on an unreadable file or an unparsable line.
    python3 scripts/flake_lib.py bot-login
        prints BOT_LOGIN.
    python3 scripts/flake_lib.py check-app-slug SLUG
        exit 0 when a minted App token's slug names BOT_LOGIN, else 1: the
        one check every workflow job that mints the token runs.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import MISSING, asdict, dataclass, field, fields, replace
from datetime import date
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import sys


# --- identity ------------------------------------------------------------------

# The only login whose sentinel comments are state. The `ledger` and `publish`
# jobs write with the `tbd-flake-fixer` App's token, so GitHub records this as
# the author; the jobs that mint the token check its `app-slug` output against
# this constant (`check-app-slug` below), and the readers without a token use it
# directly. Spec §4.4.
BOT_LOGIN = "tbd-flake-fixer[bot]"
BOT_USER_TYPE = "Bot"

# Passes on retry by design; the quarantine audit makes the same single
# exclusion (Tests/CLAUDE.md, "Quarantine"). Spec §4.1.
EXCLUDED_TEST_ID = "TBDDaemonTests.FlakyQuarantineSelfTests/retriesUntilPass()"

TITLE_PREFIX = "Flaky test: "
FLAKY_LABEL = "flaky"


def trusted_author(login: str | None, user_type: str | None) -> bool:
    return login == BOT_LOGIN and user_type == BOT_USER_TYPE


def issue_title(test_id: str) -> str:
    return f"{TITLE_PREFIX}{test_id}"


def xunit_test_id(classname: str, name: str) -> str:
    """The ledger's canonical ID: `<classname>/<name>` (spec §4.2).

    Swift Testing writes the module and every enclosing suite, joined by `.`, as
    `classname`; a test outside any suite has the bare module. XCTest names
    carry no `()` and follow the same rule.
    """
    return f"{classname}/{name}"


def from_retry_metrics_id(test_id: str) -> str:
    """A `retry-metrics` `testID` (`RetryMetrics.stableID`) in the xunit form.

    Split on `/`: the last segment is the name and the rest, joined with `.`, is
    the classname. With no `/` the test is outside any suite: everything up to
    the first `.` is the classname (module names contain no `.`) and the rest is
    the name. Swift type and function names cannot contain `/`.
    """
    if "/" in test_id:
        *classparts, name = test_id.split("/")
        return ".".join(classparts) + "/" + name
    module, _, name = test_id.partition(".")
    return f"{module}/{name}"


def filter_id(xunit_id: str) -> str:
    """The xunit form in the form SwiftPM's `--filter` matches: the inverse of
    `from_retry_metrics_id`. `M.A.B/f()` becomes `M.A/B/f()`; `M/f()` becomes
    `M.f()`."""
    classname, _, name = xunit_id.rpartition("/")
    module, *suites = classname.split(".")
    if not suites:
        return f"{module}.{name}"
    return f"{module}.{suites[0]}" + "".join(f"/{s}" for s in suites[1:]) + f"/{name}"


def function_name(test_id: str) -> str:
    """The test's function name without its parameter list, as the quarantine
    audit's `inventory` prints it."""
    return test_id.rpartition("/")[2].split("(", 1)[0]


# --- xunit ---------------------------------------------------------------------


@dataclass(frozen=True)
class Case:
    test_id: str
    outcome: str  # "passed" | "failed" | "skipped"
    message: str  # the first failure or error message; "" otherwise
    file: str  # basename of the xunit file it came from


class MalformedXunit(Exception):
    pass


class _CaseParser(HTMLParser):
    """Every `<testcase>`, with its outcome. Modelled on `_ResultParser` in
    `scripts/remote_verify.py`, including its depth counter: a file cut off
    mid-write leaves a result element open and must not read as complete."""

    def __init__(self, file: str):
        super().__init__(convert_charrefs=True)
        self.file = file
        self.cases: list[Case] = []
        self.root_opened = False
        self._depth = 0
        self._case: dict[str, str] | None = None
        self._outcome = "passed"
        self._message: str | None = None
        self._text: list[str] = []
        self._in_failure = False

    @property
    def root_closed(self) -> bool:
        return self.root_opened and self._depth == 0

    def handle_starttag(self, tag, attrs):
        values = {name: value or "" for name, value in attrs}
        if tag in ("testsuites", "testsuite"):
            self.root_opened = True
            self._depth += 1
        elif tag == "testcase":
            self._case = values
            self._outcome = "passed"
            self._message = None
        elif tag in ("failure", "error") and self._case is not None:
            self._outcome = "failed"
            self._in_failure = True
            self._text = []
            if self._message is None:
                self._message = values.get("message", "")
        elif tag == "skipped" and self._case is not None and self._outcome != "failed":
            self._outcome = "skipped"

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_data(self, data):
        if self._in_failure:
            self._text.append(data)

    def handle_endtag(self, tag):
        if tag in ("failure", "error"):
            if self._in_failure and not self._message:
                self._message = "".join(self._text).strip()
            self._in_failure = False
        elif tag == "testcase" and self._case is not None:
            classname = self._case.get("classname", "")
            name = self._case.get("name", "")
            self.cases.append(
                Case(
                    test_id=xunit_test_id(classname, name),
                    outcome=self._outcome,
                    message=(self._message or "") if self._outcome == "failed" else "",
                    file=self.file,
                )
            )
            self._case = None
        elif tag in ("testsuites", "testsuite"):
            self._depth = max(0, self._depth - 1)


def cases_in(path: Path) -> list[Case]:
    """Every case in one xunit file. Raises `MalformedXunit` on a file that is
    empty, unreadable, or truncated."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        raise MalformedXunit(f"{path}: {error}") from error
    parser = _CaseParser(path.name)
    parser.feed(text)
    parser.close()
    if not parser.root_closed:
        raise MalformedXunit(f"{path}: no complete <testsuite> (empty or truncated)")
    return parser.cases


def xunit_files(directory: Path, stem: str | None = None) -> list[Path]:
    """Every `*.xml` under `directory`. With `stem`, only the pair SwiftPM's
    `--xunit-output <stem>.xml` writes: `<stem>.xml` (XCTest) and
    `<stem>-swift-testing.xml` (Swift Testing). A reader that globbed only the
    first would see no Swift Testing case at all."""
    paths = [p for p in directory.rglob("*.xml") if p.is_file()]
    if stem is not None:
        wanted = {f"{stem}.xml", f"{stem}-swift-testing.xml"}
        paths = [p for p in paths if p.name in wanted]
    return sorted(paths)


def signature(message: str, lines: int = 3, chars: int = 300) -> str:
    """A failure message's first lines, for the ledger's history."""
    kept = [line.rstrip() for line in message.strip().splitlines()[:lines]]
    text = "\n".join(kept)
    return text if len(text) <= chars else text[: chars - 1] + "…"


# --- retry-metrics ---------------------------------------------------------------


class MalformedRecords(Exception):
    pass


def retry_records(path: Path) -> list[dict]:
    """Every record in one retry-metrics JSONL file. Raises `MalformedRecords`
    on an unreadable file or a line that is not a JSON object with a `testID`."""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise MalformedRecords(f"{path}: {error}") from error
    records = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise MalformedRecords(f"{path}:{number}: {error}") from error
        if not isinstance(record, dict) or not isinstance(record.get("testID"), str):
            raise MalformedRecords(f"{path}:{number}: not a retry-metrics record")
        records.append(record)
    return records


# --- the ledger's state ------------------------------------------------------------

SCHEMA = 1
SENTINEL = "<!-- flake-ledger v1 -->"
STATE_BEGIN, STATE_END = "<!-- flake-ledger-state", "flake-ledger-state -->"
ATTEMPTS_SENTINEL = "<!-- flakefix-attempts v1 -->"
ATTEMPTS_BEGIN, ATTEMPTS_END = "<!-- flakefix-attempts-state", "flakefix-attempts-state -->"

# GitHub refuses a comment body over 65,536 characters; keep headroom.
MAX_COMMENT_CHARS = 60000
# Spec §4.3: a test qualifies once its current episode spans this many distinct
# occurrence keys.
QUALIFY_DISTINCT_OCCURRENCES = 2
# The human-readable failure list shows at most this many, newest first. The
# JSON block keeps every failure (or, past the body limit, its folded count).
HUMAN_FAILURE_ROWS = 200
# Past the body limit, the oldest failures are folded into per-place counts. A
# folded failure this close in time to the newest one may still be inside an
# artifact read window (7 days, spec §4.4), so its merge key is kept beside the
# counts until it ages out, and rereading its run adds nothing.
FOLD_KEEP_KEYS_DAYS = 8
# Each degrading step works on this fraction of the failures at a time, so a
# large state renders in a bounded number of passes rather than one per failure.
DEGRADE_BATCH_FRACTION = 0.1
# The valve's inert ref for a branch (docs/specs/2026-08-16-remote-verification-
# valve-design.md) is the same branch, so it is the same occurrence.
PREFLIGHT_PREFIX = "preflight/"


@dataclass(frozen=True)
class Failure:
    key: str  # merge key within one test's state: f"{run_id}:{attempt}:{origin}"
    run_id: int
    attempt: int
    occurrence: str  # "night:YYYY-MM-DD" | "branch:<name>" | "main:YYYY-MM-DD"
    at: str  # ISO-8601 UTC, the start of the attempt that failed
    source: str  # "nightly" | "ci-xunit" | "ci-retry"
    signature: str = ""
    head_sha: str = ""
    episode: int = 0
    pre_fix: bool = False  # after a fix, on a commit without it: recorded, never counted
    suite_issue: int | None = None  # the nightly stress target's own issue
    file: str | None = None  # from retry-metrics records only
    line: int | None = None


@dataclass(frozen=True)
class Folded:
    """Failures folded into a count to keep the comment under the body limit."""

    occurrence: str
    episode: int
    pre_fix: bool
    count: int
    first: str
    last: str


@dataclass
class State:
    test_id: str
    episode: int = 0
    failures: list[Failure] = field(default_factory=list)
    folded: list[Folded] = field(default_factory=list)
    # [key, at] of folded failures recent enough to be read again (FOLD_KEEP_KEYS_DAYS).
    folded_keys: list[list[str]] = field(default_factory=list)
    # Fix commits on record (spec §4.4): {"sha", "at", "episode", "via", "pr"}.
    fixes: list[dict] = field(default_factory=list)
    # Bot PR outcomes the ledger recorded: {"number", "outcome", "merge_sha", "episode"}.
    prs: list[dict] = field(default_factory=list)
    # A shared or suite-level `.flaky(issue:)` issue this test's issue links (spec §4.4).
    links: list[int] = field(default_factory=list)


def occurrence_key(source: str, branch: str, at: str) -> str:
    """Where a failure happened (spec §4.3). A nightly failure counts per UTC
    night; one on `main` per UTC day; one on any other branch per branch, with
    the valve's `preflight/<branch>` folded into `<branch>`."""
    day = at[:10]
    if source == "nightly":
        return f"night:{day}"
    if branch == "main":
        return f"main:{day}"
    if branch.startswith(PREFLIGHT_PREFIX):
        branch = branch[len(PREFLIGHT_PREFIX) :]
    return f"branch:{branch}"


def current_failures(state: State) -> list[Failure]:
    return [f for f in state.failures if f.episode == state.episode and not f.pre_fix]


def _current_folded(state: State) -> list[Folded]:
    return [f for f in state.folded if f.episode == state.episode and not f.pre_fix]


def distinct_occurrences(state: State) -> set[str]:
    return {f.occurrence for f in current_failures(state)} | {
        f.occurrence for f in _current_folded(state)
    }


def failure_count(state: State) -> int:
    return len(state.failures) + sum(f.count for f in state.folded)


def current_count(state: State) -> int:
    return len(current_failures(state)) + sum(f.count for f in _current_folded(state))


def qualifies(state: State) -> bool:
    """Spec §4.3: the current episode spans two or more distinct occurrence
    keys, or the current episode is a recurrence with at least one failure."""
    if state.episode > 0 and current_count(state) > 0:
        return True
    return len(distinct_occurrences(state)) >= QUALIFY_DISTINCT_OCCURRENCES


def merge(old: State, new_failures: Iterable[Failure]) -> tuple[State, bool]:
    """Add failures whose merge key the state does not hold yet."""
    known = {f.key for f in old.failures} | {k for k, _ in old.folded_keys}
    added = [f for f in new_failures if f.key not in known]
    if not added:
        return old, False
    merged = replace(old, failures=sorted(old.failures + added, key=_failure_order))
    return merged, True


def _failure_order(failure: Failure) -> tuple:
    return (failure.at, failure.key)


# --- rendering -------------------------------------------------------------------


def _json_block(begin: str, end: str, payload: dict) -> str:
    # Angle brackets are escaped as JSON unicode escapes, which json.loads turns
    # back: no string value can close the surrounding HTML comment (`-->`, or
    # HTML5's `--!>`), and none can spell a block marker (`<!-- ...`).
    text = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    text = text.replace("<", "\\u003c").replace(">", "\\u003e")
    return f"{begin}\n{text}\n{end}"


def _parse_json_block(body: str, begin: str, end: str) -> dict | None:
    """The JSON block, which a render always puts last. Read from the end so
    nothing in the human part above it can stand in for it."""
    stripped = body.rstrip()
    if not stripped.endswith(end):
        return None
    stop = len(stripped) - len(end)
    start = stripped.rfind(begin, 0, stop)
    if start < 0:
        return None
    try:
        payload = json.loads(stripped[start + len(begin) : stop])
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def code_span(text: str) -> str:
    """Inline code that no message can break out of. Inside a code span
    `@login` and `#123` neither notify nor link; angle brackets become
    look-alikes so no message can open or close an HTML comment."""
    safe = text.replace("`", "'").replace("<", "‹").replace(">", "›")
    flat = " ⏎ ".join(safe.splitlines()) or " "
    return f"`{flat}`"


def run_url(repo: str, run_id: int, attempt: int) -> str:
    return f"https://github.com/{repo}/actions/runs/{run_id}/attempts/{attempt}"


def _state_payload(state: State) -> dict:
    return {
        "schema": SCHEMA,
        "test_id": state.test_id,
        "episode": state.episode,
        "failures": [_compact(asdict(f)) for f in state.failures],
        "folded": [asdict(f) for f in state.folded],
        "folded_keys": state.folded_keys,
        "fixes": state.fixes,
        "prs": state.prs,
        "links": state.links,
    }


def _compact(record: dict) -> dict:
    defaults = {f.name: f.default for f in fields(Failure) if f.default is not MISSING}
    return {k: v for k, v in record.items() if k not in defaults or v != defaults[k]}


def _human(state: State, repo: str, rows: int) -> str:
    distinct = distinct_occurrences(state)
    lines = [
        SENTINEL,
        f"### Flake ledger: {code_span(state.test_id)}",
        "",
        f"**Failures:** {failure_count(state)} recorded in all. The current episode "
        f"(episode {state.episode + 1}) has {current_count(state)}, across {len(distinct)} "
        f"distinct places (threshold: {QUALIFY_DISTINCT_OCCURRENCES}). Qualifies for a fix "
        f"attempt: {'yes' if qualifies(state) else 'no'}.",
    ]
    if state.links:
        refs = ", ".join(f"#{n}" for n in state.links)
        lines += ["", f"The `.flaky(issue:)` trait on this test names {refs}, which is shared with other tests or covers a whole suite; this issue tracks this test alone."]
    if distinct:
        lines += ["", "**Nights and branches (current episode):**"]
        lines += [f"- {code_span(o)}" for o in sorted(distinct)]
    if state.fixes:
        lines += ["", "**Fixes on record:**"]
        for fix in state.fixes:
            via = f"#{fix['pr']}" if fix.get("pr") else "a commit"
            lines.append(f"- {code_span(fix['sha'][:12])} via {via}, episode {fix['episode'] + 1}")
    if state.prs:
        lines += ["", "**Bot PRs:**"]
        lines += [f"- #{p['number']}: {p['outcome']}" for p in state.prs]
    shown = sorted(state.failures, key=_failure_order, reverse=True)[:rows]
    if shown:
        lines += ["", "**Failures, newest first:**"]
        for f in shown:
            tags = [f.source, f"episode {f.episode + 1}"]
            if f.pre_fix:
                tags.append("pre-fix")
            if f.suite_issue:
                tags.append(f"stress target #{f.suite_issue}")
            sig = f" {code_span(f.signature)}" if f.signature else ""
            lines.append(
                f"- {f.at} [run {f.run_id}, attempt {f.attempt}]({run_url(repo, f.run_id, f.attempt)})"
                f" {code_span(f.occurrence)} ({', '.join(tags)}){sig}"
            )
        hidden = len(state.failures) - len(shown)
        if hidden:
            lines.append(f"- … and {hidden} older failures, in the JSON block below")
    if state.folded:
        lines.append(f"- {sum(f.count for f in state.folded)} older failures are kept as counts only")
    lines += [
        "",
        "<sub>Written by the flake ledger (docs/specs/2026-10-07-flake-autofix-design.md). "
        "Edited in place each run; do not edit by hand.</sub>",
    ]
    return "\n".join(lines)


def _render(state: State, repo: str, rows: int) -> str:
    return _human(state, repo, rows) + "\n\n" + _json_block(STATE_BEGIN, STATE_END, _state_payload(state))


def _batch(total: int) -> int:
    return max(1, int(total * DEGRADE_BATCH_FRACTION))


def _fold(state: State, count: int) -> State:
    """Fold the `count` oldest failures into per-place counts, keeping the merge
    keys of those still young enough to be read again."""
    ordered = sorted(state.failures, key=_failure_order)
    newest = ordered[-1].at[:10]
    folded = list(state.folded)
    keys = [pair for pair in state.folded_keys if _days_between(pair[1][:10], newest) <= FOLD_KEEP_KEYS_DAYS]
    for failure in ordered[:count]:
        place = (failure.occurrence, failure.episode, failure.pre_fix)
        for i, f in enumerate(folded):
            if (f.occurrence, f.episode, f.pre_fix) == place:
                folded[i] = replace(f, count=f.count + 1, first=min(f.first, failure.at), last=max(f.last, failure.at))
                break
        else:
            folded.append(Folded(failure.occurrence, failure.episode, failure.pre_fix, 1, failure.at, failure.at))
        if _days_between(failure.at[:10], newest) <= FOLD_KEEP_KEYS_DAYS:
            keys.append([failure.key, failure.at])
    return replace(state, failures=ordered[count:], folded=folded, folded_keys=keys)


def _days_between(a: str, b: str) -> int:
    return (date.fromisoformat(b) - date.fromisoformat(a)).days


def render_comment(state: State, repo: str) -> str:
    """The ledger comment: a human part, then the state as JSON inside an HTML
    comment. Kept under `MAX_COMMENT_CHARS` by, in order: blanking signatures
    oldest first, showing fewer rows in the human list, and folding the oldest
    failures into per-place counts, each step in batches. Only the merge keys
    of folded failures inside the read window are kept, so the body fits unless
    roughly a thousand failures land within one window."""
    rows = HUMAN_FAILURE_ROWS
    body = _render(state, repo, rows)
    if len(body) <= MAX_COMMENT_CHARS:
        return body
    ordered = sorted(state.failures, key=_failure_order)
    signed = [i for i, f in enumerate(ordered) if f.signature]
    step = _batch(len(ordered))
    for start in range(0, len(signed), step):
        for i in signed[start : start + step]:
            ordered[i] = replace(ordered[i], signature="")
        state = replace(state, failures=list(ordered))
        body = _render(state, repo, rows)
        if len(body) <= MAX_COMMENT_CHARS:
            return body
    while rows > 20:
        rows //= 2
        body = _render(state, repo, rows)
        if len(body) <= MAX_COMMENT_CHARS:
            return body
    while len(body) > MAX_COMMENT_CHARS and state.failures:
        state = _fold(state, _batch(len(state.failures)))
        body = _render(state, repo, rows)
    return body


def parse_comment(body: str, login: str | None, user_type: str | None) -> State | None:
    """The state in a ledger comment, or None. A comment is state only when its
    author is the bot (`trusted_author`), it starts with the sentinel, and its
    JSON block parses with this schema: a forged comment is never state."""
    if not trusted_author(login, user_type) or not body.startswith(SENTINEL):
        return None
    payload = _parse_json_block(body, STATE_BEGIN, STATE_END)
    if not payload or payload.get("schema") != SCHEMA or not isinstance(payload.get("test_id"), str):
        return None
    try:
        return State(
            test_id=payload["test_id"],
            episode=int(payload.get("episode", 0)),
            failures=[Failure(**f) for f in payload.get("failures", [])],
            folded=[Folded(**f) for f in payload.get("folded", [])],
            folded_keys=[[str(k), str(at)] for k, at in payload.get("folded_keys", [])],
            fixes=list(payload.get("fixes", [])),
            prs=list(payload.get("prs", [])),
            links=[int(n) for n in payload.get("links", [])],
        )
    except (TypeError, ValueError):
        return None


# --- the attempt comment (written by `publish`, read by `ledger` and the picker) ---

ATTEMPT_OUTCOMES = ("aborted", "no-diff", "push-refused", "pr-opened")
ATTEMPT_NOTES_CHARS = 4000


@dataclass(frozen=True)
class Attempt:
    run_id: int
    started_at: str
    main_sha: str
    episode: int
    outcome: str  # one of ATTEMPT_OUTCOMES
    notes: str = ""  # session-reported; capped at ATTEMPT_NOTES_CHARS
    pr: int | None = None
    scope: str | None = None  # "test" | "pass"
    n: int | None = None
    false_pass: float | None = None  # None means unknown
    weak: bool | None = None
    protected_touched: list[str] | None = None
    verdict: str | None = None  # "pass" | "fail"


def render_attempts(attempts: list[Attempt], repo: str) -> str:
    lines = [ATTEMPTS_SENTINEL, "### Fix attempts", ""]
    for a in attempts:
        extra = f", PR #{a.pr}, verdict {a.verdict}" if a.pr else ""
        lines.append(
            f"- [{a.started_at}]({run_url(repo, a.run_id, 1)}) on `{a.main_sha[:12]}`: "
            f"{a.outcome}{extra} (episode {a.episode + 1})"
        )
    payload = {"schema": SCHEMA, "attempts": [asdict(a) for a in attempts]}
    return "\n".join(lines) + "\n\n" + _json_block(ATTEMPTS_BEGIN, ATTEMPTS_END, payload)


def parse_attempts(body: str, login: str | None, user_type: str | None) -> list[Attempt] | None:
    """The attempts in an attempt comment, or None unless the bot wrote it."""
    if not trusted_author(login, user_type) or not body.startswith(ATTEMPTS_SENTINEL):
        return None
    payload = _parse_json_block(body, ATTEMPTS_BEGIN, ATTEMPTS_END)
    if not payload or payload.get("schema") != SCHEMA:
        return None
    try:
        return [Attempt(**a) for a in payload.get("attempts", [])]
    except TypeError:
        return None


# --- CLI ---------------------------------------------------------------------------

_ROW_SAFE = re.compile(r"[\t\r\n]+")


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: flake_lib.py {cases|retry-records|bot-login|check-app-slug} ...", file=sys.stderr)
        return 2
    command, rest = argv[0], argv[1:]
    if command == "bot-login":
        print(BOT_LOGIN)
        return 0
    if command == "check-app-slug":
        # The workflows' one check that a minted App token's slug names the
        # login the readers trust. Exit 1, with the reason, when it does not.
        if len(rest) != 1:
            print("usage: flake_lib.py check-app-slug SLUG", file=sys.stderr)
            return 2
        if f"{rest[0]}[bot]" != BOT_LOGIN:
            print(f"the App token belongs to '{rest[0]}[bot]', but the ledger's readers trust only '{BOT_LOGIN}'", file=sys.stderr)
            return 1
        return 0
    if command == "cases":
        rows = []
        for name in rest:
            try:
                for c in cases_in(Path(name)):
                    first = _ROW_SAFE.sub(" ", c.message.strip().splitlines()[0]) if c.message.strip() else ""
                    rows.append(f"{c.test_id}\t{c.outcome}\t{c.file}\t{first}")
            except MalformedXunit as error:
                print(f"flake_lib: {error}", file=sys.stderr)
                return 2
        if rows:
            print("\n".join(rows))
        return 0
    if command == "retry-records":
        if len(rest) < 2 or rest[0] != "--test":
            print("usage: flake_lib.py retry-records --test ID FILE...", file=sys.stderr)
            return 2
        target, files = rest[1], rest[2:]
        for name in files:
            try:
                records = retry_records(Path(name))
            except MalformedRecords as error:
                print(f"flake_lib: {error}", file=sys.stderr)
                return 2
            for r in records:
                if from_retry_metrics_id(r["testID"]) == target:
                    print(f"{name}\t{r.get('outcome', '')}")
        return 0
    print(f"flake_lib: unknown command {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
