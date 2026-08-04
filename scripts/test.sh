#!/usr/bin/env bash
#
# The test suite, with the developer's real `~/tbd`, `~/.claude` and `~/.codex`
# fenced off.
#
# SwiftPM is invoked through `scripts/swift-safe`, never directly: that wrapper
# holds a machine-global admission lock and bounds compiler jobs so concurrent
# TBD worktrees cannot each start a full compiler swarm, and the repo guardrail
# blocks raw `swift build/test/run` for that reason. The two wrappers solve
# orthogonal problems — admission control there, filesystem isolation here — so
# they stack rather than replace one another, and every argument this script
# does not consume is forwarded through to `swift test`.
#
# Three layers. The first two are always on; the third is CI-only.
#
#   1. CONTAINMENT — always on. `TBD_HOME`, `TBD_SOCKET_PATH` and
#      `TBD_CLAUDE_HOST_HOME` point at a fresh scratch dir for the whole run,
#      so any code path that resolves a TBD-owned path — or the host Claude
#      store a profile dir mirrors — lands there instead of in the real one.
#      This catches leaks nobody has diagnosed yet, including ones in code that
#      has no injection seam at all.
#   2. THE TRIPWIRE — always on. `HOME` and `CFFIXED_USER_HOME` point at a
#      *different* directory from layer 1, and the two names a leak reaches for
#      inside it — `tbd` and `.claude` — are pre-created mode `000`. Code that
#      asks the fence where home is lands in layer 1's scratch and works; code
#      that assembles a path out of the home directory instead gets `EACCES` at
#      the exact call site, inside the failing test, with the offending path in
#      the error. See "READING A PERMISSION-DENIED FAILURE" below.
#   3. DETECTION — on in CI (`$CI` set), off elsewhere; `--fingerprint` opts in
#      locally and `--no-fingerprint` forces it off anywhere. The real `~/tbd`,
#      `~/.claude` and `~/.codex` are fingerprinted before and after, and a
#      changed fingerprint fails the run even when every test passed. This is
#      now a backstop rather than the primary guard; see "WHY THE TRIPWIRE
#      SUPERSEDES THE FINGERPRINT".
#
# READING A PERMISSION-DENIED FAILURE. If a test under this wrapper fails with
# "You don't have permission to save the file …" or `EACCES`/`NSFileWriteNoPermissionError`
# on a path ending in `/tbd/…` or `/.claude/…`, that is not a broken machine and
# not a bad scratch dir. It means: **this code assembled a path out of the home
# directory instead of asking `TBDConstants`.** On a developer box the same code
# would have written into the real `~/tbd` or `~/.claude`. The fix is to route
# the path through `TBDConstants` (or whatever injected seam the type already
# takes) — never to relax the decoy's mode, and never to point `HOME` back at
# the real one.
#
# WHY BOTH FENCE VARS, AND WHY `HOME` ALONE IS NOT ENOUGH. They cover disjoint
# halves and neither substitutes for the other. Measured here on macOS 26.1:
#
#   - `$HOME` does NOT fence Foundation. CoreFoundation's home lookup tries
#     `CFFIXED_USER_HOME`, then `getpwuid`, and only then `$HOME` — and
#     `getpwuid` always succeeds, so the `$HOME` branch is unreachable. With
#     `HOME` pointed at a scratch dir, `NSHomeDirectory()`,
#     `FileManager.homeDirectoryForCurrentUser`, `URL.homeDirectory`,
#     `expandingTildeInPath` and `NSSearchPathForDirectoriesInDomains` all still
#     returned the developer's real home.
#   - `CFFIXED_USER_HOME` DOES fence Foundation, verified for a plain unsigned
#     SPM binary: every one of the above returned the scratch path. CF does not
#     cache it, so a runtime `setenv` takes effect on the next call.
#   - So `HOME` fences *subprocesses* — `git`, `tmux`, shells; they do not link
#     CoreFoundation — and `CFFIXED_USER_HOME` fences *in-process Foundation*.
#     Both are needed.
#
# Two things it deliberately does NOT fence, so don't read it as total:
#
#   - **`UserDefaults`.** `cfprefsd` resolves preference paths over XPC, so it
#     ignores `CFFIXED_USER_HOME` entirely. The existing
#     `AppState(userDefaults: UserDefaults(suiteName:))` discipline in
#     `CLAUDE.md` stays load-bearing.
#   - **The Keychain.** It breaks rather than redirects under
#     `CFFIXED_USER_HOME`: `SecItemAdd` returns `-60006` and
#     `SecItemCopyMatching` returns `-25300`, and pre-seeding
#     `$FAKE_HOME/Library/Keychains` does not help. Keychain-touching code must
#     go through an injection seam in tests (`ClaudeCredentialsKeychainDeleting`
#     is the existing one) — under this wrapper a test that reaches the real
#     `Security` framework will fail, by design.
#
# WHY THE TRIPWIRE SUPERSEDES THE FINGERPRINT. The fingerprint compares two
# directory listings, so it can only see a leak that changes the set of names.
# `createDirectory(withIntermediateDirectories: true)` on an *already existing*
# directory returns success without issuing a write syscall — so a leak that
# writes to a FIXED path is caught at most once, ever, and is silent on every
# run afterwards. (Leaks that mint a fresh name per run — the profile-dir leak
# minted a new UUID each time — are the ones it does catch, which is why that
# one eventually became visible.) The tripwire has no such blind spot: it fails
# on the permission check at the call site, not on a state diff, so it fires
# every run and names the culprit. Corollary for anyone testing a guard: **start
# from a clean state.** A leftover directory from an earlier unfenced run makes
# a correctly-working fence look bypassed, because the re-create silently
# succeeds. That misdiagnosis has already happened once.
#
# WHY DETECTION IS CI-ONLY, AND WHY THE DEFAULT SAYS SO. It is trustworthy only
# where nothing else writes to those directories, and that means a CI runner: no
# live daemon, no real worktrees, no sibling checkouts. The fingerprint brackets
# a build plus a full suite — minutes, on a developer box where a running daemon
# legitimately creates `worktrees/<slot>/<name>`, `scratch/`, `notes/` and
# `channels/` entries, any sibling worktree running `scripts/restart.sh` drops a
# top-level `state.db.pre-migration.<ts>`, Claude Code writes into `~/.claude`
# throughout, and any concurrent session starting an agent in a new directory
# mints a fresh `~/.claude/projects/<cwd-hash>`. Those are real writes by real
# software, not leaks, and a guard that reddens on them gets switched off inside
# a week.
#
# So the DEFAULT follows the argument instead of contradicting it: detection is
# on when `$CI` is set and off otherwise. It is not "on unless the one caller
# who knows better opts out" — a developer running this wrapper directly used to
# inherit a guard written for a machine they are not on. `--fingerprint` turns it
# on locally for a deliberate leak hunt (do it on an otherwise-quiet box);
# `--no-fingerprint` forces it off anywhere, including CI. The fence is the layer
# that actually *stops* leaks, and it is never optional.
#
# All six env vars are OVERWRITTEN, not defaulted: an inherited value is
# discarded for the duration of the run. That is the point — a fence you can
# disable by exporting something first is not a fence — but it does mean this
# wrapper cannot be pointed at a config dir of your own.
#
# They are applied as a prefix on the `swift test` invocation rather than
# exported, so this script's own `$HOME` stays real and
# `scripts/tbd-home-fingerprint.sh` — which deliberately reads `${HOME}` — needs
# no special-casing on either side of the run.
#
# `--fingerprint` / `--no-fingerprint` are consumed wherever they appear; every
# other argument is forwarded to `swift test` untouched. Position-independent on
# purpose: a leading-only strip forwards a late `--no-fingerprint` to `swift
# test`, which errors out. That is loud rather than silent, but a positional
# collision is impossible — `swift test` has no flag of either name — so
# filtering them out everywhere is strictly safer at no cost. Last one wins.
#   scripts/test.sh
#   scripts/test.sh --parallel -j 2 --filter '^TBDDaemonTests\.'
#   scripts/test.sh --no-fingerprint --parallel -j 2
#   scripts/test.sh --fingerprint            # deliberate local leak hunt
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# On in CI, off on a developer box. See "WHY DETECTION IS CI-ONLY" above.
fingerprint=0
if [ -n "${CI:-}" ]; then
  fingerprint=1
