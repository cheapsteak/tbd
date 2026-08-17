#!/usr/bin/env bash
#
# The test suite, with the developer's real `~/tbd`, `~/.claude`, `~/.codex`
# and tmux socket directory fenced off.
#
# SwiftPM is invoked through `scripts/swift-safe`, never directly: that wrapper
# holds a machine-global admission lock and bounds compiler jobs so concurrent
# TBD worktrees cannot each start a full compiler swarm, and the repo guardrail
# blocks raw `swift build/test/run` for that reason. The two wrappers solve
# orthogonal problems — admission control there, filesystem isolation here — and
# every argument this script does not consume is forwarded through to
# `swift test`.
#
# STACKING THEM TAKES ONE EXPLICIT LINE, and leaving it out silently disarms the
# admission half. `swift-safe` derives its lock from `$TBD_HOME/runtime/…` when
# `TBD_SWIFT_LOCK_PATH` is unset — and the fence below points `TBD_HOME` at a
# `mktemp -d` that is unique per invocation, so every fenced run would take a
# PRIVATE lock and two concurrent runs would never serialize. That is precisely
# the compiler swarm `swift-safe` exists to prevent, arriving through the
# wrapper that is supposed to compose with it. So `TBD_SWIFT_LOCK_PATH` is
# pinned below, computed from the REAL home before the `env` prefix overrides it
# and passed explicitly — never left for `swift-safe` to derive from an
# environment this script has already rewritten.
#
# Three layers. The first two are always on; the third is CI-only.
#
#   1. CONTAINMENT — always on. `TBD_HOME`, `TBD_SOCKET_PATH`,
#      `TBD_CLAUDE_HOST_HOME` and `TMUX_TMPDIR` point at a fresh scratch dir
#      for the whole run, so any code path that resolves a TBD-owned path — or
#      the host Claude store a profile dir mirrors, or a tmux socket — lands
#      there instead of in the real one. This catches leaks nobody has
#      diagnosed yet, including ones in code that has no injection seam at all.
#   2. THE TRIPWIRE — always on. `HOME` and `CFFIXED_USER_HOME` point at a
#      *different* directory from layer 1, and the two names a leak reaches for
#      inside it — `tbd` and `.claude` — are pre-created mode `000`. Code that
#      asks the fence where home is lands in layer 1's scratch and works; code
#      that assembles a path out of the home directory instead gets `EACCES` at
#      the exact call site, inside the failing test, with the offending path in
#      the error. See "READING A PERMISSION-DENIED FAILURE" below.
#   3. DETECTION — on in CI (`$CI` set), off elsewhere; `--fingerprint` opts in
#      locally and `--no-fingerprint` forces it off anywhere. The real `~/tbd`,
#      `~/.claude`, `~/.codex` and tmux socket directory are fingerprinted
#      before and after, and a changed fingerprint fails the run even when
#      every test passed. This is now a backstop rather than the primary
#      guard; see "WHY THE TRIPWIRE SUPERSEDES THE FINGERPRINT".
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
# All seven FENCE vars are OVERWRITTEN, not defaulted: an inherited value is
# discarded for the duration of the run. That is the point — a fence you can
# disable by exporting something first is not a fence — but it does mean this
# wrapper cannot be pointed at a config dir of your own.
#
# `TBD_SWIFT_LOCK_PATH`, the eighth, is the deliberate exception: it is
# admission control rather than isolation, an inherited value names a lock the
# caller wants this run to contend on, and honouring it can only ever make the
# run wait for more things. Nothing about the fence weakens if it is respected.
#
# They are applied as a prefix on the `swift test` invocation rather than
# exported, so this script's own `$HOME` and `$TMUX_TMPDIR` stay real and
# `scripts/tbd-home-fingerprint.sh` — which deliberately reads both — needs
# no special-casing on either side of the run. The shared-lock computation below
# depends on the same property: it reads the real `$HOME` / `$TBD_HOME`, which
# only works because nothing here has exported the fenced values.
#
# `--fingerprint` / `--no-fingerprint` are consumed wherever they appear; every
# other argument is forwarded to `swift test` untouched. Position-independent on
# purpose: a leading-only strip forwards a late `--no-fingerprint` to `swift
# test`, which errors out. That is loud rather than silent, but a positional
# collision is impossible — `swift test` has no flag of either name — so
# filtering them out everywhere is strictly safer at no cost. Last one wins.
#   scripts/test.sh
#   scripts/test.sh --parallel --filter '^TBDDaemonTests\.'
#   scripts/test.sh --no-fingerprint --parallel
#   scripts/test.sh --fingerprint            # deliberate local leak hunt
#
# THE REMOTE VERIFICATION VALVE — OFF UNLESS `TBD_REMOTE_VERIFY=1`.
# (docs/specs/2026-08-16-remote-verification-valve-design.md.) This wrapper is
# the only caller that opts in, because it is the one whose entire output is a
# verdict: nothing it produces has to exist on this disk, so the same bit can be
# computed on GitHub. `scripts/restart.sh` and every other artifact build stay
# local permanently and are untouched by any of this.
#
# Enabled, the run bounds its queueing: `TBD_SWIFT_QUEUE_YIELD_SECONDS` tells
# `scripts/swift-safe` to give up its place in the queue after
# `TBD_REMOTE_VERIFY_YIELD_SECONDS` (default 300) and answer 76. The threshold
# measures QUEUE time, never run time, so a yield discards nothing — a wait that
# never acquired the slot has compiled nothing. 300 is sized against remote
# capacity rather than impatience: two hours of sampled contention put T=60 at
# ~28 trips an hour against a remote that sustains ~12 runs an hour, while T=300
# fires four or five times, on the tail this valve exists for.
#
# THREE EXIT CODES DECIDE WHAT HAPPENS NEXT, AND CONFLATING ANY TWO IS A SILENT
# WRONG ANSWER:
#
#   76 from `swift-safe` — it yielded the queue at our request. Verify remotely.
#   75 from `swift-safe` — the wait TIMED OUT, or was ABANDONED because nobody
#      is left to read the result. Neither is a request to verify elsewhere, so
#      75 is propagated untouched; dispatching one spends a scarce remote slot
#      on a verdict nobody wants.
#   78 from `remote-verify.sh` — a precondition refused (dirty tree, no `gh`,
#      no pushable ref). The run falls back to the local queue. THE VALVE IS AN
#      OPTIMISATION, NEVER A GATE: a refusal must never fail a run.
#
# Any other status from `remote-verify.sh` is the run's verdict — 0 for a green
# remote run, 1 for a red one whose failing tests it has already printed.
#
# TESTED BY `scripts/test.test.sh`, which drives the guards below against
# fixture directories with a stub `swift` — no build, no real `~/tbd`. Every
# guard there is mutation-checked: the assertion is shown going red against a
# deliberately weakened copy of this file. A guard nobody can break on purpose
# is a guard nobody can prove works.

