#!/usr/bin/env bash
# Tests for scripts/sweep-branch-dbs.sh — run: bash scripts/sweep-branch-dbs.test.sh
# No Postgres, no `tbd`, no real worktree: every external command is a fake
# behind the script's BRANCHDB_* seams, driven by files in a temp dir.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F`/"$t" below
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/sweep-branch-dbs.sh"
# shellcheck source=/dev/null
source "$SCRIPT"   # source-guard prevents main() from running

FAIL=0
assert_eq()        { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains()  { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }
assert_lacks()     { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] contains [$3]"; FAIL=1; fi; }
mktmpd()           { mktemp -d "${TMPDIR:-/tmp}/branchdb-test.XXXXXX"; }

# --- fake Postgres -----------------------------------------------------------
# $F/dbs         "name<TAB>bytes" rows (the cluster's databases)
# $F/recovery    pg_is_in_recovery() answer (default f)
# $F/down        if present, every psql call fails like a refused connection
# $F/conns/<db>  pg_stat_activity count for <db> (default 0)
# $F/dropped     names the fake dropdb was asked to drop, one per line
# $F/psql.log    every SQL string psql received
_mk_fakes() {
  local f="$1"
  mkdir -p "$f/conns"; : > "$f/dbs"; : > "$f/dropped"; : > "$f/psql.log"
  cat > "$f/psql" <<'EOF'
#!/usr/bin/env bash
F="$(cd "$(dirname "$0")" && pwd)"
sql=""; while (( $# )); do [[ "$1" == "-c" ]] && { sql="$2"; shift; }; shift; done
printf '%s\n' "$sql" >> "$F/psql.log"
if [[ -e "$F/down" ]]; then echo 'psql: error: FATAL:  the database system is in recovery mode' >&2; exit 2; fi
case "$sql" in
  *pg_is_in_recovery*) cat "$F/recovery" 2>/dev/null || echo f ;;
  *pg_stat_activity*)  db="${sql#*\'}"; db="${db%\'*}"; cat "$F/conns/$db" 2>/dev/null || echo 0 ;;
  *pg_database*)       cat "$F/dbs" ;;
  *) echo "unexpected sql: $sql" >&2; exit 3 ;;
esac
EOF
  cat > "$f/dropdb" <<'EOF'
#!/usr/bin/env bash
F="$(cd "$(dirname "$0")" && pwd)"
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" >> "$F/dropped"
EOF
  chmod +x "$f/psql" "$f/dropdb"
}

# _run FAKEDIR ARGS... -> combined output of the script with every seam faked.
# The TBD listing is "unavailable" (`false`) unless TBD_JSON names a file, so no
# case can ever reach a real `tbd`.
_run() {
  local f="$1"; shift
  local tbd_cmd=false; [[ -n "${TBD_JSON:-}" ]] && tbd_cmd="cat $(printf '%q' "$TBD_JSON")"
  BRANCHDB_PSQL_CMD="$f/psql" BRANCHDB_DROPDB_CMD="$f/dropdb" \
  BRANCHDB_TBD_LIST_CMD="$tbd_cmd" \
  BRANCHDB_DF_CMD="printf 'Filesystem 1K-blocks Used Available\nfake 100 50 1000\n'" \
    "${BASH:-bash}" "$SCRIPT" "$@" 2>&1
}

# A fixture: a root with worktrees "Feature-One" and "keep_me", and a cluster
# holding their databases, one orphan, foreign/protected names and an
# unrelated database.
_fixture() {
  T="$(mktmpd)"; F="$T/pg"; _mk_fakes "$F"
  mkdir -p "$T/wt/repo/Feature-One" "$T/wt/repo/keep_me"
  printf '%s\t%s\n' \
    app_db_feature_one 1048576 \
    app_db_keep_me 1048576 \
    app_db_gone_branch 2097152 \
    app_db_Weird 10 \
    other_db 10 \
    postgres 10 > "$F/dbs"
}
_dropped() { tr '\n' ' ' < "$F/dropped" | sed 's/ $//'; }

# --- label rule --------------------------------------------------------------

