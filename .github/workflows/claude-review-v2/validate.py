#!/usr/bin/env python3
"""Validate step for the claude-review-v2 pipeline.

Deterministic bookend that runs AFTER the model review session
(docs/specs/2026-08-03-pr-review-fanout-design.md §3.2, §3.4, §3.5). It:

- schema-validates every specialist findings file and the merged review-result,
- with `--expected-specialists`, checks that every named specialist actually
  produced a findings file (a partial fan-out must never read as a clean run),
- checks the disposition list COVERS every specialist finding ID (presence only —
  the disposition's judgment is never evaluated here, spec §3.4),
- computes the verdict from the merged findings' severities (the model never
  types the verdict) and writes it to verdict.txt.

Any validation failure or uncovered finding exits non-zero: the gate fails
closed. Pure policy functions take plain data; main() is the only I/O shell.

`jsonschema` (pip-installed in CI) is imported lazily inside the validation
functions so the pure functions — and prepare.py — never need it.
"""

from __future__ import annotations

import argparse
import glob
import json
import sys
from pathlib import Path

_SCHEMAS_DIR = Path(__file__).resolve().parent / "schemas"


class SchemaValidationError(Exception):
    """A findings/result file failed schema validation; message names the file
    and the failing field."""


# --- pure policy ------------------------------------------------------------

_REJECT_SEVERITIES = frozenset({"HIGH", "MEDIUM"})
_KNOWN_SEVERITIES = frozenset({"HIGH", "MEDIUM", "MINOR"})


def verdict_from_findings(findings: list[dict]) -> str:
    """REJECT iff any finding carries severity HIGH or MEDIUM, else APPROVE.

    Severity is compared case-sensitively against the schema enum; an unknown
    severity raises rather than silently approving (an invalid file should have
    failed schema validation — never map "can't read it" to APPROVE).
    """
    for finding in findings:
        severity = finding.get("severity")
        if severity not in _KNOWN_SEVERITIES:
            raise ValueError(
                f"finding {finding.get('id', '<no id>')!r} has unknown severity "
                f"{severity!r} (expected one of {sorted(_KNOWN_SEVERITIES)}) — "
                "refusing to compute a verdict"
            )
        if severity in _REJECT_SEVERITIES:
            return "REJECT"
    return "APPROVE"


def missing_specialists(expected: list[str], seen: list[str]) -> list[str]:
    """Return expected specialist names with no findings file, in expected order.

    Set membership only: duplicates in `seen` are fine (two files for the same
    specialist is last-write-wins upstream, not this function's business), and
    names in `seen` that were never expected are ignored here — main() reports
    those as a warning, not a failure.
    """
    seen_set = set(seen)
    return [name for name in expected if name not in seen_set]


def check_disposition(
    specialist_ids: list[str], disposition: list[dict]
) -> list[str]:
    """Return specialist finding IDs with no disposition entry.

    Coverage check only (spec §3.4): the disposition's CONTENT — whether a drop
    or downgrade was justified — is a judgment left visible to humans in the
    review comment, never judged here.
    """
    covered = {entry.get("id") for entry in disposition}
    return [finding_id for finding_id in specialist_ids if finding_id not in covered]


# --- schema validation (I/O + lazy jsonschema import) -----------------------


def _validate_file(path: str, schema_filename: str) -> dict:
    try:
        import jsonschema
    except ImportError as exc:  # pragma: no cover - environment misconfiguration
        raise SchemaValidationError(
            f"cannot validate {path}: the 'jsonschema' package is not installed "
            f"(pip install jsonschema) — failing closed ({exc})"
        ) from exc

    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise SchemaValidationError(f"{path}: not readable as JSON: {exc}") from exc

    with open(_SCHEMAS_DIR / schema_filename, encoding="utf-8") as handle:
        schema = json.load(handle)

    validator_cls = jsonschema.validators.validator_for(schema)
    errors = sorted(
        validator_cls(schema).iter_errors(data),
        key=lambda err: list(err.absolute_path),
    )
    if errors:
        details = "; ".join(
            f"at {'/'.join(str(part) for part in err.absolute_path) or '<root>'}: "
            f"{err.message}"
            for err in errors
        )
        raise SchemaValidationError(f"{path}: schema validation failed: {details}")
    return data


