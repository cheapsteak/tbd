#!/usr/bin/env python3
"""Validate step for the claude-review-v2 pipeline.

Deterministic bookend that runs AFTER the model review session
(docs/specs/2026-08-03-pr-review-fanout-design.md §3.2, §3.4, §3.5). It:

- schema-validates every specialist findings file and the merged review-result,
- with `--expected-specialists`, checks that every named specialist actually
  produced a VALID findings file (a partial fan-out must never read as a clean
  run), reporting separately whether a lens produced nothing at all, produced a
  file the schema rejected, or — when NOTHING at all reached disk, neither a
  findings file nor a review-result.json — whether the session stalled before
  reviewing anything. Omitting the flag requests no such
  check; supplying it while naming no specialist is a broken invocation and
  fails closed rather than skipping the check,
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
import re
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


def parse_expected_specialists(raw: str | None) -> list[str]:
    """Split the `--expected-specialists` value into names, in declared order.

    Two spellings of "nothing" must not read alike, and telling them apart is
    what keeps this a fail-CLOSED gate:

    - **Flag omitted** (`None`) — the caller requests no completeness check.
      Returns `[]`, which every downstream check reads as "no claim was made
      about which lenses should have reported". The e2e suite runs a single
      lens this way.
    - **Flag supplied, naming no lens** (`''`, whitespace, bare separators) —
      the caller meant to declare a set and declared nothing. This is what the
      workflow produces when `--expected-specialists "$REVIEW_SPECIALISTS"`
      expands an unset or blank variable, and reading it as "no check
      requested" would silently disable BOTH the completeness check and the
      session-stall class, so a half-finished fan-out with a valid result file
      would report APPROVE. Raises instead: an unusable invocation is a broken
      gate, not a permissive one.
    """
    if raw is None:
        return []
    names = [name.strip() for name in raw.split(",") if name.strip()]
    if not names:
        raise ValueError(
            f"--expected-specialists was supplied as {raw!r} but names no "
            "specialist. Omit the flag to skip the completeness check; an "
            "empty value is a broken invocation (usually REVIEW_SPECIALISTS "
            "unset or blank in the workflow) and would disable both the "
            "completeness check and the session-stall diagnosis — refusing to "
            "compute a verdict"
        )
    return names


_FINDINGS_FILENAME_RE = re.compile(r"\Afindings-(?P<name>.+)\.json\Z")


def specialist_name_from_path(path: str) -> str | None:
    """Derive the specialist name from a `findings-<name>.json` path.

    Used only to attribute a file that FAILED schema validation: its declared
    `specialist` field is untrustworthy (the file may not even parse), but the
    filename is dictated by the orchestrator prompt. Returns None for a name
    that doesn't fit the convention — the caller then reports the plainer
    "no findings file" diagnostic rather than guessing.
    """
    match = _FINDINGS_FILENAME_RE.match(Path(path).name)
    return match.group("name") if match else None


def missing_specialist_report(missing: list[str], rejected: list[str]) -> str:
    """Compose the fail-closed diagnostic for expected specialists that
    contributed no VALID findings, distinguishing the two causes.

    Both causes fail closed identically; only the sentence differs, and the
    difference matters. "That review lens never ran" points an operator at an
    orchestrator race. When the lens ran and its file was merely rejected by
    the validator a moment earlier, that sentence is false and sends the
    operator hunting a race that isn't there — the real cause is the schema
    error printed just above.
    """
    rejected_set = set(rejected)
    absent = [name for name in missing if name not in rejected_set]
    invalid = [name for name in missing if name in rejected_set]

    clauses = []
    if absent:
        clauses.append(
            "expected specialist(s) produced no findings file: "
            f"{', '.join(absent)} — that review lens never ran "
            "(orchestrator may have merged before all specialists completed)"
        )
    if invalid:
        clauses.append(
            "expected specialist(s) produced a findings file that FAILED "
            f"validation: {', '.join(invalid)} — that review lens DID run, but "
            "its output was rejected by the schema errors above, so its "
            "findings were discarded"
        )
    return "; ".join(clauses) + "; failing closed"


STALL_REPORT = (
    "the review session produced NOTHING: no specialist findings file and no "
    "review-result.json. This is an INFRASTRUCTURE failure — the session ended "
    "before any lens reported — and is not a review verdict: no code was "
    "reviewed. Re-running the check may clear it, because the failure is a "
    "race. If it recurs, see "
    "docs/specs/2026-08-10-review-orchestrator-liveness-design.md; failing closed"
)


def is_session_stall(
    expected: list[str],
    seen: list[str],
    rejected: list[str],
    result_present: bool,
    any_specialist_file: bool,
) -> bool:
    """True when the session produced no output of any kind.

    Distinct from a partial fan-out, and the distinction sends an operator to a
    different place. A lens that reported, or a file the schema rejected, both
    prove the session ran and the review is the thing that went wrong. NOTHING
    on disk means the session never got far enough to review anything, and the
    per-lens diagnostic's "orchestrator may have merged before all specialists
    completed" is then a false lead — no merge was attempted.

    Both file-shaped inputs are about PRESENCE, never validity, because the
    claim being made is "nothing reached disk":

    - `result_present` is whether review-result.json EXISTS, not whether it
      passed the schema. The Stop hook releases the session the moment that
      file parses as JSON, so "present but schema-invalid" is a normal terminal
      state; reading validity here would announce that the session produced
      nothing while its result file sits on disk, and would suppress the schema
      error naming the actual defect.
    - `any_specialist_file` is whether the specialist glob matched ANY file.
      `seen` and `rejected` are populated per-lens, so a matched file that
      cannot be attributed to a lens — `findings-.json`, which fits the glob
      but not the `findings-<name>.json` convention — appears in neither, and
      inferring the stall from those two lists alone would announce that the
      session produced nothing directly beneath that file's own parse error.

    Requires a declared expected set: without one there is no claim to make
    about which lenses should have reported.
    """
    if result_present or not expected:
        return False
    return not any_specialist_file and not seen and not rejected


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


def read_infrastructure_failure(path: str) -> str | None:
    """The session's deterministic fail-closed channel for "I cannot review".

    When the review session cannot produce the PR's diff at all (the pinned
    merge-base diff itself errors), it is told to write review-result.json as
    `{"infrastructure_failure": "<why>"}` instead of inventing an empty review
    — because an empty findings array computes as APPROVE, which would turn an
    unreviewed PR into a green required check. This reader returns that message
    (whitespace-collapsed, capped so a runaway string cannot mangle the
    single-line ::error:: annotation) when the file is a JSON object carrying a
    non-empty string under that key, and None otherwise. Missing or unparseable
    files are None on purpose: those states belong to the stall and schema
    diagnostics, which name them more precisely.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    return infrastructure_failure_message(data)


