#!/usr/bin/env python3
"""Convert hardlinked dependency trees to APFS clones, in place and atomically.

WHY
---
A package manager configured to install by *hardlink* from a shared cache gives
every file a link count equal to the number of checkouts sharing it. macOS
resolves inode->path by walking the sibling-link set, so one lookup becomes N
path resolutions, and `mds` burns a core doing it -- with Spotlight indexing
switched off, which is what makes it so hard to attribute.

Measured on a machine with ~60 worktrees, before and after running this:

    mds filesystem operations   28,959/sec  ->  6.3/sec     (~4,560x)
    mds CPU                     40.8-45.1%  ->  0.06-0.56%  of a core
    mds resident set               185 MB   ->  12 MB
    disk used                     unchanged

Full mechanism, the diagnostic that distinguishes this from an ordinary
Spotlight crawl, and the measurement traps involved:
docs/perf/2026-08-30-macos-mds-hardlink-fanout.md

On APFS the fix is to install by *clone* (copy-on-write) instead: identical
block sharing, but every link count stays 1, so there is no fan-out. Changing
that setting only affects future installs, which is what this script is for --
it converts trees that already exist, with no reinstall, no network and no
lockfile. Cloning a file from itself yields an independent inode that still
shares every block, so content is byte-identical and disk does not grow.

SAFETY
------
Each file is swapped with an atomic os.replace(), so a tree never has a window
where a path is missing: a concurrent importer sees either the old inode or the
new one. Processes merely holding open file descriptors are unaffected, since
POSIX keeps the inode alive across replace and unlink.

The one case that can lose data is an installer writing into the tree while the
conversion runs: the replace can discard that write, and nothing downstream will
notice, because the replacement has nlink=1 exactly like a correct result. The
preflight below declines to *start* when an installer is already visible in the
process table, but that is a snapshot, not a lock -- an installer that starts
afterwards races, and no lock exists that uv or pnpm would honour. So the
preflight removes the common accident, not the hazard. Do not run this during a
window when installs may begin; run it when the fleet is idle.

Each swap goes through a short temp name beside the file, `.__reclone<pid>_<n>`.
A run killed between clone and replace leaves one behind. The next run removes
any whose pid is no longer alive -- a live pid may be another run mid-swap, so
those are left alone -- and verification reports any that remain.

clonefile(2) is called through ctypes rather than by spawning `cp -c` per file:
the fork overhead, not the cloning, is what dominates (~120 files/sec spawning
versus ~855/sec in-process). Cloning a whole directory with `cp -cR` and
swapping it in is comparably fast, but renames the live directory and so leaves
a window where the tree does not exist.

USAGE
-----
    scripts/reclone-hardlinked-deps.py --dry-run          # every TBD worktree
    scripts/reclone-hardlinked-deps.py                    # convert them
    scripts/reclone-hardlinked-deps.py PATH [PATH ...]    # specific worktrees
    scripts/reclone-hardlinked-deps.py --base DIR         # another worktree root

A PATH may also be a dependency tree itself: `node_modules`, `vendor/bundle`,
or a virtualenv, which is narrowed to its lib/ and verified by starting its
interpreter, exactly as the worktree scan treats it.

Idempotent: files already at nlink=1 are skipped, so re-running is a fast no-op.
Reports an empty scan as an error, never as success -- "found nothing" and
"everything is already converted" must not look alike.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import itertools
import os
import re
import stat
import subprocess
import sys
import time
from pathlib import Path

# Dependency directories worth converting. `.venv/lib` rather than `.venv` so we
# skip bin/ and pyvenv.cfg, which are small and sometimes deliberately unique.
DEP_SUBPATHS = (".venv/lib", "node_modules", "vendor/bundle")

# The installers that write each kind of tree above, with the subcommands that
# write. "" is a bare invocation, which installs for yarn and bundle. Matching
# the subcommand, not a substring, keeps long-lived `yarn dev`, `npm run`,
# `uv run` and `bundle exec` processes from reading as an install.
INSTALLERS = {
    # .venv/lib
    "uv": {"sync", "pip", "add", "remove"},
    "pip": {"install", "uninstall"},
    "poetry": {"install", "sync", "add", "remove", "update"},
    # node_modules
    "npm": {"install", "i", "ci", "add", "update", "uninstall", "rebuild", "dedupe", "prune"},
    "pnpm": {"install", "i", "add", "update", "up", "remove", "rm"},
    "yarn": {"", "install", "add", "upgrade", "remove"},
    "bun": {"install", "i", "add", "remove", "update"},
    # vendor/bundle
    "bundle": {"", "install", "update", "add"},
}
# Script installers appear in `ps` as `node .../yarn.js install` or
# `python -m pip install`: the tool is then the interpreter's script or module.
INTERPRETERS = {"node", "python", "ruby"}
# `pip3.12` -> pip, `npm-cli.js` -> npm, `yarn-4.4.0.cjs` -> yarn.
_TOOL_NAME = re.compile(r"([a-z]+?)(?:-cli|-?[\d.]+)?(?:\.[cm]?js)?")
_TOOL_ALIASES = {"bundler": "bundle"}

# The atomic swap's temp name. Short and independent of the file it replaces, so
# it never approaches NAME_MAX; it carries the pid so a later run can tell an
# orphan of a killed run from a swap still in flight. `_.+` rather than `_\d+`
# also reclaims orphans from earlier versions of this script, which appended the
# replaced file's name.
TMP_PREFIX = ".__reclone"
_TMP_NAME = re.compile(re.escape(TMP_PREFIX) + r"(\d+)_.+")


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def load_clonefile():
    """clonefile(2) — APFS only. Returns None where it does not exist."""
    if sys.platform != "darwin":
        return None
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    fn = getattr(libc, "clonefile", None)
    if fn is None:
        return None
    fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    fn.restype = ctypes.c_int
    return fn


def installer_running() -> str | None:
    """Best-effort preflight: is an installer visible right now?

    A snapshot of the process table, not exclusion. One that starts after this
    returns still races the conversion. It catches the common accident -- running
    this while a sync is obviously in progress -- and nothing more.
    """
    try:
        out = subprocess.run(
            ["ps", "-Ao", "command"], capture_output=True, text=True, timeout=10
        ).stdout
    except Exception:
        return None  # cannot tell; do not block on a failed probe
    for line in out.splitlines():
        if _is_install(line.split()):
            return line.strip()[:120]
    return None


def _tool(word: str) -> str | None:
    m = _TOOL_NAME.fullmatch(os.path.basename(word).lower())
    return m and _TOOL_ALIASES.get(m[1], m[1])


def _is_install(argv: list[str]) -> bool:
    """Is this command line one of INSTALLERS, running a subcommand that writes?"""
    if not argv:
        return False
    tool, args = _tool(argv[0]), argv[1:]
    if tool in INTERPRETERS:
        # The first non-flag argument is the script; after `-m`, the module.
        rest = list(itertools.dropwhile(lambda a: a.startswith("-"), args))
        if not rest:
            return False
        tool, args = _tool(rest[0]), rest[1:]
    subcommands = INSTALLERS.get(tool)
    if subcommands is None:
        return False
    # A flag's value can sit before the subcommand (`pnpm --filter app install`),
    # so look at the first two words; further out are a script's own arguments
    # (`uv run pytest -k add`).
    words = [a for a in args if not a.startswith("-")][:2]
    if not words:
        return "" in subcommands
    return any(w in subcommands for w in words)


def _pid_alive(pid: int) -> bool:
    """False only when the pid is certainly gone; unsure means keep the file."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except (OSError, OverflowError):
        pass  # exists but is not ours to signal, or is not a pid at all
    return True


