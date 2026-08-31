# Hardlink fan-out: why `mds` can burn a core with Spotlight disabled

**Audience:** anyone on macOS/APFS running many parallel checkouts (git worktrees,
CI sandboxes, per-branch dev environments) where each one carries a large
dependency tree — `.venv`, `node_modules`, `vendor/`. You do not need to use TBD
for any of this to apply.

**Symptom this explains:** `mds` (the Spotlight metadata server) sustains 40–50%
of a CPU core, and shows up as the single largest producer of filesystem
operations on the machine, **even though Spotlight indexing is switched off** and
the Spotlight store has not been written in a year.

**One-line cause:** a package manager configured to install by **hardlink** makes
every one of its files carry a link count equal to the number of checkouts, and
each inode-to-path resolution then fans out across every sibling link. With 69
links, one lookup becomes 66 path resolutions.

**One-line fix:** on APFS, install by **clone** (copy-on-write) instead of
hardlink. You get the same disk sharing with a link count of 1, and the fan-out
disappears. Measured on the machine described below, this cut `mds`'s filesystem
operations by ~4,560x and its CPU from ~45% of a core to under 1%.

---

## Why this is easy to misdiagnose

Three separate things conspire to point the investigation in the wrong direction.

- **`mdutil` says indexing is off, so `mds` looks innocent.** It is not indexing.
  It is resolving inode numbers to pathnames, which is a different job that stays
  live regardless of indexing state. Turning indexing off — and even disabling
  search-serving with `mdutil -d -a` — changes nothing. On the machine this was
  measured on, `mds` CPU went *up* slightly afterwards.
- **`du` reports the disk cost of hardlinked and cloned trees completely
  differently, and one of those reports is wrong.** `du` deduplicates hardlinks
  *within a single invocation*, but it knows nothing about copy-on-write block
  sharing. So a cloned tree reports its full nominal size while occupying almost
  nothing. Anyone measuring "how much disk is this costing" with a per-directory
  `du` loop will conclude cloning is expensive and hardlinking is thrifty. Both
  halves of that conclusion are wrong.
- **The fix and the bug look identical to a link-count check.** A cloned file has
  `nlink == 1`, exactly like a full copy. A naive assertion that flags
  `nlink <= 1` as "this was copied, fix your config" will fire on precisely the
  configuration you want, and drive you back to the pathological one.

## How to tell whether you have this

You need one measurement. Capture filesystem activity machine-wide and look at
`mds`'s own lines — `fs_usage -p <mds-pid>` returns nothing, because SIP blocks
introspection of protected daemons, so filter after the fact:

```sh
sudo fs_usage -w -f filesys | grep -E ' mds\.[0-9]+$' > /tmp/mds.txt
```

Then measure the **run-length of consecutive `fsgetpath` calls that share a
relative path**:

```sh
grep ' fsgetpath ' /tmp/mds.txt \
 | sed -E 's/^[0-9:.]+ +fsgetpath +//; s/[[:space:]]+[0-9]+\.[0-9]+[[:space:]]+mds\.[0-9]+[[:space:]]*$//' \
 | sed -E 's|.*/\.venv/||' \
 | awk 'NR==1{p=$0;n=1;next} $0==p{n++;next} {print n;p=$0;n=1} END{print n}' \
 | sort -n | uniq -c | sort -rn | head -5
```

- **A dominant run-length well above 1, roughly equal to your checkout count** —
  you have hardlink fan-out. Confirm with `stat -f '%l' <any file in the tree>`;
  the link count should match.
- **Run-lengths collapsing toward 1** — something else is going on; this document
  does not describe your problem.

The distinction matters because the raw operation counts look the same either
way. What identifies the mechanism is the *ordering*: the file stays constant
while the checkout advances.

## The mechanism

The call pattern is a tight repeating triad — `fsgetpath`, then `fstatfs64`,
then `fsctl` against the data volume, interleaved with real metadata reads
(`RdMeta`) against the physical device.

`fsgetpath` maps a volume ID plus an object ID back to a pathname. For a file
with a single link that is a cheap lookup. For a file with *N* hardlinks it is
inherently ambiguous — the inode genuinely has *N* equally valid pathnames — and
resolving it walks the sibling-link set.