test_label_rule() {
  assert_eq "lowercased, dash to underscore" "feature_one" "$(label_for /x/y/Feature-One)"
  assert_eq "uses the basename only"          "leaf"        "$(label_for /A-B/C-D/leaf)"
  assert_eq "trailing slash ignored"          "leaf"        "$(label_for /x/leaf/)"
  assert_eq "drops chars outside [a-z0-9_]"   "fixbug12"    "$(label_for '/x/fix.bug@#1 2')"
  assert_eq "keeps digits and underscores"    "a_1_b"       "$(label_for /x/a_1-b)"
  local long="Abcdefghij-abcdefghij-abcdefghij-abcdefghij-abcdefghij-abcdefghij"
  local want="abcdefghij_abcdefghij_abcdefghij_abcdefghij_abcdefghij"; want="${want:0:54}"
  assert_eq "cut to 54 chars"                 "$want"       "$(label_for "/x/$long")"
  assert_eq "cut length is 54"                "54"          "$(label_for "/x/$long" | tr -d '\n' | wc -c | tr -d ' ')"
  assert_eq "all-invalid basename is empty"   ""            "$(label_for '/x/...')"
}

test_labels_match_both_prefix_directions() {
  labels_match abc abc        && r=y || r=n; assert_eq "equal matches" y "$r"
  labels_match abcdef abc     && r=y || r=n; assert_eq "db is a truncation of the live label -> match" y "$r"
  labels_match abc abcdef     && r=y || r=n; assert_eq "live label is a prefix of the db -> match (KEEP)" y "$r"
  labels_match abc abd        && r=y || r=n; assert_eq "divergent names do not match" n "$r"
}

test_prefix_validation() {
  valid_prefix app_db_ && r=y || r=n;   assert_eq "plain prefix ok" y "$r"
  valid_prefix 'a"b' && r=y || r=n;     assert_eq "quote rejected" n "$r"
  valid_prefix 'a-b' && r=y || r=n;     assert_eq "dash rejected" n "$r"
  valid_prefix 'a%' && r=y || r=n;      assert_eq "LIKE wildcard rejected" n "$r"
  local out; out="$("${BASH:-bash}" "$SCRIPT" --prefix 'x;drop' --root /tmp 2>&1)"; local rc=$?
  assert_eq "bad prefix exits 2" 2 "$rc"
  out="$("${BASH:-bash}" "$SCRIPT" --root /tmp 2>&1)"; rc=$?
  assert_eq "missing prefix exits 2" 2 "$rc"; assert_contains "missing prefix explained" "$out" "--prefix is required"
}

# --- sweep -------------------------------------------------------------------

test_dry_run_reports_and_drops_nothing() {
  _fixture
  local out; out="$(_run "$F" --prefix app_db_ --root "$T/wt/*/*")"
  assert_contains "live db kept"      "$out" "KEEP live app_db_feature_one"
  assert_contains "second live kept"  "$out" "KEEP live app_db_keep_me"
  assert_contains "orphan reported"   "$out" "ORPHAN app_db_gone_branch 2.0 MiB"
  assert_contains "foreign name kept" "$out" "KEEP foreign app_db_Weird"
  assert_contains "total line"        "$out" "TOTAL kept=3 orphans=1 orphan_size=2.0 MiB"
  assert_lacks    "unprefixed ignored" "$out" "other_db"
  assert_eq       "dry-run dropped nothing" "" "$(_dropped)"
  rm -rf "$T"
}

test_apply_drops_only_orphans() {
  _fixture
  local out; out="$(_run "$F" --prefix app_db_ --root "$T/wt/*/*" --apply)"
  assert_contains "drop reported" "$out" "DROPPED app_db_gone_branch"
  assert_contains "df delta printed" "$out" "df delta:"
  assert_eq "only the orphan was dropped" "app_db_gone_branch" "$(_dropped)"
  rm -rf "$T"
}