def tbd_worktree_roots() -> list[Path]:
    """TBD lays worktrees out as $TBD_HOME/worktrees/<repo>/<worktree>."""
    base = Path(os.environ.get("TBD_HOME", Path.home() / "tbd")) / "worktrees"
    if not base.is_dir():
        return []
    return [wt for repo in sorted(base.iterdir()) if repo.is_dir()
            for wt in sorted(repo.iterdir()) if wt.is_dir()]


def _is_venv(d: Path) -> bool:
    # PEP 405: every venv creator (venv, virtualenv, uv) writes pyvenv.cfg.
    return d.name == ".venv" or (d / "pyvenv.cfg").is_file()


def expand(targets: list[Path]) -> list[Path]:
    """A worktree becomes the dependency trees inside it; a dependency tree is
    itself, except that a virtualenv narrows to its lib/ as in DEP_SUBPATHS."""
    trees: list[Path] = []
    for t in targets:
        t = Path(os.path.abspath(t))  # so `.` and a bare `lib` have a parent name
        if t.name == "node_modules" or (t.name == "bundle" and t.parent.name == "vendor"):
            trees.append(t)
        elif t.name == "lib" and _is_venv(t.parent):
            trees.append(t)
        elif _is_venv(t):
            if (t / "lib").is_dir():
                trees.append(t / "lib")
        else:
            trees.extend(t / sub for sub in DEP_SUBPATHS if (t / sub).is_dir())
    return trees