# ---------------------------------------------------------------------------
# GUARD HELPERS
#
# Defined above the source guard so the harness can call them directly — the
# uid arm in particular cannot be reached by running this script, since a test
# cannot create a directory owned by somebody else without root. Strict mode is
# set below, after the guard, so sourcing this file has no side effects at all.
# ---------------------------------------------------------------------------

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

# The post-`mkdir` half. `stat -f '%u'` is deliberately not given `-L`, so a
# path that turned into a symlink between the two calls reports the link's own
# owner rather than the target's — but the `-L` test above it is what actually
# rejects that case.
#
# THE RESIDUAL TOCTOU IS ACCEPTED, DELIBERATELY. A same-uid process could swap
# the directory for a symlink between this check and the `chmod` that follows.
# Closing it needs an fd held across both — `open(O_NOFOLLOW)` then `fchmod` —
# which bash cannot express, so the fix would be a helper binary. It buys
# nothing: every parent directory on the path is already mode 700 and owned by
# this uid ($TMPDIR is per-user on darwin, and the `/tmp` fallback is chmod
# 700'd immediately after this check), so the only process that can win the
# race is one already running as this user, which can simply chmod the target
# directly and needs no race at all. The checks exist to stop a FOREIGN uid
# planting a symlink in a world-writable `/tmp`, and against that threat they
# are not racy: the sticky bit means only the owner can replace an entry.
require_owned_dir_after_mkdir() {
  local path="$1" what="$2" owner
  [ -L "$path" ] && fence_bail "$what is a SYMLINK: $path"
  [ -d "$path" ] || fence_bail "$what is not a directory: $path"
  owner="$(stat -f '%u' "$path")"
  [ "$owner" = "$(id -u)" ] || fence_bail "$what is owned by uid $owner, not $(id -u): $path"
}