So the cost of one logical lookup scales with the link count, and the link count
is exactly the number of checkouts sharing that dependency tree. The load is
therefore **quadratic in checkout count**: each new checkout both adds a new
source of file activity *and* increments the link count on every file, raising
the cost of every *other* checkout's lookups. Going from 10 to 80 checkouts is
not 8× the metadata load — it is closer to 64×.

Crucially, the underlying activity that triggers all this is unremarkable. In
the measurement below, roughly 118 files per second were actually being touched —
what an ordinary language server or a dependency sync would do. Every bit of the
alarming aggregate number is amplification.

## The evidence

Measured on an M4 Pro (12 cores, macOS 26.x, APFS), with ~80 git worktrees each
carrying a Python `.venv` of ~47,800 directory entries, and Spotlight indexing
disabled on all volumes.

- **`mds` produced 868,769 of 1,737,746 filesystem events** in a 30-second
  machine-wide capture — 50% of all filesystem operations on the machine,
  ~29,000 ops/sec.
- **The dominant `fsgetpath` run-length was 66, occurring 1,027 times** in a
  single window, with the relative path held constant while the worktree
  advanced. Independent per-tree crawlers could not stay in lockstep 1,027
  consecutive times; this is sibling enumeration.
- **`stat` on the file being resolved reported `nlink=69`** — 66 live worktrees
  plus the package cache and two absent checkouts. The fan-out matches the link
  count, not the worktree count.
- **234,334 `fsgetpath` calls ÷ 66 = ~3,550 distinct files, ~118/sec.** The real
  workload is small.
- **`mds` sustained 26.7s of CPU across a 60s window (44.4% of a core) with zero
  checkout creation happening** — this is steady-state cost, not a
  provisioning-time cost.

One tempting comparison is worth explicitly discarding. Checkouts created before
the hardlink setting was introduced had `nlink=1` and showed **zero** `mds` hits,
versus ~1,900 each for the hardlinked ones. That looks like a clean natural
experiment and is not one: those same checkouts are also the oldest and least
active, so link count and idleness are perfectly collinear. The run-length
distribution is what carries the argument.

## Why a package manager creates this

Modern package managers install from a shared content-addressed cache by linking
rather than copying. The available strategies are not equivalent on APFS:

- **`hardlink`** — one inode, *N* directory entries. Minimal disk. **Link count
  grows with every checkout, so this is the strategy that creates the fan-out.**
- **`clone` (copy-on-write, `clonefile(2)`)** — *N* independent inodes sharing
  the same physical blocks until written. Disk cost is comparable to hardlinking,
  but **every link count stays 1, so there is no fan-out.** APFS only.
- **`copy`** — *N* independent inodes, *N* full copies. No fan-out, but genuinely
  expensive in disk.
- **`symlink`** — avoids the fan-out, but introduces dangling-reference risk when
  the cache is pruned and breaks tools that resolve `__file__` or walk package
  data. Not recommended for virtualenvs.

For `uv` specifically, **`clone` is already the default on macOS**. Verified by
installing the same package into two fresh virtualenvs with `UV_LINK_MODE` unset:

```
a: nlink=1 inode=819209901
b: nlink=1 inode=819209957      <- distinct inodes, link count 1
```

That default is the right one, and the failure mode documented here comes from
overriding it. A configuration that pins `UV_LINK_MODE=hardlink` — typically
added to "stop each checkout paying for a full copy", motivated by a `du`
measurement that cannot see clone sharing — trades a free copy-on-write share for
a link count equal to the checkout count.

## The fix

**Stop pinning hardlink; let the tool choose, or pin clone explicitly on APFS.**
For `uv`, remove the `UV_LINK_MODE=hardlink` export, or set
`UV_LINK_MODE=clone`. Existing environments keep their old link counts until
rebuilt, so converting them requires a reinstall (`uv sync --reinstall`, or
deleting and re-provisioning the environment).

Two things to fix alongside it, or the change will be undone by its own guardrails:

- **Any assertion that flags `nlink <= 1` as "this was copied" must be retired or
  inverted.** On APFS that check condemns the correct configuration.
- **Any disk-cost measurement built on per-directory `du` must be redone.** It
  cannot distinguish a clone from a copy and will keep reporting the fixed state
  as expensive. Compare volume free space before and after instead.

