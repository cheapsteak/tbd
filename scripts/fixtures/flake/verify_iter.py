"""Fixture builder for scripts/flake-verify.test.sh: one stress-loop iteration.

    verify_iter.py DIR I [--name Test] [--kind PASS|FAIL] [--reason R]
        [--target ID] [--outcome passed|failed|skipped|absent]
        [--other-failed ID] [--record OUTCOME ...] [--record-id ID]
        [--metrics ok|missing|garbage] [--log TEXT] [--xctest]

writes exactly what `scripts/nightly-flake-stress.sh` leaves for iteration I
of its one target: a results.tsv row, the SwiftPM xunit pair (the target goes
in `<name>-<i>-swift-testing.xml`, or in `<name>-<i>.xml` with --xctest), the
retry-metrics ledger, and the iteration log. The xunit and record shapes are
the ones cut from real CI artifacts in fixtures/flake/.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import flake_lib as fl  # noqa: E402


def case(test_id: str, outcome: str) -> str:
    classname, _, name = test_id.rpartition("/")
    body = {"passed": "", "failed": '\n      <failure message="Expectation failed: lock is held" />\n    ',
            "skipped": "\n      <skipped />\n    "}[outcome]
    if not body:
        return f'    <testcase classname="{classname}" name="{name}" time="0.5" />\n'
    return f'    <testcase classname="{classname}" name="{name}" time="0.5" >{body}</testcase>\n'


def suite(cases: list[str]) -> str:
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n'
            f'  <testsuite name="TestResults" tests="{len(cases)}">\n' + "".join(cases) + "  </testsuite>\n</testsuites>\n")


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("dir", type=Path)
    p.add_argument("i", type=int)
    p.add_argument("--name", default="Test")
    p.add_argument("--kind", default="PASS")
    p.add_argument("--reason", default="")
    p.add_argument("--target", default="TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()")
    p.add_argument("--outcome", default="passed")
    p.add_argument("--other-failed", action="append", default=[])
    p.add_argument("--record", action="append", default=[])
    p.add_argument("--record-id")
    p.add_argument("--metrics", default="ok")
    p.add_argument("--log", default="")
    p.add_argument("--xctest", action="store_true")
    a = p.parse_args(argv)
    d, stem = a.dir, f"{a.name}-{a.i}"
    for sub in ("xunit", "metrics", "logs"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    reason = a.reason or ("12" if a.kind == "PASS" else "rc=1 with 12 tests executed")
    count = "12" if a.kind == "PASS" else ""
    with (d / "results.tsv").open("a") as tsv:
        tsv.write("\t".join([a.name, str(a.i), a.kind, count, "0" if a.kind == "PASS" else "1",
                             "3.5", "3", "3", "20", reason]) + "\n")
    swift = [case("TBDSharedTests/hookPathArchive()", "passed")]
    swift += [case(t, "failed") for t in a.other_failed]
    xctest = [case("TBDAppTests.ArchiveTombstoneTests/testArchive", "passed")]
    if a.outcome != "absent":
        (xctest if a.xctest else swift).append(case(a.target, a.outcome))
    if not a.reason.startswith("wedged") and not a.reason.startswith("no 'Test"):
        (d / "xunit" / f"{stem}-swift-testing.xml").write_text(suite(swift))
        (d / "xunit" / f"{stem}.xml").write_text(suite(xctest))
    metrics = d / "metrics" / f"{stem}.jsonl"
    if a.metrics == "ok":
        lines = [json.dumps({"testID": a.record_id or fl.filter_id(a.target), "issue": 1, "attempts": 1,
                             "outcome": o, "file": "Tests/X.swift", "line": 1, "schema": 1}) for o in a.record]
        metrics.write_text("".join(f"{ln}\n" for ln in lines))
    elif a.metrics == "garbage":
        metrics.write_text("{not json\n")
    (d / "logs" / f"{stem}.log").write_text(a.log + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
