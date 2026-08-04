#!/usr/bin/env python3
"""Comment-body renderer for the claude-review-v2 pipeline.

Owns the construction of v2's single per-PR comment
(docs/specs/2026-08-03-pr-review-fanout-design.md §3.5). The workflow calls it
and pipes stdout into the body file; the upsert itself (find the App's newest
sentinel-led comment → PATCH, else POST) stays in the workflow shell.

Two modes:

- `review`     — the body posted after a full review: the three marker lines,
                 the model's `comment_body` prose (or a machine-rendered
                 fallback when that prose is missing), then the attribution.
- `skip-note`  — the prior comment's body with the "review skipped" note
                 re-applied, or a fresh markers-only body when the prior
                 comment has vanished.

Invariants every rendered body holds, in both modes:

- the three marker lines are the first three lines, in a fixed order,
- sections are separated by exactly one blank line,
- model prose is emitted verbatim — never interpolated into a shell command,
  never pattern-matched, never rewritten,
- rendering NEVER fails: unreadable or malformed input yields a valid degraded
  body plus a warning on stderr, which the workflow surfaces as `::warning::`.
  The step's pass/fail is governed by validate.py, never by this script.

All policy lives in pure functions (no clock, no subprocess, no network — every
input is a parameter); main() is the only I/O shell. Python 3 stdlib only.
"""

from __future__ import annotations

import argparse
import json
import sys

# --- sentinels --------------------------------------------------------------

# Opens every v2 comment body. The workflow's upsert matches the App's newest
# comment whose body STARTS WITH this line, so it must stay line 1.
COMMENT_SENTINEL = "<!-- claude-review-v2 -->"

# Marks a skip note as workflow-authored provenance. Skip notes are stripped by
# this sentinel — never by their prose, which a review discussing this very
# workflow can quote verbatim.
SKIP_NOTE_SENTINEL = "<!-- claude-review-v2-skip-note -->"

# Skip notes written before the sentinel existed carry no provenance at all.
# They are recognized by this prefix, and ONLY in the trailing position (see
# strip_skip_notes) — a rendered body always ends with the attribution line, so
# nothing the model wrote can occupy that position.
_LEGACY_SKIP_NOTE_PREFIX = "> ⏭️ Review skipped"


# --- section assembly -------------------------------------------------------


def _join_sections(sections: list[str]) -> str:
    """Join non-empty sections with exactly one blank line between them."""
    return "\n\n".join(
        section.strip("\n") for section in sections if section.strip() != ""
    )


def marker_block(patch_id: str, verdict: str) -> str:
    """The three machine-read marker lines, in the order prepare.py expects.

    An empty patch id renders an empty marker value, which prepare.py's
    hex-only matcher rejects — the next run then full-reviews, the safe
    direction.
    """
    return "\n".join(
        [
            COMMENT_SENTINEL,
            f"<!-- last-reviewed-patch-id: {patch_id} -->",
            f"<!-- last-verdict: {verdict} -->",
        ]
    )


def attribution_line(repo: str, base_ref: str) -> str:
    """The one-line provenance footer that closes every rendered review body."""
    return (
        f"_Posted by the [claude-review-v2 shadow check](https://github.com/"
        f"{repo}/blob/{base_ref}/.github/workflows/claude-code-review-v2.yml) — "
        "this comment is updated in place on each run._"
    )


# --- fallback rendering -----------------------------------------------------


def _finding_bullet(finding: dict) -> str:
    """One markdown bullet for a finding: severity, location, title, body."""
    severity = str(finding.get("severity") or "").strip() or "UNKNOWN"
    path = str(finding.get("file") or "").strip()
    line = finding.get("line")
    location = f"{path}:{line}" if path and isinstance(line, int) else path
    title = str(finding.get("title") or "").strip() or "(no title recorded)"

    bullet = f"- **{severity}**"
    if location:
        bullet += f" — `{location}`"
    bullet += f" — {title}"

    body = str(finding.get("body") or "").strip()
    if body:
        indented = "\n".join(
            f"  {row}" if row.strip() else "" for row in body.split("\n")
        )
        bullet += f"\n{indented}"
    return bullet


def fallback_body(findings: list[dict], verdict: str) -> str:
    """Render a review body from the findings alone, for a run whose prose is blank.

    A REJECT is computed from finding severities, independently of the prose —
    so a run can reject with nothing visible to explain it. This renders that
    explanation from the machine-readable record instead of posting markers
    alone.
    """
    if not findings:
        return (
            "_This run produced no review prose and recorded no findings. "
            f"Computed verdict: **{verdict}**._"
        )
    lead = (
        "_This run produced no review prose, so the findings below are "
        "rendered from `review-result.json` by the workflow rather than "
        f"written by the reviewer. Computed verdict: **{verdict}**._"
    )
    bullets = "\n".join(_finding_bullet(finding) for finding in findings)
    return f"{lead}\n\n{bullets}"


def unreadable_result_body(verdict: str) -> str:
    """Body for a run whose review-result.json is missing or unparseable."""
    return (
        "_This run's `review-result.json` could not be read, so neither review "
        "prose nor findings are available here. Computed verdict: "
        f"**{verdict}**._"
    )


# --- review-mode body -------------------------------------------------------


def prose_of(result: dict | None) -> str:
    """The model's `comment_body`, or "" when absent, non-string, or blank."""
    if not isinstance(result, dict):
        return ""
    prose = result.get("comment_body")
    if not isinstance(prose, str) or prose.strip() == "":
        return ""
    return prose


def findings_of(result: dict | None) -> list[dict]:
    """The merged findings list, or [] when absent or not a list of objects."""
    if not isinstance(result, dict):
        return []
    findings = result.get("findings")
    if not isinstance(findings, list):
        return []
    return [item for item in findings if isinstance(item, dict)]


