#!/usr/bin/env bash
# The flake fixer's macOS shell under the runner's bash 3.2 — run:
#   /bin/bash scripts/flake-bash32.test.sh
#
# The `fix` job runs on macOS, whose /bin/bash is GNU bash 3.2, and every
# `run:` step there runs under it: the default shell resolves `bash` to it, and
# the steps after session 1 name /bin/bash outright. The other flake harnesses
# run on Linux under bash 5, which parses and runs constructs 3.2 refuses, so
# the first live `fix` run (37845177223) died on a step they had passed.
#
# What this checks, for every `run:` script of every macOS job in
# flake-fixer.yml and every shell script those steps run there:
#   - `bash -n` under 3.2;
#   - a `case` inside `$( … )`, `<( … )` or `>( … )` whose patterns lack the
#     leading `(`. Bash 3.2 ends the substitution at the first pattern's `)`,
#     and it parses a substitution only when it runs it, so `bash -n` passes
#     and the step fails at run time – the failure 37845177223 hit;
#   - constructs bash 3.2 does not have (associative arrays, `mapfile`,
#     `${v,,}`, `|&`, `;&`, `[[ -v`, negative subscripts, …);
#   - an array that can be empty, expanded bare under `set -u`, which 3.2
#     reads as unbound (a site that cannot be empty says `# non-empty: why`);
#   - and it RUNS, under 3.2, the steps every later step depends on: the
#     environment record, the clean-environment preamble that restores it, and
#     the step that packages the attempt.
#
# It needs a bash 3.2 (FLAKE_BASH32, default /bin/bash), so it runs in the
# macOS `lint` job in test.yml. Without one it skips – except under $CI, where
# a skip would be a silent pass, so it fails.
#
# EVERY GUARD IS MUTATION-CHECKED: each check runs against the workflow and
# against a copy with the guarded-against construct put back.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2016 # literal $( ), ${ } and ${{ }} must NOT expand here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/flake-fixer.yml"
BASH32="${FLAKE_BASH32:-/bin/bash}"

# The shell scripts the macOS steps run, directly or through flake-verify.sh
# and test.sh. A macOS step naming a scripts/*.sh not listed here, or a listed
# script running one by its own directory (`$SCRIPT_DIR/x.sh`, `scripts/x.sh`,
# `$HERE/x.sh`), fails the coverage case. A script reached any other way –
# a path built at run time – is not seen.
MACOS_SCRIPTS=(
  flake-verify.sh
  nightly-flake-stress.sh
  nightly-quarantine-audit.sh
  repair-spm-workspace.sh
  test.sh
  remote-verify.sh
  tbd-home-fingerprint.sh
)

major="$("$BASH32" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
if [[ "$major" != 3 ]]; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL - $BASH32 is not bash 3.2 (major version [${major}]); run this harness on macOS, or set FLAKE_BASH32"
    exit 1
  fi
  echo "SKIP - no bash 3.2 at $BASH32 (major version [${major}]); set FLAKE_BASH32 to one"
  exit 0
fi
echo "bash under test: $("$BASH32" -c 'echo "$BASH_VERSION"')"

FAIL=0
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output lacks [$3]"; FAIL=1; fi; }
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] != [$3]"; FAIL=1; fi; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/flake-bash32-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mktmpd() { mktemp -d "$SCRATCH/d.XXXXXX"; }

# The extractor and the two static checks. No YAML parser on the runners: the
# workflow's layout (two-space jobs, `runs-on:` at four, steps at six, `run:`
# at eight) is what the other flake harnesses read too.
LINT="$SCRATCH/lint.py"
cat > "$LINT" <<'PY'
import re, sys
from pathlib import Path