# THE SHARED ADMISSION LOCK. The branches mirror `_lock_path()` in
# `scripts/swift-safe`: an explicit `TBD_SWIFT_LOCK_PATH` wins, otherwise
# `$TBD_HOME/runtime/…`, otherwise `~/tbd/runtime/…`. Mirroring rather than
# inventing a path of our own is what makes a fenced run contend with the plain
# `scripts/swift-safe build` a sibling worktree is running; a lock nobody else
# takes is not a lock.
#
# It must be called while `$HOME` and `$TBD_HOME` still hold the CALLER's real
# values. See the call site.
resolve_swift_lock_path() {
  if [ -n "${TBD_SWIFT_LOCK_PATH:-}" ]; then
    printf '%s\n' "$TBD_SWIFT_LOCK_PATH"
  else
    printf '%s\n' "${TBD_HOME:-$HOME/tbd}/runtime/swift-build.lock"
  fi
}

# THE YIELD BOUND IS VALIDATED HERE BECAUSE A BAD ONE IS INVISIBLE DOWNSTREAM.
# `scripts/swift-safe` refuses a non-positive, `nan`, `inf` or non-numeric
# `TBD_SWIFT_QUEUE_YIELD_SECONDS` with a `SystemExit`, and a `SystemExit` carrying
# a message exits **1** — which is exactly what a failing test suite returns. So
# a forwarded typo does not look like a misconfiguration, it looks like a red
# run, and the fix people would reach for is to go hunting through tests that
# never ran. `TBD_REMOTE_VERIFY_YIELD_SECONDS=0` is the plausible way somebody
# spells "always go remote", and it lands precisely there.
#
# The accepted grammar is deliberately narrower than `float()`: decimal digits
# with at most one point, and not zero in any spelling. That refuses `1e3` and
# `+1`, which `swift-safe` would have taken — loudly, at the call site, with the
# variable named — rather than widening a validator whose whole job is to be
# obviously right.
valid_yield_bound() {
  local value="$1"
  case "$value" in
    ''|*[!0-9.]*) return 1 ;;   # empty, or anything but digits and points
    *.*.*)        return 1 ;;   # more than one point
    .)            return 1 ;;   # a lone point
  esac
  # Zero in every spelling — `0`, `00`, `0.0`, `.0` — is what is left once the
  # zeros and the point come out.
  case "${value//0/}" in
    ''|.) return 1 ;;
  esac
  return 0
}

# Sourced rather than executed: `scripts/test.test.sh` wants the helpers above
# without the run below. The siblings in this directory express the same thing
# as `main "$@"` under the inverse condition; this script stays straight-line
# because every statement below is a step of one fence that runs exactly once,
# and there is nothing to call twice.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

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