The fix preserves every checkout. Nothing here requires reducing how many
parallel checkouts you keep.

## Converting existing environments

Changing the setting only affects environments built after it. Existing ones
keep their link counts until rebuilt, and since the fan-out is driven by the
link count, nothing improves until enough of them are converted.

Reinstalling (`uv sync --reinstall`) is the obvious route, but it needs the
network and the lockfile, and it rewrites environments other sessions may be
using. Converting in place is cheaper and content-preserving: cloning a file
from itself produces an independent inode that still shares every block.

Three approaches, because the differences matter more than they look:

- **`cp -c` per file, spawned from `find`/`xargs`** — correct but slow, ~120
  files/sec. The cost is process spawn, not cloning; a virtualenv of ~45,000
  files takes several minutes.
- **`cp -cR` on the whole tree, then swap the directory** — ~1,400 files/sec,
  but it renames the live directory, so there is a brief window in which
  `lib/` does not exist. A lazy import landing in that window fails. Fine for
  idle checkouts, not for ones with running processes.
- **`clonefile(2)` per file from a single process, replaced atomically** — the
  one to use. It has the speed of the recursive copy (~855 files/sec measured)
  without the window: each file is swapped with `os.replace()`, so a reader
  sees either the old inode or the new one and never a missing path. Safe to
  run against checkouts with live sessions.

The third, in full:

```python
"""Convert hardlinked files to APFS clones in place. Content is byte-identical
and blocks stay shared, so this costs no real disk -- it only breaks the link
count that macOS `mds` fans out across."""
import ctypes, ctypes.util, os, sys

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
libc.clonefile.restype = ctypes.c_int

def convert(root):
    done = failed = 0
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            p = os.path.join(dirpath, name)
            try:
                st = os.lstat(p)
                if not os.path.isfile(p) or os.path.islink(p) or st.st_nlink <= 1:
                    continue
                tmp = os.path.join(dirpath, f".__cl{os.getpid()}_{name}")
                try:
                    if libc.clonefile(p.encode(), tmp.encode(), 0) != 0:
                        raise OSError(ctypes.get_errno(), p)
                    os.chmod(tmp, st.st_mode & 0o7777)
                    os.utime(tmp, (st.st_atime, st.st_mtime))
                    os.replace(tmp, p)          # atomic; p is never absent
                    done += 1
                except Exception:
                    try: os.unlink(tmp)
                    except OSError: pass
                    failed += 1
            except OSError:
                failed += 1
    return done, failed

if __name__ == "__main__":
    print("cloned=%d failed=%d" % convert(sys.argv[1]))
```

Two things to check before running it against a live checkout:

- **No installer is mid-flight.** A running `uv sync` or `pip install` writing
  into the tree is the one case that genuinely loses data. Everything else is
  safe, including processes with open file descriptors — POSIX keeps the inode
  alive across replace and unlink, so anything already executing is unaffected.
- **Verify afterwards**, since a silent partial conversion looks like success:
  the interpreter still starts, a few third-party imports resolve, the
  site-packages count is unchanged, and `find <venv> -type f -links +1` is
  empty.

Expect language servers to re-index the tree afterwards; they observe a mass
delete-and-create. That churn is transient.

## What does not work