def render_review_body(
    patch_id: str,
    verdict: str,
    result: dict | None,
    repo: str,
    base_ref: str,
) -> tuple[str, str | None]:
    """Render the post-review comment body.

    `result` is review-result.json's parsed contents, or None when the file was
    missing or unparseable. Returns (body, warning) — `warning` is None on the
    normal path and a one-line degradation reason otherwise, which the workflow
    surfaces as a `::warning::`.
    """
    markers = marker_block(patch_id, verdict)
    attribution = attribution_line(repo, base_ref)

    if result is None:
        return (
            _join_sections([markers, unreadable_result_body(verdict), attribution]),
            "review-result.json was missing or unreadable — posted the verdict "
            "markers with a note in place of the review",
        )

    prose = prose_of(result)
    if prose:
        return _join_sections([markers, prose, attribution]), None

    findings = findings_of(result)
    warning = (
        f"review-result.json carried no comment_body prose — rendered a "
        f"machine fallback from {len(findings)} finding(s)"
        if findings
        else "review-result.json carried no comment_body prose and no findings "
        "— posted the verdict markers with a note"
    )
    return (
        _join_sections([markers, fallback_body(findings, verdict), attribution]),
        warning,
    )


# --- skip-mode body ---------------------------------------------------------


def skip_note(verdict: str, prior_comment_found: bool = True) -> str:
    """The one-line "review skipped" note, carrying its provenance sentinel."""
    note = (
        "> ⏭️ Review skipped — diff unchanged since the last review (patch-id "
        f"match). Re-asserting the recorded verdict: {verdict}."
    )
    if not prior_comment_found:
        note += (
            " (The prior review comment could not be found to update, so its "
            "findings are not reproduced here.)"
        )
    return f"{note} {SKIP_NOTE_SENTINEL}"


def strip_skip_notes(body: str) -> str:
    """Remove previously appended skip notes from the END of a comment body.

    Skip notes are appended after the attribution line, so they are exactly the
    trailing block; stripping walks backwards from the end and stops at the
    first line that is neither blank nor a skip note. Model prose therefore
    cannot be eaten — a rendered body always ends with the attribution, which
    halts the walk before any prose line is reached, and a prose line that
    merely quotes the note's text sits above it untouched.
    """
    lines = body.split("\n")
    while lines:
        last = lines[-1]
        if last.strip() == "":
            lines.pop()
            continue
        if SKIP_NOTE_SENTINEL in last or last.startswith(_LEGACY_SKIP_NOTE_PREFIX):
            lines.pop()
            continue
        break
    return "\n".join(lines)


def render_skip_body(
    prior_body: str,
    patch_id: str,
    verdict: str,
    repo: str,
    base_ref: str,
) -> tuple[str, str | None]:
    """Render the comment body for a skipped review.

    With a prior v2 comment body, everything already in it is kept — markers
    (so the next identical push skips again) and review prose (so a re-asserted
    REJECT still shows the author what to fix) — with any earlier skip note
    replaced rather than accumulated. Without one, a fresh markers-only body is
    rendered in the same shape the review path writes, so the next run's fetch
    matches it. Returns (body, warning).
    """
    if prior_body.startswith(COMMENT_SENTINEL):
        kept = strip_skip_notes(prior_body)
        return _join_sections([kept, skip_note(verdict)]), None
    markers = marker_block(patch_id, verdict)
    attribution = attribution_line(repo, base_ref)
    return (
        _join_sections(
            [markers, attribution, skip_note(verdict, prior_comment_found=False)]
        ),
        "no prior v2 comment body to update — rendered a fresh markers-only "
        "body carrying the skip note",
    )


# --- main (the only I/O shell) ----------------------------------------------


def load_result(path: str) -> tuple[dict | None, str | None]:
    """Read review-result.json; returns (result, warning), never raises.

    A missing file, unreadable file, invalid JSON, or a non-object payload all
    yield (None, reason) — the renderer degrades, it does not fail.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as exc:
        return None, f"could not read {path}: {exc}"
    except json.JSONDecodeError as exc:
        return None, f"{path} is not valid JSON: {exc}"
    if not isinstance(data, dict):
        return None, f"{path} is not a JSON object (got {type(data).__name__})"
    return data, None


def _read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)

    def add_common(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("--patch-id", default="", help="head patch-id (hex or empty)")
        sub.add_argument("--verdict", required=True, help="APPROVE or REJECT")
        sub.add_argument("--repo", required=True, help="owner/name")
        sub.add_argument("--base-ref", required=True, help="PR base branch name")

    review = subparsers.add_parser(
        "review", help="render the body posted after a full review"
    )
    add_common(review)
    review.add_argument(
        "--result-file",
        required=True,
        help="path to review-result.json; missing or malformed degrades to a "
        "machine-rendered body rather than failing",
    )

    skip = subparsers.add_parser(
        "skip-note", help="render the body for a skipped review"
    )
    add_common(skip)
    skip.add_argument(
        "--prior-body-file",
        default=None,
        help="file holding the prior v2 comment body; missing or empty renders "
        "a fresh markers-only body",
    )

    args = parser.parse_args(argv)

    if args.mode == "review":
        result, read_warning = load_result(args.result_file)
        body, render_warning = render_review_body(
            args.patch_id, args.verdict, result, args.repo, args.base_ref
        )
        warning = read_warning or render_warning
    else:
        prior_body = _read_text(args.prior_body_file) if args.prior_body_file else ""
        body, warning = render_skip_body(
            prior_body, args.patch_id, args.verdict, args.repo, args.base_ref
        )

    print(body)
    if warning:
        print(warning, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
