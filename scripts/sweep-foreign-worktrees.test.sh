#!/usr/bin/env bash
# Tests for scripts/sweep-foreign-worktrees.sh — run: bash scripts/sweep-foreign-worktrees.test.sh
# Needs git and jq; no build. Every fixture is a real git repo with real worktrees
# under one mktemp -d root, and every external tool (tbd, gh, lsof, fetch) is a fake
# behind the script's seams. Real `tbd`/`gh`/`lsof` are shadowed on PATH by shims that
# fail loudly, and SWEEP_FW_REQUIRE_SEAMS=1 makes the script itself refuse to run
# with any seam unset — so no test can fall through to this machine's real state.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F`/"$t" below
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/sweep-foreign-worktrees.sh"
# shellcheck source=/dev/null
source "$SCRIPT"   # source-guard prevents main() from running; gives us canon_path

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }
assert_lacks()    { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] unexpectedly has [$3]"; FAIL=1; fi; }
assert_dir()      { assert_eq "$1" "true" "$([[ -d "$2" ]] && echo true || echo false)"; }
assert_no_dir()   { assert_eq "$1" "false" "$([[ -d "$2" ]] && echo true || echo false)"; }
assert_file()     { assert_eq "$1" "true" "$([[ -f "$2" ]] && echo true || echo false)"; }

# --- isolation ---------------------------------------------------------------
ROOT="$(canon_path "$(mktemp -d "${TMPDIR:-/tmp}/sweep-fw-test.XXXXXX")")"
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home"; mkdir -p "$HOME"
export TBD_HOME="$ROOT/home/tbd"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Acme Dev" GIT_AUTHOR_EMAIL="dev@example.invalid"
export GIT_COMMITTER_NAME="Acme Dev" GIT_COMMITTER_EMAIL="dev@example.invalid"

# Shims: any reach for a real tool fails the run loudly.
mkdir -p "$ROOT/shim"
for tool in tbd gh lsof; do
  printf '#!/bin/sh\necho "REAL %s REACHED — a seam is unset" >&2\nexit 97\n' "$tool" > "$ROOT/shim/$tool"
  chmod +x "$ROOT/shim/$tool"
done
export PATH="$ROOT/shim:$PATH"

# Generic fakes, driven by files in $FAKE_DIR (one per test).
mkdir -p "$ROOT/fakes"
cat > "$ROOT/fakes/tbd" <<'EOF'
#!/bin/sh
[ -f "$FAKE_DIR/tbd-fail" ] && exit 1
case "$*" in
  "repo list --json") cat "$FAKE_DIR/tbd-repos.json" ;;
  "worktree list --json") cat "$FAKE_DIR/tbd-wts.json" ;;
  "worktree list --status archived --json") cat "$FAKE_DIR/tbd-archived.json" ;;
  *) echo "fake tbd: unexpected args: $*" >&2; exit 3 ;;
esac
EOF
cat > "$ROOT/fakes/gh" <<'EOF'
#!/bin/sh
[ -f "$FAKE_DIR/gh-fail" ] && exit 1
key=""
while [ $# -gt 0 ]; do
  case "$1" in --head) key="head-$2"; shift ;; --search) key="search-$2"; shift ;; esac
  shift
done
echo "$key" >> "$FAKE_DIR/gh-calls"
if [ -f "$FAKE_DIR/gh-$key.json" ]; then cat "$FAKE_DIR/gh-$key.json"; else echo "[]"; fi
EOF
cat > "$ROOT/fakes/fetch" <<'EOF'
#!/bin/sh
echo "$2" >> "$FAKE_DIR/fetch-calls"
exit 1
EOF
chmod +x "$ROOT/fakes/"*
export SWEEP_FW_TBD_BIN="$ROOT/fakes/tbd" SWEEP_FW_GH_BIN="$ROOT/fakes/gh" SWEEP_FW_FETCH_BIN="$ROOT/fakes/fetch"
NO_LIVE="printf 'p1\\nfcwd\\nn/\\n'"   # one unrelated cwd: a working lsof that sees nothing under any fixture
export SWEEP_FW_LSOF_CMD="$NO_LIVE"
export SWEEP_FW_REQUIRE_SEAMS=1