fi
swift_test_args=()
for arg in "$@"; do
  case "$arg" in
    --no-fingerprint) fingerprint=0 ;;
    --fingerprint) fingerprint=1 ;;
    *) swift_test_args+=("$arg") ;;
  esac
done

fingerprint_before=""
if [ "$fingerprint" -eq 1 ]; then
  fingerprint_before="$(scripts/tbd-home-fingerprint.sh)"
fi

# `/tmp`, not `mktemp -d`'s default `$TMPDIR`: on darwin TMPDIR is a ~50-char
# path under /var/folders, and `sun_path` for a unix socket caps at ~104 bytes,
# so `$TMPDIR/<scratch>/sock` can overflow.
# `/tmp/tbd-test-home.XXXXXXXX/sanctioned/tbd/sock` is ~47 bytes and cannot.
#
# TBD_SOCKET_PATH is set anyway — it is the sanctioned escape hatch for that
# cap (see `TBDConstants.socketPath`) and pinning it here means a future move
# of this scratch dir to a deeper path cannot silently reintroduce the
# overflow. It is set to exactly the value TBD_HOME would derive, so
# `ConstantsTests.ProductionVarSmokeSuite.socketPathSuffix` — which asserts a
# `/sock` suffix — still holds under this wrapper.
#
# TBD_CLAUDE_HOST_HOME is the third leg and is easy to forget, because fencing
# `TBD_HOME` alone looks complete: a default-constructed
# `ClaudeProfileConfigDirManager` then gets a scratch `baseDirectory` and the
# developer's REAL `~/.claude` as its `hostBaseDirectory`, which
# `ensureMirrorSlot` creates directories in, moves whole subtrees within, and
# writes symlinks into.
#
# TBD_TEST_CODEX_HOME is the fourth, and it is the same omission one store over:
# `CodexHomeManager` falls back to `~/.codex` and `ensureProfilePlugin()`
# creates directories and writes a plugin manifest, hooks and a profile TOML
# there. It was previously left to individual tests to remember, which is
# exactly the shape the run-wide fence exists to replace.
scratch_home="$(mktemp -d /tmp/tbd-test-home.XXXXXXXX)"
cleanup() { rm -rf "$scratch_home"; }
# EXIT alone is sufficient, including when this wrapper is killed:
# `scripts/nightly-flake-stress.sh` TERMs it when its outer deadline fires, and
# bash runs an EXIT trap on a fatal signal as well as on a normal exit —
# measured here, the scratch dir is gone either way. No INT/TERM handler needed.
#
# The other half of that interaction lives in the harness: it kills the process
# tree LEAVES FIRST, so `swift test` is already dead before bash gets round to
# this `rm -rf`. A parent-first kill would have this deleting a `TBD_HOME` an
# orphaned test run was still writing into.
trap cleanup EXIT

