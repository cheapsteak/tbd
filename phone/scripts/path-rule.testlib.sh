# shellcheck shell=bash
# shellcheck disable=SC2154 # `here` and `tmp` are the sourcing harness's
# Test support for the path rule, sourced by stage-loader.test.sh, vendor-update.test.sh and
# vendor-check.test.sh. Not a script of its own.
#
# stage-loader.sh, vendor-update.sh and vendor-check.sh each write out the rule a vendored
# library's name and file paths must pass. Each keeps its own copy because each must stay one
# self-contained file: the loader repo's deploy compares stage-loader.sh alone with main's
# (docs/phone-control-loader-repo.md), so it can source nothing. This file holds the one table
# of paths the copies must agree on, and `path_rule_check`, which every one of the three
# harnesses runs, so a copy that drifts fails all three:
# - the rule's lines must read the same, word for word, in the three scripts;
# - each script, run on each path in the table, must give that path's verdict.
#
# Each script meets a path where it would in use, with a file in place wherever the path
# leads, so that only the rule can refuse it:
# - stage-loader.sh: a `file` row of vendor/vendor.lock in a minimal loader;
# - vendor-check.sh: the same row, with the file's real checksum, in a vendor root;
# - vendor-update.sh: a <file> argument, against a package that holds the file.
#
# The caller defines `ok` and `bad`, and sets `here` (this directory) and `tmp` (a scratch
# directory it removes).

# One segment of 200 characters, inside every file system's 255-byte name limit.
path_rule_long="$(printf '%0200d' 0 | tr 0 a)"

# The table: each entry is a verdict, `good` or `bad`, a tab, and a path. No path holds a tab
# or a newline, which a lock row cannot carry. `path_rule_registry` puts every path in one
# package, where vendor-update.sh vendors each top-level license-like name it finds, so a bad
# license-like name sits under dist/ (vendor-update.test.sh tries a bad one at the top level);
# and no two paths differ only in case, which a case-insensitive file system would merge.
path_rule_cases=(
  $'good\tx.js'
  $'good\tLICENSE'
  $'good\tdist/x.js'
  $'good\tdist/x.min.js'
  $'good\tdist/a_b-c.d.js'
  $'good\t_internal/x.js'
  $'good\t9/x.js'
  $'good\tdist/a..b.js'
  $'good\ta/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/x.js'
  "good	$path_rule_long/x.js"
  $'good\tx.css'
  $'good\tdist/a.min.css'
  $'good\tLICENCE'
  $'good\tCOPYING.txt'
  $'good\tNOTICE'
  $'good\tdist/license.TXT'
  $'good\tdist/Copying'
  $'bad\t..'
  $'bad\t../x.js'
  $'bad\tdist/../x.js'
  $'bad\tdist/..'
  $'bad\t.'
  $'bad\t./x.js'
  $'bad\t.hidden.js'
  $'bad\tdist/.cache/x.js'
  $'bad\t-x.js'
  $'bad\tdist//x.js'
  $'bad\tdist/'
  $'bad\t/x.js'
  $'bad\t/dist/x.js'
  $'bad\ta b.js'
  $'bad\tdist/a b.js'
  $'bad\ta+b.js'
  $'bad\tcaf\303\251.js'
  $'bad\tdist/\342\200\256sj.x'
  $'bad\ta$b.js'
  $'bad\ta;b.js'
  $'bad\ta*b.js'
  $'bad\ta?b.js'
  $'bad\ta\\b.js'
  $'bad\ta:b.js'
  $'bad\ta\'b.js'
  $'bad\ta%2fb.js'
  $'bad\ta~b.js'
  "bad	$path_rule_long/../x.js"
  "bad	$path_rule_long/a b.js"
  $'bad\tdist/x.html'
  $'bad\tx.htm'
  $'bad\tx.xhtml'
  $'bad\tx.xht'
  $'bad\tindex.xht'
  $'bad\tx.svg'
  $'bad\tx.svgz'
  $'bad\tx.xml'
  $'bad\tx.xsl'
  $'bad\tx.xslt'
  $'bad\tx.mht'
  $'bad\tx.mhtml'
  $'bad\tx.rss'
  $'bad\tx.atom'
  $'bad\tx.shtml'
  $'bad\tx.pdf'
  $'bad\tx.json'
  $'bad\tx.wasm'
  $'bad\tdist/x.mjs'
  $'bad\tdist/x.js.map'
  $'bad\tdist/upper.JS'
  $'bad\tdist/x.js.html'
  $'bad\tdist/x.js/'
  $'bad\tREADME'
  $'bad\tdist/LICENSE.md'
  $'bad\tdist/LICENSE.html'
  $'bad\tdist/LICENSE-MIT'
  $'bad\tdist/NOTICE.txt.svg'
)

# The rule's lines in the script $1: from its opening comment through `lib_path=`.
path_rule_text() {
  awk '/^# The path rule/ { on = 1 } on { print } on && /^lib_path=/ { exit }' "$1"
}

# Writes a file at $2 under the directory $1, wherever the path leads. A path that names no
# file (`..`, `dist/`) gets none.
path_rule_place() {
  local file="$1/$2"
  { mkdir -p "$(dirname "$file")" && printf 'x\n' >"$file"; } 2>/dev/null || true
}