# run the script as a subprocess; refuse outright if a seam were somehow unset
run_sweep() {
  local v
  for v in SWEEP_FW_TBD_BIN SWEEP_FW_GH_BIN SWEEP_FW_LSOF_CMD SWEEP_FW_FETCH_BIN FAKE_DIR; do
    [[ -n "${!v:-}" ]] || { echo "HARNESS: $v unset; aborting before reaching any real tool" >&2; exit 99; }
  done
  [[ "$TBD_HOME" == "$ROOT"/* && "$HOME" == "$ROOT"/* ]] || { echo "HARNESS: HOME/TBD_HOME escaped the fixture root" >&2; exit 99; }
  bash "$SCRIPT" "$@" 2>&1
}

# --- fixtures ----------------------------------------------------------------
N=0
# new_case -> fresh fixture dir T with a repo (one commit on main); fakes report nothing.
new_case() {
  N=$((N + 1)); T="$ROOT/case$N"; mkdir -p "$T/fake"
  export TBD_HOME="$T/tbdhome"
  export FAKE_DIR="$T/fake"
  echo "[]" > "$FAKE_DIR/tbd-repos.json"; echo "[]" > "$FAKE_DIR/tbd-wts.json"; echo "[]" > "$FAKE_DIR/tbd-archived.json"
  export SWEEP_FW_LSOF_CMD="$NO_LIVE"
  REPO="$T/repo"
  git init -q -b main "$REPO"
  echo base > "$REPO/README"; git -C "$REPO" add README; git -C "$REPO" commit -qm "base"
}

# age PATH... -> push every file and dir under each PATH far into the past
age() { local p; for p in "$@"; do find "$p" -exec touch -t 200001010000.00 {} + 2>/dev/null; done; }

age_wt() {  # age_wt WT -> the worktree plus its gitdir HEAD/index
  local gd; gd="$(git -C "$1" rev-parse --absolute-git-dir)"
  age "$1" "$gd/HEAD" "$gd/index"
}

# mk_wt NAME -> sets WT to a new idle linked worktree on branch NAME with one commit
mk_wt() {
  WT="$T/wts/$1"
  git -C "$REPO" worktree add -q -b "$1" "$WT" main
  echo "$1" > "$WT/work.txt"; git -C "$WT" add work.txt; git -C "$WT" commit -qm "work on $1"
  WT="$(canon_path "$WT")"
}

# merged_pr BRANCH OID [NUM] -> the fake gh reports a merged PR for BRANCH with head OID
merged_pr() {
  printf '[{"number":%s,"headRefOid":"%s","url":"https://example.invalid/acme/acme-app/pull/%s"}]\n' \
    "${3:-7}" "$2" "${3:-7}" > "$FAKE_DIR/gh-head-$1.json"
}

# mk_auto NAME -> an AUTO-eligible candidate: merged PR contains HEAD, clean, idle
mk_auto() { mk_wt "$1"; merged_pr "$1" "$(git -C "$WT" rev-parse HEAD)"; age_wt "$WT"; }

listed() { git -C "$REPO" worktree list --porcelain | grep -c "^worktree .*/$1\$"; }
today() { date +%Y%m%d; }

# --- seams / harness ---------------------------------------------------------

test_require_seams_refuses_when_a_seam_is_unset() {
  new_case
  local out; out="$(SWEEP_FW_GH_BIN="" bash "$SCRIPT" --repo "$REPO" 2>&1)"; local st=$?
  assert_eq "unset seam -> exit 2" "2" "$st"
  assert_contains "unset seam named" "$out" "SWEEP_FW_GH_BIN is unset"
}

# --- auto tier: report -------------------------------------------------------

test_auto_candidate_reported_and_dry_run_removes_nothing() {
  new_case; mk_auto feat-a
  local out; out="$(run_sweep --repo "$REPO")"
  assert_contains "AUTO line" "$out" "AUTO merged-pr#7 $WT"
  assert_contains "summary says report only" "$out" "report only"
  assert_dir "dry-run leaves the worktree" "$WT"
  assert_eq "still listed by git" "1" "$(listed feat-a)"
  assert_lacks "main worktree never a candidate" "$out" " $(canon_path "$REPO")"$'\n'
}

test_dirty_tracked_change_is_kept() {
  new_case; mk_auto feat-a
  echo changed >> "$WT/work.txt"; age_wt "$WT"
  assert_contains "dirty kept" "$(run_sweep --repo "$REPO")" "KEEP dirty $WT"
}

test_untracked_file_is_dirty() {
  new_case; mk_auto feat-a
  echo x > "$WT/stray.txt"; age_wt "$WT"
  assert_contains "untracked file kept" "$(run_sweep --repo "$REPO")" "KEEP dirty $WT"
}

test_context_only_untracked_is_still_clean() {
  new_case; mk_auto feat-a
  mkdir -p "$WT/.context"; echo notes > "$WT/.context/notes.md"; age_wt "$WT"
  assert_contains ".context-only is AUTO" "$(run_sweep --repo "$REPO")" "AUTO merged-pr#7 $WT"
}

test_no_merged_pr_is_kept() {
  new_case; mk_wt feat-a; age_wt "$WT"
  assert_contains "no PR kept" "$(run_sweep --repo "$REPO" --apply)" "KEEP no-merged-pr $WT"
  assert_dir "no-PR worktree survives --apply" "$WT"
}

test_head_moved_past_merged_pr_is_follow_up_and_never_removed() {
  new_case; mk_wt feat-a
  merged_pr feat-a "$(git -C "$WT" rev-parse HEAD)" 12
  echo more >> "$WT/work.txt"; git -C "$WT" commit -qam "follow-up commit"
  age_wt "$WT"
  local out; out="$(run_sweep --repo "$REPO" --apply)"
  assert_contains "FOLLOW-UP reported" "$out" "FOLLOW-UP head-moved-past-merged-pr#12 $WT"
  assert_dir "FOLLOW-UP survives --apply" "$WT"
}

test_live_cwd_under_worktree_is_kept() {
  new_case; mk_auto feat-a
  mkdir -p "$WT/sub"; age_wt "$WT"
  export SWEEP_FW_LSOF_CMD="printf 'p1\nfcwd\nn%s\n' '$WT/sub'"
  local out; out="$(run_sweep --repo "$REPO" --apply)"
  assert_contains "live cwd kept" "$out" "KEEP live-process $WT"
  assert_dir "live worktree survives --apply" "$WT"
}

test_live_cwd_through_symlink_is_kept() {
  new_case; mk_auto feat-a
  ln -s "$T/wts" "$T/wts-link"
  export SWEEP_FW_LSOF_CMD="printf 'p1\nfcwd\nn%s\n' '$T/wts-link/feat-a'"
  assert_contains "symlinked cwd canonicalized" "$(run_sweep --repo "$REPO")" "KEEP live-process $WT"
}

test_live_binary_under_worktree_is_kept() {
  new_case; mk_auto feat-a
  echo "bin/" >> "$(git -C "$WT" rev-parse --git-common-dir)/info/exclude"   # ignored, so still clean
  mkdir -p "$WT/bin"; : > "$WT/bin/tool"; age_wt "$WT"
  export SWEEP_FW_LSOF_CMD="printf 'p1\nfcwd\nn/\nftxt\nn%s\n' '$WT/bin/tool'"
  assert_contains "live binary kept" "$(run_sweep --repo "$REPO")" "KEEP live-process $WT"
}

test_live_cwd_in_sibling_prefix_does_not_count() {
  new_case; mk_auto feat-a
  mkdir -p "$T/wts/feat-ab"
  export SWEEP_FW_LSOF_CMD="printf 'p1\nfcwd\nn%s\n' '$T/wts/feat-ab'"
  assert_contains "prefix sibling is not under" "$(run_sweep --repo "$REPO")" "AUTO merged-pr#7 $WT"
}

test_empty_or_failing_lsof_makes_sweep_keep_everything() {
  local seam out
  for seam in 'printf ""' 'false' 'printf "p1\nfcwd\nn/\n"; exit 1'; do
    new_case; mk_auto feat-a
    export SWEEP_FW_LSOF_CMD="$seam"
    out="$(run_sweep --repo "$REPO" --apply)"
    assert_contains "lsof [$seam] -> check unavailable" "$out" "KEEP live-check-unavailable $WT"
    assert_contains "lsof [$seam] -> warned" "$out" "live-process check unavailable"
    assert_dir "lsof [$seam] -> nothing auto-removed" "$WT"
  done
}

test_empty_or_failing_lsof_makes_salvage_remove_refuse() {
  local seam out st
  for seam in 'printf ""' 'false'; do
    new_case; mk_wt feat-op; echo x > "$WT/untracked.txt"
    export SWEEP_FW_LSOF_CMD="$seam"
    out="$(run_sweep --salvage-remove "$WT" --apply)"; st=$?
    assert_eq "lsof [$seam] -> refuse exit 2" "2" "$st"
    assert_contains "lsof [$seam] -> refusal explained" "$out" "cannot check for live processes"
    assert_dir "lsof [$seam] -> worktree survives" "$WT"
    assert_no_dir "lsof [$seam] -> no salvage step ran" "$TBD_HOME/salvage"
    assert_eq "lsof [$seam] -> no salvage ref" "" "$(git -C "$REPO" for-each-ref refs/salvage)"
  done
}

test_recently_modified_file_is_kept() {
  new_case; mk_auto feat-a
  touch "$WT/work.txt"
  assert_contains "recent mtime kept" "$(run_sweep --repo "$REPO")" "KEEP recent-activity $WT"
}

test_recent_gitdir_index_is_kept() {
  new_case; mk_auto feat-a
  touch "$(git -C "$WT" rev-parse --absolute-git-dir)/index"
  assert_contains "recent index kept" "$(run_sweep --repo "$REPO")" "KEEP recent-activity $WT"
}

test_idle_hours_zero_disables_recency() {
  new_case; mk_auto feat-a; touch "$WT/work.txt"
  assert_contains "--idle-hours 0" "$(run_sweep --repo "$REPO" --idle-hours 0)" "AUTO merged-pr#7 $WT"
}

test_report_run_does_not_defeat_the_next_idle_check() {
  new_case; mk_auto feat-a
  run_sweep --repo "$REPO" >/dev/null
  assert_contains "second run still idle" "$(run_sweep --repo "$REPO")" "AUTO merged-pr#7 $WT"
}

test_locked_worktree_is_kept() {
  new_case; mk_auto feat-a
  git -C "$REPO" worktree lock "$WT"; age_wt "$WT"
  local out; out="$(run_sweep --repo "$REPO" --apply)"
  assert_contains "locked kept" "$out" "KEEP locked $WT"
  assert_dir "locked survives --apply" "$WT"
}

test_gh_failure_is_kept() {
  new_case; mk_auto feat-a; : > "$FAKE_DIR/gh-fail"
  assert_contains "gh failure kept" "$(run_sweep --repo "$REPO" --apply)" "KEEP gh-failed $WT"
  assert_dir "gh-failure survives --apply" "$WT"
}

test_pr_head_unavailable_is_kept_after_fetch_attempt() {
  new_case; mk_wt feat-a; age_wt "$WT"
  merged_pr feat-a 0123456789abcdef0123456789abcdef01234567
  assert_contains "unavailable head kept" "$(run_sweep --repo "$REPO")" "KEEP pr-head-unavailable#7 $WT"
  assert_contains "fetch seam was tried" "$(cat "$FAKE_DIR/fetch-calls" 2>/dev/null)" "0123456789abcdef0123456789abcdef01234567"
}

test_detached_head_uses_commit_search() {
  new_case; mk_wt feat-a
  local sha; sha="$(git -C "$WT" rev-parse HEAD)"
  git -C "$WT" checkout -q --detach; age_wt "$WT"
  printf '[{"number":9,"headRefOid":"%s","url":"u"}]\n' "$sha" > "$FAKE_DIR/gh-search-$sha.json"
  assert_contains "detached AUTO via search" "$(run_sweep --repo "$REPO")" "AUTO merged-pr#9 $WT"
  assert_contains "searched by sha" "$(cat "$FAKE_DIR/gh-calls")" "search-$sha"
}

# --- discovery ---------------------------------------------------------------

test_tbd_managed_worktree_is_not_a_candidate() {
  new_case; mk_auto feat-a
  local managed="$WT"
  mk_auto feat-b
  printf '[{"path":"%s","status":"archived"}]\n' "$managed" > "$FAKE_DIR/tbd-archived.json"
  local out; out="$(run_sweep --repo "$REPO" --apply)"
  assert_lacks "archived TBD worktree skipped" "$out" "$managed"$'\n'
  assert_dir "TBD worktree untouched" "$managed"
  assert_no_dir "foreign sibling removed" "$WT"
}

test_registered_repos_are_discovered() {
  new_case; mk_auto feat-a
  printf '[{"path":"%s"},{"path":"%s/gone"}]\n' "$REPO" "$T" > "$FAKE_DIR/tbd-repos.json"
  local out; out="$(run_sweep)"
  assert_contains "registered repo walked" "$out" "AUTO merged-pr#7 $WT"
  assert_contains "missing registered repo skipped" "$out" "skip registered repo"
}

test_tbd_unreachable_refuses() {
  new_case; mk_auto feat-a; : > "$FAKE_DIR/tbd-fail"
  local out; out="$(run_sweep --repo "$REPO" --apply)"; local st=$?
  assert_eq "tbd failure -> exit 2" "2" "$st"
  assert_contains "refusal explained" "$out" "refusing"
  assert_dir "nothing removed when TBD cannot be asked" "$WT"
}

test_container_directory_is_never_a_repo() {
  new_case
  # A directory that holds worktrees but is not a repo, as TBD's own layout does.
  local container="$T/home/tbd/worktrees/wt-12345"
  mkdir -p "$container"
  git -C "$REPO" worktree add -q -b inside "$container/acme-app" main
  merged_pr inside "$(git -C "$container/acme-app" rev-parse HEAD)"; age_wt "$container/acme-app"
  echo keep > "$container/loose-file"
  local out st
  out="$(run_sweep --repo "$container" --apply)"; st=$?
  assert_eq "container --repo -> exit 2" "2" "$st"
  assert_contains "container rejected" "$out" "is not a git repository toplevel; nothing done"
  assert_dir "worktree inside container untouched" "$container/acme-app"
  assert_file "loose file in container untouched" "$container/loose-file"
  assert_eq "still listed by git" "1" "$(listed acme-app)"
  out="$(run_sweep --salvage-remove "$container" --apply)"; st=$?
  assert_eq "container --salvage-remove -> exit 2" "2" "$st"
  assert_dir "container worktree survives salvage-remove" "$container/acme-app"
  assert_no_dir "no salvage written" "$TBD_HOME/salvage"
}

test_subdirectory_of_a_worktree_is_rejected() {
  new_case; mk_wt feat-a; mkdir -p "$WT/sub"
  local out; out="$(run_sweep --salvage-remove "$WT/sub" --apply)"; local st=$?
  assert_eq "subdir -> exit 2" "2" "$st"
  assert_dir "worktree survives" "$WT"
}

# --- auto tier: apply --------------------------------------------------------

test_apply_salvages_context_then_removes() {
  new_case; mk_wt feat-a
  mkdir -p "$WT/.context"; echo "plan" > "$WT/.context/notes.md"
  merged_pr feat-a "$(git -C "$WT" rev-parse HEAD)"; age_wt "$WT"
  local out; out="$(run_sweep --repo "$REPO" --apply --salvage-dir "$T/salv")"
  assert_no_dir "AUTO worktree removed" "$WT"
  assert_eq "no longer listed by git" "0" "$(listed feat-a)"
  assert_eq ".context salvaged" "plan" "$(cat "$T/salv/$(today)/feat-a/.context/notes.md" 2>/dev/null)"
  assert_contains "removal logged" "$out" "removed: $WT"
}

test_apply_context_copy_failure_blocks_removal() {
  new_case; mk_wt feat-a
  mkdir -p "$WT/.context"; echo "plan" > "$WT/.context/notes.md"
  merged_pr feat-a "$(git -C "$WT" rev-parse HEAD)"; age_wt "$WT"
  : > "$T/salv-is-a-file"
  local out; out="$(run_sweep --repo "$REPO" --apply --salvage-dir "$T/salv-is-a-file")"; local st=$?
  assert_contains "failure explained" "$out" "NOT removing: $WT"
  assert_eq "failure -> nonzero exit" "1" "$st"
  assert_dir "worktree survives a failed salvage" "$WT"
}

# --- operator tier -----------------------------------------------------------

mk_operator_case() {  # a worktree with a commit, an uncommitted edit, an untracked file and .context
  new_case; mk_wt feat-op
  OLD_HEAD="$(git -C "$WT" rev-parse HEAD)"
  echo edited >> "$WT/work.txt"
  echo scratch > "$WT/untracked.txt"
  mkdir -p "$WT/.context"; echo "ctx" > "$WT/.context/notes.md"
  ENTRY="$TBD_HOME/salvage/$(today)/feat-op"
}

test_operator_without_apply_only_plans() {
  mk_operator_case
  local out; out="$(run_sweep --salvage-remove "$WT")"
  assert_contains "plan printed" "$out" "PLAN salvage $WT"
  assert_contains "branch shown" "$out" "branch: feat-op"
  assert_dir "worktree untouched" "$WT"
  assert_no_dir "no salvage dir created" "$TBD_HOME/salvage"
  assert_eq "no salvage ref created" "" "$(git -C "$REPO" for-each-ref refs/salvage)"
}

test_operator_salvage_writes_every_artifact_then_removes() {
  mk_operator_case
  local out; out="$(run_sweep --salvage-remove "$WT" --apply)"; local st=$?
  assert_eq "exit 0" "0" "$st"
  assert_no_dir "worktree removed" "$WT"
  assert_eq "no longer listed" "0" "$(listed feat-op)"
  local info; info="$(cat "$ENTRY/INFO.txt" 2>/dev/null)"
  assert_contains "INFO path" "$info" "path: $WT"
  assert_contains "INFO branch" "$info" "branch: feat-op"
  assert_contains "INFO HEAD" "$info" "HEAD: $OLD_HEAD"
  assert_contains "INFO last commit subject" "$info" "work on feat-op"
  assert_eq "salvage ref resolves to the old HEAD" "$OLD_HEAD" \
    "$(git -C "$REPO" rev-parse --verify -q "refs/salvage/feat-op-$(today)")"
  assert_contains "patch carries the edit" "$(cat "$ENTRY/uncommitted.patch" 2>/dev/null)" "+edited"
  assert_contains "tarball holds the untracked file" "$(tar -tzf "$ENTRY/untracked.tar.gz" 2>/dev/null)" "untracked.txt"
  assert_eq ".context copied" "ctx" "$(cat "$ENTRY/.context/notes.md" 2>/dev/null)"
}

test_operator_detached_and_clean_omits_patch() {
  new_case; mk_wt feat-op; git -C "$WT" checkout -q --detach
  run_sweep --salvage-remove "$WT" --apply >/dev/null
  local e; e="$TBD_HOME/salvage/$(today)/feat-op"
  assert_contains "INFO says DETACHED" "$(cat "$e/INFO.txt" 2>/dev/null)" "branch: DETACHED"
  assert_eq "empty patch omitted" "false" "$([[ -e "$e/uncommitted.patch" ]] && echo true || echo false)"
  assert_eq "no untracked -> no tarball" "false" "$([[ -e "$e/untracked.tar.gz" ]] && echo true || echo false)"
  assert_no_dir "removed" "$WT"
}

test_operator_untracked_over_cap_aborts() {
  mk_operator_case
  local out; out="$(run_sweep --salvage-remove "$WT" --apply --untracked-cap-mb 0)"; local st=$?
  assert_eq "over cap -> exit 1" "1" "$st"
  assert_contains "cap abort explained" "$out" "over the 0 MB cap"
  assert_contains "escape hatch named" "$out" "--allow-untracked-loss"
  assert_dir "worktree survives the cap" "$WT"
  assert_contains "file list written instead" "$(cat "$ENTRY/untracked-files.txt" 2>/dev/null)" "untracked.txt"
  assert_eq "no tarball written" "false" "$([[ -e "$ENTRY/untracked.tar.gz" ]] && echo true || echo false)"
  out="$(run_sweep --salvage-remove "$WT" --apply --untracked-cap-mb 0 --allow-untracked-loss)"
  assert_no_dir "--allow-untracked-loss proceeds" "$WT"
  assert_dir "second run used a fresh, suffixed entry" "$ENTRY-2"
  assert_eq "salvage ref suffixed, not overwritten" "$OLD_HEAD" \
    "$(git -C "$REPO" rev-parse --verify -q "refs/salvage/feat-op-$(today)-2")"
}

test_operator_salvage_step_failure_blocks_removal() {
  if [[ "$(id -u)" == "0" ]]; then echo "ok   - (skipped: root ignores file modes)"; return; fi
  mk_operator_case
  chmod 000 "$WT/.context/notes.md"
  local out; out="$(run_sweep --salvage-remove "$WT" --apply)"; local st=$?
  chmod 644 "$WT/.context/notes.md"
  assert_eq "failed step -> exit 1" "1" "$st"
  assert_contains "abort explained" "$out" "copying .context failed"
  assert_dir "worktree survives a failed step" "$WT"
  assert_file "earlier steps still ran" "$ENTRY/INFO.txt"
}

test_operator_existing_entry_is_never_overwritten() {
  mk_operator_case
  mkdir -p "$ENTRY"; echo precious > "$ENTRY/INFO.txt"
  run_sweep --salvage-remove "$WT" --apply >/dev/null
  assert_eq "old entry intact" "precious" "$(cat "$ENTRY/INFO.txt")"
  assert_file "new entry suffixed" "$ENTRY-2/INFO.txt"
}

test_operator_refuses_main_managed_and_live() {
  new_case; mk_wt feat-op
  local out st
  out="$(run_sweep --salvage-remove "$REPO" --apply)"; st=$?
  assert_eq "main refused" "2" "$st"; assert_contains "main reason" "$out" "main worktree"
  printf '[{"path":"%s","status":"active"}]\n' "$WT" > "$FAKE_DIR/tbd-wts.json"
  out="$(run_sweep --salvage-remove "$WT" --apply)"; st=$?
  assert_eq "managed refused" "2" "$st"; assert_contains "managed reason" "$out" "TBD manages"
  echo "[]" > "$FAKE_DIR/tbd-wts.json"
  export SWEEP_FW_LSOF_CMD="printf 'p1\nfcwd\nn%s\n' '$WT'"
  out="$(run_sweep --salvage-remove "$WT" --apply)"; st=$?
  assert_eq "live refused" "2" "$st"; assert_contains "live reason" "$out" "live process"
  assert_dir "worktree survives every refusal" "$WT"
  assert_no_dir "no salvage written" "$TBD_HOME/salvage"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "---"; if [[ "$FAIL" == "0" ]]; then echo "all passed"; else echo "FAILURES"; fi
exit $FAIL