def convert(root: Path, clonefile, dry: bool,
            walk_errors: list[OSError]) -> tuple[int, int, int, int]:
    """Returns (converted, peak_nlink_seen, failed, stale_temps_removed).

    os.walk swallows OSError by default, so an unreadable subtree is skipped in
    silence -- and a scan that never saw a directory reports the same "clean" as
    one that saw it and found nothing. Collect those failures so the caller can
    refuse to claim success.
    """
    done = failed = peak = swept = 0
    pid, seq = os.getpid(), itertools.count()
    for dirpath, _dirs, files in os.walk(root, onerror=walk_errors.append):
        for name in files:
            p = os.path.join(dirpath, name)
            if m := _TMP_NAME.fullmatch(name):
                # A swap temp. Only a dead run's is an orphan; a live pid's may
                # be mid-replace in another run.
                if not _pid_alive(int(m[1])):
                    try:
                        if not dry:
                            os.unlink(p)
                        swept += 1
                    except OSError:
                        pass  # verify() reports it
                continue
            try:
                st = os.lstat(p)
            except OSError:
                continue
            # Symlinks share no blocks; nlink==1 files are already done.
            if not stat.S_ISREG(st.st_mode) or st.st_nlink <= 1:
                continue
            peak = max(peak, st.st_nlink)
            if dry:
                done += 1
                continue
            tmp = os.path.join(dirpath, f"{TMP_PREFIX}{pid}_{next(seq)}")
            if clonefile(os.fsencode(p), os.fsencode(tmp), 0) != 0:
                # Nothing was created -- on EEXIST, whatever holds that name is
                # not ours -- so there is nothing to remove.
                failed += 1
                continue
            try:
                os.chmod(tmp, st.st_mode & 0o7777)
                os.utime(tmp, (st.st_atime, st.st_mtime))
                os.replace(tmp, p)  # atomic: p is never absent
                done += 1
            except OSError:
                try:
                    os.unlink(tmp)  # ours: clonefile just created it
                except OSError:
                    pass
                failed += 1
    return done, peak, failed, swept


def verify(trees: list[Path]) -> bool:
    """A silent partial conversion otherwise looks exactly like success."""
    ok = True
    for t in trees:
        errs: list[OSError] = []
        remaining = temps = 0
        for dirpath, _d, files in os.walk(t, onerror=errs.append):
            for f in files:
                if _TMP_NAME.fullmatch(f):
                    temps += 1
                elif _nlink_gt1(os.path.join(dirpath, f)):
                    remaining += 1
        if errs:
            # Unverifiable is not the same as verified. Say so.
            print(f"  could not read {len(errs)} director(ies) under {t}; "
                  f"cannot confirm it is clean (first: {errs[0]})", file=sys.stderr)
            ok = False
        if remaining:
            print(f"  {remaining:,} file(s) still hardlinked in {t}", file=sys.stderr)
            ok = False
        if temps:
            print(f"  {temps:,} {TMP_PREFIX}* temp file(s) remain in {t} "
                  "(another run still active, or removal failed)", file=sys.stderr)
            ok = False
    for t in trees:
        # A converted venv that no longer runs is the failure worth catching loud.
        if t.name == "lib" and _is_venv(t.parent):
            py = t.parent / "bin" / "python"
            if py.is_file() and os.access(py, os.X_OK):
                r = subprocess.run([str(py), "-c", "import sys"], capture_output=True)
                if r.returncode != 0:
                    print(f"  FAILED: {t.parent} interpreter no longer runs", file=sys.stderr)
                    ok = False
    return ok


