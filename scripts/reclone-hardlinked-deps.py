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
notice, because the replacement has nlink=1 exactly like a correct result. Two
checks narrow that and neither closes it. The preflight below declines to
*start* when an installer is already visible in the process table, but that is
a snapshot, not a lock -- an installer that starts afterwards races, and no lock
exists that uv or pnpm would honour. And just before each replace the original
is looked up again; one whose inode, size or mtime moved during its clone is
left as found and reported, but a write landing between that lookup and the
replace is still lost.

So run this when the fleet is idle, never while installs may begin. That
includes `uv run`, which syncs the venv before it runs its command. The
preflight deliberately does not match `uv run`, or any other run/exec command:
each lives as long as the command it runs, so matching them would block this
script for as long as any agent or dev server is up.

Each swap goes through a short temp name beside the file, `.__reclone<pid>_<n>`.
A run killed between clone and replace leaves one behind. The next run removes
any whose pid is no longer alive -- a live pid may be another run mid-swap, so
those are left alone -- and verification reports any that remain. The same
rule covers `.__cl<pid>_<name>`, the temp of the bare clonefile loop this
script grew from.

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
interpreter, exactly as the worktree scan treats it. TBD worktrees are scanned
only when no PATH and no --base is given.

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
from dataclasses import dataclass, field
from pathlib import Path

# Dependency directories worth converting. `.venv/lib` rather than `.venv` so we
# skip bin/ and pyvenv.cfg, which are small and sometimes deliberately unique.
DEP_SUBPATHS = (".venv/lib", "node_modules", "vendor/bundle")

# The installers that write each kind of tree above, with the subcommands that
# write. "" is a bare invocation, which installs for yarn and bundle; "*" alone
# is any invocation; "*" inside a subcommand is any one word, such as a
# workspace name. Only short-lived commands belong here: `uv run`, `npm run`,
# `bundle exec` and the like live as long as what they run (see SAFETY).
INSTALLERS = {
    # .venv/lib
    "uv": {"sync", "pip", "add", "remove", "venv"},
    "pip": {"install", "uninstall"},
    "pip-sync": {"*"},
    "poetry": {"install", "sync", "add", "remove", "update"},
    "pdm": {"install", "sync", "add", "remove", "update"},
    # node_modules
    "npm": {"install", "i", "add", "ci", "clean-install", "install-test", "it",
            "install-ci-test", "cit", "uninstall", "un", "remove", "rm", "r",
            "update", "up", "upgrade", "rebuild", "rb", "dedupe", "ddp", "prune",
            "audit fix"},
    "pnpm": {"install", "i", "add", "remove", "rm", "uninstall", "un", "update",
             "up", "rebuild", "rb", "prune", "dedupe"},
    "yarn": {"", "install", "add", "remove", "up", "upgrade", "dedupe",
             "workspace * add", "workspace * remove", "workspace * up",
             "workspace * upgrade"},
    "bun": {"install", "i", "add", "remove", "rm", "update"},
    # vendor/bundle
    "bundle": {"", "install", "update", "add", "clean"},
}
# Script installers appear in `ps` as `node .../yarn.js install` or
# `python -m pip install`: the tool is then the interpreter's script or module.
INTERPRETERS = {"node", "python", "ruby"}
# Words that hand the rest of the line to another program, so the word after
# them is that program's, never a subcommand (`npm -s run up`).
RUNNERS = {"run", "run-script", "exec", "dlx"}
# `pip3.12` -> pip, `npm-cli.js` -> npm, `yarn-4.4.0.cjs` -> yarn.
_TOOL_NAME = re.compile(r"([a-z][a-z-]*?)(?:-cli|-?[\d.]+)?(?:\.[cm]?js)?")
_TOOL_ALIASES = {"bundler": "bundle"}

# The atomic swap's temp name. Short and independent of the file it replaces, so
# it never approaches NAME_MAX; it carries the pid so a later run can tell an
# orphan of a killed run from a swap still in flight.
TMP_PREFIX = ".__reclone"
# Orphans worth sweeping. `_.+` rather than `_\d+` also matches the file-named
# temps of earlier versions of this script; `.__cl` is the bare loop's (SAFETY).
_TMP_NAME = re.compile(r"\.__(?:reclone|cl)(\d+)_.+")

