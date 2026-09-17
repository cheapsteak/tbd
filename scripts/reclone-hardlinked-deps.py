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

Idempotent: files already at nlink=1 are skipped, so re-running is a fast no-op.
Reports an empty scan as an error, never as success -- "found nothing" and
"everything is already converted" must not look alike.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import os
import subprocess
import sys
import time
from pathlib import Path

# Dependency directories worth converting. `.venv/lib` rather than `.venv` so we
# skip bin/ and pyvenv.cfg, which are small and sometimes deliberately unique.
DEP_SUBPATHS = (".venv/lib", "node_modules", "vendor/bundle")

INSTALLER_PATTERNS = ("uv sync", "uv pip", "pip install", "pnpm install", "npm install")


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
        if line.startswith("ps -Ao"):
            continue
        for pat in INSTALLER_PATTERNS:
            if pat in line:
                return line.strip()[:120]
    return None


def tbd_worktree_roots() -> list[Path]:
    """TBD lays worktrees out as $TBD_HOME/worktrees/<repo>/<worktree>."""
    base = Path(os.environ.get("TBD_HOME", Path.home() / "tbd")) / "worktrees"
    if not base.is_dir():
        return []
    return [wt for repo in sorted(base.iterdir()) if repo.is_dir()
            for wt in sorted(repo.iterdir()) if wt.is_dir()]


def expand(targets: list[Path]) -> list[Path]:
    """A worktree becomes the dependency trees inside it; a dep dir is itself."""
    trees: list[Path] = []
    for t in targets:
        if t.name in ("node_modules", "lib") or t.name.startswith(".venv"):
            trees.append(t)
            continue
        for sub in DEP_SUBPATHS:
            p = t / sub
            if p.is_dir():
                trees.append(p)
    return trees


def convert(root: Path, clonefile, dry: bool, walk_errors: list[OSError]) -> tuple[int, int, int]:
    """Returns (converted, peak_nlink_seen, failed).

    os.walk swallows OSError by default, so an unreadable subtree is skipped in
    silence -- and a scan that never saw a directory reports the same "clean" as
    one that saw it and found nothing. Collect those failures so the caller can
    refuse to claim success.
    """
    done = failed = peak = 0
    for dirpath, _dirs, files in os.walk(root, onerror=walk_errors.append):
        for name in files:
            p = os.path.join(dirpath, name)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            # Symlinks share no blocks; nlink==1 files are already done.
            if not os.path.isfile(p) or os.path.islink(p) or st.st_nlink <= 1:
                continue
            peak = max(peak, st.st_nlink)
            if dry:
                done += 1
                continue
            tmp = os.path.join(dirpath, f".__reclone{os.getpid()}_{name}")
            try:
                if clonefile(p.encode(), tmp.encode(), 0) != 0:
                    raise OSError(ctypes.get_errno(), f"clonefile: {p}")
                os.chmod(tmp, st.st_mode & 0o7777)
                os.utime(tmp, (st.st_atime, st.st_mtime))
                os.replace(tmp, p)  # atomic: p is never absent
                done += 1
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                failed += 1
    return done, peak, failed


def verify(trees: list[Path]) -> bool:
    """A silent partial conversion otherwise looks exactly like success."""
    ok = True
    for t in trees:
        errs: list[OSError] = []
        remaining = sum(
            1
            for dirpath, _d, files in os.walk(t, onerror=errs.append)
            for f in files
            if _nlink_gt1(os.path.join(dirpath, f))
        )
        if errs:
            # Unverifiable is not the same as verified. Say so.
            print(f"  could not read {len(errs)} director(ies) under {t}; "
                  f"cannot confirm it is clean (first: {errs[0]})", file=sys.stderr)
            ok = False
        if remaining:
            print(f"  {remaining:,} file(s) still hardlinked in {t}", file=sys.stderr)
            ok = False
    for t in trees:
        # A converted venv that no longer runs is the failure worth catching loud.
        if t.name == "lib" and t.parent.name == ".venv":
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
    return os.path.isfile(path) and not os.path.islink(path) and st.st_nlink > 1


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Convert hardlinked dependency trees to APFS clones.",
        epilog="With no paths, scans every TBD worktree under $TBD_HOME/worktrees.",
    )
    ap.add_argument("paths", nargs="*", type=Path, help="worktrees or dependency dirs")
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

    if not args.dry_run:
        if (proc := installer_running()) is not None:
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

    total = failed_total = peak_overall = 0
    walk_errors: list[OSError] = []
    t0 = time.time()
    for i, tree in enumerate(trees, 1):
        tree_errors: list[OSError] = []
        d, peak, f = convert(tree, clonefile, args.dry_run, tree_errors)
        walk_errors.extend(tree_errors)
        total += d
        failed_total += f
        peak_overall = max(peak_overall, peak)
        if not args.quiet:
            if d or f:
                verb = "would convert" if args.dry_run else "converted"
                extra = f", {f} FAILED" if f else ""
                print(f"  [{i}/{len(trees)}] {verb} {d:>7,} files "
                      f"(peak nlink {peak:>6,}){extra}  {tree}")
            elif tree_errors:
                # Never label a tree clean when part of it could not be read.
                print(f"  [{i}/{len(trees)}] UNREADABLE in part "
                      f"({len(tree_errors)} dir(s))  {tree}")
            else:
                print(f"  [{i}/{len(trees)}] already clean  {tree}")

    elapsed = time.time() - t0
    if walk_errors:
        print(f"\nWARNING: {len(walk_errors)} director(ies) could not be read and were "
              f"skipped; counts below are a lower bound.", file=sys.stderr)
        print(f"  first: {walk_errors[0]}", file=sys.stderr)

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