test_connection_at_drop_time_keeps_db() {
  _fixture
  printf '%s\t%s\n' app_db_also_gone 5 >> "$F/dbs"
  echo 1 > "$F/conns/app_db_gone_branch"   # someone connected after the scan
  local out; out="$(_run "$F" --prefix app_db_ --root "$T/wt/*/*" --apply)"
  assert_contains "busy orphan kept" "$out" "KEEP busy app_db_gone_branch (1 connections)"
  assert_eq "busy orphan not dropped; idle orphan dropped" "app_db_also_gone" "$(_dropped)"
  assert_contains "connection count re-queried" "$(cat "$F/psql.log")" "datname = 'app_db_gone_branch'"
  rm -rf "$T"
}

test_truncated_live_label_keeps_longer_and_shorter_db() {
  T="$(mktmpd)"; F="$T/pg"; _mk_fakes "$F"
  local base="a-very-long-worktree-name-that-runs-well-past-the-label-limit-of-54"
  mkdir -p "$T/wt/$base" "$T/wt/short"
  local l; l="$(label_for "$T/wt/$base")"
  printf '%s\t1\n' "app_db_$l" "app_db_${l:0:40}" "app_db_short_and_more" "app_db_unrelated" > "$F/dbs"
  local out; out="$(_run "$F" --prefix app_db_ --root "$T/wt/*")"
  assert_contains "exact 54-char label kept"        "$out" "KEEP live app_db_$l "
  assert_contains "further-truncated name kept"      "$out" "KEEP live app_db_${l:0:40} "
  assert_contains "longer name over a live label kept" "$out" "KEEP live app_db_short_and_more"
  assert_contains "unrelated is the only orphan"     "$out" "orphans=1"
  rm -rf "$T"
}

test_empty_live_label_keeps_everything() {
  _fixture
  mkdir -p "$T/wt/repo/@@"   # basename yields an empty label
  local out; out="$(_run "$F" --prefix app_db_ --root "$T/wt/*/*" --apply)"
  assert_contains "empty label warned" "$out" "empty label"
  assert_contains "orphan kept by the empty label" "$out" "KEEP live app_db_gone_branch"
  assert_eq "nothing dropped" "" "$(_dropped)"
  rm -rf "$T"
}

test_protected_names_never_touched() {
  T="$(mktmpd)"; F="$T/pg"; _mk_fakes "$F"; mkdir -p "$T/wt/x"
  printf '%s\t1\n' postgres template0 template1 > "$F/dbs"
  local out; out="$(_run "$F" --prefix t --root "$T/wt/*" --apply; _run "$F" --prefix post --root "$T/wt/*" --apply)"
  assert_lacks "template0 never listed" "$out" "template0"
  assert_lacks "postgres never listed"  "$out" "postgres"
  assert_eq "nothing dropped" "" "$(_dropped)"
  rm -rf "$T"
}

# --- refusals and skips --------------------------------------------------------

test_refuses_empty_scan() {
  _fixture
  mkdir -p "$T/empty"
  local out rc
  out="$(_run "$F" --prefix app_db_ --apply)"; rc=$?
  assert_eq "no roots and no tbd -> exit 1" 1 "$rc"
  assert_contains "no-roots refusal explained" "$out" "REFUSE"
  out="$(_run "$F" --prefix app_db_ --root "$T/empty/*" --apply)"; rc=$?
  assert_eq "root matching nothing -> exit 1" 1 "$rc"
  echo '[]' > "$T/tbd.json"
  out="$(TBD_JSON="$T/tbd.json" _run "$F" --prefix app_db_ --apply)"; rc=$?
  assert_eq "tbd reports zero worktrees -> exit 1" 1 "$rc"
  assert_contains "empty-scan refusal explained" "$out" "zero worktree paths"
  assert_eq "refusals dropped nothing" "" "$(_dropped)"
  assert_eq "refusals never queried postgres" "" "$(cat "$F/psql.log")"
  rm -rf "$T"
}

test_one_bad_root_refuses_even_with_a_good_one() {
  _fixture
  local out rc; out="$(_run "$F" --prefix app_db_ --root "$T/wt/*/*" --root "$T/typo/*" --apply)"; rc=$?
  assert_eq "typo'd root -> exit 1" 1 "$rc"
  assert_eq "nothing dropped" "" "$(_dropped)"
  rm -rf "$T"
}

test_tbd_listing_is_a_root() {
  _fixture
  # Only TBD knows about gone_branch's worktree (dir need not exist under a root).
  printf '[{"path":"%s","status":"active"},{"path":"/x/old","status":"archived"}]\n' "$T/elsewhere/gone-branch" > "$T/tbd.json"
  printf '%s\t1\n' app_db_old >> "$F/dbs"
  local out; out="$(TBD_JSON="$T/tbd.json" _run "$F" --prefix app_db_ --root "$T/wt/*/*")"
  assert_contains "tbd-listed worktree keeps its db" "$out" "KEEP live app_db_gone_branch"
  assert_contains "archived worktree does not keep its db" "$out" "ORPHAN app_db_old"
  rm -rf "$T"
}