# THE TWO ROOTS HAVE DIFFERENT LIFETIMES, ON PURPOSE.
#
# The sanctioned root is the one above: fresh per run and deleted on exit.
# Reusing it would let one run's `state.db`, sockets and profile dirs be visible
# to the next, which is exactly the cross-run contamination the fence exists to
# prevent.
#
# The fake home is stable and deliberately NOT deleted, because setting
# `CFFIXED_USER_HOME` also relocates SwiftPM's own caches (`~/.swiftpm`,
# `~/Library/Caches/org.swift.swiftpm`) into it. A fresh fake home each run
# re-pays the manifest-cache miss every time: measured on this package,
# `swift package describe` went 0.191s unfenced to 0.553s fenced-and-cold. It
# holds only caches and the decoys — no test state — so persisting it
# contaminates nothing. (The module cache lives in `.build/` and is unaffected
# either way.)
#
# IT LIVES UNDER `$TMPDIR`, NOT `/tmp`. On darwin `$TMPDIR` is a per-user
# `/var/folders/...` directory, mode 700 and owned by the calling uid, so nobody
# else can pre-create anything inside it. `/tmp` is mode 1777: any local user —
# or any process running as this one — can plant `tbd-test-fakehome.<uid>` as a
# SYMLINK first, and `mkdir -p` on a symlink-to-a-directory succeeds silently
# while `chmod` resolves straight through it. Pointed at `$HOME`, that made this
# very loop `chmod 000` the developer's real `~/tbd` and `~/.claude` — reproduced
# — leaving a daemon that cannot open `state.db` and nothing pointing back here.
# The `/tmp` fallback below exists only for a stripped environment with no
# `TMPDIR`, and the ownership checks are what make it safe.
#
# The `sun_path` argument that pins the SANCTIONED root to `/tmp` does not apply
# here: it is about the socket, which lives under the sanctioned root, and
# `TBD_SOCKET_PATH` pins it there explicitly.
sanctioned_home="$scratch_home/sanctioned/tbd"
fake_home="${TMPDIR:-/tmp}"
fake_home="${fake_home%/}/tbd-test-fakehome.$(id -u)"
mkdir -p "$sanctioned_home"