def infrastructure_failure_message(data: dict) -> str | None:
    """The dict's infrastructure_failure message, normalized, or None.

    Whitespace-collapsed and capped so a runaway or multi-line string cannot
    mangle the single-line ::error:: annotation the workflow builds from the
    last error line. Empty and non-string values are None: they are not a
    report, and the shapes that produce them belong to other diagnostics.
    """
    value = data.get("infrastructure_failure")
    if not isinstance(value, str) or not value.strip():
        return None
    return " ".join(value.split())[:500]


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
            "Omitted: no completeness check (any non-empty glob passes). "
            "Supplied but naming no specialist: an error, not a skip."
        ),
    )
    args = parser.parse_args()

    # Checked before any file is read, so a broken invocation cannot reach the
    # verdict write below under any circumstances.
    try:
        expected = parse_expected_specialists(args.expected_specialists)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        print("validation FAILED — no verdict written (gate fails closed)")
        return 1

    # The infrastructure-failure channel preempts every other check: the
    # session is saying it could not review at all, and the one wrong response
    # to that is computing a verdict from whatever else reached disk. Exiting
    # here writes no verdict.txt, the enforce step fails closed, nothing is
    # posted, and no patch-id/verdict marker is recorded — so the failure is
    # never cached against the diff the way a REJECT would be.
    infra = read_infrastructure_failure(args.result_file)
    if infra is not None:
        print(
            "error: the review session reported a review-infrastructure "
            f"failure and reviewed nothing: {infra} — this is NOT a verdict "
            "on the PR; re-run the check",
            file=sys.stderr,
        )
        print("validation FAILED — no verdict written (gate fails closed)")
        return 1

    failed = False

    specialist_paths = sorted(glob.glob(args.specialist_files))
    glob_empty = not specialist_paths

    specialist_ids: list[str] = []
    seen_specialists: list[str] = []
    rejected_specialists: list[str] = []
    infra_reports: list[tuple[str, str]] = []
    for path in specialist_paths:
        try:
            data = validate_findings_file(path)
        except SchemaValidationError as exc:
            print(f"error: {exc}", file=sys.stderr)
            failed = True
            # Remember WHICH lens this rejected file belonged to, so the
            # completeness diagnostic below can say "ran but was rejected"
            # instead of the false "never ran".
            name = specialist_name_from_path(path)
            if name is not None:
                rejected_specialists.append(name)
            continue
        # A specialist's own fail-closed channel, schema-blessed so the signal
        # is machine-read rather than prose in a subagent summary the
        # orchestrator may not relay. Without it, a specialist whose pinned
        # diff errored has only an empty findings array to offer — which
        # computes as APPROVE. The schema scopes the field: findings alongside
        # it are a self-contradiction it rejects, so a file that reaches here
        # with the field is a lens that reviewed nothing.
        specialist_infra = infrastructure_failure_message(data)
        if specialist_infra is not None:
            infra_reports.append((str(data["specialist"]), specialist_infra))
        seen_specialists.append(data["specialist"])
        specialist_ids.extend(finding["id"] for finding in data["findings"])
        if specialist_infra is None:
            print(f"ok: {path} ({len(data['findings'])} finding(s))")

    # Specialist infrastructure reports preempt every later check, exactly like
    # the result-level channel: the run is an infrastructure failure, and the
    # disposition/schema errors that would otherwise print afterwards would
    # displace this as the LAST error line — the one the workflow annotates —
    # sending an operator after the wrong problem.
    if infra_reports:
        for name, message in infra_reports:
            print(
                f"error: specialist {name!r} reported a review-infrastructure "
                f"failure and reviewed nothing: {message} — this is NOT a "
                "verdict on the PR; re-run the check",
                file=sys.stderr,
            )
        print("validation FAILED — no verdict written (gate fails closed)")
        return 1

    # PRESENCE, decided before validity: a result file that exists but fails
    # the schema is a session that reached its merge and got it wrong, not a
    # session that produced nothing — and the difference is what decides
    # whether the schema error below is printed or suppressed.
    result_present = Path(args.result_file).exists()

    result = None
    result_error = None
    try:
        result = validate_result_file(args.result_file)
        print(f"ok: {args.result_file}")
    except SchemaValidationError as exc:
        result_error = str(exc)

    if is_session_stall(
        expected,
        seen_specialists,
        rejected_specialists,
        result_present,
        not glob_empty,
    ):
        # One decisive line instead of three true-but-misleading ones. The
        # empty-glob and per-lens messages are suppressed here deliberately:
        # they describe a review that went wrong, and this is a session that
        # never reviewed anything. The suppressed result error is likewise only
        # ever "no such file" — a stall requires the result file to be ABSENT,
        # so a schema rejection can never be swallowed here.
        print(f"error: {STALL_REPORT}", file=sys.stderr)
        failed = True
    else:
        if glob_empty:
            # Fail closed: specialists that never wrote files is
            # indistinguishable from a session that died mid-fan-out.
            print(
                f"error: no specialist findings files match {args.specialist_files!r}",
                file=sys.stderr,
            )
            failed = True
        if expected:
            missing = missing_specialists(expected, seen_specialists)
            if missing:
                # Fail closed either way: a specialist that contributed no
                # VALID findings is indistinguishable from a clean run without
                # this check. The message distinguishes the two causes so an
                # operator isn't sent hunting an orchestrator race that isn't
                # there.
                print(
                    "error: "
                    f"{missing_specialist_report(missing, rejected_specialists)}",
                    file=sys.stderr,
                )
                failed = True
        if result_error is not None:
            print(f"error: {result_error}", file=sys.stderr)
            failed = True

    if expected:
        unexpected = sorted(set(seen_specialists) - set(expected))
        if unexpected:
            print(
                "warning: findings file(s) from unexpected specialist(s): "
                f"{', '.join(unexpected)} — not in --expected-specialists; "
                "validated and merged as usual"
            )

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
