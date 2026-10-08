#!/usr/bin/env python3
"""The flake verifier's pure half: baseline classification, iteration
planning, and the verdict (spec §6.3, §6.4, §6.5).

`scripts/flake-verify.sh` is the entry point and owns the tunable constants;
it calls this file for everything that is arithmetic or parsing. Every command
here is a pure function of files on disk.

    choose-scope --test ID --dir D --quarantined yes|no --iterations N --max-excluded K
        classifies each baseline iteration and writes D/scope, D/p, D/v,
        D/classes.tsv and D/baseline.md. Exit 4 when more than K iterations
        are excluded: the baseline is not measuring the test.
    plan --scope test|pass --baseline-dir D --out F --target T --min-n M
         --allotment R --rebuild B --test-t T --test-w W --pass-t T --pass-w W
        writes the iteration plan (N, p, the cap, the bound, the false-pass
        probability) as JSON.
    judge --scope test|pass --test ID --dir D --iterations N --quarantined yes|no
          [--protected-touched FILE] [--plan F]
        writes D/verdict.json, D/verdict.md and D/failing-lines.txt. Exit 0
        pass, 1 fail, 3 ineligible, 2 malformed input.
    quarantined --test ID --inventory F --root DIR
        prints yes, no, or ambiguous (exit 2), from the quarantine audit's
        inventory.

The stress loop's outputs, per iteration i of its one target T, are
D/results.tsv (one row per iteration), D/xunit/T-i.xml plus
D/xunit/T-i-swift-testing.xml, D/metrics/T-i.jsonl and D/logs/T-i.log
(`scripts/nightly-flake-stress.sh`'s header documents them).
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
import math
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import flake_lib as fl  # noqa: E402

FALSE_PASS_TARGET = 0.05
SCALE_RATES = (0.05, 0.15)
DISABLED_WARNING = "warning: retry metrics disabled"
# The harness's own reasons for an iteration that did not complete (see
# `judge_iteration` in scripts/nightly-flake-stress.sh).
INCOMPLETE_REASONS = ("wedged", "no 'Test run with", "ran ")
FAILING_LINES_PER_ITERATION = 20
FAILING_LINES_TOTAL = 400
LIMIT_SENTENCE = (
    "A clean run is one sample from a gentler regime than the one many flakes appear in "
    "(a CI runner's few idle cores, not a heavily loaded shared machine), not proof of a fix."
)


# --- reading one stress run ---------------------------------------------------------


@dataclass
class Row:
    target: str
    iteration: int
    kind: str  # PASS | FAIL
    count: str
    rc: str
    load1m: str
    spinners: str
    cores: str
    reason: str


def read_rows(directory: Path) -> list[Row]:
    path = directory / "results.tsv"
    if not path.exists():
        return []
    rows = []
    for line in path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) < 10 or not parts[1].isdigit():
            continue
        rows.append(Row(parts[0], int(parts[1]), parts[2], parts[3], parts[4], parts[5], parts[6], parts[7], parts[9]))
    return rows


def target_cases(directory: Path, name: str, i: int, test: str) -> tuple[list[fl.Case], list[fl.Case], str | None]:
    """(the target's cases, every failed case, an error) for one iteration.
    Both SwiftPM files are read: `T-i.xml` holds XCTest cases and
    `T-i-swift-testing.xml` the Swift Testing ones."""
    files = fl.xunit_files(directory / "xunit", stem=f"{name}-{i}") if (directory / "xunit").is_dir() else []
    mine, failed = [], []
    try:
        for path in files:
            for case in fl.cases_in(path):
                if case.test_id == test:
                    mine.append(case)
                if case.outcome == "failed":
                    failed.append(case)
    except fl.MalformedXunit as error:
        return mine, failed, f"xunit unreadable: {error}"
    return mine, failed, None


def wiring(directory: Path, name: str, i: int, test: str) -> tuple[list[dict] | None, str | None]:
    """The iteration's records for the target, or the reason the retry ledger
    cannot be trusted: missing, unreadable, an unparsable line, or the writer's
    own warning that it could not write."""
    path = directory / "metrics" / f"{name}-{i}.jsonl"
    try:
        records = fl.retry_records(path)
    except fl.MalformedRecords as error:
        return None, f"retry ledger missing or unreadable ({error})"
    log = directory / "logs" / f"{name}-{i}.log"
    try:
        text = log.read_text(errors="replace")
    except OSError:
        text = ""
    if DISABLED_WARNING in text:
        return None, "the retry-metrics writer reported it was disabled"
    return [r for r in records if fl.from_retry_metrics_id(r["testID"]) == test], None


def target_started(directory: Path, name: str, i: int, test: str) -> bool:
    """Whether the iteration's log shows the target starting: Swift Testing's
    `Test <name> started.` or XCTest's `Test Case '-[<class> <name>]' started.`"""
    classname, _, fname = test.rpartition("/")
    try:
        text = (directory / "logs" / f"{name}-{i}.log").read_text(errors="replace")
    except OSError:
        return False
    return f"Test {fname} started" in text or f"Test Case '-[{classname} {fname}]' started" in text


def incomplete(reason: str) -> bool:
    """A row whose iteration did not complete: wedged, truncated, or below its floor."""
    return reason.startswith(INCOMPLETE_REASONS) and (not reason.startswith("ran ") or ", below " in reason)


# --- the baseline (spec §6.3) ----------------------------------------------------------


def classify(directory: Path, test: str, quarantined: bool, iterations: int) -> list[tuple[int, str, str]]:
    """(iteration, class, why) for each of 1..iterations. A row the harness
    never wrote is excluded: it says nothing about the target."""
    rows = {r.iteration: r for r in read_rows(directory)}
    out = []
    for i in range(1, iterations + 1):
        row = rows.get(i)
        if row is None:
            out.append((i, "excluded", "no result row (harness error)"))
            continue
        records, wiring_error = wiring(directory, row.target, i, test)
        if wiring_error:
            out.append((i, "excluded", wiring_error))
            continue
        mine, _, xunit_error = target_cases(directory, row.target, i, test)
        if any(c.outcome == "failed" for c in mine):
            out.append((i, "reproduction", "the target failed"))
            continue
        if quarantined and any(r.get("outcome") in ("passedOnRetry", "failed") for r in records or []):
            out.append((i, "reproduction", "the quarantine absorbed a failure (retry record)"))
            continue
        if row.reason.startswith("wedged") and target_started(directory, row.target, i, test):
            out.append((i, "reproduction", "killed at its deadline after the target started"))
            continue
        if row.kind == "PASS" and mine and all(c.outcome == "passed" for c in mine) and not xunit_error:
            out.append((i, "clean", "the target executed and passed"))
            continue
        why = xunit_error or ("the target never executed" if not mine else row.reason or "no verdict on the target")
        out.append((i, "excluded", why))
    return out


def choose_scope(directory: Path, test: str, quarantined: bool, iterations: int, max_excluded: int) -> int:
    classes = classify(directory, test, quarantined, iterations)
    f = sum(1 for _, c, _ in classes if c == "reproduction")
    x = sum(1 for _, c, _ in classes if c == "excluded")
    v = len(classes) - x
    (directory / "classes.tsv").write_text("".join(f"{i}\t{c}\t{why}\n" for i, c, why in classes))
    lines = [f"**Pre-fix baseline (`main`, the test alone):** {f} of {v} valid test-alone iterations reproduced the failure ({x} excluded)."]
    if x > max_excluded:
        lines.append(f"More than {max_excluded} of {len(classes)} iterations were excluded, so the baseline is not measuring the test; the attempt aborts.")
        (directory / "baseline.md").write_text("\n\n".join(lines) + "\n")
        print(f"flake-verify: {x} of {len(classes)} baseline iterations excluded (limit {max_excluded}); aborting", file=sys.stderr)
        return 4
    scope = "test" if f >= 1 else "pass"
    if f == 0:
        lines.append(
            "The test-alone regime did not reproduce the flake, so the verifier stresses the whole CI pass the test runs in. "
            "The pre-fix failure rate at pass scope was not measured; the ledger's counts are the only \"before\"."
        )
    (directory / "baseline.md").write_text("\n\n".join(lines) + "\n")
    (directory / "scope").write_text(scope + "\n")
    (directory / "p").write_text(f"{f / v if v else 0}\n")
    (directory / "f").write_text(f"{f}\n")
    (directory / "v").write_text(f"{v}\n")
    return 0


# --- the plan (spec §6.3, §9) ---------------------------------------------------------


def cap(allotment: float, rebuild: float, warmup: float, per_iteration: float) -> int:
    """cap = floor((R - B - W) / t)."""
    return max(0, math.floor((allotment - rebuild - warmup) / per_iteration))


def plan(scope: str, f: int, v: int, min_n: int, test_cap: int, pass_cap: int) -> dict:
    if scope == "pass":
        n = pass_cap
        return {
            "n": n, "p": None, "cap": pass_cap, "bound": "unknown", "false_pass": None, "weak": True,
            "scale": {str(p): round((1 - p) ** n, 3) for p in SCALE_RATES},
        }
    p = f / v
    if p >= 1:
        wanted = min_n  # N = ceil(ln 0.05 / ln 0) is undefined; run the minimum.
    else:
        wanted = max(math.ceil(math.log(FALSE_PASS_TARGET) / math.log(1 - p)), min_n)
    n = min(wanted, test_cap)
    false_pass = (1 - p) ** n
    return {
        "n": n, "p": round(p, 4), "cap": test_cap, "bound": "reached" if wanted <= test_cap else "not-reached",
        "false_pass": round(false_pass, 4), "weak": false_pass >= FALSE_PASS_TARGET, "scale": None,
    }


# --- the verdict (spec §6.4) -------------------------------------------------------------


@dataclass
class Verdict:
    reasons: list[str] = field(default_factory=list)
    target_failures: int = 0
    completed: int = 0
    other: list[str] = field(default_factory=list)
    lines: list[str] = field(default_factory=list)


def failing_lines(log: Path) -> list[str]:
    try:
        text = log.read_text(errors="replace")
    except OSError:
        return []
    keep = [ln.strip() for ln in text.splitlines() if re.search(r"✘|Expectation failed|Issue recorded|error:|Test .* failed", ln)]
    return keep[:FAILING_LINES_PER_ITERATION]


def judge(directory: Path, scope: str, test: str, n: int, quarantined: bool) -> Verdict:
    verdict = Verdict()
    for marker, reason in (("build-failed", "the candidate did not build"), ("harness-error", "the stress harness errored")):
        path = directory / marker
        if path.exists():
            verdict.reasons.append(reason)
            verdict.lines += [f"{reason}:"] + path.read_text(errors="replace").splitlines()[-60:]
            return verdict
    rows = read_rows(directory)
    names = {r.target for r in rows}
    if len(names) != 1 or sorted(r.iteration for r in rows) != list(range(1, n + 1)):
        verdict.reasons.append(f"truncated run: {len(rows)} result rows for {n} planned iterations")
    others: dict[str, None] = {}
    for row in sorted(rows, key=lambda r: r.iteration):
        i, name, problems = row.iteration, row.target, []
        if incomplete(row.reason):
            problems.append(f"iteration {i}: {row.reason}")
        else:
            verdict.completed += 1
        mine, failed, xunit_error = target_cases(directory, name, i, test)
        if xunit_error:
            problems.append(f"iteration {i}: {xunit_error}")
        if not mine:
            problems.append(f"iteration {i}: the target is absent from the xunit output")
        elif any(c.outcome == "failed" for c in mine):
            verdict.target_failures += 1
            problems.append(f"iteration {i}: the target failed")
        elif any(c.outcome != "passed" for c in mine):
            problems.append(f"iteration {i}: the target was skipped")
        if row.kind == "FAIL" and not incomplete(row.reason) and scope == "test":
            problems.append(f"iteration {i}: {row.reason}")
        records, wiring_error = wiring(directory, name, i, test)
        if wiring_error:
            problems.append(f"iteration {i}: {wiring_error}")
        elif quarantined:
            if not records:
                problems.append(f"iteration {i}: no retry record for the quarantined target")
            elif any(r.get("outcome") != "passedFirstTry" for r in records):
                problems.append(f"iteration {i}: the target needed a retry ({', '.join(sorted({str(r.get('outcome')) for r in records}))})")
        elif records:
            problems.append(f"iteration {i}: a retry record for a target the inventory says is not quarantined")
        for case in failed:
            if case.test_id != test:
                others[case.test_id] = None
        if problems:
            verdict.reasons += problems
            verdict.lines += problems
            verdict.lines += [f"    {ln}" for ln in failing_lines(directory / "logs" / f"{name}-{i}.log")]
            verdict.lines += [f"    {c.test_id}: {c.message.splitlines()[0] if c.message else ''}" for c in mine if c.outcome == "failed"]
    verdict.other = list(others)
    verdict.lines = verdict.lines[:FAILING_LINES_TOTAL]
    return verdict


def _pct(x: float) -> str:
    return f"{x * 100:.1f}%"


def render_verdict(result: dict, baseline_md: str) -> str:
    lines = []
    if result["scope"] == "test":
        why = "the baseline reproduced the failure with the test alone"
    else:
        why = "the baseline did not reproduce the failure with the test alone, so the flake may need its neighbours"
    lines.append(f"**Stress scope:** {result['scope']} ({why}).")
    if baseline_md:
        lines.append(baseline_md.strip())
    p = result.get("p")
    if result.get("bound") == "unknown":
        scale = result.get("scale") or {}
        lines.append(
            f"**Iterations:** N = {result['n']}, the pass-scope cap. There is no measured rate at pass scope, so the "
            f"false-pass probability is **unknown** (weak evidence). For scale, a no-op candidate would pass {result['n']} "
            f"runs {_pct(scale.get('0.05', 0))} of the time against a flake with p = 0.05, and "
            f"{_pct(scale.get('0.15', 0))} against p = 0.15."
        )
    elif p is not None:
        how = "ceil(ln 0.05 / ln(1 - p)), at least 20" if result["bound"] == "reached" else f"the time cap of {result['cap']}, which binds"
        weak = " This is weak evidence." if result.get("weak") else ""
        lines.append(
            f"**Iterations:** p = {p} from the baseline, N = {result['n']} ({how}; cap {result['cap']}). A no-op candidate "
            f"would still pass {result['n']} clean runs with probability (1 - p)^N = {_pct(result['false_pass'])}.{weak} "
            "That is the false-pass probability at the measured rate, not a confidence bound."
        )
    lines.append(
        f"**Result:** {result['verdict']}. {result['completed']} of {result['iterations']} iterations completed; the target "
        f"failed in {result['target_failures']}. Machine: {result['cores']} cores, {result['spinners']} induced spinners, "
        f"load1m {result['load1m']} as observed."
    )
    if result["other_failures"]:
        lines.append("**Other tests that failed in the same iterations** (they decide nothing at pass scope):\n\n"
                     + "\n".join(f"- `{t}`" for t in result["other_failures"]))
    if result["protected"]:
        lines.append("**Protected files touched**, so this candidate is not eligible for ready and a human must judge this change:\n\n"
                     + "\n".join(f"- `{p}`" for p in result["protected"]))
    if result["reasons"]:
        lines.append("**Why it failed:**\n\n" + "\n".join(f"- {r}" for r in result["reasons"][:20]))
    lines.append(LIMIT_SENTENCE)
    return "\n\n".join(lines) + "\n"


def run_judge(args) -> int:
    directory = args.dir
    quarantined = args.quarantined == "yes"
    planned = json.loads(args.plan.read_text()) if args.plan else {}
    protected = []
    if args.protected_touched and args.protected_touched.exists():
        protected = [ln.strip() for ln in args.protected_touched.read_text().splitlines() if ln.strip()]
    v = judge(directory, args.scope, args.test, args.iterations, quarantined)
    rows = read_rows(directory)
    loads = sorted({r.load1m for r in rows if r.load1m}, key=lambda s: float(s) if re.fullmatch(r"[0-9.]+", s) else 0)
    verdict = "fail" if v.reasons else ("ineligible" if protected else "pass")
    result = {
        "verdict": verdict, "scope": args.scope, "iterations": args.iterations, "completed": v.completed,
        "target_failures": v.target_failures, "reasons": v.reasons, "other_failures": v.other,
        "cores": rows[0].cores if rows else "unknown", "spinners": rows[0].spinners if rows else "unknown",
        "load1m": (loads[0] if len(loads) == 1 else f"{loads[0]} to {loads[-1]}") if loads else "unknown",
        "protected": protected,
    }
    for key in ("n", "p", "cap", "bound", "false_pass", "weak", "scale"):
        result[key] = planned.get(key)
    baseline = args.baseline_md.read_text() if args.baseline_md and args.baseline_md.exists() else ""
    (directory / "verdict.json").write_text(json.dumps(result, indent=1) + "\n")
    (directory / "verdict.md").write_text(render_verdict(result, baseline))
    (directory / "failing-lines.txt").write_text("\n".join(v.lines) + ("\n" if v.lines else ""))
    print(f"flake-verify: verdict {verdict}", file=sys.stderr)
    return {"pass": 0, "fail": 1, "ineligible": 3}[verdict]


# --- quarantine ---------------------------------------------------------------------------


def quarantined(test: str, inventory: Path, root: Path) -> str:
    """yes when exactly one `.flaky(issue:)` row names this test's function in
    its module's tests and that row's file declares its innermost suite; no
    when none does; ambiguous otherwise. The retry check cannot decide which
    records to expect for an ambiguous target."""
    classname, _, _ = test.rpartition("/")
    module, *suites = classname.split(".")
    func = fl.function_name(test)
    rows = []
    for line in inventory.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[1] == func and parts[0].startswith(f"Tests/{module}/"):
            rows.append(parts[0])
    if not rows:
        return "no"
    if not suites:
        return "yes" if len(rows) == 1 else "ambiguous"
    suite = suites[-1]
    declares = re.compile(rf"\b(struct|class|enum|actor|extension)\s+{re.escape(suite)}\b")
    matching = []
    for path in rows:
        try:
            if declares.search((root / path).read_text(errors="replace")):
                matching.append(path)
        except OSError:
            pass
    if len(matching) == 1:
        return "yes"
    if not matching:
        # Every row names a same-named function in another suite: a test's
        # function sits in its suite's body or an extension of it, so the file
        # that holds it declares the suite.
        return "no"
    return "ambiguous"


# --- CLI ----------------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="flake-verify.py")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("choose-scope")
    p.add_argument("--test", required=True)
    p.add_argument("--dir", type=Path, required=True)
    p.add_argument("--quarantined", choices=("yes", "no"), required=True)
    p.add_argument("--iterations", type=int, required=True)
    p.add_argument("--max-excluded", type=int, required=True)
    p = sub.add_parser("plan")
    p.add_argument("--scope", choices=("test", "pass"), required=True)
    p.add_argument("--baseline-dir", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--min-n", type=int, required=True)
    for name in ("allotment", "rebuild", "test-t", "test-w", "pass-t", "pass-w"):
        p.add_argument(f"--{name}", type=float, required=True)
    p = sub.add_parser("judge")
    p.add_argument("--scope", choices=("test", "pass"), required=True)
    p.add_argument("--test", required=True)
    p.add_argument("--dir", type=Path, required=True)
    p.add_argument("--iterations", type=int, required=True)
    p.add_argument("--quarantined", choices=("yes", "no"), required=True)
    p.add_argument("--protected-touched", type=Path)
    p.add_argument("--plan", type=Path)
    p.add_argument("--baseline-md", type=Path)
    p = sub.add_parser("quarantined")
    p.add_argument("--test", required=True)
    p.add_argument("--inventory", type=Path, required=True)
    p.add_argument("--root", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "choose-scope":
            return choose_scope(args.dir, args.test, args.quarantined == "yes", args.iterations, args.max_excluded)
        if args.command == "plan":
            caps = (cap(args.allotment, args.rebuild, args.test_w, args.test_t), cap(args.allotment, args.rebuild, args.pass_w, args.pass_t))
            f = v = 0
            if args.scope == "test":
                f = int((args.baseline_dir / "f").read_text())
                v = int((args.baseline_dir / "v").read_text())
                if v == 0 or f == 0:
                    print("flake-verify: test scope needs a baseline with a reproduction", file=sys.stderr)
                    return 2
            result = plan(args.scope, f, v, args.min_n, *caps)
            args.out.write_text(json.dumps(result, indent=1) + "\n")
            print(json.dumps(result))
            return 0
        if args.command == "judge":
            return run_judge(args)
        answer = quarantined(args.test, args.inventory, args.root)
        print(answer)
        return 2 if answer == "ambiguous" else 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"flake-verify: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