def extract(workflow, out):
    """Every `run:` script of every job whose runs-on starts `macos`, one
    file each, with `${{ … }}` replaced by a word. Prints `file<TAB>job<TAB>step`."""
    lines = Path(workflow).read_text().split("\n")
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    jobs, job, step, in_jobs, i = {}, None, None, False, 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("jobs:"):
            in_jobs = True
        elif in_jobs and re.match(r"^  [A-Za-z][\w-]*:\s*$", line):
            job = line.strip()[:-1]; jobs[job] = {"os": "", "runs": []}; step = None
        elif job and (m := re.match(r"^    runs-on:\s*(\S+)", line)):
            jobs[job]["os"] = m.group(1)
        elif job and (m := re.match(r"^      - name:\s*(.*)$", line)):
            step = m.group(1)
        elif job and (m := re.match(r"^(\s+)run:\s*(.*)$", line)):
            indent, rest = len(m.group(1)), m.group(2)
            if rest in ("|", "|-", "|+", ">", ">-"):
                body, i = [], i + 1
                while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > indent):
                    body.append(lines[i]); i += 1
                cut = min((len(b) - len(b.lstrip()) for b in body if b.strip()), default=0)
                jobs[job]["runs"].append((step, "\n".join(b[cut:] for b in body)))
                continue
            if len(rest) > 1 and rest[0] == rest[-1] == "'":
                rest = rest[1:-1].replace("''", "'")
            jobs[job]["runs"].append((step, rest))
        i += 1
    n = 0
    for name, job in jobs.items():
        if not job["os"].startswith("macos"):
            continue
        for step, text in job["runs"]:
            path = out / f"{n:03d}.sh"; n += 1
            path.write_text(re.sub(r"\$\{\{.*?\}\}", "GHA_EXPR", text) + "\n")
            print(f"{path}\t{name}\t{step}")

class Scan:
    """One pass over a script, as bash 3.2 reads it. `quoted` blanks
    single-quoted text, comments and heredoc bodies; `code` blanks double-quoted
    literal text too. `regions` are the substitutions, each ending where 3.2's
    scanner ends it: at the first `)` that balances a plain count of the
    parentheses, which a case pattern without its leading `(` throws off."""
    def __init__(self, s):
        self.s, self.n = s, len(s)
        self.quoted, self.code = list(s), list(s)
        self.regions, self.heredocs = [], []
        self.top(0, False)
        self.quoted, self.code = "".join(self.quoted), "".join(self.code)

    def blank(self, a, b, both=True):
        for k in range(a, min(b, self.n)):
            if self.s[k] != "\n":
                self.code[k] = " "
                if both:
                    self.quoted[k] = " "

    def word_start(self, i):
        return i == 0 or self.s[i - 1] in " \t\n;&|()"

    def squote(self, i):  # at the opening quote; returns the index after the closing one
        j = self.s.find("'", i + 1)
        j = self.n if j < 0 else j + 1
        self.blank(i, j); return j

    def ansi(self, i):  # at `$'`
        j = i + 2
        while j < self.n and self.s[j] != "'":
            j += 2 if self.s[j] == "\\" else 1
        j = min(j + 1, self.n)
        self.blank(i, j); return j

    def backtick(self, i):
        j = i + 1
        while j < self.n and self.s[j] != "`":
            j += 2 if self.s[j] == "\\" else 1
        return min(j + 1, self.n)

    def arith(self, i):  # at `$((` or a bare `((`
        depth, j = 0, i + (self.s[i] == "$")
        while j < self.n:
            depth += {"(": 1, ")": -1}.get(self.s[j], 0)
            j += 1
            if depth == 0:
                break
        return j

    def subst(self, i):  # at `$(`, `<(` or `>(`
        end = self.top(i + 2, True)
        self.regions.append((i, end)); return end

    def dquote(self, i):  # after the opening quote
        while i < self.n:
            c = self.s[i]
            if c == "\\":
                self.blank(i, i + 2, both=False); i += 2
            elif c == '"':
                return i + 1
            elif self.s.startswith("$((", i):
                i = self.arith(i)
            elif self.s.startswith("$(", i):
                i = self.subst(i)
            elif c == "`":
                i = self.backtick(i)
            else:
                self.blank(i, i + 1, both=False); i += 1
        return i

    def top(self, i, in_subst):
        depth = 0
        while i < self.n:
            c = self.s[i]
            if c == "\\":
                i += 2
            elif c == "\n" and self.heredocs:
                i = self.heredoc_bodies(i + 1)
            elif self.s.startswith("$'", i):
                i = self.ansi(i)
            elif c == "'":
                i = self.squote(i)
            elif c == '"':
                i = self.dquote(i + 1)
            elif c == "`":
                i = self.backtick(i)
            elif c == "#" and self.word_start(i):
                j = self.s.find("\n", i); j = self.n if j < 0 else j
                self.blank(i, j); i = j
            elif self.s.startswith("<<<", i):
                i += 3  # a here-string, not a heredoc
            elif self.s.startswith("<<", i):
                m = re.match(r"<<(-?)\s*(['\"]?)([A-Za-z_][\w]*)\2", self.s[i:])
                if m:
                    self.heredocs.append((m.group(3), m.group(1) == "-")); i += m.end()
                else:
                    i += 2
            elif self.s.startswith("$((", i) or (self.s.startswith("((", i) and self.word_start(i)):
                i = self.arith(i)  # where `<<` is a shift, not a heredoc
            elif self.s.startswith("$(", i) or ((c in "<>") and self.s.startswith("(", i + 1)):
                i = self.subst(i)
            elif c == "(":
                depth += 1; i += 1
            elif c == ")":
                if in_subst and depth == 0:
                    return i + 1
                depth = max(depth - 1, 0); i += 1
            else:
                i += 1
        return i

    def heredoc_bodies(self, i):
        for word, strip in self.heredocs:
            while i < self.n:
                j = self.s.find("\n", i); j = self.n if j < 0 else j
                line = self.s[i:j]
                self.blank(i, j)
                i = j + 1
                if (line.lstrip("\t") if strip else line) == word:
                    break
        self.heredocs = []
        return i

