#!/usr/bin/env bash
# CI backstop that ensures implementation/design plans are never checked into
# the repo. This is the always-on counterpart to scripts/git-hooks/pre-commit:
# that hook only fires when a contributor installs it locally (via
# scripts/install-hooks.sh), so it silently misses anyone who hasn't — which is
# exactly how PR #317 leaked a plan. This script runs in CI (see the
# `plans-guard` job in .github/workflows/test.yml) on every PR and push, so the
# policy holds regardless of local setup.
#
# It scans the whole tracked tree (the index — what would actually be pushed),
# NOT a diff against a merge base, so it needs no fetch-depth/merge-base
# plumbing and catches pre-existing leaks as well as new ones.
#
# Two rules, both read the index (git ls-files reads the index; git grep
# --cached scans the index), so they reflect the committed/staged state that a
# push would carry — not incidental untracked worktree files:
#   Rule A — tracked-but-ignored: any file that is both tracked AND matches a
#            .gitignore rule is a leaked plan (plans live in gitignored dirs and
#            can only end up tracked via `git add -f`). The one sanctioned
#            exception is docs/superpowers/plans/CLAUDE.md, which is
#            deliberately tracked as the sole file in that gitignored dir.
#   Rule B — plan marker: any tracked *.md carrying the writing-plans header
#            marker "REQUIRED SUB-SKILL" is a plan, wherever it was placed
#            (including a non-ignored dir used to dodge .gitignore). The *.md
#            pathspec keeps this hook script itself — which contains the literal
#            marker but is not .md — from matching.
#
# Policy + rationale: docs/CLAUDE.md ("Implementation and design plans are not
# committed"). Rare intentional override at commit time (local hook only):
# ALLOW_PLAN_COMMIT=1 git commit ...
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# The exact path we deliberately track inside a gitignored plan dir.
allowlisted="docs/superpowers/plans/CLAUDE.md"

# bash 3.2 (macOS) has no `mapfile`; collect offenders with a portable
# while-loop and seed the array so `${#offenders[@]}` is legal under `set -u`
# when nothing matches.
offenders=()

# Rule A — tracked files that .gitignore would otherwise ignore.
while IFS= read -r file; do
  [ -z "$file" ] && continue
  [ "$file" = "$allowlisted" ] && continue
  offenders+=("$file")
done < <(git ls-files -ci --exclude-standard)

# Rule B — tracked *.md carrying the plan header marker. `--cached` scans the
# index (staged/committed content), matching what a push would carry.
while IFS= read -r file; do
  [ -z "$file" ] && continue
  # Skip if already reported by Rule A.
  case "$file" in
    "$allowlisted") continue ;;
  esac
  already=0
  for seen in ${offenders[@]+"${offenders[@]}"}; do
    [ "$seen" = "$file" ] && already=1 && break
  done
  [ "$already" = "1" ] && continue
  offenders+=("$file")
done < <(git grep --cached -lF "REQUIRED SUB-SKILL" -- '*.md')

if [ ${#offenders[@]} -gt 0 ]; then
  echo "[plans-guard] Refusing the tracked tree: implementation plan(s) are committed:" >&2
  for f in "${offenders[@]}"; do echo "  - $f" >&2; done
  echo "" >&2
  echo "Implementation and design plans are local scratch artifacts (see docs/CLAUDE.md)." >&2
  echo "They go stale fast and have no place in the source tree. Keep them in one of the" >&2
  echo "gitignored plan dirs and do not stage them:" >&2
  echo "    docs/plans/   docs/implementation-plans/   docs/superpowers/plans/" >&2
  echo "" >&2
  echo "If the content is worth keeping, summarize it in the PR description or promote it" >&2
  echo "to a proper doc, e.g. docs/specs/<date>-<topic>-spec.md." >&2
  echo "" >&2
  echo "NOTE: a '.gitignore: paths are ignored' error on 'git add' is intent, not an" >&2
  echo "      obstacle. Do not relocate a plan to a tracked dir to force it in." >&2
  echo "" >&2
  echo "Full policy: docs/CLAUDE.md" >&2
  exit 1
fi

echo "[plans-guard] OK — no committed implementation plans in the tracked tree."
exit 0