test_skips_when_in_recovery() {
  _fixture
  echo t > "$F/recovery"
  local out rc; out="$(_run "$F" --prefix app_db_ --root "$T/wt/*/*" --apply)"; rc=$?
  assert_eq "recovery skip exits 0" 0 "$rc"
  assert_contains "recovery skip explained" "$out" "SKIP: Postgres is in recovery"
  assert_eq "nothing dropped in recovery" "" "$(_dropped)"
  assert_lacks "no listing in recovery" "$(cat "$F/psql.log")" "pg_database"
  rm -rf "$T"
}

test_skips_when_connection_fails() {
  _fixture
  : > "$F/down"
  local out rc; out="$(_run "$F" --prefix app_db_ --root "$T/wt/*/*" --apply)"; rc=$?
  assert_eq "connection failure skip exits 0" 0 "$rc"
  assert_contains "connection failure explained" "$out" "SKIP: cannot connect"
  assert_contains "server message surfaced" "$out" "in recovery mode"
  assert_eq "nothing dropped when down" "" "$(_dropped)"
  rm -rf "$T"
}

# --- single-target mode ----------------------------------------------------------

test_single_target_drops_exactly_one() {
  _fixture
  local out; out="$(_run "$F" --prefix app_db_ --worktree "$T/wt/repo/Feature-One" --apply)"
  assert_contains "target reported" "$out" "ORPHAN app_db_feature_one"
  assert_eq "only the target dropped" "app_db_feature_one" "$(_dropped)"
  rm -rf "$T"
}

test_single_target_dry_run_default_and_absent() {
  _fixture
  local out; out="$(_run "$F" --prefix app_db_ --worktree "$T/wt/repo/Feature-One")"
  assert_contains "dry-run explained" "$out" "dry-run"
  assert_eq "single dry-run dropped nothing" "" "$(_dropped)"
  out="$(_run "$F" --prefix app_db_ --worktree "$T/wt/repo/never-had-one" --apply)"
  assert_contains "absent db reported" "$out" "ABSENT app_db_never_had_one"
  assert_eq "absent db dropped nothing" "" "$(_dropped)"
  rm -rf "$T"
}

test_single_target_keeps_db_shared_with_another_live_worktree() {
  _fixture
  mkdir -p "$T/other/Feature-One"   # same basename under a different root
  local out; out="$(_run "$F" --prefix app_db_ --root "$T/other/*" --worktree "$T/wt/repo/Feature-One" --apply)"
  assert_contains "shared db kept" "$out" "KEEP shared app_db_feature_one"
  assert_eq "shared db not dropped" "" "$(_dropped)"
  rm -rf "$T"
}

test_single_target_honours_recovery_and_connections() {
  _fixture
  echo t > "$F/recovery"
  local out; out="$(_run "$F" --prefix app_db_ --worktree "$T/wt/repo/Feature-One" --apply)"
  assert_contains "single mode skips in recovery" "$out" "SKIP"
  echo f > "$F/recovery"; echo 2 > "$F/conns/app_db_feature_one"
  out="$(_run "$F" --prefix app_db_ --worktree "$T/wt/repo/Feature-One" --apply)"
  assert_contains "single mode keeps a busy db" "$out" "KEEP busy app_db_feature_one"
  assert_eq "single mode dropped nothing" "" "$(_dropped)"
  rm -rf "$T"
}

test_host_and_port_pass_through() {
  _fixture
  cat > "$F/dropdb" <<'EOF'
#!/usr/bin/env bash
F="$(cd "$(dirname "$0")" && pwd)"; printf '%s\n' "$*" >> "$F/dropped"
EOF
  _run "$F" --prefix app_db_ --root "$T/wt/*/*" --host db.local --port 5433 --apply >/dev/null
  assert_contains "dropdb got host and port" "$(_dropped)" "-h db.local -p 5433"
  rm -rf "$T"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
exit $FAIL