# Bash 4 and later. Read against the text with single-quoted strings and
# comments blanked, so an awk, jq or sed program cannot trip them.
NEWER = [
    (r"\b(declare|local|typeset)\s+-[A-Za-z]*[Agnlu]", "an associative, nameref, -g or case-converting declaration (bash 4+)"),
    (r"\blocal\s+-\s*($|[;&|])", "`local -` (bash 4.4)"),
    (r"\b(mapfile|readarray)\b", "mapfile/readarray (bash 4)"),
    (r"\$\{[#!]?[A-Za-z_]\w*(\[[^]]*\])?(\^\^?|,,?)", "${v^^} / ${v,,} case conversion (bash 4)"),
    (r"\$\{[^}]*@[QEPAaKkUuL]\}", "${v@…} transformation (bash 4.4+)"),
    (r"\|&", "`|&` (bash 4)"),
    (r";;&|(?<![;&]);&(?!&)", "`;&` / `;;&` case fall-through (bash 4)"),
    (r"&>>", "`&>>` (bash 4)"),
    (r"\bwait\s+-[A-Za-z]*[nfp]", "wait -n/-f/-p (bash 4.3+)"),
    (r"(\[\[|\[|\btest)\s+-[vR]\s", "-v/-R tests (bash 4.2+)"),
    (r"\b(EPOCHSECONDS|EPOCHREALTIME|BASHPID|SRANDOM|BASH_ARGV0)\b", "a variable bash 3.2 does not set"),
    (r"\bcoproc\b", "coproc (bash 4)"),
    (r"\$\{[A-Za-z_]\w*\[-[0-9]", "a negative array subscript (bash 4.3)"),
    (r"(?<!\$)\{[A-Za-z_]\w*\}[<>]", "a {fd}> redirection (bash 4.1)"),
    (r"\{-?\w+\.\.-?\w+\.\.-?\d+\}", "a stepped brace expansion (bash 4)"),
    (r"\bshopt\s+-[su]\b.*\b(globstar|lastpipe|autocd|checkjobs|dirspell|direxpand|inherit_errexit|localvar_inherit|localvar_unset|assoc_expand_once|globasciiranges|compat\d+)\b",
     "a shopt option bash 3.2 does not have"),
]