CLONE_NOFOLLOW = 0x0001  # <sys/clonefile.h>


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
            ["ps", "-Ao", "command"], capture_output=True, check=True,
            encoding="utf-8", errors="replace", timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError) as e:
        # Warn rather than refuse: refusing would leave no way to run this at
        # all, and what it skips is a snapshot that an idle fleet makes moot.
        print(f"WARNING: could not list processes ({e}); not checking for a "
              "running installer.", file=sys.stderr)
        return None
    for line in out.splitlines():
        if _is_install(_argv(line)):
            return line.strip()[:120]
    return None


def _argv(line: str) -> list[str]:
    """`ps` joins argv with spaces, so a path containing one comes back split.
    An absolute path that does not exist is rejoined with the words after it,
    into the longest run of up to 8 words that does."""
    words, argv, i = line.split(), [], 0
    while i < len(words):
        n = 1
        if words[i].startswith("/") and not os.path.exists(words[i]):
            n = next((k for k in range(min(len(words) - i, 8), 1, -1)
                      if os.path.exists(" ".join(words[i:i + k]))), 1)
        argv.append(" ".join(words[i:i + n]))
        i += n
    return argv


def _tool(word: str) -> str | None:
    m = _TOOL_NAME.fullmatch(os.path.basename(word).lower())
    return m and _TOOL_ALIASES.get(m[1], m[1])


def _words(args: list[str]) -> tuple[list[str], bool]:
    """The non-flag words, and whether the first directly follows a flag -- in
    which case it may be that flag's value (`pnpm --filter app install`,
    `python -W ignore -m pip`) rather than the word that matters."""
    words = [a for a in args if not a.startswith("-")]
    # Only flags precede the first word, so it follows one unless it leads.
    return words, bool(words) and words[0] != args[0]


def _starts_with(words: list[str], pattern: list[str]) -> bool:
    return len(words) >= len(pattern) and all(p in ("*", w) for p, w in zip(pattern, words))


def _is_install(argv: list[str]) -> bool:
    """Is this command line one of INSTALLERS, running a subcommand that writes?"""
    if not argv:
        return False
    tool, args = _tool(argv[0]), argv[1:]
    if tool in INTERPRETERS:
        # The tool is the script, or the module after -m.
        words, maybe_value = _words(args)
        heads = words[:2] if maybe_value else words[:1]
        head = next((w for w in heads if _tool(w) in INSTALLERS), None)
        if head is None:
            return False
        tool, args = _tool(head), args[args.index(head) + 1:]
    subcommands = INSTALLERS.get(tool)
    if subcommands is None:
        return False
    if "*" in subcommands:
        return True
    words, maybe_value = _words(args)
    if not words:
        return "" in subcommands
    offsets = (0, 1) if maybe_value and words[0] not in RUNNERS else (0,)
    return any(_starts_with(words[k:], sub.split())
               for sub in subcommands if sub for k in offsets)


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


@dataclass
class TreeResult:
    converted: int = 0
    peak_nlink: int = 0
    failed: int = 0
    changed: int = 0  # rewritten, replaced or removed during its clone; left as found
    swept: int = 0  # orphaned swap temps removed (in a dry run, found)
    first_error: str = ""
    walk_errors: list[OSError] = field(default_factory=list)

    def fail(self, why: str) -> None:
        self.failed += 1
        self.first_error = self.first_error or why


def _identity(st: os.stat_result) -> tuple[int, int, int, int]:
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns


def _discard(tmp: str) -> None:
    """Remove a temp this run's clonefile created -- never any other path."""
    try:
        os.unlink(tmp)
    except OSError:
        pass  # verify() reports it


