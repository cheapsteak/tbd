#!/usr/bin/env bash
# Harness for stage-loader.sh. Builds scratch loader trees under its own mktemp directory
# and removes only that directory. The real-tree case reads phone/loader and never writes
# to it.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
stage="$here/stage-loader.sh"
real_loader="$(cd "$here/../loader" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/stage-loader-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
failures=0
placeholder='https://loader-origin.invalid'
zeros='0000000000000000000000000000000000000000000000000000000000000000'

ok() { echo "ok - $1"; }
bad() { echo "not ok - $1" >&2; failures=$((failures + 1)); }

make_tree() { # $1 = dir; a small loader that stages cleanly
  mkdir -p "$1/channel" "$1/vendor/jsqr/dist"
  printf '<!doctype html>\n<meta http-equiv="Content-Security-Policy" content="script-src %s blob:">\n<script src="runner.js"></script>\n' \
    "$placeholder" >"$1/runner.html"
  printf '<!doctype html>\n<script type="module" src="main.js"></script>\n' >"$1/index.html"
  printf '// runner\n' >"$1/runner.js"
  printf '// main\n' >"$1/main.js"
  printf 'body {}\n' >"$1/loader.css"
  printf '{}\n' >"$1/manifest.webmanifest"
  printf '// noise\n' >"$1/channel/noise.js"
  printf 'MIT\n' >"$1/vendor/jsqr/LICENSE"
  printf '// jsQR\n' >"$1/vendor/jsqr/dist/jsQR.js"
  {
    printf '# name\tversion\tkind\tvalue\t[sha256]\n'
    printf 'jsqr\t1.4.0\ttarball\thttps://registry.example/jsqr-1.4.0.tgz\n'
    printf 'jsqr\t1.4.0\tintegrity\tsha512-AAAA\n'
    printf 'jsqr\t1.4.0\tprovenance\tno\n'
    printf 'jsqr\t1.4.0\tfile\tLICENSE\t%s\n' "$zeros"
    printf 'jsqr\t1.4.0\tfile\tdist/jsQR.js\t%s\n' "$zeros"
  } >"$1/vendor/vendor.lock"
}

run() { # stage-loader.sh arguments; sets rc, out (stdout) and err (stderr)
  rc=0
  out="$(bash "$stage" "$@" 2>"$tmp/stderr")" || rc=$?
  err="$(cat "$tmp/stderr")"
}

listed() { # $1 = path; true when the last run's listing holds it
  grep -Fxq -- "$1" <<<"$out"
}

untouched() { # $1 = site dir; true when a refused run left it absent
  [ ! -e "$1" ] && [ -z "$out" ]
}

# Each refusal case: a fresh tree that $2 (a function) changes, then a run that must exit 1
# and leave the site absent.
refuses() { # $1 = description, $2 = tree mutator, $3 = origin (optional)
  local t="$tmp/case$((++cases))"
  make_tree "$t"
  "$2" "$t"
  run "$t" "$t-site" "${3-https://acme.github.io}"
  if [ "$rc" -eq 1 ] && untouched "$t-site"; then ok "$1"; else bad "$1: rc=$rc out=$out err=$err"; fi
}
cases=0
same() { :; }

# --- Origins ---------------------------------------------------------------------------

stamps() { # $1 = origin
  local t="$tmp/case$((++cases))"
  make_tree "$t"
  run "$t" "$t-site" "$1"
  if [ "$rc" -eq 0 ] &&
    grep -Fq -- "content=\"script-src $1 blob:\"" "$t-site/runner.html" &&
    ! grep -Fq -- "$placeholder" "$t-site/runner.html" &&
    grep -Fq -- "$placeholder" "$t/runner.html"; then
    ok "$1 stages and stamps, and the source keeps its placeholder"
  else
    bad "$1: rc=$rc err=$err"
  fi
}
stamps https://acme.github.io
stamps http://127.0.0.1:4173
stamps http://localhost:8080
stamps https://acme-pages.example.com:8443