def _nlink_gt1(path: str) -> bool:
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_nlink > 1


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Convert hardlinked dependency trees to APFS clones.",
        epilog="With no paths, scans every TBD worktree under $TBD_HOME/worktrees.",
    )
    ap.add_argument("paths", nargs="*", type=Path,
                    help="worktrees, or node_modules / vendor/bundle / virtualenv dirs")
    ap.add_argument("--base", action="append", default=[], type=Path,
                    help="additional worktree root to scan (repeatable)")
    ap.add_argument("--dry-run", action="store_true", help="report only; change nothing")
    ap.add_argument("--quiet", action="store_true", help="summary only")
    args = ap.parse_args()

    # stdout is block-buffered when redirected, so a long scan would print
    # nothing until it finished -- indistinguishable from a hang. The shell
    # version of this tool passed `python3 -u`; a standalone script has to ask.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass  # not a real stream (pytest capture, a pipe replaced by a StringIO)

    clonefile = load_clonefile()
    if clonefile is None:
        print("Not macOS/APFS — hardlink imports are correct here; nothing to do.")
        return 0

    if not args.dry_run and (proc := installer_running()) is not None:
        die(f"REFUSING: an installer is running.\n  {proc}\n"
            "  Converting a tree while it is being written to can lose the install.")

    targets: list[Path] = []
    for p in args.paths:
        if not p.is_dir():
            die(f"Not a directory: {p}", 2)
        targets.append(p)
    for b in args.base:
        if not b.is_dir():
            die(f"Not a directory: {b}", 2)
        targets.extend(sorted(d for d in b.iterdir() if d.is_dir()))
    if not targets:
        targets = tbd_worktree_roots()

    trees = expand(targets)
    if not trees:
        die("REFUSING: found no dependency trees to scan.\n"
            f"  Looked at {len(targets)} target(s) for: {', '.join(DEP_SUBPATHS)}\n"
            "  Reported as an error, not success: an empty scan is\n"
            "  indistinguishable from 'everything is already converted'.\n"
            "  Pass explicit paths, --base DIR, or set $TBD_HOME.")

    if not args.quiet:
        print(f"Scanning {len(trees)} dependency tree(s)"
              f"{' (dry run)' if args.dry_run else ''}...")

    total = failed_total = swept_total = peak_overall = 0
    walk_errors: list[OSError] = []
    t0 = time.time()
    for i, tree in enumerate(trees, 1):
        tree_errors: list[OSError] = []
        d, peak, f, s = convert(tree, clonefile, args.dry_run, tree_errors)
        walk_errors.extend(tree_errors)
        total += d
        failed_total += f
        swept_total += s
        peak_overall = max(peak_overall, peak)
        if not args.quiet:
            parts: list[str] = []
            if d or f:
                verb = "would convert" if args.dry_run else "converted"
                extra = f", {f} FAILED" if f else ""
                parts.append(f"{verb} {d:>7,} files (peak nlink {peak:>6,}){extra}")
            if s:
                parts.append(f"{'would remove' if args.dry_run else 'removed'} "
                             f"{s} stale temp file(s)")
            if tree_errors:
                # Never label a tree clean when part of it could not be read.
                parts.append(f"UNREADABLE in part ({len(tree_errors)} dir(s))")
            print(f"  [{i}/{len(trees)}] {', '.join(parts) or 'already clean'}  {tree}")

    elapsed = time.time() - t0
    if walk_errors:
        print(f"\nWARNING: {len(walk_errors)} director(ies) could not be read and were "
              f"skipped; counts below are a lower bound.", file=sys.stderr)
        print(f"  first: {walk_errors[0]}", file=sys.stderr)
    if swept_total:
        print(f"\n{'Would remove' if args.dry_run else 'Removed'} {swept_total:,} "
              f"{TMP_PREFIX}* temp file(s) left by an interrupted earlier run.")

    if args.dry_run:
        print(f"\nDry run: {total:,} hardlinked file(s) across {len(trees)} tree(s) "
              f"(peak link count {peak_overall:,}).")
        print("Re-run without --dry-run to convert them.")
        return 1 if walk_errors else 0

    rate = f", {total / elapsed:,.0f} files/sec" if elapsed > 0 and total else ""
    print(f"\nConverted {total:,} file(s) in {elapsed:.1f}s{rate}.")
    if failed_total:
        print(f"WARNING: {failed_total:,} file(s) could not be converted.", file=sys.stderr)

    print("\nVerifying...")
    ok = verify(trees)
    print("All trees clean (nlink=1)." if ok else "Verification reported problems.")
    return 0 if ok and not failed_total and not walk_errors else 1


if __name__ == "__main__":
    sys.exit(main())