def empty_arrays(p, s, sc, raw):
    """Bash before 4.4 reads "${a[@]}" or ${a[*]} of an EMPTY array as unbound
    under `set -u`, and the script dies. Flagged: an array the script sets to
    `()` after it turns on nounset, expanded without the `${a[@]+"${a[@]}"}`
    or `${a[*]:-}` guard. A site that cannot be reached empty says so with a
    trailing `# non-empty: <why>` comment, and so does an array's `=()` line
    for an array that is never empty where it is expanded."""
    nounset = re.search(r"^\s*set\s+-[A-Za-z]*u|^\s*set\s+-o\s+nounset", sc.code, re.M)
    if not nounset:
        return []
    empty = {m.group(1) for m in re.finditer(r"(?<![\w$])([A-Za-z_]\w*)=\(\)", sc.code)
             if m.start() > nounset.start() and "# non-empty:" not in raw[s.count("\n", 0, m.start())]}
    found = []
    for no, text in enumerate(sc.quoted.split("\n"), 1):
        if "# non-empty:" in raw[no - 1]:
            continue
        for m in re.finditer(r"\$\{([A-Za-z_]\w*)\[[@*]\]\}", text):
            guarded = text[max(0, m.start() - 2):m.start()] in ('+"', "+'") or text[max(0, m.start() - 1):m.start()] == "+"
            if m.group(1) in empty and not guarded:
                found.append(f"{p}:{no}: ${{{m.group(1)}[@]}} of an array that can be empty, under set -u: "
                             f"bash 3.2 calls it unbound. Guard it, or mark the line `# non-empty: <why>`: {raw[no - 1].strip()}")
    return found

def check(paths):
    findings = []
    for p in paths:
        s = Path(p).read_text()
        sc = Scan(s)
        for a, b in sc.regions:
            region = sc.code[a:b]
            cases = len(re.findall(r"(?<![\w$./-])case(?=\s)", region))
            esacs = len(re.findall(r"(?<![\w$./-])esac(?![\w-])", region))
            if cases > esacs:
                line = s.count("\n", 0, a) + 1
                findings.append(f"{p}:{line}: a `case` inside {s[a:a+2]} … ): bash 3.2 ends the substitution "
                                "at its first pattern's `)`. Write each pattern as `(pat)`, or move the case into a function.")
        raw = s.split("\n")
        for no, text in enumerate(sc.quoted.split("\n"), 1):
            for rx, why in NEWER:
                if re.search(rx, text):
                    findings.append(f"{p}:{no}: {why}: {raw[no - 1].strip()}")
        findings += empty_arrays(p, s, sc, raw)
    print("\n".join(findings))
    return 1 if findings else 0

if __name__ == "__main__":
    if sys.argv[1] == "extract":
        extract(sys.argv[2], sys.argv[3])
    else:
        sys.exit(check(sys.argv[2:]))
PY

# extract FILE: the macOS run: scripts of FILE, in a directory of their own;
# prints the index (file, job, step), tab-separated. Once per file: every
# mutant is a file of its own, and the workflow is read once for all checks.
extract() {
  local d
  d="$SCRATCH/x-$(printf '%s' "$1" | shasum | cut -c1-16)"
  if [[ ! -f "$d/index" ]]; then
    mkdir -p "$d" && python3 "$LINT" extract "$1" "$d" > "$d/index.tmp" && mv "$d/index.tmp" "$d/index" || return 1
  fi
  cat "$d/index"
}

# mutated OLD NEW: a copy of the workflow with the first literal OLD replaced
# by NEW. Python rather than sed: BSD sed has no `\n` in a replacement.
mutated() {
  local c; c="$(mktmpd)/wf.yml"
  python3 - "$WORKFLOW" "$c" "$1" "$2" <<'PY'
import sys
src, dst, old, new = sys.argv[1:]
open(dst, "w").write(open(src).read().replace(old, new, 1))
PY
  cmp -s "$c" "$WORKFLOW" && { echo "FAIL - mutation [$1] did not change the workflow" >&2; FAIL=1; }
  printf '%s' "$c"
}
# check NAME FUNC OLD NEW: FUNC passes on the workflow and fails on the mutant.
check() {
  local rc=0 mutant
  "$2" "$WORKFLOW" > "$SCRATCH/check.log" 2>&1 || rc=$?
  assert_eq "$1" "0" "$rc"
  [[ "$rc" == 0 ]] || sed 's/^/       /' "$SCRATCH/check.log" | head -20
  mutant="$(mutated "$3" "$4")"
  rc=0; "$2" "$mutant" > "$SCRATCH/check.log" 2>&1 || rc=$?
  assert_eq "mutation: $1 fails without it" "1" "$rc"
}