for origin in \
  'http://acme.example' \
  'https://acme.github.io/tbd' \
  'https://acme.github.io/' \
  "'self'" \
  'https://a.example; script-src *' \
  'https://a.example blob:' \
  "$(printf 'https://a.example\nhttps://b.example')" \
  'https://a.example:123456' \
  'https://-a.example' \
  'http://127.0.0.1.acme.example' \
  'https://a.example|x' \
  '' \
  "$placeholder"; do
  refuses "refuses the origin '$origin'" same "$origin"
done

run "$tmp/usage"
if [ "$rc" -eq 64 ]; then ok "one argument is a usage error"; else bad "one argument: rc=$rc"; fi
run a b c d
if [ "$rc" -eq 64 ]; then ok "four arguments is a usage error"; else bad "four arguments: rc=$rc"; fi

# --- Allowlist -------------------------------------------------------------------------

t="$tmp/allow"
make_tree "$t"
mkdir -p "$t/test" "$t/test/unit" "$t/docs"
printf '<p>x</p>\n' >"$t/test/x.html"
printf '// a\n' >"$t/test/a.js"
printf '// unit\n' >"$t/test/unit/b.test.js"
printf '// channel test\n' >"$t/channel/a.test.js"
printf '// top test\n' >"$t/x.test.js"
printf '# readme\n' >"$t/README.md"
printf '// hidden\n' >"$t/.hidden.js"
printf '// hidden\n' >"$t/channel/.hidden.js"
printf 'notes\n' >"$t/notes.txt"
printf '// docs\n' >"$t/docs/d.js"
printf '// not in the lock\n' >"$t/vendor/jsqr/extra.js"
printf '{}\n' >"$t/vendor/jsqr/package.json"
ln -s "$t/runner.js" "$t/linked.js"
run "$t" "$t-site" https://acme.github.io
if [ "$rc" -eq 0 ]; then ok "the allowlist tree stages"; else bad "allowlist tree: rc=$rc err=$err"; fi
for p in test/x.html test/a.js test/unit/b.test.js channel/a.test.js x.test.js README.md \
  .hidden.js channel/.hidden.js notes.txt docs/d.js vendor/vendor.lock \
  vendor/jsqr/extra.js vendor/jsqr/package.json linked.js; do
  if listed "$p" || [ -e "$t-site/$p" ] || [ -L "$t-site/$p" ]; then
    bad "$p must not be staged"
  else
    ok "$p is not staged"
  fi
done
for p in runner.html runner.js index.html main.js loader.css manifest.webmanifest \
  channel/noise.js vendor/jsqr/LICENSE vendor/jsqr/dist/jsQR.js; do
  if listed "$p" && [ -f "$t-site/$p" ]; then ok "$p is staged"; else bad "$p must be staged"; fi
done
ondisk="$(cd "$t-site" && find . ! -type d | sed 's|^\./||' | LC_ALL=C sort)"
if [ "$ondisk" = "$out" ]; then
  ok "the listing is exactly the staged files, sorted"
else
  bad "listing and site differ: listing=[$out] site=[$ondisk]"
fi

lock_row() { # $1 = tree, $2 = name, $3 = path
  printf '%s\t1.0.0\tfile\t%s\t%s\n' "$2" "$3" "$zeros" >>"$1/vendor/vendor.lock"
}
no_lock() { rm "$1/vendor/vendor.lock"; }
lock_traversal() { printf 'secret\n' >"$1/secret.js"; lock_row "$1" jsqr ../../secret.js; }
lock_absolute() { lock_row "$1" jsqr /etc/hosts; }
lock_dot_name() { mkdir -p "$1/vendor/.x"; printf '//\n' >"$1/vendor/.x/a.js"; lock_row "$1" .x a.js; }
lock_missing_file() { lock_row "$1" jsqr dist/missing.js; }
lock_symlink_dir() {
  mkdir -p "$1/elsewhere"
  printf '//\n' >"$1/elsewhere/a.js"
  ln -s "$1/elsewhere" "$1/vendor/evil"
  lock_row "$1" evil a.js
}
lock_symlink_file() { ln -s "$1/runner.js" "$1/vendor/jsqr/dist/link.js"; lock_row "$1" jsqr dist/link.js; }
refuses "a missing vendor.lock refuses" no_lock
refuses "a lock path that climbs out refuses" lock_traversal
refuses "an absolute lock path refuses" lock_absolute
refuses "a dot-named vendored library refuses" lock_dot_name
refuses "a lock-listed file that is missing refuses" lock_missing_file
refuses "a lock-listed file behind a symlinked directory refuses" lock_symlink_dir
refuses "a lock-listed symlink refuses" lock_symlink_file

