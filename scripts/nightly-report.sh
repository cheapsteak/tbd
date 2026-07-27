#!/usr/bin/env bash
# scripts/nightly-report.sh — post a nightly finding as an issue comment.
#
# §9: "Failures land as issue comments — never as PR noise." That invariant is
# enforced structurally by nightly.yml's trigger set (schedule + workflow_dispatch
# only, so there is no PR for it to comment on), not by this script's manners.
#
# What this script adds is the other half: a comment that says WHERE it came
# from. A finding with no run link is a finding somebody has to go hunting for.
#
# Usage:
#   scripts/nightly-report.sh --issue 519 --title "Quarantine audit" --body-file F
#   scripts/nightly-report.sh ... --post          # actually comment (CI only)
#   scripts/nightly-report.sh --issue 519 --fixture --post
#
# DRY-RUN IS THE DEFAULT. Without --post it prints the exact comment to stdout
# and touches nothing, so the composition can be inspected and tested offline.
#
# --fixture posts the wire-verification comment: a labelled, deliberate comment
# proving `gh issue comment` actually works. A clean nightly posts NOTHING, so
# without this the reporting path would be unverified precisely when everything
# is healthy — which is this program's signature failure mode. The fixture
# comment is KEPT, not deleted: a deleted verification leaves no evidence the
# wire was ever proven.
#
# Test seams (env):
#   REPORT_GH_CMD   command standing in for `gh`   (default: gh)
#   REPORT_REPO     owner/repo                     (default: cheapsteak/tbd)
#   REPORT_RUN_URL  link back to the workflow run  (default: derived from GITHUB_*)
#   REPORT_TODAY    ISO date in the footer         (default: today, UTC)

set -uo pipefail

GH_CMD="${REPORT_GH_CMD:-gh}"
REPO="${REPORT_REPO:-cheapsteak/tbd}"

die() { echo "nightly-report: $*" >&2; exit 2; }

run_url() {
  if [[ -n "${REPORT_RUN_URL:-}" ]]; then
    printf '%s' "$REPORT_RUN_URL"
  elif [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    printf '%s/%s/actions/runs/%s' "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  else
    printf 'local run (no GITHUB_RUN_ID)'
  fi
}

compose() {
  local title="$1" body_file="$2"
  echo "### 🌙 $title"
  echo
  if [[ -n "$body_file" ]]; then
    [[ -f "$body_file" ]] || die "body file not found: $body_file"
    cat "$body_file"
  fi
  echo
  echo "---"
  echo "<sub>Nightly test-hardening workflow · ${REPORT_TODAY:-$(date -u +%Y-%m-%d)} · [run]($(run_url)) · \`scripts/nightly-report.sh\`</sub>"
}

compose_fixture() {
  cat <<'FIXTURE'
### 🔌 WIRE VERIFICATION FIXTURE — not a real report

This comment exists to prove that the nightly workflow can actually post here.

A healthy nightly posts **nothing** — so without a deliberate fixture, the
reporting path would be exercised for the first time on the night something
breaks, which is exactly when you least want to discover it does not work. That
is this program's signature failure: a mechanism that only appears to work
because it is never exercised.

It is kept rather than deleted on purpose. A deleted verification leaves no
evidence the wire was ever proven; six months from now "was the comment path
ever tested?" is answerable by scrolling, or it is answerable by nobody.

Nothing here is a finding. Real reports carry a `🌙` heading and a findings count.
FIXTURE
  echo
  echo "---"
  echo "<sub>Posted by \`scripts/nightly-report.sh --fixture\` · ${REPORT_TODAY:-$(date -u +%Y-%m-%d)} · [run]($(run_url))</sub>"
}

main() {
  local issue="" title="" body_file="" post=0 fixture=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue)     issue="${2:-}"; shift 2 ;;
      --title)     title="${2:-}"; shift 2 ;;
      --body-file) body_file="${2:-}"; shift 2 ;;
      --post)      post=1; shift ;;
      --fixture)   fixture=1; shift ;;
      *) die "unknown argument $1" ;;
    esac
  done
  [[ -n "$issue" ]] || die "--issue is required"
  [[ "$fixture" -eq 1 || -n "$title" ]] || die "--title is required"

  local comment
  if [[ "$fixture" -eq 1 ]]; then
    comment="$(compose_fixture)"
  else
    comment="$(compose "$title" "$body_file")" || exit 2
  fi

  if [[ "$post" -eq 0 ]]; then
    echo "── DRY RUN — would comment on #$issue in $REPO (pass --post to send):"
    echo
    printf '%s\n' "$comment"
    return 0
  fi

  printf '%s\n' "$comment" | "$GH_CMD" issue comment "$issue" --repo "$REPO" --body-file - \
    || die "failed to comment on #$issue"
  echo "nightly-report: commented on $REPO#$issue"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