fence_bail() {
  echo >&2
  echo "=======================================================================" >&2
  echo "  REFUSING TO RUN — THE TEST FENCE'S OWN SCRATCH HOME IS NOT SAFE" >&2
  echo "=======================================================================" >&2
  echo >&2
  echo "  $1" >&2
  echo >&2
  echo "This wrapper chmods 000 the decoy directories inside its fake home. If" >&2
  echo "that path is a symlink, or a directory somebody else owns, the chmod" >&2
  echo "resolves through it and lands on whatever it points at — which is how a" >&2
  echo "planted symlink would take out the real ~/tbd and ~/.claude." >&2
  echo >&2
  echo "Inspect the path above, remove it if it is not yours, and re-run." >&2
  echo >&2
  exit 1
}

# A path is safe to chmod only if it is a real directory (never a symlink; the
# `-L` test must come BEFORE any mkdir, which would otherwise succeed through
# it) owned by this uid.
require_owned_dir() {
  local path="$1" what="$2"
  [ -L "$path" ] && fence_bail "$what is a SYMLINK: $path"
  [ -e "$path" ] && [ ! -d "$path" ] && fence_bail "$what exists but is not a directory: $path"
  return 0
}

require_owned_dir_after_mkdir() {
  local path="$1" what="$2" owner
  [ -L "$path" ] && fence_bail "$what is a SYMLINK: $path"
  [ -d "$path" ] || fence_bail "$what is not a directory: $path"
  owner="$(stat -f '%u' "$path")"
  [ "$owner" = "$(id -u)" ] || fence_bail "$what is owned by uid $owner, not $(id -u): $path"
}

require_owned_dir "$fake_home" "the fake home"
mkdir -p "$fake_home"
require_owned_dir_after_mkdir "$fake_home" "the fake home"
# Ours, and only ours — closes the plant-a-decoy-inside hole on the `/tmp`
# fallback path, where the parent is world-writable.
chmod 700 "$fake_home"

# The decoys. These are the names a leak reaches for — `$HOME/tbd` is what
# `WorktreeLayout.basePath` used to hand-build, `$HOME/.claude` is what a
# default-constructed `ClaudeProfileConfigDirManager` mirrors into, and
# `$HOME/.codex` is what `CodexHomeManager` falls back to. Mode 000 turns
# "silently wrote to the developer's real store" into "this test failed, here,
# on this path".
#
# Recreated unconditionally rather than only when absent: a previous run that
# died between `mkdir` and `chmod`, or a stray `chmod` by a curious reader,
# would otherwise leave a permanently disarmed tripwire that nothing reports.
decoys=(tbd .claude .codex)
for decoy in "${decoys[@]}"; do
  require_owned_dir "$fake_home/$decoy" "the $decoy decoy"
  mkdir -p "$fake_home/$decoy"
  require_owned_dir_after_mkdir "$fake_home/$decoy" "the $decoy decoy"
  chmod 000 "$fake_home/$decoy"