# --- Names -----------------------------------------------------------------------------

# Without the name check, this page would list as the two lines index.html and runner.html,
# pass the page check and be served with the loader's origin.
newline_page() { printf '<p>x</p>\n' >"$1/$(printf 'index.html\nrunner.html')"; }
newline_channel() { printf '//\n' >"$1/channel/$(printf 'a\nb.js')"; }
space_name() { printf '//\n' >"$1/a b.js"; }
non_ascii_name() { printf '//\n' >"$1/$(printf 'caf\303\251.js')"; }
refuses "a page named with a newline refuses" newline_page
refuses "a channel file named with a newline refuses" newline_channel
refuses "a file named with a space refuses" space_name
refuses "a file named with a non-ASCII letter refuses" non_ascii_name

t="$tmp/newline-message"
make_tree "$t"
newline_page "$t"
run "$t" "$t-site" https://acme.github.io
if [ "$rc" -eq 1 ] && [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ] &&
  grep -Fq 'index.html?runner.html' <<<"$err"; then
  ok "the refusal names the file on one line, with the newline shown as '?'"
else
  bad "newline message: rc=$rc err=$err"
fi

# --- grep errors -----------------------------------------------------------------------

# A grep that cannot read a file exits 2, which must refuse rather than read as "no
# match". The shim stands in for an unreadable staged file: it fails, as grep does, for
# any path ending in /$FAIL_GREP_ON, and runs the real grep otherwise.
shim="$tmp/shim"
mkdir -p "$shim"
real_grep="$(command -v grep)"
cat >"$shim/grep" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in */"$FAIL_GREP_ON") echo "grep: $a: Permission denied" >&2; exit 2 ;; esac
done
exec "$REAL_GREP" "$@"
EOF
chmod +x "$shim/grep"

grep_fails_on() { # $1 = the staged file grep cannot read, $2 = description
  local t="$tmp/case$((++cases))"
  make_tree "$t"
  FAIL_GREP_ON="$1" REAL_GREP="$real_grep" PATH="$shim:$PATH" \
    run "$t" "$t-site" https://acme.github.io
  if [ "$rc" -eq 1 ] && untouched "$t-site" && grep -Fq 'grep could not read' <<<"$err"; then
    ok "$2"
  else
    bad "$2: rc=$rc out=$out err=$err"
  fi
}
grep_fails_on main.js "a staged file grep cannot read refuses, rather than passing the placeholder check"
grep_fails_on runner.html "a runner.html grep cannot read refuses"

# --- HTML ------------------------------------------------------------------------------

other_html() { printf '<p>x</p>\n' >"$1/other.html"; }
vendored_svg() { printf '<svg/>\n' >"$1/vendor/jsqr/icon.svg"; lock_row "$1" jsqr icon.svg; }
vendored_page() { printf '<p>x</p>\n' >"$1/vendor/jsqr/demo.HTML"; lock_row "$1" jsqr demo.HTML; }
refuses "a top-level other.html refuses" other_html
refuses "a vendored .svg refuses" vendored_svg
refuses "a vendored page in capitals refuses" vendored_page

# --- Placeholder and site directory ----------------------------------------------------

no_placeholder() { printf '<!doctype html>\n<script src="runner.js"></script>\n' >"$1/runner.html"; }
twice_lines() { printf '<!-- %s -->\n' "$placeholder" >>"$1/runner.html"; }
twice_one_line() {
  printf '<meta http-equiv="Content-Security-Policy" content="script-src %s %s">\n' \
    "$placeholder" "$placeholder" >"$1/runner.html"
}
in_main() { printf '// %s\n' "$placeholder" >>"$1/main.js"; }
in_channel() { printf '// %s\n' "$placeholder" >>"$1/channel/noise.js"; }
no_runner() { rm "$1/runner.html"; }
origin_already() { printf '<!-- https://acme.github.io -->\n' >>"$1/runner.html"; }
refuses "a missing placeholder refuses" no_placeholder
refuses "a placeholder on two lines refuses" twice_lines
refuses "a placeholder twice on one line refuses" twice_one_line
refuses "a placeholder in main.js refuses" in_main
refuses "a placeholder in channel/noise.js refuses" in_channel
refuses "a missing runner.html refuses" no_runner
refuses "a runner.html that already names the origin refuses" origin_already

