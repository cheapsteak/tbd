"""Fixture builder for scripts/flake-ledger.test.sh.

Builds the work directory `flake-ledger.py analyze` reads (runs.json,
issues.json, artifacts/<id>/, ...) one piece per call, so each harness case
states only what it is about. The xunit and retry-metrics shapes it writes are
the ones cut from real CI artifacts in fixtures/flake/xunit and
fixtures/flake/retry-metrics.

    build.py init WORK [--now ISO]
    build.py run WORK --id N [--workflow test|nightly] [--branch B] [--repo R]
                 [--sha S] [--created T] --attempt 'N|START|CONCLUSION' ...
                 [--artifact 'ID|NAME|CREATED' ...]
    build.py xunit PATH TEST_ID [MESSAGE]       a file whose one case fails
    build.py retry PATH TEST_ID OUTCOME FILE    append one retry-metrics record
    build.py issue WORK --number N [--title T] [--state OPEN|CLOSED]
                 [--label L ...] [--closed-reason R] [--fix SHA@AT[@PR]]
                 [--comment 'ID|LOGIN|TYPE|BODYFILE' ...]
    build.py watchlist WORK --number N [--login L] [--type T] [--created T]
                 [--comment 'ID|LOGIN|TYPE|BODYFILE' ...]
    build.py ledger-body OUT STATE_JSON         a rendered ledger comment
    build.py watchlist-body OUT STATES_JSON     a rendered watchlist comment
    build.py attempts-body OUT ATTEMPTS_JSON    a rendered attempt comment
    build.py set WORK FILE JSON                 overwrite pr_states/ancestry/...
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import flake_lib as fl  # noqa: E402

REPO = "cheapsteak/tbd"


def _load(path: Path):
    return json.loads(path.read_text()) if path.exists() else []


def _save(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=1) + "\n")


def _state(payload: dict) -> fl.State:
    state = fl._state_from_payload(payload)
    if state is None:
        raise SystemExit(f"build.py: not a state: {payload}")
    return state


def main(argv: list[str]) -> int:
    command, rest = argv[0], argv[1:]
    if command == "init":
        p = argparse.ArgumentParser()
        p.add_argument("work")
        p.add_argument("--now", default="2026-10-08T00:00:00Z")
        a = p.parse_args(rest)
        work = Path(a.work)
        (work / "artifacts").mkdir(parents=True, exist_ok=True)
        _save(work / "meta.json", {"now": a.now, "repo": REPO})
        for name in ("runs.json", "issues.json", "watchlist.json"):
            _save(work / name, [])
        for name in ("pr_states.json", "ancestry.json"):
            _save(work / name, {})
        (work / "inventory.tsv").write_text("")
        (work / "targets.tsv").write_text("GitManagerTimeout\t961\nFastPassWhole\t962\n")
        return 0
    if command == "run":
        p = argparse.ArgumentParser()
        p.add_argument("work")
        p.add_argument("--id", type=int, required=True)
        p.add_argument("--workflow", default="test")
        p.add_argument("--branch", default="feature-x")
        p.add_argument("--repo", default=REPO)
        p.add_argument("--sha", default="a" * 40)
        p.add_argument("--created")
        p.add_argument("--attempt", action="append", default=[])
        p.add_argument("--artifact", action="append", default=[])
        a = p.parse_args(rest)
        attempts = []
        for spec in a.attempt:
            n, start, conclusion = spec.split("|")
            attempts.append({"attempt": int(n), "started_at": start, "conclusion": conclusion})
        artifacts = []
        for spec in a.artifact:
            ident, name, created = spec.split("|")
            artifacts.append({"id": int(ident), "name": name, "created_at": created, "expired": False})
        run = {
            "run_id": a.id,
            "workflow": a.workflow,
            "event": "schedule" if a.workflow == "nightly" else "pull_request",
            "head_branch": a.branch,
            "head_sha": a.sha,
            "head_repo": a.repo,
            "created_at": a.created or attempts[0]["started_at"],
            "attempts": attempts,
            "artifacts": artifacts,
        }
        runs = _load(Path(a.work) / "runs.json")
        runs.append(run)
        _save(Path(a.work) / "runs.json", runs)
        return 0
    if command == "xunit":
        path, test_id = Path(rest[0]), rest[1]
        message = rest[2] if len(rest) > 2 else "Expectation failed"
        classname, _, name = test_id.rpartition("/")
        path.parent.mkdir(parents=True, exist_ok=True)
        escaped = message.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")
        path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n'
            '  <testsuite name="TestResults" errors="0" tests="2" failures="1" skipped="0" time="1.0">\n'
            '    <testcase classname="TBDSharedTests" name="hookPathArchive()" time="2.1" />\n'
            f'    <testcase classname="{classname}" name="{name}" time="5.2" >\n'
            f'      <failure message="{escaped}" />\n'
            "    </testcase>\n  </testsuite>\n</testsuites>\n"
        )
        return 0
    if command == "retry":
        path, test_id, outcome, file = Path(rest[0]), rest[1], rest[2], rest[3]
        path.parent.mkdir(parents=True, exist_ok=True)
        record = {"attempts": 2 if outcome == "passedOnRetry" else 1, "file": file, "issue": 1, "line": 10,
                  "outcome": outcome, "schema": 1, "testID": fl.filter_id(test_id)}
        with path.open("a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        return 0
    if command == "issue":
        p = argparse.ArgumentParser()
        p.add_argument("work")
        p.add_argument("--number", type=int, required=True)
        p.add_argument("--title", default="Some issue")
        p.add_argument("--state", default="OPEN")
        p.add_argument("--label", action="append", default=[])
        p.add_argument("--closed-reason")
        p.add_argument("--fix")
        p.add_argument("--comment", action="append", default=[])
        a = p.parse_args(rest)
        comments = []
        for spec in a.comment:
            ident, login, kind, body_file = spec.split("|")
            comments.append({"id": int(ident), "login": login, "type": kind, "body": Path(body_file).read_text()})
        fix = None
        if a.fix:
            parts = a.fix.split("@")
            fix = {"sha": parts[0], "at": parts[1], "pr": int(parts[2]) if len(parts) > 2 else None}
        issues = _load(Path(a.work) / "issues.json")
        issues.append({"number": a.number, "title": a.title, "state": a.state, "labels": a.label,
                       "comments": comments, "closed_reason": a.closed_reason, "closing_fix": fix})
        _save(Path(a.work) / "issues.json", issues)
        return 0
    if command == "watchlist":
        p = argparse.ArgumentParser()
        p.add_argument("work")
        p.add_argument("--number", type=int, required=True)
        p.add_argument("--login", default=fl.BOT_LOGIN)
        p.add_argument("--type", default="Bot")
        p.add_argument("--created", default="2026-10-01T00:00:00Z")
        p.add_argument("--comment", action="append", default=[])
        a = p.parse_args(rest)
        comments = []
        for spec in a.comment:
            ident, login, kind, body_file = spec.split("|")
            comments.append({"id": int(ident), "login": login, "type": kind, "body": Path(body_file).read_text()})
        found = _load(Path(a.work) / "watchlist.json")
        found.append({"number": a.number, "title": fl.WATCHLIST_TITLE, "state": "OPEN", "login": a.login,
                      "type": a.type, "created_at": a.created, "labels": [fl.WATCHLIST_LABEL], "comments": comments})
        _save(Path(a.work) / "watchlist.json", found)
        return 0
    if command == "ledger-body":
        Path(rest[0]).write_text(fl.render_comment(_state(json.loads(rest[1])), REPO))
        return 0
    if command == "watchlist-body":
        Path(rest[0]).write_text(fl.render_watchlist([_state(s) for s in json.loads(rest[1])], REPO))
        return 0
    if command == "attempts-body":
        attempts = [fl.Attempt(**a) for a in json.loads(rest[1])]
        Path(rest[0]).write_text(fl.render_attempts(attempts, REPO))
        return 0
    if command == "set":
        Path(rest[0], rest[1]).write_text(rest[2] + "\n")
        return 0
    print(f"build.py: unknown command {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