done

# `${a[@]+"${a[@]}"}` — macOS ships bash 3.2, where a bare `"${a[@]}"` on an
# EMPTY array is an unbound-variable error under `set -u`.
set +e
env \
  TBD_HOME="$sanctioned_home" \
  TBD_SOCKET_PATH="$sanctioned_home/sock" \
  TBD_CLAUDE_HOST_HOME="$sanctioned_home/claude-host" \
  TBD_TEST_CODEX_HOME="$sanctioned_home/codex-host" \
  HOME="$fake_home" \
  CFFIXED_USER_HOME="$fake_home" \
  scripts/swift-safe test ${swift_test_args[@]+"${swift_test_args[@]}"}
test_status=$?
set -e

# THE TRIPWIRE HAS TO BE RE-CHECKED, not just armed. The code inside the run
# owns these directories, so it can chmod them back — and a decoy that comes
# back readable is a disarmed tripwire that reports nothing on every subsequent
# run, since the fake home persists. (The fingerprint has the equivalent check
# by construction: it compares before against after. This layer needs it
# spelled out.)
for decoy in "${decoys[@]}"; do
  path="$fake_home/$decoy"
  [ -L "$path" ] && fence_bail "the $decoy decoy became a SYMLINK during the run: $path"
  [ -d "$path" ] || fence_bail "the $decoy decoy is no longer a directory: $path"
  mode="$(stat -f '%Lp' "$path")"
  [ "$mode" = "0" ] || fence_bail "the $decoy decoy came back mode 0$mode, not 000 — the run disarmed the tripwire: $path"
done

if [ "$fingerprint" -eq 0 ]; then
  exit "$test_status"
fi

fingerprint_after="$(scripts/tbd-home-fingerprint.sh)"

if [ "$fingerprint_before" != "$fingerprint_after" ]; then
  echo >&2
  echo "=======================================================================" >&2
  echo "  THE TEST RUN WROTE INTO ~/tbd, ~/.claude OR ~/.codex" >&2
  echo "=======================================================================" >&2
  echo >&2
  echo "CLAUDE.md: \"Tests must not touch ~/tbd\". Something resolved a real" >&2
  echo "config path despite TBD_HOME=$sanctioned_home," >&2
  echo "TBD_CLAUDE_HOST_HOME=$sanctioned_home/claude-host," >&2
  echo "TBD_TEST_CODEX_HOME=$sanctioned_home/codex-host and" >&2
  echo "HOME=CFFIXED_USER_HOME=$fake_home." >&2
  echo >&2
  echo "Entries added (+) or removed (-):" >&2
  diff <(printf '%s\n' "$fingerprint_before") <(printf '%s\n' "$fingerprint_after") \
    | grep -E '^[<>]' | sed 's/^</  - /; s/^>/  + /' >&2 || true
  echo >&2
  echo "Usual causes: a static/ambient helper that ignores its caller's" >&2
  echo "injected seam, or a path hand-built from \$HOME instead of going" >&2
  echo "through TBDConstants. Fix the leak — do not delete the entries and" >&2
  echo "move on; ~/tbd holds real state (see \"NEVER delete ~/tbd/state.db\")." >&2
  echo >&2
  echo "Reaching here at all is now unusual: a hand-built \$HOME path normally" >&2
  echo "dies at its call site on the mode-000 decoys in $fake_home." >&2
  echo "A leak that got past those wrote somewhere the decoys do not cover —" >&2
  echo "note the path above and consider whether it needs a third decoy." >&2
  echo >&2
  exit 1
fi

exit "$test_status"
