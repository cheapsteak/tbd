"""Fixture builder for scripts/flake-pick.test.sh: one issue, from a JSON spec.

    pick_issue.py ISSUES_JSON SPEC_JSON

appends to ISSUES_JSON (the shape `flake-ledger.py fetch` writes) an issue
whose comments are rendered by flake_lib itself, so the picker reads exactly
what the ledger and `publish` write. SPEC keys, all optional but `number`:

    number, test, state ("OPEN"), labels (["flaky"]), episode (0),
    failures: [[occurrence, at, signature?, source?, file?, line?, episode?]],
    fixes, prs, attempts (flake_lib.Attempt fields),
    comments: [[login, type, body]] — extra comments, e.g. a human's or a forgery,
    ledger_author ([BOT_LOGIN, "Bot"]), no_ledger (false)
"""

from __future__ import annotations

import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import flake_lib as fl  # noqa: E402

REPO = "cheapsteak/tbd"


def main(path: str, spec_text: str) -> int:
    spec = json.loads(spec_text)
    target = Path(path)
    issues = json.loads(target.read_text()) if target.exists() else []
    test = spec.get("test", "TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()")
    failures = []
    for i, row in enumerate(spec.get("failures", [])):
        occurrence, at = row[0], row[1]
        failures.append(
            fl.Failure(
                key=f"{1000 + i}:1:x",
                run_id=1000 + i,
                attempt=1,
                occurrence=occurrence,
                at=at,
                source=row[3] if len(row) > 3 else "ci-xunit",
                signature=row[2] if len(row) > 2 else "",
                file=row[4] if len(row) > 4 else None,
                line=row[5] if len(row) > 5 else None,
                episode=row[6] if len(row) > 6 else spec.get("episode", 0),
            )
        )
    state = fl.State(test_id=test, episode=spec.get("episode", 0), failures=failures,
                     fixes=spec.get("fixes", []), prs=spec.get("prs", []))
    comments = []
    cid = spec["number"] * 100
    if not spec.get("no_ledger"):
        login, kind = spec.get("ledger_author", [fl.BOT_LOGIN, "Bot"])
        comments.append({"id": cid, "login": login, "type": kind, "body": fl.render_comment(state, REPO)})
    if spec.get("attempts"):
        attempts = [fl.Attempt(**a) for a in spec["attempts"]]
        comments.append({"id": cid + 1, "login": fl.BOT_LOGIN, "type": "Bot", "body": fl.render_attempts(attempts, REPO)})
    for j, (login, kind, body) in enumerate(spec.get("comments", [])):
        comments.append({"id": cid + 10 + j, "login": login, "type": kind, "body": body})
    issues.append({
        "number": spec["number"],
        "title": spec.get("title", fl.issue_title(test)),
        "state": spec.get("state", "OPEN"),
        "labels": spec.get("labels", [fl.FLAKY_LABEL]),
        "comments": comments,
        "closed_reason": None,
        "closing_fix": None,
    })
    target.write_text(json.dumps(issues, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