- **`.metadata_never_index`** — the traditional marker file is
  [reported broken on recent macOS](https://eclecticlight.co/2025/06/16/spotlight-search-can-be-blocked-by-extended-attributes/).
  Do not rely on it.
- **`mdutil -X`** — per its man page this *removes the index directory and does
  not disable indexing*, so it provokes a full rebuild. The opposite of what you
  want.
- **`mdutil -i off` / `mdutil -d`** — these are what make the situation
  confusing in the first place. Both were already set throughout the measurements
  above, and neither reduced the load.
- **Disabling `com.apple.metadata.mds` via `launchctl`** — SIP-protected;
  requires disabling System Integrity Protection, and there are
  [reports](https://developer.apple.com/forums/thread/774617) that the processes
  return anyway. Large blast radius, poor evidence it even works.

**Spotlight Privacy-list exclusion** (System Settings → Spotlight → Search
Privacy) of the parent directory holding your checkouts is the reasonable
symptom-level fallback if you cannot change link mode. It needs no renaming and
breaks no tooling. Note there is an open report of
[exclusions being disregarded on macOS 26](https://developer.apple.com/forums/thread/814978),
so verify it actually reduced the numbers rather than assuming.

## Before and after

The intervention: 51 virtualenvs converted from hardlinks to clones (~2.3
million files, zero failures, every one verified to still start its interpreter
and resolve imports), taking the link count on a representative file from 69 to
1. Nothing else changed — no worktrees were deleted for this measurement, and
Spotlight was already disabled throughout.

**The primary result, measured as `mds`'s own filesystem operations in a
machine-wide `fs_usage` capture:**

- **Before, at `nlink=69`** — 868,769 operations in 30s = **28,959/sec**, which
  was 50% of all filesystem activity on the machine.
- **After, at `nlink=1`** — 127 operations in 20s = **6.3/sec**.
- **A reduction of roughly 4,560x.**

**`mds` CPU, sampled six times over ten minutes afterwards** — 0.56%, 0.26%,
0.09%, 0.07%, 0.38%, 0.06% of a core, against a 40.8–45.1% baseline. Six
samples rather than one because of the burstiness noted below; the spread
(0.06–0.56%) matters more than any single figure. Its resident set also
fell from 185 MB to 12 MB, and the process was never restarted (same pid
throughout), so this is the same daemon doing far less work rather than a fresh
one that has not warmed up.

Three measurement traps are worth recording, because each one nearly produced a
wrong number:

- **`mds` load is bursty, so a single CPU sample proves little.** Cumulative CPU
  over ten hours averaged 5.9% of a core while individual samples read 40–45%.
  A before/after pair taken at two arbitrary moments could show almost any
  ratio. The operations-per-second figure is the trustworthy one because it
  measures the *multiplier* directly; the CPU distribution is reported as six
  samples for the same reason.
- **A measurement can create its own contamination.** An initial "after" reading
  was taken by a script that created its output file *before* sampling, while a
  queued conversion sweep was waiting for exactly that file to appear. The sweep
  started two seconds into the sample window and ran through it, producing a
  meaningless 42.6% that briefly looked like "the fix did nothing". Sequence
  such things on the *process* exiting, not on a file appearing.
- **Verify the daemon did not simply die.** A CPU reading of ~0 is equally
  consistent with success and with a crashed process. Check the pid is unchanged
  and the service still responds.

**What did not change: `fseventsd`.** It stayed at 96.5% of a core against a
98.9% baseline. This is expected rather than disappointing, and the distinction
is the useful part — the two daemons scale on different quantities:

- **`mds`** costs scale with **link count**, which this change addresses.
- **`fseventsd`** costs scale with the **number of watched paths**, which this
  change does not touch at all. Converting a file in place leaves its path,
  its directory entry, and the total file count exactly as they were; only the
  inode behind it differs.

The only thing observed to move `fseventsd` was removing checkouts outright: its
resident set fell 5.5 GB to 4.8 GB when 14 worktrees were archived. Its resident
set also fell to 2.20 GB across the conversion, which is **not explained** — the
prediction was no effect, and a large one appeared. It may be that the mass
replacement forced it to rebuild internal state. Recorded as an observation, not
a mechanism.

## Limits of this analysis

Stated plainly, because several attractive-looking conclusions in this
investigation turned out to be measurement artifacts:

- **The client driving the ~118 lookups/sec was never identified.** SIP blocks
  `fs_usage -p` and `sample` against `mds`, so its callers are not observable.
  The amplification is established; the trigger is not.
- **`fseventsd` is a separate, unexplained problem.** It sat pinned at ~99–101%
  of a core throughout, independent of a 23× swing in event rate, with a hot loop
  in `_platform_strncmp` under a mutex. Archiving 14 checkouts dropped its RSS
  from 5.5 GB to 4.8 GB while leaving CPU unchanged — consistent with saturation
  at a single-thread ceiling rather than load-proportional work. Nothing in this
  document fixes it.
- **No public prior art was found** for the hardlink fan-out mechanism. The
  generic "large dependency trees make Spotlight expensive" pattern is well
  documented for `.venv` and `node_modules`, but the specific claim that *link
  count* rather than *file count* is the multiplier appears to be undocumented
  elsewhere. It is well supported by the measurements here and has not been
  independently corroborated.