def validate_findings_file(path: str) -> dict:
    """Validate one specialist findings file; returns the parsed data.

    Raises SchemaValidationError naming the file and failing field."""
    return _validate_file(path, "findings.schema.json")


def validate_result_file(path: str) -> dict:
    """Validate the merged review-result file; returns the parsed data.

    Raises SchemaValidationError naming the file and failing field."""
    return _validate_file(path, "review-result.schema.json")


# --- main (the only I/O shell) ----------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--specialist-files",
        required=True,
        help="glob for the specialist findings files, e.g. 'findings-*.json'",
    )
    parser.add_argument(
        "--result-file", required=True, help="path to review-result.json"
    )
    parser.add_argument(
        "--expected-specialists",
        default=None,
        help=(
            "comma-separated specialist names that must each have produced a "
            "findings file, e.g. 'correctness,conventions'. "
            "Omitted: no completeness check (any non-empty glob passes)."
        ),
    )
    args = parser.parse_args()

    failed = False

    specialist_paths = sorted(glob.glob(args.specialist_files))
    if not specialist_paths:
        # Fail closed: specialists that never wrote files is indistinguishable
        # from a session that died mid-fan-out.
        print(
            f"error: no specialist findings files match {args.specialist_files!r}",
            file=sys.stderr,
        )
        failed = True

    specialist_ids: list[str] = []
    seen_specialists: list[str] = []
    for path in specialist_paths:
        try:
            data = validate_findings_file(path)
        except SchemaValidationError as exc:
            print(f"error: {exc}", file=sys.stderr)
            failed = True
            continue
        seen_specialists.append(data["specialist"])
        specialist_ids.extend(finding["id"] for finding in data["findings"])
        print(f"ok: {path} ({len(data['findings'])} finding(s))")

    if args.expected_specialists is not None:
        expected = [
            name.strip()
            for name in args.expected_specialists.split(",")
            if name.strip()
        ]
        missing = missing_specialists(expected, seen_specialists)
        if missing:
            # Fail closed: a specialist with no findings file means that whole
            # review lens never ran (e.g. the orchestrator merged before all
            # background specialists completed) — indistinguishable from a
            # clean run without this check.
            print(
                "error: expected specialist(s) produced no findings file: "
                f"{', '.join(missing)} — that review lens never ran "
                "(orchestrator may have merged before all specialists "
                "completed); failing closed",
                file=sys.stderr,
            )
            failed = True
        unexpected = sorted(set(seen_specialists) - set(expected))
        if unexpected:
            print(
                "warning: findings file(s) from unexpected specialist(s): "
                f"{', '.join(unexpected)} — not in --expected-specialists; "
                "validated and merged as usual"
            )

    result = None
    try:
        result = validate_result_file(args.result_file)
        print(f"ok: {args.result_file}")
    except SchemaValidationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        failed = True

    if result is not None:
        uncovered = check_disposition(specialist_ids, result["disposition"])
        if uncovered:
            print(
                "error: disposition list does not account for specialist "
                f"finding(s): {', '.join(uncovered)} — every specialist finding "
                "needs a kept/merged/downgraded/dropped entry",
                file=sys.stderr,
            )
            failed = True

    if failed or result is None:
        print("validation FAILED — no verdict written (gate fails closed)")
        return 1

    try:
        verdict = verdict_from_findings(result["findings"])
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        print("validation FAILED — no verdict written (gate fails closed)")
        return 1

    with open("verdict.txt", "w", encoding="utf-8") as handle:
        handle.write(verdict)
    print(f"verdict: {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