t="$tmp/unstaged-placeholder"
make_tree "$t"
mkdir -p "$t/test"
printf '%s\n' "$placeholder" >"$t/test/x.js"
printf '%s\n' "$placeholder" >"$t/README.md"
run "$t" "$t-site" https://acme.github.io
if [ "$rc" -eq 0 ]; then ok "a placeholder in an unstaged file is fine"; else bad "unstaged placeholder: rc=$rc err=$err"; fi

t="$tmp/full-site"
make_tree "$t"
mkdir -p "$t-site"
printf 'keep\n' >"$t-site/keep.txt"
run "$t" "$t-site" https://acme.github.io
if [ "$rc" -eq 1 ] && [ "$(ls -A "$t-site")" = keep.txt ] && [ "$(cat "$t-site/keep.txt")" = keep ]; then
  ok "a non-empty site directory refuses and is left as it was"
else
  bad "non-empty site: rc=$rc err=$err"
fi

t="$tmp/dot-site"
make_tree "$t"
mkdir -p "$t-site"
printf 'x\n' >"$t-site/.nojekyll"
run "$t" "$t-site" https://acme.github.io
if [ "$rc" -eq 1 ]; then ok "a site directory holding only a dotfile refuses"; else bad "dotfile site: rc=$rc"; fi

t="$tmp/file-site"
make_tree "$t"
printf 'x\n' >"$t-site"
run "$t" "$t-site" https://acme.github.io
if [ "$rc" -eq 1 ]; then ok "a site path that is a file refuses"; else bad "file site: rc=$rc"; fi

t="$tmp/empty-site"
make_tree "$t"
mkdir -p "$t-site"
run "$t" "$t-site" https://acme.github.io
if [ "$rc" -eq 0 ] && [ -f "$t-site/runner.html" ]; then ok "an empty site directory stages"; else bad "empty site: rc=$rc err=$err"; fi

run "$tmp/no-such-loader" "$tmp/no-such-loader-site" https://acme.github.io
if [ "$rc" -eq 1 ] && untouched "$tmp/no-such-loader-site"; then ok "a missing loader directory refuses"; else bad "missing loader: rc=$rc"; fi

# --- The real tree ---------------------------------------------------------------------

before="$(cd "$real_loader" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort)"
run "$real_loader" "$tmp/real-site" https://acme.github.io
after="$(cd "$real_loader" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort)"
if [ "$rc" -eq 0 ]; then ok "the real phone/loader stages"; else bad "real tree: rc=$rc err=$err"; fi
for p in runner.html runner.js channel/noise.js vendor/jsqr/dist/jsQR.js; do
  if listed "$p"; then ok "the real tree stages $p"; else bad "the real tree must stage $p"; fi
done
if grep -Eq '^test/|\.test\.js$|\.md$|(^|/)\.|^vendor/vendor\.lock$' <<<"$out"; then
  bad "the real tree staged a test, doc, dotfile or the lock: $out"
else
  ok "the real tree stages nothing under test/, no *.test.js, *.md, dotfile or lock"
fi
if grep -Fq 'script-src https://acme.github.io blob:;' "$tmp/real-site/runner.html" 2>/dev/null; then
  ok "the real runner.html is stamped"
else
  bad "the real runner.html is not stamped"
fi
if [ "$before" = "$after" ]; then ok "the real tree is unchanged"; else bad "staging changed the real tree"; fi

[ "$failures" -eq 0 ] || {
  echo "stage-loader.test.sh: $failures failure(s)" >&2
  exit 1
}
echo "stage-loader.test.sh: all passed"