# THE VALVE, CONFIGURED BEFORE ANYTHING ELSE HAPPENS. See "THE REMOTE
# VERIFICATION VALVE" above. Deciding it here means a bad bound is refused
# before a scratch home is minted, a lock file is touched or a fingerprint is
# taken — there is nothing to unwind, and the caller finds out immediately
# rather than half an hour into a wait.
#
# `TBD_REMOTE_VERIFY` unset leaves `remote_verify_enabled` at 0 and
# `fenced_env` empty, so every path below is what it was before the valve
# existed: no bound is forwarded, and 76 is just an exit status.
DEFAULT_REMOTE_VERIFY_YIELD_SECONDS=300
YIELDED_THE_QUEUE=76
REMOTE_VERIFY_REFUSED=78

remote_verify_enabled=0
fenced_env=()
if [ "${TBD_REMOTE_VERIFY:-}" = "1" ]; then
  remote_verify_enabled=1
  yield_seconds="${TBD_REMOTE_VERIFY_YIELD_SECONDS-$DEFAULT_REMOTE_VERIFY_YIELD_SECONDS}"
  if ! valid_yield_bound "$yield_seconds"; then
    echo "test.sh: TBD_REMOTE_VERIFY_YIELD_SECONDS must be a positive number" >&2
    echo "         (decimal digits, at most one point), got: '$yield_seconds'" >&2
    echo "         Forwarding it would make swift-safe exit 1, which is" >&2
    echo "         indistinguishable from a failing test suite." >&2
    exit 64
  fi
  fenced_env=(TBD_SWIFT_QUEUE_YIELD_SECONDS="$yield_seconds")
fi

# Resolved HERE, while `$HOME` and `$TBD_HOME` still hold the caller's real
# values — the `env` prefix at the bottom rewrites both, and `swift-safe`
# deriving the lock from the rewritten pair is exactly the bug this pins shut.
swift_lock_path="$(resolve_swift_lock_path)"

# Created BEFORE the fingerprint is taken, not left to `swift-safe`. The lock
# lives in the real `~/tbd`, so a run that materialises it mid-flight adds a
# `~/tbd/runtime` entry between the two snapshots and reddens the detection
# layer on any box where that directory does not exist yet — a CI runner, every
# time. Bringing it into existence up front puts it on BOTH sides of the diff.
# The detector already prunes this directory's contents as volatile (see
# `scripts/tbd-home-fingerprint.sh`), so nothing is hidden by doing so: the
# `runtime` entry itself is still fingerprinted, and every other name in `~/tbd`
# is still compared exactly as before.
mkdir -p "$(dirname "$swift_lock_path")"
: >> "$swift_lock_path"

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
#
# TMUX_TMPDIR is the fifth, and the store it fences is not a TBD one at all:
# `/tmp/tmux-<uid>`, shared by every tmux server this user runs. Nothing in
# `Sources/` or `Tests/` ever passes an absolute `-S <path>`; every call site
# uses `-L <name>`, which tmux resolves under `$TMUX_TMPDIR/tmux-<uid>/`, so
# this one variable redirects all of them.
#
# WHY IT MATTERS MORE THAN IT LOOKS: **tmux never unlinks its socket file on
# server exit** — measured against tmux 3.6a, and true for a killed server, a
# cleanly `kill-server`ed one and one that self-exits when its last session
# ends alike. It unlinks a stale socket lazily instead, at bind time, when a
# NEW server is started on that exact path. Every test here mints a fresh
# UUID-suffixed socket name, so that lazy unlink never fires and every file
# survives forever: ~7,100 dead socket files accumulated in one developer's
# real `/tmp/tmux-<uid>` over nine days, behind 7 live servers. No teardown
# can fix that — a test that dutifully kills its server still leaves the file
# — which is why the fix is a fenced directory that gets deleted wholesale,
# not a missing `kill-server` somewhere.
#
# IT MUST STAY DIRECTLY UNDER THE SHORT `/tmp` SCRATCH ROOT. tmux connects
# over a unix socket, so `$TMUX_TMPDIR/tmux-<uid>/<name>` is bound by the same
# ~104-byte `sun_path` cap as TBD's own socket, and tmux reports an overflow
# only as `error connecting to <path> (File name too long)`. The budget:
# `/tmp/tbd-test-home.XXXXXXXX/tmux/tmux-<uid>/` is ~42 bytes, and the suite's
# longest socket name is ~31 bytes today (`tbd-test-send-mismatch-` plus 8 hex
# characters) with 50 budgeted as headroom — ~92 bytes against ~104. Nesting
# this directory any deeper spends that headroom and every live tmux test
# starts failing at once. `scripts/test.test.sh` asserts the budget so a
# refactor that moves it cannot land quietly.
scratch_home="$(mktemp -d /tmp/tbd-test-home.XXXXXXXX)"
tmux_tmpdir="$scratch_home/tmux"