# The step NAME's run: script, by the index extract printed.
script_of() { awk -F'\t' -v name="$2" 'index($3, name) == 1 {print $1; exit}' <<< "$1"; }

# ============================================================================
# static checks
# ============================================================================

all_parse() {
  local index f bad=0
  index="$(extract "$1")" || return 2
  [[ "$(wc -l <<< "$index")" -ge 20 ]] || { echo "only $(wc -l <<< "$index") macOS run: scripts found"; return 2; }
  while IFS=$'\t' read -r f _ _; do "$BASH32" -n "$f" || bad=1; done <<< "$index"
  for f in "${MACOS_SCRIPTS[@]}"; do "$BASH32" -n "$HERE/$f" || bad=1; done
  return "$bad"
}
test_every_macos_script_parses_under_bash_32() {
  check "every macOS run: script and script parses under bash 3.2" all_parse \
    '          set -euo pipefail
          T="$RUNNER_TEMP/flakefix"' '          set -euo pipefail
          if true; then
          T="$RUNNER_TEMP/flakefix"'
}

lint_clean() {
  local index files=() f
  index="$(extract "$1")" || return 2
  while IFS=$'\t' read -r f _ _; do files+=("$f"); done <<< "$index"
  for f in "${MACOS_SCRIPTS[@]}"; do files+=("$HERE/$f"); done
  python3 "$LINT" check "${files[@]}"
}
# The record step as it was when run 37845177223 failed.
CASE_IN_SUBST='          rec="$({
            for v in $(compgen -e); do
              case "$v" in GITHUB_OUTPUT|GITHUB_STEP_SUMMARY|GITHUB_ENV|GITHUB_PATH|GITHUB_STATE|BASH_ENV|ENV|SHELLOPTS|BASHOPTS|_|GIT_CONFIG_*) ;;
                *) printf '"'"'%s=%s\0'"'"' "$v" "${!v}" ;; esac
            done
            printf '"'"'%s\0'"'"' GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
          } | base64 | tr -d '"'"'\n'"'"')"'
test_no_case_inside_a_substitution() {
  check "no case pattern can end a substitution early" lint_clean \
    '          rec="$(record | base64 | tr -d '"'"'\n'"'"')"' "$CASE_IN_SUBST"
  check "nor one inside a process substitution" lint_clean \
    '< <(printf '"'"'%s'"'"' "$restore" | /usr/bin/base64 -d)' \
    '< <(case x in x) printf '"'"'%s'"'"' "$restore" ;; esac | /usr/bin/base64 -d)'
  # Why the lint exists: 3.2 parses a substitution only when it runs it.
  local mutant index rc=0
  mutant="$(mutated '          rec="$(record | base64 | tr -d '"'"'\n'"'"')"' "$CASE_IN_SUBST")"
  index="$(extract "$mutant")"
  "$BASH32" -n "$(script_of "$index" "Record the verifier")" 2> /dev/null || rc=$?
  assert_eq "bash 3.2's own -n does not see it" "0" "$rc"
}

test_no_bash_4_construct() {
  check "no associative array" lint_clean '          base="$(git rev-parse HEAD)"' \
    '          declare -A seen=()
          base="$(git rev-parse HEAD)"'
  check "no case conversion" lint_clean '          base="$(git rev-parse HEAD)"' \
    '          base="$(git rev-parse HEAD)"; base="${base,,}"'
  check "no mapfile" lint_clean '          base="$(git rev-parse HEAD)"' \
    '          mapfile -t lines < "$GITHUB_ENV"
          base="$(git rev-parse HEAD)"'
  check "no |&" lint_clean '          base="$(git rev-parse HEAD)"' \
    '          base="$(git rev-parse HEAD |& cat)"'
}

