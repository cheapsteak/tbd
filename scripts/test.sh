#!/usr/bin/env bash
#
# `swift test`, with the developer's real `~/tbd` and `~/.claude` fenced off.
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
#   3. DETECTION — on by default, off with `--no-fingerprint`. The real `~/tbd`
#      and `~/.claude` are fingerprinted before and after, and a changed
#      fingerprint fails the run even when every test passed. This is now a
#      backstop rather than the primary guard; see "WHY THE TRIPWIRE SUPERSEDES
#      THE FINGERPRINT".
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
# WHY DETECTION IS CI-ONLY. It is trustworthy only where nothing else writes to
# those directories, and that means a CI runner: no live daemon, no real
# worktrees, no sibling checkouts. The fingerprint brackets a build plus a full
# suite — minutes, on a developer box where a running daemon legitimately
# creates `worktrees/<slot>/<name>`, `scratch/`, `notes/` and `channels/`
# entries, any sibling worktree running `scripts/restart.sh` drops a top-level
# `state.db.pre-migration.<ts>`, and Claude Code writes into `~/.claude`
# throughout. Those are real writes by real software, not leaks, and a guard
# that reddens on them gets switched off inside a week. So the pre-push hook
# passes `--no-fingerprint` and keeps the fence only; CI runs both layers, where
# a red is always a real finding. The fence is the layer that actually *stops*
# leaks, and it is never optional.
#
# All five env vars are OVERWRITTEN, not defaulted: an inherited value is
# discarded for the duration of the run. That is the point — a fence you can
# disable by exporting something first is not a fence — but it does mean this
# wrapper cannot be pointed at a config dir of your own.
#
# They are applied as a prefix on the `swift test` invocation rather than
# exported, so this script's own `$HOME` stays real and
# `scripts/tbd-home-fingerprint.sh` — which deliberately reads `${HOME}` — needs
# no special-casing on either side of the run.
#
# `--no-fingerprint` is consumed wherever it appears; every other argument is
# forwarded to `swift test` untouched. Position-independent on purpose: a
# leading-only strip forwards a late `--no-fingerprint` to `swift test`, which
# errors out. That is loud rather than silent, but a positional collision is
# impossible — `swift test` has no flag of that name — so filtering it out
# everywhere is strictly safer at no cost.
#   scripts/test.sh
#   scripts/test.sh --parallel -j 2 --filter '^TBDDaemonTests\.'
#   scripts/test.sh --no-fingerprint --parallel -j 2
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fingerprint=1
swift_test_args=()
for arg in "$@"; do
  case "$arg" in
    --no-fingerprint) fingerprint=0 ;;
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
# holds only caches and the two decoys — no test state — so persisting it
# contaminates nothing. (The module cache lives in `.build/` and is unaffected
# either way.) The `$(id -u)` suffix keeps two users on one box out of each
# other's dir; concurrent worktrees sharing one is fine and intended, since
# everything in it is either a cache or a directory nobody may write to.
sanctioned_home="$scratch_home/sanctioned/tbd"
fake_home="/tmp/tbd-test-fakehome.$(id -u)"
mkdir -p "$sanctioned_home" "$fake_home"

# The decoys. These are the two names a leak reaches for — `$HOME/tbd` is what
# `WorktreeLayout.basePath` used to hand-build, and `$HOME/.claude` is what a
# default-constructed `ClaudeProfileConfigDirManager` mirrors into. Mode 000
# turns "silently wrote to the developer's real store" into "this test failed,
# here, on this path".
#
# Recreated unconditionally rather than only when absent: a previous run that
# died between `mkdir` and `chmod`, or a stray `chmod` by a curious reader,
# would otherwise leave a permanently disarmed tripwire that nothing reports.
for decoy in tbd .claude; do
  mkdir -p "$fake_home/$decoy"
  chmod 000 "$fake_home/$decoy"
done

# `${a[@]+"${a[@]}"}` — macOS ships bash 3.2, where a bare `"${a[@]}"` on an
# EMPTY array is an unbound-variable error under `set -u`.
set +e
env \
  TBD_HOME="$sanctioned_home" \
  TBD_SOCKET_PATH="$sanctioned_home/sock" \
  TBD_CLAUDE_HOST_HOME="$sanctioned_home/claude-host" \
  HOME="$fake_home" \
  CFFIXED_USER_HOME="$fake_home" \
  swift test ${swift_test_args[@]+"${swift_test_args[@]}"}
test_status=$?
set -e

if [ "$fingerprint" -eq 0 ]; then
  exit "$test_status"
fi

fingerprint_after="$(scripts/tbd-home-fingerprint.sh)"

if [ "$fingerprint_before" != "$fingerprint_after" ]; then
  echo >&2
  echo "=======================================================================" >&2
  echo "  THE TEST RUN WROTE INTO ~/tbd OR ~/.claude" >&2
  echo "=======================================================================" >&2
  echo >&2
  echo "CLAUDE.md: \"Tests must not touch ~/tbd\". Something resolved a real" >&2
  echo "config path despite TBD_HOME=$sanctioned_home," >&2
  echo "TBD_CLAUDE_HOST_HOME=$sanctioned_home/claude-host and" >&2
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