def convert(root: Path, clonefile, dry: bool) -> TreeResult:
    """Convert one tree.

    os.walk swallows OSError by default, so an unreadable subtree is skipped in
    silence -- and a scan that never saw a directory reports the same "clean" as
    one that saw it and found nothing. The result carries those failures so the
    caller can refuse to claim success.
    """
    r = TreeResult()
    pid, seq = os.getpid(), itertools.count()
    for dirpath, _dirs, files in os.walk(root, onerror=r.walk_errors.append):
        for name in files:
            p = os.path.join(dirpath, name)
            if m := _TMP_NAME.fullmatch(name):
                # A swap temp. Only a dead run's is an orphan; a live pid's may
                # be mid-replace in another run.
                if not _pid_alive(int(m[1])):
                    try:
                        if not dry:
                            os.unlink(p)
                        r.swept += 1
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
            r.peak_nlink = max(r.peak_nlink, st.st_nlink)
            if dry:
                r.converted += 1
                continue
            tmp = os.path.join(dirpath, f"{TMP_PREFIX}{pid}_{next(seq)}")
            # The clone carries mode and nanosecond timestamps over by itself.
            if clonefile(os.fsencode(p), os.fsencode(tmp), CLONE_NOFOLLOW) != 0:
                # Nothing was created -- on EEXIST, whatever holds that name is
                # not ours -- so there is nothing to remove.
                r.fail(f"{os.strerror(ctypes.get_errno())}: {os.path.relpath(p, root)}")
                continue
            try:
                now = _identity(os.lstat(p))
            except OSError:
                now = None
            if now != _identity(st):
                # An installer rewrote, replaced or removed it during the clone;
                # replacing it now would put the old content back.
                r.changed += 1
                _discard(tmp)
                continue
            try:
                os.replace(tmp, p)  # atomic: p is never absent
                r.converted += 1
            except OSError as e:
                r.fail(f"{e.strerror}: {os.path.relpath(p, root)}")
                _discard(tmp)
    return r


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
            print(f"  {temps:,} swap temp file(s) remain in {t} "
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


def _describe(r: TreeResult, dry: bool) -> str:
    parts: list[str] = []
    if r.converted or r.failed or r.changed:
        verb = "would convert" if dry else "converted"
        parts.append(f"{verb} {r.converted:>7,} files (peak nlink {r.peak_nlink:>6,})")
    if r.failed:
        parts.append(f"{r.failed} FAILED (first: {r.first_error})")
    if r.changed:
        parts.append(f"{r.changed} CHANGED during clone, left as found")
    if r.swept:
        parts.append(f"{'would remove' if dry else 'removed'} {r.swept} stale temp file(s)")
    if r.walk_errors:
        # Never label a tree clean when part of it could not be read.
        parts.append(f"UNREADABLE in part ({len(r.walk_errors)} dir(s))")
    return ", ".join(parts) or "already clean"


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Convert hardlinked dependency trees to APFS clones.",
        epilog="With no paths and no --base, scans every TBD worktree under "
               "$TBD_HOME/worktrees.",
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
    # Only when nothing was named: an explicit target that holds nothing is an
    # empty scan, never a reason to go and convert every TBD worktree instead.
    if not args.paths and not args.base:
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

    results: list[TreeResult] = []
    t0 = time.time()
    for i, tree in enumerate(trees, 1):
        r = convert(tree, clonefile, args.dry_run)
        results.append(r)
        if not args.quiet:
            print(f"  [{i}/{len(trees)}] {_describe(r, args.dry_run)}  {tree}")
    elapsed = time.time() - t0

    total = sum(r.converted for r in results)
    failed = sum(r.failed for r in results)
    changed = sum(r.changed for r in results)
    swept = sum(r.swept for r in results)
    peak = max(r.peak_nlink for r in results)
    walk_errors = [e for r in results for e in r.walk_errors]
    first_error = next((r.first_error for r in results if r.first_error), "")

    if walk_errors:
        print(f"\nWARNING: {len(walk_errors)} director(ies) could not be read and were "
              f"skipped; counts below are a lower bound.", file=sys.stderr)
        print(f"  first: {walk_errors[0]}", file=sys.stderr)
    if swept:
        print(f"\n{'Would remove' if args.dry_run else 'Removed'} {swept:,} "
              "swap temp file(s) left by an interrupted earlier run.")

    if args.dry_run:
        print(f"\nDry run: {total:,} hardlinked file(s) across {len(trees)} tree(s) "
              f"(peak link count {peak:,}).")
        print("Re-run without --dry-run to convert them.")
        return 1 if walk_errors else 0

    rate = f", {total / elapsed:,.0f} files/sec" if elapsed > 0 and total else ""
    print(f"\nConverted {total:,} file(s) in {elapsed:.1f}s{rate}.")
    if failed:
        print(f"WARNING: {failed:,} file(s) could not be converted "
              f"(first: {first_error}).", file=sys.stderr)
    if changed:
        print(f"WARNING: {changed:,} file(s) changed while being cloned and were left "
              "as found; something is writing into these trees. Re-run once it is "
              "done.", file=sys.stderr)

    print("\nVerifying...")
    ok = verify(trees)
    print("All trees clean (nlink=1)." if ok else "Verification reported problems.")
    return 0 if ok and not (failed or changed or walk_errors) else 1


if __name__ == "__main__":
    sys.exit(main())