test_the_lint_reads_no_quoted_text_or_comment_as_code() {
  local f out
  f="$SCRATCH/quoted.sh"
  cat > "$f" <<'SH'
# mapfile in a comment, and |& too; it's ) here
jq -r '.a |& .b' f
x="$(echo 'case a in a) b')"
y="$(echo "use case in a sentence")"
z=$(case a in (a) echo ok ;; esac)
w=$( # a comment's ) paren
  echo ok)
SH
  out="$(python3 "$LINT" check "$f")"
  assert_eq "quoted text, comments and a balanced case are clean" "" "$out"
  "$BASH32" "$f" > /dev/null 2>&1
  assert_eq "and the fixture itself runs under bash 3.2" "0" "$?"
  # A here-string or a shift is no heredoc: what follows is still read.
  cat > "$f" <<'SH'
read -r x <<< word
(( y = 1 << 2 ))
declare -A m=()
SH
  out="$(python3 "$LINT" check "$f")"
  assert_eq "a here-string or a shift hides nothing after it" "1" "$(grep -c 'associative' <<< "$out")"
}

# An array that can be empty, expanded bare under `set -u`: bash 3.2 dies.
test_no_bare_expansion_of_an_array_that_can_be_empty() {
  local f out
  f="$SCRATCH/empty.sh"
  cat > "$f" <<'SH'
set -uo pipefail
a=()
echo "${a[@]}"
SH
  out="$(python3 "$LINT" check "$f")"
  assert_contains "flagged" "$out" "can be empty"
  "$BASH32" "$f" > /dev/null 2>&1
  assert_eq "and bash 3.2 does die of it" "1" "$?"
  cat > "$f" <<'SH'
set -uo pipefail
a=()
echo ${a[@]+"${a[@]}"} "${a[*]:-}"
[[ ${#a[@]} -gt 0 ]] && echo "${a[@]}"  # non-empty: inside the length check
b=()  # non-empty: filled below
b+=(x)
echo "${b[@]}"
SH
  out="$(python3 "$LINT" check "$f")"
  assert_eq "guarded or marked: clean" "" "$out"
  "$BASH32" "$f" > /dev/null 2>&1
  assert_eq "and it runs under bash 3.2" "0" "$?"
}

# macos_scripts_listed FILE [DIR]: every scripts/*.sh a macOS step of FILE
# names, and every script one of MACOS_SCRIPTS (read from DIR) runs by its own
# directory, is in MACOS_SCRIPTS.
macos_scripts_listed() {
  local index named n f dir="${2:-$HERE}" missing=0
  index="$(extract "$1")" || return 2
  named="$({
    cut -f1 <<< "$index" | xargs cat | grep -v '^ *#' | grep -oE 'scripts/[A-Za-z0-9_./-]+\.sh' | sed 's|^scripts/||'
    for f in "${MACOS_SCRIPTS[@]}"; do
      grep -v '^ *#' "$dir/$f" | grep -oE '(scripts/|\$SCRIPT_DIR/|\$\{SCRIPT_DIR\}/|\$HERE/)[A-Za-z0-9_./-]+\.sh' |
        sed -E 's#^(scripts/|\$SCRIPT_DIR/|\$\{SCRIPT_DIR\}/|\$HERE/)##'
    done
  } | sort -u)"
  [[ -n "$named" ]] || return 2
  while IFS= read -r n; do
    [[ " ${MACOS_SCRIPTS[*]} " == *" $n "* ]] || { echo "a macOS step runs scripts/$n, which this harness does not check"; missing=1; }
  done <<< "$named"
  return "$missing"
}
test_every_script_a_macos_step_runs_is_checked() {
  check "every scripts/*.sh a macOS step names is in MACOS_SCRIPTS" macos_scripts_listed \
    '        run: bash scripts/repair-spm-workspace.sh' '        run: bash scripts/repair-spm-workspace.sh && bash scripts/ci/new-step.sh'
  # And one a listed script runs itself.
  local d f rc=0
  d="$(mktmpd)"
  for f in "${MACOS_SCRIPTS[@]}"; do cp "$HERE/$f" "$d/"; done
  printf '%s\n' 'bash "$SCRIPT_DIR/new-helper.sh"' >> "$d/flake-verify.sh"
  macos_scripts_listed "$WORKFLOW" "$d" > /dev/null || rc=$?
  assert_eq "mutation: a script flake-verify.sh runs itself must be listed too" "1" "$rc"
}

# ============================================================================
# the steps every later step depends on, run under bash 3.2
# ============================================================================

# record FILE OUT: run FILE's "Record the verifier's environment" step under
# 3.2 as the runner runs a step with no `shell:` (`bash -e {0}`); the step's
# output goes to OUT.
record() {
  local index; index="$(extract "$1")"
  : > "$2"
  env -i PATH="$PATH" HOME="$HOME" T=/t VS=/vs VT=/vt GITHUB_OUTPUT="$2" \
    "$BASH32" -e "$(script_of "$index" "Record the verifier")"
}
record_runs() {
  local out="$SCRATCH/record-out" rec
  record "$1" "$out" || return 1
  [[ "$(grep -c '^env=' "$out")" == 1 ]] || return 1
  rec="$(sed -n 's/^env=//p' "$out" | /usr/bin/base64 -d | tr '\0' '\n')"
  grep -qx 'T=/t' <<< "$rec" && grep -qx 'GIT_CONFIG_GLOBAL=/dev/null' <<< "$rec" && ! grep -q '^GITHUB_OUTPUT=' <<< "$rec"
}
test_the_environment_record_runs_under_bash_32() {
  check "the environment record runs under bash 3.2" record_runs \
    '          rec="$(record | base64 | tr -d '"'"'\n'"'"')"' "$CASE_IN_SUBST"
}

# The clean-environment preamble, through the last step that carries it: with
# the record it re-runs itself and reaches the step's own body; without one it
# refuses.
preamble_runs() {
  local index script rt rc=0 log
  index="$(extract "$1")"; rt="$(mktmpd)"
  script="$(script_of "$index" "End red when a session failed")"
  record "$1" "$rt/rec" || return 1
  : > "$rt/out"; : > "$rt/summary"
  log="$(env -i PATH="$PATH" GITHUB_OUTPUT="$rt/out" GITHUB_STEP_SUMMARY="$rt/summary" CLEAN_ENV="$(sed -n 's/^env=//p' "$rt/rec")" \
    "$BASH32" --noprofile --norc -p -eo pipefail "$script" 2>&1)" || rc=$?
  [[ "$rc" == 1 && "$log" == *"a fixer session failed"* ]] || { echo "with a record: rc=$rc [$log]"; return 1; }
  rc=0; log="$(env -i PATH="$PATH" GITHUB_OUTPUT="$rt/out" GITHUB_STEP_SUMMARY="$rt/summary" CLEAN_ENV= \
    "$BASH32" --noprofile --norc -p -eo pipefail "$script" 2>&1)" || rc=$?
  [[ "$rc" == 1 && "$log" == *"the recorded environment is missing"* ]] || { echo "without one: rc=$rc [$log]"; return 1; }
}
test_the_clean_environment_preamble_runs_under_bash_32() {
  check "the preamble restores the record under bash 3.2" preamble_runs \
    '          rec="$(record | base64 | tr -d '"'"'\n'"'"')"' "$CASE_IN_SUBST"
}

# Package, as it runs after a step before session 1 failed: run 37845177223.
package_runs() {
  local index script rt
  index="$(extract "$1")"; rt="$(mktmpd)"
  script="$(script_of "$index" "Package the attempt")"
  sed "s|GHA_EXPR|$rt|g" "$script" > "$rt/package.sh"
  mkdir -p "$rt/flakefix"; echo '{"n": 45}' > "$rt/flakefix/plan.json"
  : > "$rt/out"; : > "$rt/summary"
  env -i PATH="$PATH" GITHUB_OUTPUT="$rt/out" GITHUB_STEP_SUMMARY="$rt/summary" \
    C1=skipped TRY2=false C2=skipped S1=skipped S1_CONCLUSION= S2=skipped S2_CONCLUSION= \
    "$BASH32" --noprofile --norc -p -eo pipefail "$rt/package.sh" || return 1
  [[ "$(cat "$rt/flakefix/outcome")" == aborted ]] && grep -q '^sums=outcome:' "$rt/out"
}
test_the_package_step_runs_under_bash_32() {
  check "the package step runs under bash 3.2" package_runs \
    '          rm -f "$T/abort_kind"' \
    '          declare -A kinds=()
          rm -f "$T/abort_kind"'
}

for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  echo "== $t"
  "$t"
done
if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $FAIL