# THE SWEEP KILLS SERVERS; THE `rm -rf` ONLY REMOVES FILES. Those are not the
# same leak, and the expensive one is the process: unlinking a socket out from
# under a live tmux server leaves it running forever with nothing able to reach
# it. So every socket the run created is issued a `kill-server` BEFORE the
# scratch dir goes away. Most will already be dead — a dead server's file is
# still there (see above) — so errors are ignored throughout.
sweep_tmux_servers() {
  local tmux_bin socket_dir socket
  tmux_bin="$(command -v tmux || true)"
  # No tmux on PATH means no server this run could have started.
  [ -n "$tmux_bin" ] || return 0
  # `${var:-}` — defensive under `set -u`. The assignment above precedes the
  # trap today; this keeps that ordering from being load-bearing.
  [ -n "${tmux_tmpdir:-}" ] || return 0
  socket_dir="$tmux_tmpdir/tmux-$(id -u)"
  [ -d "$socket_dir" ] || return 0
  for socket in "$socket_dir"/*; do
    # `-e` rather than `-S`: it skips the unmatched-glob case, and tmux owns
    # this directory exclusively, so anything in it is one of its sockets.
    [ -e "$socket" ] || continue
    "$tmux_bin" -S "$socket" kill-server >/dev/null 2>&1 || true
  done
  return 0
}

cleanup() { sweep_tmux_servers; rm -rf "$scratch_home"; }
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

# tmux creates `$TMUX_TMPDIR/tmux-<uid>` itself, but refuses if the parent is
# missing — so the parent is ours to make. Mode 700 for the same reason tmux
# insists on 700 for the directory it creates inside: a socket anyone can
# connect to is a shell anyone can type into. The scratch root is already
# ours alone; this is belt and braces on a `/tmp` path.
mkdir -p "$tmux_tmpdir"
chmod 700 "$tmux_tmpdir"

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

# THE FENCED INVOCATION LIVES IN ONE PLACE, AND THAT IS THE POINT. The valve's
# fallback below runs it a second time, and a second copy of this `env` prefix
# is a fence that can drift: the two copies would have to be kept in step by
# hand forever, and the failure mode of missing one is a run that silently
# writes into the developer's real `~/tbd`. There is exactly one prefix, so
# there is nothing to keep in step.
#
# `fenced_env` carries per-call environment and comes FIRST, so a fence
# variable can never be overridden by it — `env` takes the last assignment of a
# name, and the fence must always be the last word.
#
# `${a[@]+"${a[@]}"}` — macOS ships bash 3.2, where a bare `"${a[@]}"` on an
# EMPTY array is an unbound-variable error under `set -u`.
run_fenced_suite() {
  env \
    ${fenced_env[@]+"${fenced_env[@]}"} \
    TBD_HOME="$sanctioned_home" \
    TBD_SOCKET_PATH="$sanctioned_home/sock" \
    TBD_CLAUDE_HOST_HOME="$sanctioned_home/claude-host" \
    TBD_TEST_CODEX_HOME="$sanctioned_home/codex-host" \
    TMUX_TMPDIR="$tmux_tmpdir" \
    TBD_SWIFT_LOCK_PATH="$swift_lock_path" \
    HOME="$fake_home" \
    CFFIXED_USER_HOME="$fake_home" \
    scripts/swift-safe test ${swift_test_args[@]+"${swift_test_args[@]}"}
}

set +e
run_fenced_suite
test_status=$?
set -e

# THE OVERFLOW PATH. 76 is `swift-safe` reporting that it gave up its place in
# the queue at our request, having compiled nothing — so there is no work to
# discard and no build to kill, and the same verdict can be fetched from CI.
#
# The flag is re-checked rather than inferred from the status. A bound is only
# ever forwarded when the valve is on, so 76 cannot arise here otherwise — but
# inferring it would mean a suite that exits 76 for reasons of its own silently
# changed what this wrapper does, and "the flag is off" must mean the pre-valve
# behavior exactly.
if [ "$remote_verify_enabled" -eq 1 ] && [ "$test_status" -eq "$YIELDED_THE_QUEUE" ]; then
  # A MISSING REMOTE PATH IS A REFUSAL, NOT A VERDICT. Without this the shell
  # answers 127 for "command not found", which would be adopted below as the
  # run's exit status — a broken checkout reported as a failing test suite, with
  # nothing said about why. Everything else here exists to keep a misrouted exit
  # code from masquerading as a test result; so does this.
  if [ ! -x scripts/remote-verify.sh ]; then
    echo "test.sh: scripts/remote-verify.sh is missing or not executable;" >&2
    echo "         staying in the local queue instead of verifying remotely." >&2
    remote_status=$REMOTE_VERIFY_REFUSED
  else
    # Deliberately NOT fenced: the remote path needs the caller's real `$HOME`
    # to find `gh`'s credentials and the real repository to push from. It
    # touches no TBD-owned path.
    set +e
    scripts/remote-verify.sh
    remote_status=$?
    set -e
  fi

  if [ "$remote_status" -eq "$REMOTE_VERIFY_REFUSED" ]; then
    # A REFUSAL IS NOT A FAILURE. The remote path named its condition on stderr
    # and declined; this lane returns to the local queue and waits it out, as it
    # would have done before the valve existed. Anything else would make the
    # valve a gate — a run that cannot go remote must still be able to test.
    #
    # The re-run drops the bound, so it queues without limit rather than
    # yielding again and asking a precondition that just refused a second time.
    fenced_env=()
    set +e
    run_fenced_suite
    test_status=$?
    set -e
  else
    # 0 or 1 — the remote verdict, with its failing tests already printed.
    test_status=$remote_status
  fi
fi

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
  echo "  THE TEST RUN WROTE INTO ~/tbd, ~/.claude, ~/.codex OR /tmp/tmux-<uid>" >&2
  echo "=======================================================================" >&2
  echo >&2
  echo "CLAUDE.md: \"Tests must not touch ~/tbd\". Something resolved a real" >&2
  echo "config path despite TBD_HOME=$sanctioned_home," >&2
  echo "TBD_CLAUDE_HOST_HOME=$sanctioned_home/claude-host," >&2
  echo "TBD_TEST_CODEX_HOME=$sanctioned_home/codex-host," >&2
  echo "TMUX_TMPDIR=$tmux_tmpdir and" >&2
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
  echo "If the entry is a tmux socket, the fix is TMUX_TMPDIR — never a" >&2
  echo "relaxed guard and never a teardown. tmux does NOT unlink its socket" >&2
  echo "file when a server exits, so killing the server leaves the file" >&2
  echo "behind; the only thing that removes it is deleting the directory it" >&2
  echo "lives in, which this wrapper can do only for a directory it owns." >&2
  echo "Something spawned tmux with an environment that dropped TMUX_TMPDIR:" >&2
  echo "look for a Process whose \`environment\` is built from scratch." >&2
  echo >&2
  echo "Reaching here at all is now unusual: a hand-built \$HOME path normally" >&2
  echo "dies at its call site on the mode-000 decoys in $fake_home." >&2
  echo "A leak that got past those wrote somewhere the decoys do not cover —" >&2
  echo "note the path above and consider whether it needs a third decoy." >&2
  echo >&2
  exit 1
fi

exit "$test_status"