# The lock rows of one library `lib` listing the file at $2 under $1/lib, with its checksum
# when it exists.
path_rule_lock() {
  local sum='0000000000000000000000000000000000000000000000000000000000000000'
  if [ -f "$1/lib/$2" ]; then sum="$(shasum -a 256 "$1/lib/$2" | awk '{print $1}')"; fi
  printf '# name\tversion\tkind\tvalue\t[sha256]\n'
  printf 'lib\t1.0.0\ttarball\tfile:///lib-1.0.0.tgz\n'
  printf 'lib\t1.0.0\tintegrity\tsha512-AAAA\n'
  printf 'lib\t1.0.0\tprovenance\tno\n'
  printf 'lib\t1.0.0\tfile\t%s\t%s\n' "$2" "$sum"
}

# `good` for exit 0, `bad` for a refusal (exit 1, or 2 for vendor-update's bad usage), and
# `exit <n>` for anything else.
path_rule_verdict() {
  case "$1" in
    0) echo good ;;
    1 | 2) echo bad ;;
    *) echo "exit $1" ;;
  esac
}

# The verdict of stage-loader.sh on the path $2, in a loader built under $1.
path_rule_stage() {
  local t="$1" rc=0
  mkdir -p "$t/vendor"
  printf '<meta content="script-src https://loader-origin.invalid">\n' >"$t/runner.html"
  path_rule_place "$t/vendor/lib" "$2"
  path_rule_lock "$t/vendor" "$2" >"$t/vendor/vendor.lock"
  bash "$here/stage-loader.sh" "$t" "$t-site" https://acme.github.io >/dev/null 2>&1 || rc=$?
  path_rule_verdict "$rc"
}

# The verdict of vendor-check.sh on the path $2, in a vendor root built at $1.
path_rule_vendor_check() {
  local root="$1" rc=0
  mkdir -p "$root"
  path_rule_place "$root/lib" "$2"
  path_rule_lock "$root" "$2" >"$root/vendor.lock"
  bash "$here/vendor-check.sh" "$root" >/dev/null 2>&1 || rc=$?
  path_rule_verdict "$rc"
}

# The verdict of vendor-update.sh on the path $2, vendoring from the registry at $1 into a
# fresh vendor root $3.
path_rule_vendor_update() {
  local rc=0
  VENDOR_REGISTRY="file://$1" VENDOR_ROOT="$3" bash "$here/vendor-update.sh" lib 1.0.0 "$2" >/dev/null 2>&1 || rc=$?
  path_rule_verdict "$rc"
}

# A file:// registry serving lib@1.0.0, whose package holds a license and a file wherever each
# path in the table leads.
path_rule_registry() {
  local reg="$1" entry sum
  mkdir -p "$reg/src/package" "$reg/lib"
  printf 'MIT License\n' >"$reg/src/package/LICENSE"
  for entry in "${path_rule_cases[@]}"; do
    path_rule_place "$reg/src/package" "${entry#*$'\t'}"
  done
  tar -czf "$reg/lib-1.0.0.tgz" -C "$reg/src" package
  sum="$(openssl dgst -sha512 -binary "$reg/lib-1.0.0.tgz" | base64 | tr -d '\n')"
  printf '{"name":"lib","version":"1.0.0","dist":{"tarball":"file://%s/lib-1.0.0.tgz","integrity":"sha512-%s"}}\n' \
    "$reg" "$sum" >"$reg/lib/1.0.0"
}

# Runs the three scripts on every path in the table, and checks the rule's lines.
path_rule_check() {
  local dir="$tmp/path-rule" script text first='' entry want path got n=0 mismatches=0
  mkdir -p "$dir"

  for script in stage-loader.sh vendor-update.sh vendor-check.sh; do
    text="$(path_rule_text "$here/$script")"
    if [ -z "$text" ]; then
      bad "path rule: $script has no '# The path rule' block ending in lib_path="
      return
    fi
    if [ -z "$first" ]; then
      first="$text"
    elif [ "$text" != "$first" ]; then
      bad "path rule: $script's rule lines differ from stage-loader.sh's"
      return
    fi
  done
  ok "path rule: the rule's lines read the same in stage-loader.sh, vendor-update.sh and vendor-check.sh"

  path_rule_registry "$dir/registry"
  for entry in "${path_rule_cases[@]}"; do
    n=$((n + 1))
    want="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    got="stage-loader.sh $(path_rule_stage "$dir/stage-$n" "$path")"
    got="$got, vendor-update.sh $(path_rule_vendor_update "$dir/registry" "$path" "$dir/update-$n")"
    got="$got, vendor-check.sh $(path_rule_vendor_check "$dir/check-$n" "$path")"
    if [ "$got" != "stage-loader.sh $want, vendor-update.sh $want, vendor-check.sh $want" ]; then
      bad "path rule: '$(printf '%s' "$path" | tr -c 'A-Za-z0-9._/-' '?')' should be $want: $got"
      mismatches=$((mismatches + 1))
    fi
  done
  if [ "$mismatches" -eq 0 ]; then
    ok "path rule: the three scripts agree on all ${#path_rule_cases[@]} paths in the table"
  fi
}
