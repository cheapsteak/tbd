#!/usr/bin/env python3
"""Catch a TBDDaemon memory spike in the act, on a live daemon, without suspending it.

    daemon-footprint-watch.py [--pid N] [--interval 1.0] [--threshold-mb 1024] [--out DIR]
    daemon-footprint-watch.py --report <run dir>
    daemon-footprint-watch.py --prune [--keep-days 14]
    daemon-footprint-watch.py --self-test

WHY THIS EXISTS
---------------
A daemon at 13 h uptime serving 185 terminal rows was measured at a
phys_footprint of 5.6 GB. Two minutes later it was 990 MB, and four minutes
after that 325 MB. Its lifetime peak was 7.4 GB. Throughout all of it `ps` RSS
reported 68 MB, because the compressor had already swept the pages: on this
platform RSS reports very nearly the opposite of the truth, and any monitoring
built on it will report a healthy process while the machine swaps.

vmmap at the trough showed 3.2 GB of MALLOC_SMALL across 829 regions plus 4.2 GB
of empty MALLOC_SMALL regions. That is the signature of spike-and-release churn,
not of a leak, and it is why a snapshot taken after the fact explains nothing:
by the time a human notices the machine is slow, the allocator has already given
the pages back and there is nothing left to attribute.

`heap` is the wrong instrument for the same reason, and worse. It suspended the
daemon for about 28 s, and it only samples when you run it, which for a spike
that lasts a couple of minutes means you sample a trough.

So the instrument has to be running before the spike, cost nothing while it
waits, and fire on its own. That is this script.

WHAT IS MEASURED
----------------
Every tick the script asks the kernel for the target's resource usage through
`proc_pid_rusage(pid, RUSAGE_INFO_V4, &buf)` in libproc, via ctypes. The call
costs about 1 microsecond, needs no privilege for a process owned by the same
user, and does not suspend or otherwise disturb the target. Recorded per tick:

  ri_phys_footprint                the counter the OS itself bills the process
                                   on, compressed pages included. This is the
                                   number RSS lies about.
  ri_interval_max_phys_footprint   the peak footprint since the last interval
                                   reset.
  ri_lifetime_max_phys_footprint   the peak since the process started.
  ri_resident_size                 RSS, recorded only so the divergence from
                                   footprint stays visible in the record.
  ri_user_time, ri_system_time     CPU, reported by the kernel in mach time
                                   units and converted to nanoseconds through
                                   `mach_timebase_info` before being recorded,
                                   then differenced per tick.
  ri_pageins                       compressor and swap activity.

After each read the script calls `proc_reset_footprint_interval(pid)`, so the
next tick's interval max is the peak reached *since this tick*. That is the part
that makes a spike shorter than the sampling interval impossible to miss: the
current footprint can be back down by the time we look, but the interval max
cannot hide. Both calls are declared in <libproc.h>. The counter belongs to the
process, not to the watcher, so any other tool that resets the same process's
footprint interval shortens this watch's windows, which is why a watch takes a
lock file per target pid.

The interval is reset once more, at acquire, before the very first sample is
read. Until somebody resets it the kernel reports the peak since process start,
so an un-reset first read hands back a lifetime peak as if it had just happened:
on the incident daemon that is 7.4 GB, which would fire a capture at t0 on a
process that is merely old and would then dominate `--report`. If that reset
ever fails the run records one `interval_reset_failed` marker for the target, so
an interval max that only ever climbs is diagnosable from the record instead of
being read as a real spike.

A target younger than one baseline window has its rise rule held off for the
remainder of that window. A daemon that has just restarted climbs from nothing
to its working set in the first seconds, and a rise measured against a floor of
20 MB fires on that climb every time, then holds the detector in the resulting
spike for a whole baseline window and folds any real spike into it. The age
comes from `ri_proc_start_abstime` read against `mach_absolute_time`, and the
run records a `rise_suppressed` marker saying how old the target was and until
when the rule is held off. The absolute threshold is deliberately not held off:
a young daemon crossing a gigabyte is a real event whatever its age. A daemon
that has been up for hours is older than the window, so nothing is suppressed
for it and a rise in the first minutes of the watch is still caught.

One JSON line per tick lands in `samples.jsonl`, flushed on every write, because
the person reading this file at 3am is not the process writing it.

THREE LAYERS
------------
1. The sampler, always on, described above.
2. Capture on trigger: when the footprint or the interval max crosses an
   absolute threshold, or rises above a rolling baseline, the script shells out
   to `footprint -p <pid>` for the per-tag region breakdown and to `sample` for
   a call graph, into `captures/<timestamp>-<reason>/`. Both run in a background
   thread so the sampler keeps ticking, one capture at a time, rate limited so a
   two minute spike does not produce a hundred of them.
3. A `log stream` sidecar, so there is something to correlate the spike
   against. It is spawned behind a `/bin/sh` watchdog that polls this
   script's pid and kills the stream when it is gone, because a plain child
   survives a SIGKILLed parent and streams the system log into a file nobody
   is reading until the machine reboots.

HOW TO READ THE RESULTS
-----------------------
Point `--report` at a run directory. It replays `samples.jsonl` through the same
`SpikeDetector` the live run used, with that run's own thresholds read back from
`run.json`, and prints each spike with its onset, trigger rule, peak, end and
duration, the captures that belong to it, and what the daemon was logging in the
60 s before onset and during the spike. Replaying the detector rather than
re-testing the threshold is what keeps the report and the live run in agreement:
a rise-triggered spike well under the absolute threshold is a spike in both, or
in neither.

The run's own markers are replayed in step with its samples, for the same
reason. A `target_lost` closes whatever spike was open at that instant and a
`target_acquired` starts a detector with no history, exactly as the live watch
does, because a daemon restart mid-run otherwise hands the new process's first
sample the dead one's baseline, in-spike state and previous peak: a replacement
daemon coming up above the threshold gets no onset in the report while the live
run took one, and the capture directory that run wrote belongs to no spike.

In the raw samples the two things worth reading together are the footprint and
the interval max. A tick whose interval max is far above its own footprint saw a
spike that opened and closed between two ticks. A run of ticks where both are
high is a spike you can actually sample, and that is where `sample.txt` in the
matching capture directory is worth reading: it says which stacks were running
while the memory was outstanding. `footprint.txt` says which allocator tags hold
it. A large empty MALLOC_SMALL total in there is released churn, not a leak.

WHY THE LOG SIDECAR IS ON BY DEFAULT
------------------------------------
The daemon's `.info` and `.debug` rows are not persisted: a read of the last
hour returned 0 rows at info level against 527 at notice and above. A live
stream subscriber is also what activates debug rows in the first place. So
without the sidecar running for the whole watch there is simply nothing to
correlate a spike against, and the spike will not come back for a second look.
The alternative, if a sidecar process for hours is unwelcome, is to enable
persistence once with

    sudo log config --subsystem com.tbd.daemon --mode "level:debug,persist:debug"

after which `log show --last` can answer the same question retroactively. Note
`/usr/bin/log` is spelled out everywhere here: bare `log` is shadowed in some
shells.

OUTPUT, AND WHO CLEANS IT UP
----------------------------
Everything lands under `--out`, which defaults to
`$TBD_HOME/diag/daemon-footprint/<YYYYmmdd-HHMMSS>/` (TBD_HOME defaults to
`~/tbd`). The run directory holds `run.json`, `samples.jsonl`, `daemon-log.txt`,
`sidecar.pid` and `captures/`. These files outlive the run, and no daemon-side
sweep covers them: the daemon knows nothing about this directory.

The named reconciler for them is this script's own startup sweep. Every live
watch, before it samples anything, walks `$TBD_HOME/diag/daemon-footprint/` and
removes each run directory whose newest file is older than `--keep-days`
(default 14; `0` disables the sweep entirely), along with any
`.watch-<pid>.lock` whose holder is dead. `--prune` runs the same pass alone and
exits, for reclaiming without starting a watch. So a tree forgotten in August is
reclaimed the next time anybody starts a watch, instead of waiting for the
operator who started that watch to remember it.

The exception is a run some watcher still holds. `run.json` records
`watcher_pid` and `watcher_start_abstime`, the same pid-and-start-stamp pair the
lock file carries and read from the same rusage, and a run whose watcher is
still alive at that identity is never removed however old its files are. That
has to be an exception rather than an inference from mtime: a watch that has not
found a target writes no samples at all, so a perfectly live overnight run can
have a `samples.jsonl` nothing has touched for days.

The sweep is keep-biased throughout, because the cost of deleting a run somebody
wanted is unbounded and the cost of keeping one nobody wants is a directory.
Anything newer than the cutoff is never touched. A directory with no `run.json`,
or one that cannot be parsed, is not read as unclaimed; it goes by age alone. A
watcher pid that answers but whose identity cannot be established counts as
alive. Symlinks are never followed: a link contributes its own mtime and never
its target's, so a link into a directory somebody else is writing cannot keep a
dead run alive forever, and nothing outside the daemon-footprint directory is
ever removed. What the sweep did lands in the new run's `samples.jsonl` as a
`swept` marker naming the directories it removed and how many it kept for a live
watcher, and the same summary is printed to stdout.

Nothing here writes to the database, signals the daemon, or restarts anything;
the only state it changes in the target is the footprint interval counter it
resets.

A run directory is written once and never reused. If `--out` already holds a
`samples.jsonl` or a `run.json` the watch refuses to start and exits 2, because
appending a second run to the first one's sample stream produces a file whose
gaps and pid changes read as the target's behaviour rather than as two runs.

A pid is not an identity, and the watch does not treat one as an identity in
either direction. `ri_proc_start_abstime` is recorded for the target at acquire
and compared on every tick, so a daemon that died and came back onto the same
pid is lost and re-acquired rather than sampled straight through as if nothing
had happened, and the run's markers say so. The lock file described next carries
the same stamp for the same reason, and it is what the startup sweep reads to
tell a run somebody is still writing from a run somebody forgot.

One file lives outside the run directory. While a watch holds a target it owns
`$TBD_HOME/diag/daemon-footprint/.watch-<target pid>.lock`, a JSON object naming
the watcher's own pid and start stamp, because `proc_reset_footprint_interval`
is per-process and a second watch on the same target silently steals half of
both watches' interval windows. The lock is removed when the target is lost and
again at shutdown. A watcher killed with SIGKILL cannot remove it, so a stale
lock is reclaimed two ways: by the next watcher that wants that same target and
finds its holder dead, and by the startup sweep above, which removes every lock
in the directory whose holder is dead whatever target it names. The stamp is
what makes "dead" answerable at all - a holder pid handed on to an unrelated
process answers `kill -0` forever, and a lock reclaimed on liveness alone would
never be reclaimed again. A lock written by an older watch holds a bare pid,
which is still read, and falls back to liveness alone. A watch that cannot
create the file at all measures anyway and records a `watch_unlocked` marker;
what it gives up is the guarantee that nobody else is resetting the same
interval counter, so the record says the guarantee was not held rather than
leaving a window somebody else shortened looking like the target's own
behaviour.

REJECTED ALTERNATIVES
---------------------
Daemon self-report through os.Logger or task_vm_info. Compiled behavior on a
timer, so a default-off flag and a spec before a single number arrives, and the
number it would emit is the same kernel counter this script reads from outside
for free. To survive in the log it would have to be `.notice`, which is
operator-visible noise on every tick forever.

os_signpost. A ring buffer that is not persisted, so the interval that matters
has usually been overwritten by the time anyone looks.

A diagnostic RPC. A round trip on the daemon's own event loop to learn a fact
the OS serves in a microsecond, and the event loop is a plausible suspect. It
may still earn its place later for facts only the daemon knows, such as
in-flight RPC count or pending broadcast bytes, if the evidence points there.

MallocStackLogging. It has to be set at launch, so it cannot be turned on when a
spike appears, and it records every malloc: on a process churning millions of
small allocations it adds gigabytes of its own. It is step two, once the window
and the subsystem are known.

xctrace Allocations, attached. Same cost profile, and it means holding hours of
trace for a spike that took 13 h to show up once.

A DispatchSource memory pressure handler. It reports system-wide pressure, not
this process's growth, and it is a hook for shedding caches rather than an
instrument for finding out who allocated.

malloc_zone_statistics. In-process only, and it says how much is held, never by
whom. `footprint -p` gives the per-tag region breakdown from outside without a
suspend.

Periodic vmmap. It took 5.9 s and briefly held the task on a 26 MB process, and
it is worse at gigabytes. It is available here as an opt-in addition to a
capture, never as a poll.

Existing debug logging on its own. Nothing below notice is retained, which is
the same wall the sidecar exists to get around.

LEADS, NOT CONCLUSIONS
----------------------
A heap taken at a trough showed 27 NIO ByteBuffer storages averaging 157 KB, one
1.5 MB contiguous array of Worktree, 2.7 MB of String-to-JSONEncoderValue
dictionaries, and 2.4 MB of StringStorage. Together those smell like RPC
response encoding fanned out to many clients, and the daemon's `perf-rpc`
category logs `rpc in-flight high: N` at debug level, which the sidecar carries
and `--report` counts in the window around each spike. That is a hypothesis to
test against a capture taken at a peak, not a finding.
"""

from __future__ import annotations

import argparse
import bisect
import contextlib
import ctypes
import io
import json
import mmap
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter, deque
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Sequence

# Python 3.9 floor: this must run on the stock /usr/bin/python3, so no `match`,
# no `dataclass(slots=True)`, and the `__future__` import above is what keeps
# 3.10-style `X | None` annotations from being evaluated at definition time.

SCRIPT_VERSION = "1"

DEFAULT_INTERVAL = 1.0
DEFAULT_THRESHOLD_MB = 1024
DEFAULT_RISE_MB = 512
DEFAULT_REARM_MB = 512
DEFAULT_BASELINE_WINDOW = 300.0

# How long a run directory nobody is watching survives the next watch's startup
# sweep. Two weeks, because that is longer than any investigation this
# instrument has been pointed at and short enough that a forgotten overnight
# tree does not sit on the disk for a quarter. 0 disables the sweep.
DEFAULT_KEEP_DAYS = 14
SECONDS_PER_DAY = 86400.0

MB = 1024 * 1024

# A spike is considered over, and the onset trigger re-armed, once the footprint
# falls this far below the level that fired it. Hysteresis: without it a
# footprint hovering at the threshold captures on every tick.
RELEASE_FRACTION = 0.75

# The second release rule: back within this fraction of a rise of the rolling
# trough. RELEASE_FRACTION alone can never fire when the trough itself sits
# above it, and the incident daemon idled at 990 MB against a 1024 MB threshold,
# so it would have stayed "in spike" for the rest of the night and the 7 GB and
# 8 GB spikes that followed would have captured nothing. It is not guarded by
# the absolute threshold: the threshold onset is edge triggered, so a plateau
# that releases under this rule cannot re-fire one.
RELEASE_RISE_FRACTION = 0.5

# At most an onset capture and one high-water capture per spike. A capture costs
# seconds of `sample`; a two minute spike must not spend all of it capturing.
MAX_CAPTURES_PER_SPIKE = 2

FOOTPRINT_TIMEOUT = 60
SAMPLE_TIMEOUT = 60
VMMAP_TIMEOUT = 120

# `log stream --style compact` emits "2026-09-03 18:01:53.945 Db TBDDaemon[...]
# [com.tbd.daemon:migrations] message". No UTC offset in this style, so the
# timestamp is read as local time, which is what the sampler writes too.
LOG_TIMESTAMP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)")
LOG_CATEGORY_RE = re.compile(r"\[(com\.tbd\.[^:\]\s]+):([^\]\s]+)\]")
RPC_INFLIGHT_RE = re.compile(r"rpc in-flight high")


# ----------------------------------------------------------------------------
# KERNEL COUNTERS
# ----------------------------------------------------------------------------

RUSAGE_INFO_V4 = 4


class RusageInfoV4(ctypes.Structure):
    """<sys/resource.h> struct rusage_info_v4, field for field and in order.

    Getting this layout wrong does not fail loudly, it returns a plausible wrong
    number from the neighbouring field, so it is transcribed whole rather than
    truncated at the fields of interest.
    """

    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
        ("ri_cpu_time_qos_default", ctypes.c_uint64),
        ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
        ("ri_cpu_time_qos_background", ctypes.c_uint64),
        ("ri_cpu_time_qos_utility", ctypes.c_uint64),
        ("ri_cpu_time_qos_legacy", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64),
        ("ri_billed_system_time", ctypes.c_uint64),
        ("ri_serviced_system_time", ctypes.c_uint64),
        ("ri_logical_writes", ctypes.c_uint64),
        ("ri_lifetime_max_phys_footprint", ctypes.c_uint64),
        ("ri_instructions", ctypes.c_uint64),
        ("ri_cycles", ctypes.c_uint64),
        ("ri_billed_energy", ctypes.c_uint64),
        ("ri_serviced_energy", ctypes.c_uint64),
        ("ri_interval_max_phys_footprint", ctypes.c_uint64),
        ("ri_runnable_time", ctypes.c_uint64),
    ]


class MachTimebaseInfo(ctypes.Structure):
    """<mach/mach_time.h> struct mach_timebase_info: nanoseconds = units * numer / denom."""

    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def read_mach_timebase() -> tuple[int, int, bool]:
    """The machine's mach-time to nanosecond ratio, read once from libSystem.

    Returns (numer, denom, read_ok).

    `ri_user_time` and `ri_system_time` are mach absolute time units, not
    nanoseconds, and on Apple silicon the two differ by a factor of about 41.7:
    a measured 1.705 s of burned CPU produced a delta of 40,915,797 units
    against a timebase of numer 125 / denom 3. Reading them as nanoseconds
    understates CPU by that factor, which is how a busy process reports a
    fraction of a percent. Falls back to 1/1 (the Intel identity) if the call
    fails, so a bad read is a wrong scale rather than a dead sampler.

    The third element is what makes that fallback legible afterwards. 1/1 is
    also the genuine Apple-Intel timebase, so the numbers alone cannot say
    whether a run scaled CPU correctly or gave up: on Apple silicon they would
    understate every cpu_pct in the run by about 41.7 and nothing in the record
    would say so. The caller records the ratio in `run.json` and writes a marker
    when this flag is False.
    """
    try:
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        lib.mach_timebase_info.argtypes = [ctypes.POINTER(MachTimebaseInfo)]
        lib.mach_timebase_info.restype = ctypes.c_int
        info = MachTimebaseInfo()
        if lib.mach_timebase_info(ctypes.byref(info)) == 0 and info.denom:
            return int(info.numer), int(info.denom), True
    except Exception:  # noqa: BLE001 - a missing timebase must not stop the watch
        pass
    return 1, 1, False


def process_age_seconds(start_abstime: int, numer: int, denom: int) -> float | None:
    """Seconds since the target launched, or None if that cannot be established.

    `ri_proc_start_abstime` is a mach absolute time stamp on the same clock
    `mach_absolute_time` reads, so the difference scaled by the machine's
    timebase is the process's age. The libSystem call is made here rather than
    bound at import, so nothing at module scope touches a macOS symbol and the
    self-test keeps running on a machine that has none.

    None means "unknown age", and every caller reads that as "suppress nothing":
    a missing age must never be able to silence a real spike.
    """
    if start_abstime <= 0 or denom <= 0 or numer <= 0:
        return None
    try:
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        lib.mach_absolute_time.argtypes = []
        lib.mach_absolute_time.restype = ctypes.c_uint64
        now_abs = int(lib.mach_absolute_time())
    except Exception:  # noqa: BLE001 - an unreadable clock is not fatal
        return None
    if now_abs <= start_abstime:
        return None
    return (now_abs - start_abstime) * numer / denom / 1e9


class LibProc:
    """The two libproc entry points this script needs, bound once."""

    def __init__(self) -> None:
        self._lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        self._lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self._lib.proc_pid_rusage.restype = ctypes.c_int
        self._lib.proc_reset_footprint_interval.argtypes = [ctypes.c_int]
        self._lib.proc_reset_footprint_interval.restype = ctypes.c_int
        self.timebase_numer, self.timebase_denom, self.timebase_ok = read_mach_timebase()

    def rusage(self, pid: int) -> RusageInfoV4 | None:
        """Kernel counters for `pid`, or None if it is gone or not ours."""
        buf = RusageInfoV4()
        if self._lib.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(buf)) != 0:
            return None
        return buf

    def mach_to_ns(self, units: int) -> int:
        """Scale one mach absolute time value to nanoseconds."""
        return int(units) * self.timebase_numer // self.timebase_denom

    def cpu_times_ns(self, usage: RusageInfoV4) -> tuple[int, int]:
        """(user, system) CPU for this sample, in true nanoseconds."""
        return self.mach_to_ns(usage.ri_user_time), self.mach_to_ns(usage.ri_system_time)

    def reset_footprint_interval(self, pid: int) -> bool:
        """Restart the interval max, so the next read is the peak since now."""
        return self._lib.proc_reset_footprint_interval(pid) == 0


# ----------------------------------------------------------------------------
# THE DETECTOR
# ----------------------------------------------------------------------------


@dataclass(frozen=True)
class CaptureRequest:
    """One decision to capture, and everything the record needs about why."""

    when: float
    reason: str  # "threshold", "rise" or "highwater"
    footprint: int
    interval_max: int
    peak: int
    baseline: int


class SpikeDetector:
    """Decides when a capture is worth taking, from footprints alone.

    Pure and side effect free on purpose: the live loop and the self-test drive
    exactly the same `observe`, so the rate-limiting rules can be tested against
    synthetic series without a daemon, a clock, or a filesystem.

    THE RULES, AND WHY THEY ARE SHAPED THIS WAY

    Onset, absolute threshold: edge triggered. It fires when the peak reaches
    the threshold and the previous tick's peak did not, or when there was no
    previous tick at all. The second half is deliberate: a daemon already over
    the threshold when the watch starts is a spike in progress, and starting a
    watch mid-spike is the normal way this instrument gets used, so it earns one
    capture at t0. What the edge stops is the level plateau. A daemon idling at
    1100 MB against the 1024 MB default would otherwise re-arm and re-fire the
    same onset forever, which is what the level-triggered version did.

    Onset, rise: the peak stands `rise` above the rolling baseline minimum.
    Level triggered, and safely so, because the baseline climbs to meet a
    plateau within one baseline window and the rise then goes to zero.

    Release, either rule: (a) the peak has fallen below `release_fraction` of
    the level that fired the spike, or (b) the peak is back within
    `release_rise_fraction` of a rise above the rolling trough. Rule (b) carries
    no absolute-threshold guard; it does not need one now that the threshold
    onset is edge triggered, and the rise onset cannot re-fire on a plateau
    because the baseline has climbed up to the plateau.

    The consequence worth stating: a plateau releases once its baseline catches
    up, and a further climb off that plateau (5 GB held for an hour, then 8 GB)
    is then caught by the rise rule measured against the plateau baseline. The
    old design, which held one plateau open as a single unending spike, missed
    exactly that second step.
    """

    def __init__(
        self,
        threshold_bytes: int,
        rise_bytes: int,
        rearm_bytes: int,
        baseline_window: float,
        release_fraction: float = RELEASE_FRACTION,
        release_rise_fraction: float = RELEASE_RISE_FRACTION,
        max_captures_per_spike: int = MAX_CAPTURES_PER_SPIKE,
        rise_suppressed_until: float | None = None,
    ) -> None:
        self.threshold_bytes = threshold_bytes
        self.rise_bytes = rise_bytes
        self.rearm_bytes = rearm_bytes
        self.baseline_window = baseline_window
        self.release_fraction = release_fraction
        self.release_rise_fraction = release_rise_fraction
        self.max_captures_per_spike = max_captures_per_spike
        # Until this instant the rise rule does not fire. Set when the target
        # was acquired younger than one baseline window, so its climb to a
        # working set is not reported as a spike. None means never suppressed.
        self.rise_suppressed_until = rise_suppressed_until
        self._window: deque[tuple[float, int]] = deque()
        self._in_spike = False
        self._trigger_level = 0
        self._last_capture_value = 0
        self._previous_capture_value = 0
        self._captures_this_spike = 0
        # The previous tick's peak, which is what makes the threshold onset an
        # edge rather than a level. None means no tick has been seen yet.
        self._previous_peak: int | None = None

    @property
    def in_spike(self) -> bool:
        return self._in_spike

    def fresh(self, rise_suppressed_until: float | None = None) -> SpikeDetector:
        """A detector with these same rules and none of this one's history.

        The live watch builds one of these per target, because a restarted
        daemon measured against the dead one's baseline, or inheriting its
        in-spike state and its previous peak, reports the new process's startup
        as a spike of the old one. `--report` needs the same thing at the same
        instants, and it only has the detector it was handed, so it asks that
        detector for a replacement rather than being told the thresholds twice.
        """
        return SpikeDetector(
            threshold_bytes=self.threshold_bytes,
            rise_bytes=self.rise_bytes,
            rearm_bytes=self.rearm_bytes,
            baseline_window=self.baseline_window,
            release_fraction=self.release_fraction,
            release_rise_fraction=self.release_rise_fraction,
            max_captures_per_spike=self.max_captures_per_spike,
            rise_suppressed_until=rise_suppressed_until,
        )

    def baseline(self) -> int:
        """Lowest footprint seen inside the baseline window.

        The minimum, not the mean: a rolling mean is dragged up by the spike it
        is supposed to be measuring the rise from.
        """
        return min(value for _, value in self._window) if self._window else 0

    def observe(self, now: float, footprint: int, interval_max: int) -> list[CaptureRequest]:
        """Feed one tick, get back the captures it justifies (usually none)."""
        self._window.append((now, footprint))
        cutoff = now - self.baseline_window
        while len(self._window) > 1 and self._window[0][0] < cutoff:
            self._window.popleft()

        baseline = self.baseline()
        # The interval max is a peak the current footprint may have already
        # walked back from, so a spike between two ticks still trips this.
        peak = max(footprint, interval_max)
        previous_peak = self._previous_peak
        self._previous_peak = peak
        actions: list[CaptureRequest] = []

        if not self._in_spike:
            reason, level = self._trigger_for(now, peak, baseline, previous_peak)
            if reason is not None:
                self._in_spike = True
                self._trigger_level = level
                self._previous_capture_value = 0
                self._last_capture_value = peak
                self._captures_this_spike = 1
                actions.append(CaptureRequest(now, reason, footprint, interval_max, peak, baseline))
            return actions

        if self._releases(peak, baseline):
            # Fallen far enough below what fired it, or back down onto its own
            # baseline. The spike is over and the onset triggers are armed
            # again; no capture on the way down.
            self._in_spike = False
            self._trigger_level = 0
            self._last_capture_value = 0
            self._previous_capture_value = 0
            self._captures_this_spike = 0
            return actions

        if (
            self._captures_this_spike < self.max_captures_per_spike
            and peak >= self._last_capture_value + self.rearm_bytes
        ):
            self._captures_this_spike += 1
            self._previous_capture_value = self._last_capture_value
            self._last_capture_value = peak
            actions.append(
                CaptureRequest(now, "highwater", footprint, interval_max, peak, baseline)
            )
        return actions

    def withdraw(self, request: CaptureRequest) -> None:
        """Give back the accounting for a capture the runner refused to take.

        `observe` bills the capture before the runner is asked, because it is
        the detector that decides a capture is warranted. When the runner is
        busy with the previous one it declines, and without this the spike has
        silently spent a slot on a capture that never happened: a spike is
        allowed only `max_captures_per_spike`, so on a two-capture budget one
        refusal can mean the peak of the spike is never sampled at all.

        `_last_capture_value` is given back unconditionally, for a refused onset
        as much as for a refused high-water, because it is the rearm bar and
        nothing was recorded at the level it was raised to. Restoring it only
        for the high-water case left a refused onset's bar parked at the refused
        peak, so a spike that opens at 1500 MB and holds there took zero
        captures for as long as it lasted: the onset was refused, the bar said
        1500 MB, and no tick could ever clear 1500 plus a rearm. An onset
        restores to 0, which is what `_previous_capture_value` holds at onset,
        so the next tick at the same peak re-issues the capture as a
        `highwater` with the spike still open.

        A refused onset does not clear `in_spike`: the spike is real, it was
        detected, and re-entering it from scratch on the next tick would re-fire
        an onset capture on every tick for as long as the runner stays busy.
        """
        if self._captures_this_spike > 0:
            self._captures_this_spike -= 1
        self._last_capture_value = self._previous_capture_value

    def _releases(self, peak: int, baseline: int) -> bool:
        """Whether this tick ends the spike. Either rule is enough.

        (a) The original hysteresis: the peak has fallen well below the level
        that fired the spike. It is the only rule that can end a spike while the
        footprint is still far above its own baseline, and it cannot fire at all
        when the trough sits above `release_fraction` of that level.

        (b) Back within half a rise of the rolling trough. This is the case (a)
        cannot reach: a daemon idling at 990 MB against a 1024 MB threshold, or
        a rise-triggered spike whose baseline is more than three times the rise.
        It also ends a sustained plateau, because holding a level for longer than
        the baseline window drags the rolling minimum up to meet it, so
        `peak - baseline` goes to zero. That is the intended reading: a level
        held for a whole baseline window is the new normal, not an ongoing
        event. Nothing re-fires when it releases, because the threshold onset is
        edge triggered and the rise onset measures against that same climbed
        baseline. What does still fire is a further climb off the plateau, which
        is the case the old absolute-threshold guard on this rule swallowed.
        """
        if peak < self._trigger_level * self.release_fraction:
            return True
        return peak - baseline < self.rise_bytes * self.release_rise_fraction

    def _trigger_for(
        self, now: float, peak: int, baseline: int, previous_peak: int | None
    ) -> tuple[str | None, int]:
        """Which rule fires on this peak, and the level to release against.

        The threshold rule is edge triggered against `previous_peak`: no
        previous tick, or a previous tick below the threshold. A target already
        over the threshold when the watch starts therefore gets exactly one
        capture, and a plateau parked above it gets nothing after that.

        The rise rule is held off entirely until `rise_suppressed_until`, which
        the caller sets when it acquires a target younger than one baseline
        window. Such a target is still climbing to its working set, and a rise
        measured against its near-zero floor fires on the climb every time. The
        threshold rule is not held off with it: a young daemon crossing an
        absolute gigabyte is real whatever its age, and suppressing that too
        would blind the watch to the case it exists for.
        """
        if self.threshold_bytes > 0 and peak >= self.threshold_bytes:
            crossed = previous_peak is None or previous_peak < self.threshold_bytes
            if crossed:
                return "threshold", self.threshold_bytes
        if self.rise_suppressed_until is not None and now < self.rise_suppressed_until:
            return None, 0
        if self.rise_bytes > 0 and peak - baseline >= self.rise_bytes:
            return "rise", baseline + self.rise_bytes
        return None, 0


# ----------------------------------------------------------------------------
# CAPTURE
# ----------------------------------------------------------------------------


class CaptureRunner:
    """Runs one capture at a time, off the sampler's thread.

    Every failure here is recorded and swallowed. A capture that cannot run is a
    missing detail; a capture that takes the sampler down loses the whole night.
    """

    def __init__(
        self,
        captures_dir: Path,
        emit,
        want_sample: bool = True,
        want_vmmap: bool = False,
    ) -> None:
        self.captures_dir = captures_dir
        self.emit = emit
        self.want_sample = want_sample
        self.want_vmmap = want_vmmap
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        # Whether the last start attempt was refused because a capture was
        # already running. One busy episode is one marker: the sampler re-issues
        # the request on every tick until the runner is free, and a `sample`
        # call graph on a large process takes tens of seconds, so marking every
        # refusal wrote the same line hundreds of times for one refused capture.
        self._busy_refusal_noted = False

    def busy(self) -> bool:
        with self._lock:
            return self._running()

    def _running(self) -> bool:
        """Whether a capture is in flight. Caller holds the lock.

        Observing the runner idle also ends any refusal episode, so the next one
        is announced again. That is the half `start` cannot do on its own: a
        refusal is only ever recorded against a capture that was running, and
        the flag has to be clear again before the next capture starts.
        """
        alive = self._thread is not None and self._thread.is_alive()
        if not alive:
            self._busy_refusal_noted = False
        return alive

    def worst_case_seconds(self) -> float:
        """How long one capture can take, from the commands actually enabled.

        The commands run in sequence, so their timeouts add up. A join bounded
        by one command's timeout abandons a capture that was still writing.
        """
        total = float(FOOTPRINT_TIMEOUT)
        if self.want_sample:
            total += SAMPLE_TIMEOUT
        if self.want_vmmap:
            total += VMMAP_TIMEOUT
        return total + 5

    def start(self, pid: int, request: CaptureRequest) -> str | None:
        """Kick off a capture, returning its directory name, or None if busy.

        A refusal is recorded once per busy episode rather than once per tick.
        The sampler withdraws the refused capture and re-issues it on the next
        tick, which is what gets it taken as soon as the runner is free, but it
        means a `sample` that runs for a minute refuses sixty times over and
        used to write sixty identical markers into the record.
        """
        with self._lock:
            if self._running():
                if not self._busy_refusal_noted:
                    self._busy_refusal_noted = True
                    self.emit(
                        {
                            "event": "capture_skipped",
                            "reason": request.reason,
                            "why": "a capture is already running",
                        }
                    )
                return None
            stamp = datetime.fromtimestamp(request.when).strftime("%Y%m%d-%H%M%S")
            name = f"{stamp}-{request.reason}"
            target = self.captures_dir / name
            suffix = 1
            while target.exists():
                suffix += 1
                target = self.captures_dir / f"{name}-{suffix}"
            name = target.name
            thread = threading.Thread(
                target=self._run, args=(pid, request, target), name="capture", daemon=True
            )
            self._thread = thread
        thread.start()
        return name

    def join(self, timeout: float) -> None:
        with self._lock:
            thread = self._thread
        if thread is not None:
            thread.join(timeout)

    def _run(self, pid: int, request: CaptureRequest, target: Path) -> None:
        try:
            target.mkdir(parents=True, exist_ok=True)
            (target / "trigger.json").write_text(
                json.dumps(
                    {
                        "when": request.when,
                        "when_iso": iso(request.when),
                        "reason": request.reason,
                        "pid": pid,
                        "phys_footprint": request.footprint,
                        "interval_max_phys_footprint": request.interval_max,
                        "peak": request.peak,
                        "baseline": request.baseline,
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            commands: list[tuple[str, list[str], int]] = [
                ("footprint", ["/usr/bin/footprint", "-p", str(pid)], FOOTPRINT_TIMEOUT)
            ]
            if self.want_sample:
                # -file, because `sample` prints only a three line status to
                # stdout and writes the call graph to a file of its own choosing
                # otherwise. -mayDie so it does not abort if the target exits.
                commands.append(
                    (
                        "sample",
                        [
                            "/usr/bin/sample",
                            str(pid),
                            "2",
                            "-mayDie",
                            "-file",
                            str(target / "sample.txt"),
                        ],
                        SAMPLE_TIMEOUT,
                    )
                )
            if self.want_vmmap:
                commands.append(("vmmap", ["/usr/bin/vmmap", "-summary", str(pid)], VMMAP_TIMEOUT))

            with (target / "capture.log").open("a", encoding="utf-8") as journal:
                for label, argv, timeout in commands:
                    self._run_one(label, argv, timeout, target, journal)
        except Exception as exc:  # noqa: BLE001 - a capture must never kill the watch
            self.emit({"event": "capture_failed", "dir": target.name, "error": repr(exc)})

    def _run_one(self, label: str, argv: list[str], timeout: int, target: Path, journal) -> None:
        journal.write(f"$ {' '.join(argv)}\n")
        journal.flush()
        started = time.time()
        try:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        except Exception as exc:  # noqa: BLE001 - timeouts and missing tools alike
            journal.write(f"[{label}] failed after {time.time() - started:.1f}s: {exc!r}\n")
            journal.flush()
            self.emit(
                {
                    "event": "capture_tool_failed",
                    "dir": target.name,
                    "tool": label,
                    "error": repr(exc),
                }
            )
            return
        journal.write(f"[{label}] rc={done.returncode} in {time.time() - started:.1f}s\n")
        if done.stdout and label != "footprint" and label != "vmmap":
            journal.write(done.stdout)
        if done.stderr:
            journal.write(done.stderr)
        journal.flush()
        if done.returncode != 0:
            # A tool that ran and refused is as much a hole in the record as one
            # that never started, and it used to leave no marker at all: the
            # target exiting between the trigger and the fork wrote an empty
            # `footprint.txt` and the run read as if the capture had worked.
            # The stderr head is kept short, and folded onto one line, because
            # it lands in samples.jsonl and in a one-line-per-problem report.
            self.emit(
                {
                    "event": "capture_tool_failed",
                    "dir": target.name,
                    "tool": label,
                    "rc": done.returncode,
                    "error": " ".join((done.stderr or "").split())[:200],
                }
            )
            return
        if label == "footprint":
            (target / "footprint.txt").write_text(done.stdout, encoding="utf-8")
        elif label == "vmmap":
            (target / "vmmap.txt").write_text(done.stdout, encoding="utf-8")


# ----------------------------------------------------------------------------
# LOG SIDECAR
# ----------------------------------------------------------------------------


# The watchdog the sidecar actually runs. It takes the watcher's pid, a file to
# write the stream's pid into, and then the command to run as "$@" - never
# interpolated into this text, so a path with a space or a quote in it cannot
# become shell syntax.
#
# `sleep 5 & wait` rather than a bare `sleep 5`: a POSIX shell runs a trap only
# when the current command finishes, and `wait` is the one command a signal
# interrupts, so this is what makes the TERM path prompt instead of taking up to
# five seconds.
SIDECAR_WATCHDOG = r"""
parent=$1
pidfile=$2
shift 2
"$@" &
child=$!
printf '%s\n' "$child" > "$pidfile" 2>/dev/null || :
finish() {
  kill "$child" 2>/dev/null || :
  exit 0
}
trap finish TERM INT
while kill -0 "$parent" 2>/dev/null; do
  kill -0 "$child" 2>/dev/null || exit 0
  sleep 5 &
  wait $!
done
kill "$child" 2>/dev/null || :
"""


class LogSidecar:
    """A `log stream` child, kept alive by a watchdog that outlives no one.

    The stream is not spawned directly. `/bin/sh` runs it in the background and
    then does two things forever: it polls the watcher's pid with `kill -0`
    every five seconds and kills the stream the moment the watcher is gone, and
    it traps TERM and INT and kills the stream on the way out. The pair is
    spawned in a session of its own, so `stop()` can signal the whole process
    group and reach both halves at once.

    That indirection exists because a `log stream` child does not die with its
    parent. SIGKILL the watcher - `kill -9`, an OOM kill, a crash - and the
    ordinary Popen child is re-parented to launchd and streams the whole system
    log into a file nobody is reading for as long as the machine is up. There is
    no reconciler for it, and the only trace it leaves is a file that grows. The
    trap is what keeps the normal path prompt; the poll is what limits the
    SIGKILL path to about five seconds in the normal case.

    That is a normal case, not a hard bound. `kill -0` asks about a number, so a
    watcher whose pid is handed to another process inside one poll window is
    still answered for by the newcomer and the stream is kept alive by a pid
    that is no longer this watch. It takes a pid wrapping round to a specific
    number within five seconds, which is unlikely but not impossible, and the
    cost when it happens is the orphan this watchdog exists to prevent.

    Nothing here ever signals a process it did not spawn: the group it kills is
    the one it created with `start_new_session`, and the killpg is guarded on
    that group still being led by the sh it started.
    """

    LOG_ARGV = [
        "/usr/bin/log",
        "stream",
        "--level",
        "debug",
        "--style",
        "compact",
        "--predicate",
        'subsystem BEGINSWITH "com.tbd"',
    ]

    def __init__(self, path: Path, pid_path: Path) -> None:
        self.path = path
        self.pid_path = pid_path
        self.process: subprocess.Popen | None = None
        self.stream_pid: int | None = None
        self._handle = None

    def start(self) -> int | None:
        """Spawn the watchdog. Returns the sh pid; `stream_pid` gets the log's."""
        self._handle = self.path.open("a", encoding="utf-8")
        self.process = subprocess.Popen(
            [
                "/bin/sh",
                "-c",
                SIDECAR_WATCHDOG,
                "sidecar-watchdog",  # $0
                str(os.getpid()),  # $1, the pid the watchdog polls
                str(self.pid_path),  # $2, where it writes the stream pid
            ]
            + self.LOG_ARGV,  # "$@", never spliced into the script text
            stdout=self._handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        self.stream_pid = self._read_stream_pid()
        return self.process.pid

    def _read_stream_pid(self, budget: float = 2.0) -> int | None:
        """The `log` pid the watchdog wrote, if it has got round to it yet.

        Best effort and time boxed: the pid is for the record and for a human
        checking afterwards that nothing was left behind, and `stop()` does not
        depend on it. Waiting on it forever would trade a diagnostic for a hang.
        """
        deadline = time.time() + budget
        while time.time() < deadline:
            try:
                return int(self.pid_path.read_text(encoding="utf-8").strip())
            except (OSError, ValueError):
                time.sleep(0.05)
        return None

    def _signal_group(self, sig: int) -> None:
        """Signal the sidecar's own process group, or the sh alone if it moved.

        `start_new_session` makes the sh a group leader, so its group id equals
        its pid. If that is somehow not what the kernel reports, the group is
        not ours to signal and only the child we spawned is.
        """
        if self.process is None:
            return
        try:
            pgid = os.getpgid(self.process.pid)
        except OSError:
            pgid = None
        try:
            if pgid == self.process.pid:
                os.killpg(pgid, sig)
            else:
                os.kill(self.process.pid, sig)
        except OSError:
            pass

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self._signal_group(signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._signal_group(signal.SIGKILL)
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
        if self._handle is not None:
            self._handle.close()
            self._handle = None


# ----------------------------------------------------------------------------
# TARGET RESOLUTION
# ----------------------------------------------------------------------------


def tbd_home() -> Path:
    return Path(os.environ.get("TBD_HOME") or (Path.home() / "tbd"))


def pid_file_path() -> Path:
    return tbd_home() / "tbdd.pid"


def read_pid_file(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def footprint_root() -> Path:
    """The directory every run directory and every watch lock lives under."""
    return tbd_home() / "diag" / "daemon-footprint"


def watch_lock_path(target_pid: int) -> Path:
    """The rendezvous file that says a watch already holds this target."""
    return footprint_root() / f".watch-{target_pid}.lock"


def read_lock(path: Path) -> tuple[int | None, int | None]:
    """(holder pid, holder start stamp) from a lock file, or (None, None).

    A lock is one JSON object: `{"pid": N, "start_abstime": S}`. The stamp is
    what makes the pid mean something: a pid on its own is reused, so a watcher
    that was SIGKILLed and whose pid was handed to an unrelated process reads as
    a live holder for as long as that process runs, and nothing ever reclaims
    the lock.

    A file holding a bare pid, which is what earlier watches wrote, still reads:
    it yields a pid and no stamp, and `holder_is_alive` then falls back to
    liveness alone. A file that parses as neither yields no pid at all, which
    `take_lock` reclaims exactly as it always did.
    """
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None, None
    if not text:
        return None, None
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = None
    if isinstance(payload, dict):
        try:
            pid = int(payload["pid"])
        except (KeyError, TypeError, ValueError):
            return None, None
        raw = payload.get("start_abstime")
        try:
            start = int(raw) if raw is not None else None
        except (TypeError, ValueError):
            start = None
        return pid, (start or None)
    try:
        return int(text), None
    except ValueError:
        return None, None


def write_lock(handle: int, start_abstime: int | None) -> None:
    """Write this process's identity into an open, exclusively created lock."""
    with os.fdopen(handle, "w", encoding="utf-8") as lock:
        lock.write(json.dumps({"pid": os.getpid(), "start_abstime": start_abstime}) + "\n")


_LIBPROC: LibProc | None = None


def shared_libproc() -> LibProc | None:
    """The process-wide libproc binding, or None where there is no libproc.

    Bound lazily and kept, because `process_identity` is called from the lock
    paths a handful of times per run and binding costs a dylib load. None on any
    machine without libproc, which is what keeps the self-test importable and
    runnable on Linux.
    """
    global _LIBPROC
    if _LIBPROC is None:
        try:
            _LIBPROC = LibProc()
        except Exception:  # noqa: BLE001 - no libproc is not fatal, only less certain
            return None
    return _LIBPROC


def process_identity(pid: int) -> tuple[bool, int | None]:
    """(is `pid` live, its start stamp) - the seam every identity check goes through.

    A signal of 0 tests for the process without disturbing it. EPERM means it
    exists and belongs to somebody else, which is still live. Anything
    non-positive is not a pid at all and is dead, because signal 0 to pid 0
    addresses this process group rather than one process.

    The stamp is `ri_proc_start_abstime`, the only thing that tells two
    processes at one pid apart. None means "cannot tell", never "different": no
    libproc, a process owned by somebody else, or a pid already gone.

    Callers take this as a parameter rather than calling it directly, so a test
    can hand back fixed tuples and run on a machine with no libproc at all.
    """
    if pid <= 0:
        return False, None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False, None
    except OSError:
        return True, None
    lib = shared_libproc()
    if lib is None:
        return True, None
    usage = lib.rusage(pid)
    if usage is None:
        return True, None
    return True, (int(usage.ri_proc_start_abstime) or None)


def identity_changed(recorded_start: int | None, current_start: int | None) -> bool:
    """Whether a pid is now held by a different process than the one recorded.

    True only when both stamps are known and they differ. An unknown stamp on
    either side is "cannot tell", which every caller reads as "carry on": a fact
    that could not be read must never be able to throw away a live target.
    """
    if not recorded_start or not current_start:
        return False
    return int(recorded_start) != int(current_start)


def holder_is_alive(
    pid: int,
    recorded_start: int | None = None,
    identity=process_identity,
) -> bool:
    """Whether a lock holder is still running. Uncertainty counts as alive.

    Live means the pid answers *and* the process answering is the one that took
    the lock. A recorded stamp the running process does not match means that pid
    was reused after the holder died, so the lock is stale and reclaimable; a
    lock with no recorded stamp, which is what a legacy plain-pid file is, falls
    back to liveness alone and is reclaimed only when the pid is dead.
    """
    alive, current_start = identity(pid)
    if not alive:
        return False
    if recorded_start is None or current_start is None:
        return True
    return not identity_changed(recorded_start, current_start)


# ----------------------------------------------------------------------------
# RECLAIM: THE NAMED RECONCILER FOR RUN DIRECTORIES
# ----------------------------------------------------------------------------


@dataclass
class SweepResult:
    """What one pass over the daemon-footprint directory did."""

    removed: list[str] = field(default_factory=list)
    removed_locks: list[str] = field(default_factory=list)
    kept_live: int = 0


def newest_mtime(path: Path) -> float:
    """The most recent mtime anywhere under `path`, symlinks never followed.

    `lstat` throughout, so a symlink contributes its own mtime and never its
    target's. Reading through one is both a way for a link into a directory
    somebody else is writing to keep a dead run alive forever, and a way out of
    this tree entirely.

    The directory's own mtime is included, so a run directory holding nothing
    still has an age instead of reading as epoch zero.
    """
    try:
        newest = path.lstat().st_mtime
    except OSError:
        return 0.0
    for current, dirs, files in os.walk(str(path), followlinks=False):
        for name in dirs + files:
            try:
                stamp = os.lstat(os.path.join(current, name)).st_mtime
            except OSError:
                continue
            if stamp > newest:
                newest = stamp
    return newest


def read_run_watcher(run_dir: Path) -> tuple[int | None, int | None]:
    """(watcher pid, its start stamp) from a run's `run.json`, or (None, None).

    Anything missing, unreadable, unparseable, or written by a watch older than
    these fields reads as "no watcher named", which leaves the directory to the
    age rule alone rather than to a guess.
    """
    try:
        payload = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None, None
    if not isinstance(payload, dict):
        return None, None
    try:
        pid = int(payload["watcher_pid"])
    except (KeyError, TypeError, ValueError):
        return None, None
    raw = payload.get("watcher_start_abstime")
    try:
        start = int(raw) if raw is not None else None
    except (TypeError, ValueError):
        start = None
    return pid, (start or None)


def sweep_footprint_root(
    root: Path | None = None,
    keep_days: float = DEFAULT_KEEP_DAYS,
    now: float | None = None,
    identity=process_identity,
    skip: Path | None = None,
) -> SweepResult:
    """Reclaim run directories nobody is watching, and locks nobody holds.

    This is the named reconciler for `$TBD_HOME/diag/daemon-footprint/`. It runs
    at the start of every live watch and on `--prune`, and nothing else ever
    removes anything here: no daemon sweep covers this directory, and an
    operator who has to remember a path is an operator who does not.

    Two rules, and both have to hold before anything is removed. A run directory
    goes when its newest file is older than `keep_days` and no live watcher
    claims it; a `.watch-<pid>.lock` goes when its holder is dead. Liveness is
    the same identity test the lock reclaim uses, injected so the self-test can
    run where there is no libproc: a pid that answers *and* whose start stamp
    matches the one recorded is the process that wrote the file.

    Everything about it is keep-biased. `keep_days <= 0` disables it outright.
    Anything younger than the cutoff is never looked at further. A run with no
    readable watcher goes by age alone rather than being read as abandoned, an
    unreadable identity counts as alive, and a removal that fails is dropped
    rather than retried. Symlinks are skipped at the top level and never
    followed below it, and every path removed is rebuilt under the resolved root
    and checked against its prefix, so a name cannot reach out of this tree.

    `skip` is the caller's own run directory, which is young by construction but
    is named explicitly anyway: a sweep that could delete the directory it is
    about to write into would be a bug that only shows up on a clock change.
    """
    result = SweepResult()
    if keep_days <= 0:
        return result
    root = footprint_root() if root is None else root
    try:
        root_real = root.resolve()
        names = sorted(os.listdir(str(root_real)))
    except OSError:
        return result
    now = time.time() if now is None else now
    cutoff = now - keep_days * SECONDS_PER_DAY
    prefix = str(root_real).rstrip(os.sep) + os.sep
    skip_real: Path | None = None
    if skip is not None:
        try:
            skip_real = skip.resolve()
        except OSError:
            skip_real = None

    for name in names:
        path = root_real / name
        if not str(path).startswith(prefix):
            continue
        if os.path.islink(str(path)):
            # Never followed and never removed: whatever it points at is not
            # this tree's to reclaim.
            continue
        if name.startswith(".watch-") and name.endswith(".lock"):
            holder, holder_start = read_lock(path)
            if holder is None or holder == os.getpid():
                continue
            if holder_is_alive(holder, holder_start, identity):
                continue
            try:
                path.unlink()
            except OSError:
                continue
            result.removed_locks.append(name)
            continue
        if not os.path.isdir(str(path)):
            continue
        if skip_real is not None and path == skip_real:
            continue
        if newest_mtime(path) >= cutoff:
            continue
        watcher_pid, watcher_start = read_run_watcher(path)
        if watcher_pid is not None and holder_is_alive(watcher_pid, watcher_start, identity):
            # Old files, live watch. A watch that has not found a target writes
            # no samples, so age alone would reclaim a run in progress.
            result.kept_live += 1
            continue
        try:
            shutil.rmtree(str(path))
        except OSError:
            continue
        result.removed.append(name)
    return result


def sweep_summary(result: SweepResult, keep_days: float, root: Path | None = None) -> str:
    """One line saying what the sweep did, for stdout."""
    root = footprint_root() if root is None else root
    if keep_days <= 0:
        return f"sweep disabled (--keep-days 0); nothing reclaimed under {root}"
    return (
        f"swept {root}: {len(result.removed)} run director"
        f"{'y' if len(result.removed) == 1 else 'ies'} removed, "
        f"{len(result.removed_locks)} stale lock(s) removed, "
        f"{result.kept_live} kept for a live watch (--keep-days {keep_days:g})"
    )


def prune(keep_days: float) -> int:
    """`--prune`: run the startup sweep on its own and say what it removed."""
    root = footprint_root()
    result = sweep_footprint_root(root=root, keep_days=keep_days)
    for name in result.removed + result.removed_locks:
        print(f"removed {root / name}")
    print(sweep_summary(result, keep_days, root))
    return 0


# The daemon executable is named TBDDaemon. `tbdd` is accepted too, so a future
# rename to match the pid file does not silently stop the watch from acquiring.
DAEMON_COMM_NAMES = ("TBDDaemon", "tbdd")


def process_comm(pid: int) -> str | None:
    """The executable path `ps` reports for `pid`, or None if it cannot say."""
    try:
        done = subprocess.run(
            ["/bin/ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True, timeout=10
        )
    except Exception:  # noqa: BLE001 - an unreadable comm is not fatal
        return None
    value = done.stdout.strip()
    return value or None


def comm_is_daemon(comm: str | None) -> bool:
    """Whether a `ps -o comm=` value names the TBD daemon executable."""
    if not comm:
        return False
    return comm.rsplit("/", 1)[-1] in DAEMON_COMM_NAMES


def process_start_time(pid: int) -> str | None:
    """The target's wall-clock start, so a restart mid-run is unambiguous."""
    try:
        done = subprocess.run(
            ["/bin/ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=10
        )
    except Exception:  # noqa: BLE001 - a missing start time is not fatal
        return None
    value = done.stdout.strip()
    return value or None


# ----------------------------------------------------------------------------
# FORMATTING
# ----------------------------------------------------------------------------


def iso(epoch: float) -> str:
    """Local time with a UTC offset, so a run is readable months later."""
    return datetime.fromtimestamp(epoch).astimezone().isoformat(timespec="milliseconds")


def hhmmss(epoch: float) -> str:
    return datetime.fromtimestamp(epoch).strftime("%H:%M:%S.%f")[:-3]


def fmt_bytes(value: float) -> str:
    step = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if step < 1024 or unit == "TB":
            return f"{step:.2f} {unit}" if unit != "B" else f"{step:.0f} B"
        step /= 1024
    return f"{step:.2f} TB"


# ----------------------------------------------------------------------------
# THE SAMPLER LOOP
# ----------------------------------------------------------------------------


class Watch:
    """Sampler, detector, capture runner and sidecar, wired together."""

    def __init__(
        self, args: argparse.Namespace, out_dir: Path, libproc: LibProc | None = None
    ) -> None:
        self.args = args
        self.out_dir = out_dir
        self.captures_dir = out_dir / "captures"
        self.samples_path = out_dir / "samples.jsonl"
        self.log_path = out_dir / "daemon-log.txt"
        self.stop_event = threading.Event()
        # A second SIGINT during shutdown sets this and abandons the join on an
        # in-flight capture. Separate from stop_event because by then stop_event
        # is already set and would tell us nothing.
        self.abandon_event = threading.Event()
        self.signal_count = 0
        # Injectable so the identity tests can drive `tick` on a machine with no
        # libproc; every real run binds the real one here.
        self.libproc = LibProc() if libproc is None else libproc
        self.detector = self.make_detector()
        self._emit_lock = threading.Lock()
        self._samples = None
        self.capture_runner = CaptureRunner(
            self.captures_dir,
            self.emit,
            want_sample=not args.no_sample,
            want_vmmap=args.vmmap,
        )
        self.sidecar: LogSidecar | None = None
        self.pid: int | None = None
        # What `run` hands back. 0 unless a bail wants to say something more
        # specific than "the operator stopped it".
        self.exit_code = 0
        # The per-target lock this watch currently owns, if any.
        self._lock_path: Path | None = None
        # Which other watchers have already been named in the record, so a pid
        # file pointing at a target somebody else holds does not write the same
        # marker on every tick for as long as they hold it.
        self._conflict_noted: set[int] = set()
        self._prev_cpu: tuple[float, int, int] | None = None
        # The acquired target's `ri_proc_start_abstime`, which is what tells a
        # daemon that restarted onto the same pid from the one that was
        # acquired. None means the stamp could not be read, which suppresses the
        # check rather than dropping a live target.
        self._target_start_abstime: int | None = None
        self._reset_failure_noted = False
        # Which pids a comm marker has already been written about, so a pid file
        # pointing at the wrong process does not write the same marker forever.
        # An acquired pid is dropped from this set when the target is lost, so a
        # pid that comes back (a reused pid, or a pid file rewritten with the
        # same number) is described again rather than silently reused.
        self._comm_noted: set[int] = set()

    def make_detector(self, rise_suppressed_until: float | None = None) -> SpikeDetector:
        """A detector carrying no history, built from this run's thresholds."""
        return SpikeDetector(
            threshold_bytes=int(self.args.threshold_mb * MB),
            rise_bytes=int(self.args.rise_mb * MB),
            rearm_bytes=int(self.args.rearm_mb * MB),
            baseline_window=self.args.baseline_window,
            rise_suppressed_until=rise_suppressed_until,
        )

    # -- record ------------------------------------------------------------

    def emit(self, record: dict) -> None:
        """Append one JSON line. Called from the capture thread too."""
        record.setdefault("epoch", time.time())
        record.setdefault("ts", iso(record["epoch"]))
        line = json.dumps(record)
        with self._emit_lock:
            if self._samples is None:
                return
            self._samples.write(line + "\n")
            self._samples.flush()

    # -- target ------------------------------------------------------------

    def take_lock(self, target_pid: int, identity=process_identity) -> tuple[str, int | None]:
        """Claim this target's watch lock. Returns (status, holder pid or None).

        The status is one of three words, and nothing else:

        "acquired"  the lock file is ours and `release_lock` will remove it.
        "conflict"  somebody else holds it; the holder pid is returned with it
                    when the file could be read, and None when it could not.
        "unlocked"  no lock file could be created or reclaimed at all, so the
                    watch proceeds without one and says so in the record.

        The three words exist because this used to return `None` for both
        "acquired" and "gave up", and callers read `None` as success: a second
        FileExistsError from a holder that had already been declared dead
        returned None and the watch believed it held a lock it had never
        created. A watch reads the same three-way answer whatever happened.

        Created with O_EXCL, so two watchers starting at the same instant cannot
        both believe they took it. A lock whose holder is dead is stale and is
        removed and retaken here, which is the only thing that ever reclaims one:
        a SIGKILLed watcher cannot unlink its own. The lock is a guard against a
        second watcher, not a precondition for measuring anything, so an
        unwritable directory is "unlocked" and the watch goes on measuring.

        What is written is the holder's pid *and* its start stamp, and both are
        checked on reclaim, because a pid alone cannot say whether the process
        answering is the watcher that took the lock or an unrelated process that
        was handed its number afterwards. `identity` is the seam that reads
        both, injectable so the tests can run where there is no libproc.
        """
        path = watch_lock_path(target_pid)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
        except OSError:
            return "unlocked", None
        for _ in range(2):
            try:
                handle = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            except FileExistsError:
                holder, holder_start = read_lock(path)
                if (
                    holder is not None
                    and holder != os.getpid()
                    and holder_is_alive(holder, holder_start, identity)
                ):
                    return "conflict", holder
                try:
                    path.unlink()
                except OSError:
                    # The holder is dead but its file cannot be removed, so no
                    # live watcher is being conflicted with and there is nothing
                    # to reclaim either. Measure, unlocked.
                    return "unlocked", None
                continue
            except OSError:
                return "unlocked", None
            write_lock(handle, identity(os.getpid())[1])
            self._lock_path = path
            return "acquired", None
        # Both attempts lost the race to create the file, each time to a holder
        # that read as dead. Something is recreating it as fast as it is
        # reclaimed, which is a second watcher whether or not its pid is
        # readable now, and it is the one case that must not read as success.
        return "conflict", read_lock(path)[0]

    def release_lock(self) -> None:
        """Give the lock back, and only ever our own."""
        path = self._lock_path
        self._lock_path = None
        if path is None:
            return
        try:
            if read_lock(path)[0] == os.getpid():
                path.unlink()
        except OSError:
            pass

    def note_unlocked(self, target_pid: int) -> None:
        """Record that this target is being watched without holding its lock.

        Not a refusal: the measurement is unaffected. What it costs is the
        guarantee that nobody else is resetting the same footprint interval, so
        the record has to say the guarantee was not held rather than leaving an
        interval max that somebody else shortened looking like the target's own.
        """
        self.emit(
            {
                "event": "watch_unlocked",
                "pid": target_pid,
                "lock": str(watch_lock_path(target_pid)),
                "note": "watch lock could not be created; a second watcher would go unnoticed",
            }
        )

    def note_conflict(self, target_pid: int, holder: int | None) -> None:
        """Record, and for an explicit --pid refuse outright, a second watcher.

        Two watches on one target both call `proc_reset_footprint_interval` on
        it, and the counter is per-process: each reset shortens the other
        watch's window, so the sub-tick guarantee both of them are written
        around quietly stops holding. An explicit --pid names one process and
        has nowhere else to go, so it says so and stops; the pid-file path keeps
        looking, because the daemon it is waiting for may yet be restarted onto
        a pid nobody holds.
        """
        if holder not in self._conflict_noted:
            self._conflict_noted.add(holder)
            self.emit(
                {
                    "event": "watch_conflict",
                    "pid": target_pid,
                    "holder_pid": holder,
                    "lock": str(watch_lock_path(target_pid)),
                }
            )
        if self.args.pid is not None:
            named = f"pid {holder}" if holder is not None else "another watcher"
            print(
                f"pid {target_pid} is already being watched by {named} "
                f"({watch_lock_path(target_pid)}); two watches steal each other's "
                "footprint interval resets. Stop that watch first.",
                file=sys.stderr,
            )
            self.exit_code = 4
            self.stop_event.set()

    def acquire(self, pid: int, now: float | None = None) -> bool:
        """Take the target, or refuse because another watch already holds it."""
        status, holder = self.take_lock(pid)
        if status == "conflict":
            self.note_conflict(pid, holder)
            return False
        now = time.time() if now is None else now
        if status == "unlocked":
            self.note_unlocked(pid)
        self.pid = pid
        self._prev_cpu = None
        self._reset_failure_noted = False
        # How far into its own startup the target is, and which process at this
        # pid this is. Both read before the interval reset, from the same struct
        # the sampler reads every tick.
        usage = self.libproc.rusage(pid)
        self._target_start_abstime = (
            None if usage is None else (int(usage.ri_proc_start_abstime) or None)
        )
        age = (
            None
            if usage is None
            else process_age_seconds(
                int(usage.ri_proc_start_abstime),
                self.libproc.timebase_numer,
                self.libproc.timebase_denom,
            )
        )
        # Reset before the first read, not just after it. Nobody has reset this
        # counter since the target launched, so an un-reset first sample reports
        # the peak since process start: 7.4 GB on the incident daemon, which
        # would fire a capture at t0 and then dominate every report of the run.
        reset_ok = self.libproc.reset_footprint_interval(pid)
        self.emit(
            {
                # Stamped with the tick that acquired the target, like the
                # `rise_suppressed` marker below and like the samples
                # themselves. Stamped with the wall clock instead it lands
                # *after* the first sample of the target it introduces, and a
                # replay that resets the detector on this marker would hand that
                # first sample to the previous target's detector.
                "epoch": now,
                "event": "target_acquired",
                "pid": pid,
                "start_time": process_start_time(pid),
                # The stamp the tick-by-tick identity check compares against.
                # Recorded so a restart onto the same pid is legible from the
                # record: two acquisitions of one pid with different stamps are
                # two processes, which no wall-clock start time can settle at
                # one-second resolution.
                "start_abstime": self._target_start_abstime,
                "target_age_s": None if age is None else round(age, 3),
            }
        )
        # A target still climbing to its working set would fire the rise rule on
        # the climb, so the rule is held off for whatever is left of one baseline
        # window. An unreadable age suppresses nothing, and says so: a missing
        # fact must never be able to silence a real spike.
        suppressed_until = None
        if age is None:
            self.emit(
                {
                    "event": "target_age_unknown",
                    "pid": pid,
                    "note": "process age unreadable; the rise rule is not suppressed",
                }
            )
        elif age < self.args.baseline_window:
            suppressed_until = now + (self.args.baseline_window - age)
            self.emit(
                {
                    # Stamped with the tick that acquired the target rather
                    # than with the instant this line was written, so a replay
                    # applies it to the same sample the live detector did.
                    "epoch": now,
                    "event": "rise_suppressed",
                    "pid": pid,
                    "until": suppressed_until,
                    "until_iso": iso(suppressed_until),
                    "target_age_s": round(age, 3),
                }
            )
        # A fresh detector per target. A restarted daemon climbs from nothing to
        # its working set in the first seconds, and measuring that climb against
        # the dead process's baseline, or inheriting its in-spike state, would
        # report the new process's startup as a spike of the old one.
        self.detector = self.make_detector(rise_suppressed_until=suppressed_until)
        if not reset_ok:
            self.note_reset_failure()
        return True

    def note_reset_failure(self) -> None:
        """Record, once per acquired target, that the interval reset is failing.

        Once per target rather than once per tick: the failure is a property of
        the target, and a marker on every tick would bury the samples. Without
        the marker an interval max that only ever climbs looks like a real spike
        that never released.
        """
        if self._reset_failure_noted:
            return
        self._reset_failure_noted = True
        self.emit({"event": "interval_reset_failed", "pid": self.pid})

    def lose(self, now: float | None = None) -> None:
        # Stamped with the tick that found the target gone, for the same reason
        # `target_acquired` is: a replay closes the open spike at this instant,
        # and the instant has to sit between the target's last sample and the
        # next target's first one.
        when = time.time() if now is None else now
        if self.pid is not None:
            self.emit({"epoch": when, "event": "target_lost", "pid": self.pid})
            # Forget what was noted about this pid. The number is free for
            # reuse the moment the process is gone, so a remembered marker
            # would suppress the description of a different process.
            self._comm_noted.discard(self.pid)
        # The lock names a target, and this watch no longer holds one.
        self.release_lock()
        self.pid = None
        self._prev_cpu = None
        self._target_start_abstime = None

    def comm_for(self, pid: int) -> str | None:
        """`ps -o comm=` for a pid, read fresh on every acquire attempt.

        This used to be memoised per pid for the lifetime of the run. That was
        wrong twice over: the map only ever grew, one entry per pid the file
        ever named, and a pid that had been rejected once was rejected from the
        cache forever, so a daemon that started on a pid some earlier process
        had held could never be acquired. `resolve_pid` runs only while no
        target is held, so the cost of reading it fresh is one `ps` per tick
        while the watch is idle and none at all once it has a target.
        """
        return process_comm(pid)

    def resolve_pid(self) -> int | None:
        """The pid to sample, or None to keep looking on the next tick.

        A pid alone is not identity. Pids are reused, and `$TBD_HOME/tbdd.pid`
        outlives the daemon that wrote it, so a readable pid can be any process
        the user happens to own. When the pid came from the file it therefore
        has to name the daemon executable as well; when the operator passed
        `--pid` it is taken as given, and the record says what was sampled so
        nobody has to guess afterwards which process a run describes.
        """
        explicit = self.args.pid is not None
        candidate = self.args.pid if explicit else read_pid_file(pid_file_path())
        if candidate is None:
            return None
        # Only accept a pid we can actually read, so a stale pid file does not
        # look like an acquired target.
        if self.libproc.rusage(candidate) is None:
            return None
        comm = self.comm_for(candidate)
        if explicit:
            if candidate not in self._comm_noted:
                self._comm_noted.add(candidate)
                self.emit({"event": "target_comm", "pid": candidate, "comm": comm})
            return candidate
        if not comm_is_daemon(comm):
            if candidate not in self._comm_noted:
                self._comm_noted.add(candidate)
                self.emit({"event": "pid_file_mismatch", "pid": candidate, "comm": comm})
            return None
        return candidate

    # -- reclaim -----------------------------------------------------------

    def sweep_old_runs(self) -> SweepResult:
        """Run the startup sweep and say on stdout what it did.

        The reconciler for run directories runs here rather than on a timer or
        in the daemon, because a watch is the only thing that ever visits this
        directory and starting one is the moment somebody is looking at it. A
        failure to reclaim must never stop a watch from measuring, so the whole
        pass is guarded: a sweep that raises leaves an empty result and the
        watch carries on.
        """
        try:
            result = sweep_footprint_root(keep_days=self.args.keep_days, skip=self.out_dir)
        except Exception as exc:  # noqa: BLE001 - reclaiming must not cost a watch
            print(f"sweep failed, continuing without it: {exc!r}", file=sys.stderr)
            return SweepResult()
        print(sweep_summary(result, self.args.keep_days))
        return result

    # -- loop --------------------------------------------------------------

    def run(self) -> int:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.captures_dir.mkdir(parents=True, exist_ok=True)
        # Before anything else, including opening the record: a watch reclaims
        # what earlier watches left behind whether or not it goes on to find a
        # target. The marker it produces is emitted further down, below the
        # `--pid` bail, for the same reason the timebase marker is.
        sweep = self.sweep_old_runs()
        self._samples = self.samples_path.open("a", encoding="utf-8")

        initial_pid = self.resolve_pid()
        if initial_pid is None and self.args.pid is not None:
            # An explicit --pid names one process. If it cannot be read it is
            # gone, or it belongs to another user, and no amount of waiting will
            # change that: keeping the pid-file path's "keep looking" behaviour
            # here would silently sample nothing all night.
            print(
                f"--pid {self.args.pid} cannot be read: no such process, or it is not "
                "owned by this user.",
                file=sys.stderr,
            )
            with self._emit_lock:
                if self._samples is not None:
                    self._samples.close()
                    self._samples = None
            # Nothing was sampled, so leave no `samples.jsonl` behind: an empty
            # one would make the same --out refuse the corrected retry as a
            # second run appended to a first.
            try:
                if self.samples_path.stat().st_size == 0:
                    self.samples_path.unlink()
            except OSError:
                pass
            return 2

        # Emitted below the bail above, not before it: a marker written first
        # leaves a non-empty samples.jsonl behind for a --pid that could not be
        # read at all, and the corrected retry against the same --out is then
        # refused as a second run appended to a first.
        self.emit(
            {
                "event": "swept",
                "removed": sweep.removed,
                "kept_live": sweep.kept_live,
                "removed_locks": sweep.removed_locks,
                "keep_days": self.args.keep_days,
                "root": str(footprint_root()),
            }
        )
        if not self.libproc.timebase_ok:
            # 1/1 is also the real Apple-Intel ratio, so without this marker a
            # run that gave up on the timebase is indistinguishable from one
            # that read it, and every cpu_pct in it would be wrong by ~41.7 on
            # Apple silicon with nothing in the record to say so.
            self.emit(
                {
                    "event": "timebase_fallback",
                    "note": "mach_timebase_info unavailable; CPU scaled 1:1",
                }
            )

        sidecar_pid = None
        # Everything from the sidecar's first breath onwards is inside the try,
        # so nothing between spawning it and entering the loop can leave a `log
        # stream` child running with nobody left to terminate it. Writing
        # run.json is the concrete way that used to happen: an --out path that
        # is unwritable raises after the child exists.
        try:
            if not self.args.no_log_stream:
                self.sidecar = LogSidecar(self.log_path, self.out_dir / "sidecar.pid")
                sidecar_pid = self.sidecar.start()
            self.write_run_json(initial_pid, sidecar_pid)

            print(f"watching -> {self.out_dir}")
            if initial_pid is None:
                print("no target yet; will keep looking at the pid file every tick")
            else:
                print(f"target pid {initial_pid}")
            if sidecar_pid is not None:
                stream_pid = self.sidecar.stream_pid if self.sidecar else None
                stream_note = f", log stream pid {stream_pid}" if stream_pid else ""
                print(
                    f"log sidecar watchdog pid {sidecar_pid}{stream_note} "
                    f"-> {self.log_path.name}"
                )
            print("Ctrl-C to stop")

            if initial_pid is not None:
                self.acquire(initial_pid)

            while not self.stop_event.is_set():
                tick_started = time.time()
                self.tick(tick_started)
                remaining = self.args.interval - (time.time() - tick_started)
                if remaining > 0:
                    self.stop_event.wait(remaining)
        finally:
            self.shutdown()
        return self.exit_code

    def write_run_json(self, initial_pid: int | None, sidecar_pid: int | None) -> None:
        (self.out_dir / "run.json").write_text(
            json.dumps(
                {
                    "script_version": SCRIPT_VERSION,
                    "started_at": iso(time.time()),
                    "started_epoch": time.time(),
                    # Who is writing this directory, in the same terms the watch
                    # lock uses: a pid alone is reused, so the startup sweep of
                    # a later watch needs the start stamp to tell "still being
                    # written" from "the pid came round".
                    "watcher_pid": os.getpid(),
                    "watcher_start_abstime": process_identity(os.getpid())[1],
                    "target_pid": initial_pid,
                    "target_start_time": process_start_time(initial_pid) if initial_pid else None,
                    "log_stream_pid": sidecar_pid,
                    "log_stream_watchdog_pid": sidecar_pid,
                    "log_stream_child_pid": self.sidecar.stream_pid if self.sidecar else None,
                    # The ratio every cpu_pct in samples.jsonl was scaled by,
                    # and whether it was read or fallen back to. 1/1 with
                    # timebase_ok false is a run whose CPU numbers are wrong by
                    # the machine's real ratio.
                    "timebase_numer": self.libproc.timebase_numer,
                    "timebase_denom": self.libproc.timebase_denom,
                    "timebase_ok": self.libproc.timebase_ok,
                    "args": {
                        "interval": self.args.interval,
                        "threshold_mb": self.args.threshold_mb,
                        "rise_mb": self.args.rise_mb,
                        "rearm_mb": self.args.rearm_mb,
                        "baseline_window": self.args.baseline_window,
                        "vmmap": self.args.vmmap,
                        "no_sample": self.args.no_sample,
                        "no_log_stream": self.args.no_log_stream,
                        "pid_override": self.args.pid,
                        "keep_days": self.args.keep_days,
                        "out": str(self.out_dir),
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    def tick(self, now: float) -> None:
        if self.pid is None:
            found = self.resolve_pid()
            if found is None:
                return
            if not self.acquire(found, now):
                return

        assert self.pid is not None
        usage = self.libproc.rusage(self.pid)
        if usage is None:
            lost = self.pid
            self.lose(now)
            if self.args.pid is not None:
                # An explicit --pid names one process. The pid file can point at
                # a restarted daemon, so that path keeps looking; this one has
                # nothing left to look at, and going quiet would sample nothing
                # all night while reporting success at the end of it.
                print(
                    f"target pid {lost} is gone and --pid names no replacement; stopping",
                    file=sys.stderr,
                )
                self.exit_code = 3
                self.stop_event.set()
            return

        if identity_changed(self._target_start_abstime, int(usage.ri_proc_start_abstime)):
            # The pid still answers, but a different process holds it now: the
            # daemon died and something was started onto its number, or it
            # restarted onto its own. Sampling straight through that hands the
            # new process the dead one's baseline, in-spike state, previous peak
            # and CPU counters, and the record says nothing happened. So the
            # target is lost and re-acquired in this same tick, exactly as a
            # target that had gone away would have been, and the run's own
            # `target_lost` and `target_acquired` markers are what let `--report`
            # replay the change the way the live watch saw it.
            lost = self.pid
            self.lose(now)
            if self.args.pid is not None:
                # An explicit --pid names one process, and that process is gone
                # whatever is answering to its number now. Same ending as the
                # target dying outright, for the same reason.
                print(
                    f"target pid {lost} now belongs to a different process and --pid names "
                    "no replacement; stopping",
                    file=sys.stderr,
                )
                self.exit_code = 3
                self.stop_event.set()
                return
            found = self.resolve_pid()
            if found is None or not self.acquire(found, now):
                return
            usage = self.libproc.rusage(self.pid)
            if usage is None:
                self.lose(now)
                return

        # Reset immediately after the read, so the next tick's interval max is
        # exactly the peak reached between these two ticks.
        if not self.libproc.reset_footprint_interval(self.pid):
            self.note_reset_failure()

        # Scaled out of mach time units first: differencing the raw counters and
        # calling the result nanoseconds understates CPU by the timebase ratio.
        user_ns, system_ns = self.libproc.cpu_times_ns(usage)
        cpu_pct = None
        if self._prev_cpu is not None:
            prev_when, prev_user, prev_system = self._prev_cpu
            elapsed = now - prev_when
            if elapsed > 0:
                busy_ns = (user_ns - prev_user) + (system_ns - prev_system)
                cpu_pct = round(busy_ns / 1e9 / elapsed * 100, 2)
        self._prev_cpu = (now, user_ns, system_ns)

        footprint = int(usage.ri_phys_footprint)
        interval_max = int(usage.ri_interval_max_phys_footprint)
        self.emit(
            {
                "epoch": now,
                "ts": iso(now),
                "pid": self.pid,
                "phys_footprint": footprint,
                "interval_max_phys_footprint": interval_max,
                "lifetime_max_phys_footprint": int(usage.ri_lifetime_max_phys_footprint),
                "resident_size": int(usage.ri_resident_size),
                "user_time_ns": user_ns,
                "system_time_ns": system_ns,
                "pageins": int(usage.ri_pageins),
                "cpu_pct": cpu_pct,
            }
        )

        for request in self.detector.observe(now, footprint, interval_max):
            name = self.capture_runner.start(self.pid, request)
            if name is None:
                # The runner was busy with the previous capture. Hand the slot
                # back so the spike can spend it on the next tick that still
                # justifies one, rather than losing it to a capture that was
                # never taken.
                self.detector.withdraw(request)
            else:
                self.emit(
                    {
                        "event": "capture",
                        "dir": name,
                        "reason": request.reason,
                        "peak": request.peak,
                        "phys_footprint": request.footprint,
                        "interval_max_phys_footprint": request.interval_max,
                        "baseline": request.baseline,
                    }
                )

    def shutdown(self) -> None:
        self.emit({"event": "watch_stopped"})
        # An in-flight capture gets a bounded chance to finish; it is a child we
        # spawned and it holds nothing the target needs. That bound is the sum
        # of the enabled tools' timeouts, up to 125 s, which is long enough that
        # a silent wait reads as a hang: say what is being waited for, and take
        # a second Ctrl-C as permission to stop waiting.
        if self.capture_runner.busy():
            budget = self.capture_runner.worst_case_seconds()
            print(
                f"waiting up to {budget:.0f}s for an in-flight capture "
                "(Ctrl-C again to abandon it)"
            )
            deadline = time.time() + budget
            while (
                self.capture_runner.busy()
                and not self.abandon_event.is_set()
                and time.time() < deadline
            ):
                # Sliced, not one long join: a signal handler runs on the main
                # thread but a join resumes for its full remaining timeout
                # afterwards, so a second Ctrl-C would otherwise change nothing.
                self.capture_runner.join(timeout=0.25)
            if self.capture_runner.busy():
                abandoned = "signal" if self.abandon_event.is_set() else "timeout"
                print(f"abandoning the in-flight capture ({abandoned}); its directory is partial")
                self.emit({"event": "capture_abandoned", "why": abandoned})
        if self.sidecar is not None:
            self.sidecar.stop()
        # Last thing before the record closes: after this the target is free for
        # another watch, and nothing else will ever remove this file.
        self.release_lock()
        with self._emit_lock:
            if self._samples is not None:
                self._samples.close()
                self._samples = None
        print(f"\nstopped. run directory: {self.out_dir}")


# ----------------------------------------------------------------------------
# REPORT
# ----------------------------------------------------------------------------


@dataclass
class Spike:
    onset: float
    end: float
    peak: int
    peak_at: float
    reason: str = "unknown"
    captures: list[str] = field(default_factory=list)

    @property
    def duration(self) -> float:
        return self.end - self.onset


def load_run(run_dir: Path) -> tuple[list[dict], list[dict], dict]:
    """Split samples.jsonl into measurement rows and marker events."""
    samples: list[dict] = []
    events: list[dict] = []
    path = run_dir / "samples.jsonl"
    if path.exists():
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "event" in record:
                    events.append(record)
                elif "phys_footprint" in record:
                    samples.append(record)
    config = {}
    run_json = run_dir / "run.json"
    if run_json.exists():
        try:
            config = json.loads(run_json.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            config = {}
    return samples, events, config


def replay_actions(events: Sequence[dict]) -> list[tuple[float, str, float | None]]:
    """The markers a replay has to act on, in the order it reaches them.

    Three kinds, each as (when, kind, value):

    "acquire"   a `target_acquired` marker. Its value is the suppression
                instant from the `rise_suppressed` marker the live run wrote
                immediately after it for the same pid, or None. The two are
                paired here, in file order, rather than sorted together by
                epoch, because the suppression is stamped with the acquiring
                tick and the acquire marker with the same tick: sorting alone
                cannot say which of two markers at one instant came first, and
                pairing them makes the question moot.
    "lose"      a `target_lost` marker.
    "suppress"  a `rise_suppressed` marker with no acquire of its own to belong
                to. Applied to whichever detector is current, which is what the
                replay did with every suppression before acquires reset one.
    """
    consumed: set[int] = set()
    paired: dict[int, float] = {}
    for index, event in enumerate(events):
        if event.get("event") != "target_acquired":
            continue
        # The suppression this acquire wrote: same pid, before the next acquire
        # or loss, and not already claimed by an earlier acquire.
        for offset in range(index + 1, len(events)):
            following = events[offset]
            kind = following.get("event")
            if kind in ("target_acquired", "target_lost"):
                break
            if (
                kind == "rise_suppressed"
                and offset not in consumed
                and following.get("pid") == event.get("pid")
                and following.get("until") is not None
            ):
                consumed.add(offset)
                paired[index] = float(following["until"])
                break

    actions: list[tuple[float, str, float | None]] = []
    for index, event in enumerate(events):
        name = event.get("event")
        when = float(event.get("epoch", 0.0))
        if name == "target_acquired":
            actions.append((when, "acquire", paired.get(index)))
        elif name == "target_lost":
            actions.append((when, "lose", None))
        elif (
            name == "rise_suppressed"
            and event.get("until") is not None
            and index not in consumed
        ):
            actions.append((when, "suppress", float(event["until"])))
    # A stable sort, so two markers stamped with the same tick keep the order
    # the run wrote them in.
    actions.sort(key=lambda action: action[0])
    return actions


def find_spikes(
    samples: list[dict],
    detector: SpikeDetector,
    events: Sequence[dict] = (),
) -> list[Spike]:
    """Replay the live detector over recorded samples and bracket its spikes.

    The report used to re-test `value >= threshold` on its own, which could not
    see a rise-triggered spike at all and disagreed with the live run about
    where a spike ended. Driving the same pure detector makes the two agree by
    construction: a spike is the interval from the tick that put the detector
    into `in_spike` to the tick that took it out again, or to the last sample if
    the run ended mid-spike, and its reason is whichever rule fired at onset.

    `events` is the run's own markers, replayed in epoch order alongside the
    samples, and they are part of that same agreement. The live watch builds a
    fresh detector per target and tells it about a warmup suppression; a replay
    that drove one detector across a daemon restart handed the new process's
    first sample the dead one's baseline, in-spike state and previous peak. A
    new daemon coming up above the threshold then took no onset in the report
    while the live run had taken one, and the capture directory the live run
    wrote belonged to no spike at all.
    """
    pending = replay_actions(events)
    spikes: list[Spike] = []
    current: Spike | None = None

    def close(at: float) -> None:
        """End an open spike at `at`, because its target is going away."""
        nonlocal current
        if current is not None:
            current.end = max(current.end, at)
            spikes.append(current)
            current = None

    def apply(action: tuple[float, str, float | None]) -> None:
        nonlocal detector
        when, kind, value = action
        if kind == "suppress":
            detector.rise_suppressed_until = value
            return
        # Both a loss and an acquisition start a new process's history. The
        # spike belonged to the process that is gone, so it ends here rather
        # than being stretched across the gap to the next target's samples.
        close(when)
        detector = detector.fresh(rise_suppressed_until=value if kind == "acquire" else None)

    for sample in samples:
        when = sample.get("epoch", 0.0)
        while pending and pending[0][0] <= when:
            apply(pending.pop(0))
        footprint = int(sample.get("phys_footprint", 0))
        interval_max = int(sample.get("interval_max_phys_footprint", 0))
        value = max(footprint, interval_max)

        was_in_spike = detector.in_spike
        requests = detector.observe(when, footprint, interval_max)

        if not was_in_spike and detector.in_spike:
            reason = requests[0].reason if requests else "unknown"
            current = Spike(onset=when, end=when, peak=value, peak_at=when, reason=reason)
        elif current is not None:
            current.end = when
            if value > current.peak:
                current.peak = value
                current.peak_at = when
            if not detector.in_spike:
                spikes.append(current)
                current = None
    # A target lost after the last sample still ends the spike where the run
    # said it ended, rather than at the last tick that happened to be recorded.
    while pending:
        apply(pending.pop(0))
    if current is not None:
        spikes.append(current)
    return spikes


def attach_captures(spikes: list[Spike], events: list[dict], slack: float) -> None:
    for event in events:
        if event.get("event") != "capture":
            continue
        when = event.get("epoch", 0.0)
        for spike in spikes:
            if spike.onset - slack <= when <= spike.end + slack:
                spike.captures.append(f"{event.get('dir')} ({event.get('reason')})")
                break


def parse_log_epoch(line: str) -> float | None:
    match = LOG_TIMESTAMP_RE.match(line)
    if not match:
        return None
    try:
        return datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp()
    except ValueError:
        return None


def log_windows(
    path: Path, windows: list[tuple[str, float, float, bool]]
) -> dict[str, tuple[Counter, list[tuple[float, str]]]]:
    """Category counts and `rpc in-flight high` lines for every window at once.

    A window is (key, start, end, end_inclusive). The flag is what lets the
    report's two windows per spike partition the log instead of overlapping at
    one line: the 60 s before onset ends exclusively, the spike itself is
    inclusive at both ends, so the row logged exactly at onset is counted once.

    One pass over `daemon-log.txt`, bucketing each line into whichever of the
    requested windows contain it. A `log stream` sidecar left running overnight
    produces a large file, and the report wants two windows per spike: scanning
    it once per window meant rereading gigabytes to answer questions that one
    read already had the data for.

    Within that pass the windows are searched rather than swept. Testing every
    window against every line is lines times windows, and a night that produced
    forty spikes asks eighty questions of every one of millions of lines while
    almost all of them fall outside every window. So the windows are sorted by
    start, a line outside `[earliest start, latest end]` is dropped on two
    comparisons, and `bisect` narrows the rest to the windows that started at or
    before the line. Bucketing is unchanged, so the report reads identically:
    the per-window lists are appended in file order whatever order the windows
    are considered in.
    """
    results: dict[str, tuple[Counter, list[tuple[float, str]]]] = {
        key: (Counter(), []) for key, _, _, _ in windows
    }
    if not windows or not path.exists():
        return results
    ordered = sorted(windows, key=lambda item: item[1])
    starts = [start for _, start, _, _ in ordered]
    first_start = starts[0]
    last_end = max(end for _, _, end, _ in ordered)
    last_epoch: float | None = None
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            epoch = parse_log_epoch(line)
            if epoch is None:
                # Continuation of a multi-line message: it belongs to the line
                # above, so it inherits its timestamp rather than being dropped.
                epoch = last_epoch
            else:
                last_epoch = epoch
            if epoch is None:
                continue
            if epoch < first_start or epoch > last_end:
                continue
            # Windows starting after this line cannot contain it; of the rest,
            # only those still open at `epoch` do.
            reachable = bisect.bisect_right(starts, epoch)
            matched = [
                key
                for key, _, end, inclusive in ordered[:reachable]
                if (epoch <= end if inclusive else epoch < end)
            ]
            if not matched:
                continue
            # Both regexes run at most once per line, however many windows the
            # line lands in.
            found = LOG_CATEGORY_RE.search(line)
            category = f"{found.group(1)}:{found.group(2)}" if found else None
            inflight_line = line.rstrip() if RPC_INFLIGHT_RE.search(line) else None
            for key in matched:
                counts, inflight = results[key]
                if category is not None:
                    counts[category] += 1
                if inflight_line is not None:
                    inflight.append((epoch, inflight_line))
    return results


def median_interval(samples: list[dict], fallback: float = 1.0) -> float:
    deltas = [
        b.get("epoch", 0.0) - a.get("epoch", 0.0)
        for a, b in zip(samples, samples[1:])
        if b.get("epoch", 0.0) > a.get("epoch", 0.0)
    ]
    if not deltas:
        return fallback
    deltas.sort()
    return deltas[len(deltas) // 2]


def report(
    run_dir: Path,
    threshold_override_mb: float | None = None,
    rise_override_mb: float | None = None,
    rearm_override_mb: float | None = None,
    baseline_window_override: float | None = None,
    out=sys.stdout,
) -> int:
    samples, events, config = load_run(run_dir)
    if not samples:
        print(f"no samples in {run_dir / 'samples.jsonl'}", file=out)
        return 1

    run_args = config.get("args") or {}

    def setting(name: str, override: float | None, fallback: float) -> tuple[float, str]:
        """One replay setting, and where it came from.

        A replay whose rules are not the run's own rules answers a different
        question than the run did, so every one of the four says which it is.
        Overriding all four is legitimate: re-reading last night's samples with
        a tighter rise is exactly what the recorded stream is for.
        """
        if override is not None:
            return float(override), "override"
        configured = run_args.get(name)
        if configured is not None:
            return float(configured), "run.json"
        return float(fallback), "built-in default"

    threshold_mb, source = setting("threshold_mb", threshold_override_mb, DEFAULT_THRESHOLD_MB)
    rise_mb, rise_source = setting("rise_mb", rise_override_mb, DEFAULT_RISE_MB)
    rearm_mb, rearm_source = setting("rearm_mb", rearm_override_mb, DEFAULT_REARM_MB)
    baseline_window, baseline_source = setting(
        "baseline_window", baseline_window_override, DEFAULT_BASELINE_WINDOW
    )

    first, last = samples[0], samples[-1]
    span = last.get("epoch", 0.0) - first.get("epoch", 0.0)
    lifetime = max(s.get("lifetime_max_phys_footprint", 0) for s in samples)
    highest = max(
        max(s.get("phys_footprint", 0), s.get("interval_max_phys_footprint", 0)) for s in samples
    )

    print(f"run directory   {run_dir}", file=out)
    print(f"samples         {len(samples)}", file=out)
    print(
        f"span            {iso(first['epoch'])}  ->  {iso(last['epoch'])}  ({span:.1f} s)", file=out
    )
    print(f"threshold       {threshold_mb:g} MB (from {source})", file=out)
    print(f"rise            {rise_mb:g} MB (from {rise_source})", file=out)
    print(f"rearm           {rearm_mb:g} MB (from {rearm_source})", file=out)
    print(f"baseline window {baseline_window:g} s (from {baseline_source})", file=out)
    print(f"highest sample  {fmt_bytes(highest)}", file=out)
    print(f"lifetime peak   {fmt_bytes(lifetime)}", file=out)
    print(file=out)

    markers = [
        e
        for e in events
        if e.get("event")
        in (
            "target_acquired",
            "target_lost",
            "interval_reset_failed",
            "target_comm",
            "pid_file_mismatch",
            "timebase_fallback",
            "rise_suppressed",
            "target_age_unknown",
            "watch_conflict",
            "watch_unlocked",
        )
    ]
    if markers:
        print(f"MARKERS ({len(markers)})", file=out)
        for event in markers:
            # Assembled from whichever fields the marker carries, because not
            # every marker is about a pid: timebase_fallback is about the run.
            bits = []
            if event.get("pid") is not None:
                bits.append(f"pid {event['pid']}")
            if event.get("comm"):
                bits.append(f"comm {event['comm']}")
            if event.get("start_time"):
                bits.append(f"started {event['start_time']}")
            if event.get("target_age_s") is not None:
                bits.append(f"age {event['target_age_s']:.1f} s")
            if event.get("until_iso"):
                bits.append(f"until {event['until_iso']}")
            if event.get("holder_pid") is not None:
                bits.append(f"held by pid {event['holder_pid']}")
            if event.get("note"):
                bits.append(str(event["note"]))
            detail = "  ".join(bits)
            print(f"  {hhmmss(event.get('epoch', 0.0)):<14}{event['event']:<24}{detail}", file=out)
        print(file=out)

    failures = [e for e in events if str(e.get("event", "")).startswith("capture_")]
    if failures:
        print(f"CAPTURE PROBLEMS ({len(failures)})", file=out)
        for event in failures:
            bits = []
            if event.get("tool"):
                bits.append(str(event["tool"]))
            if event.get("rc") is not None:
                bits.append(f"rc={event['rc']}")
            detail = event.get("error") or event.get("why") or ""
            if detail:
                bits.append(str(detail))
            print(
                f"  {hhmmss(event.get('epoch', 0.0)):<14}{event['event']:<22}"
                f"{'  '.join(bits)}",
                file=out,
            )
        print(file=out)

    detector = SpikeDetector(
        threshold_bytes=int(threshold_mb * MB),
        rise_bytes=int(rise_mb * MB),
        rearm_bytes=int(rearm_mb * MB),
        baseline_window=baseline_window,
    )
    spikes = find_spikes(samples, detector, events)
    attach_captures(spikes, events, slack=max(median_interval(samples), 1.0) * 2)
    rules = (
        f"threshold {threshold_mb:g} MB, rise {rise_mb:g} MB over a "
        f"{baseline_window:g} s baseline"
    )
    if not spikes:
        print(f"no spike in this run under the run's own rules ({rules}).", file=out)
        return 0

    log_path = run_dir / "daemon-log.txt"
    print(f"SPIKES ({len(spikes)}), detector replayed with {rules}", file=out)

    # Every window the log is asked about, resolved in one pass over the file.
    windows: list[tuple[str, float, float, bool]] = []
    for index, spike in enumerate(spikes, start=1):
        # End-exclusive before, inclusive during: the two partition the log, so
        # the row logged at the onset instant belongs to the spike and is not
        # also counted as part of what led up to it.
        windows.append((f"{index}:before", spike.onset - 60, spike.onset, False))
        windows.append((f"{index}:during", spike.onset, spike.end, True))
    scanned = log_windows(log_path, windows)

    for index, spike in enumerate(spikes, start=1):
        print(file=out)
        print(
            f"spike {index}  onset {hhmmss(spike.onset)}  reason {spike.reason}  "
            f"peak {fmt_bytes(spike.peak)} "
            f"at {hhmmss(spike.peak_at)}  end {hhmmss(spike.end)}  "
            f"duration {spike.duration:.1f} s",
            file=out,
        )
        if spike.captures:
            for name in spike.captures:
                print(f"    capture   {name}", file=out)
        else:
            print("    capture   (none)", file=out)

        if not log_path.exists():
            continue
        for label, key in (
            ("60 s before onset", f"{index}:before"),
            ("during spike", f"{index}:during"),
        ):
            counts, inflight = scanned[key]
            print(f"    log, {label}:", file=out)
            if not counts:
                print("        (no com.tbd rows in this window)", file=out)
            for category, count in counts.most_common(10):
                print(f"        {count:>7}  {category}", file=out)
            if inflight:
                print(f"        rpc in-flight high lines: {len(inflight)}", file=out)
                for when, line in inflight[:5]:
                    print(f"          {hhmmss(when)}  {line[-100:]}", file=out)
    return 0


# ----------------------------------------------------------------------------
# SELF TEST
# ----------------------------------------------------------------------------


def _mb(value: float) -> int:
    return int(value * MB)


def _detector(
    threshold_mb: float,
    rise_mb: float,
    rearm_mb: float = 512,
    baseline_window: float = DEFAULT_BASELINE_WINDOW,
    rise_suppressed_until: float | None = None,
) -> SpikeDetector:
    """A detector for one case. A zero threshold or rise disables that rule.

    Disabling the rise rule is spelled 0, never a huge out-of-reach number: the
    rise participates in the release rules as well as the onset ones, so a rise
    of a million megabytes does not mean "never rises", it means "always back at
    its baseline", which releases every spike on the tick after it opens.
    """
    return SpikeDetector(
        threshold_bytes=_mb(threshold_mb),
        rise_bytes=_mb(rise_mb),
        rearm_bytes=_mb(rearm_mb),
        baseline_window=baseline_window,
        rise_suppressed_until=rise_suppressed_until,
    )


def _drive(detector: SpikeDetector, series, start: float = 1000.0) -> list[CaptureRequest]:
    """Feed (footprint_mb, interval_max_mb) pairs one second apart."""
    captured: list[CaptureRequest] = []
    for step, item in enumerate(series):
        footprint_mb, interval_mb = item if isinstance(item, tuple) else (item, item)
        captured.extend(detector.observe(start + step, _mb(footprint_mb), _mb(interval_mb)))
    return captured


def _check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


class _Skipped(Exception):
    """Raised by a leg that cannot run here, so it prints `skip` rather than `ok`.

    One leg exercises the ctypes glue against the real libproc, which exists
    only on macOS. Reporting that as a pass on Linux would mean CI printing `ok`
    for a check it never ran; reporting it as a failure would redden a suite
    that is otherwise deliberately platform independent.
    """


def _synthetic_log_line(epoch: float, category: str) -> str:
    """One `log stream --style compact` row, shaped so the report can parse it."""
    stamp = datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    return f"{stamp} Db TBDDaemon[4242] [com.tbd.daemon:{category}] hello\n"


def _write_synthetic_run(
    run_dir: Path,
    base: float,
    series: Sequence[float],
    run_args: dict,
    captures: list[tuple[float, str, str]],
    markers: Sequence[dict] = (),
) -> None:
    """Write a `samples.jsonl` and `run.json` shaped exactly like a real run."""
    lines = []
    for step, value in enumerate(series):
        lines.append(
            json.dumps(
                {
                    "epoch": base + step,
                    "ts": iso(base + step),
                    "pid": 4242,
                    "phys_footprint": _mb(value),
                    "interval_max_phys_footprint": _mb(value),
                    "lifetime_max_phys_footprint": _mb(max(series)),
                    "resident_size": _mb(60),
                    "user_time_ns": 0,
                    "system_time_ns": 0,
                    "pageins": 0,
                    "cpu_pct": 0.0,
                }
            )
        )
    for when, name, reason in captures:
        lines.append(
            json.dumps(
                {
                    "event": "capture",
                    "epoch": when,
                    "ts": iso(when),
                    "dir": name,
                    "reason": reason,
                }
            )
        )
    for marker in markers:
        lines.append(json.dumps(marker))
    (run_dir / "samples.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (run_dir / "run.json").write_text(json.dumps({"args": run_args}), encoding="utf-8")


def _seed_swept_run(
    root: Path,
    name: str,
    now: float,
    age_days: float,
    watcher: tuple[int, int | None] | None = None,
    run_json: bool = True,
) -> Path:
    """A run directory of a chosen age, optionally naming the watcher that owns it.

    Every entry and the directory itself are stamped, the directory last,
    because writing a file into it bumps its own mtime back to the present.
    """
    run_dir = root / name
    run_dir.mkdir(parents=True)
    (run_dir / "samples.jsonl").write_text("{}\n", encoding="utf-8")
    entries = [run_dir / "samples.jsonl"]
    if run_json:
        payload: dict = {"script_version": SCRIPT_VERSION}
        if watcher is not None:
            payload["watcher_pid"] = watcher[0]
            payload["watcher_start_abstime"] = watcher[1]
        (run_dir / "run.json").write_text(json.dumps(payload), encoding="utf-8")
        entries.append(run_dir / "run.json")
    stamp = now - age_days * SECONDS_PER_DAY
    for entry in entries + [run_dir]:
        os.utime(str(entry), (stamp, stamp))
    return run_dir


def _lock_text(pid: int, start: int | None) -> str:
    return json.dumps({"pid": pid, "start_abstime": start}) + "\n"


def self_test() -> int:
    """Drive the detector and the report over synthetic series, no daemon needed."""
    failures: list[str] = []

    def case(name: str, body) -> None:
        try:
            body()
            print(f"ok    {name}")
        except _Skipped as exc:
            print(f"skip  {name}: {exc}")
        except AssertionError as exc:
            failures.append(f"{name}: {exc}")
            print(f"FAIL  {name}: {exc}")

    def balloon() -> None:
        # The rise rule is switched off, so this case exercises the absolute
        # threshold rule alone; the rise rule has its own case.
        detector = _detector(threshold_mb=1024, rise_mb=0, rearm_mb=512)
        events = _drive(detector, [100, 100, 100, 1100, 1200, 1700, 2400, 1500, 1000, 700, 1100])
        reasons = [event.reason for event in events]
        _check(
            reasons == ["threshold", "highwater", "threshold"],
            f"expected onset, high-water, re-armed onset; got {reasons}",
        )
        _check(events[0].peak == _mb(1100), "onset should capture at the first crossing")
        _check(
            events[1].peak == _mb(1700),
            "high-water capture should wait for a rearm-mb rise above the last capture",
        )

    def subtick_spike() -> None:
        # Every current footprint stays far below the threshold; only the
        # interval max ever sees the balloon.
        detector = _detector(threshold_mb=1024, rise_mb=0, rearm_mb=512)
        events = _drive(detector, [(100, 100), (100, 100), (100, 2000), (100, 100), (100, 100)])
        _check(len(events) == 1, f"expected exactly one capture, got {len(events)}")
        _check(events[0].reason == "threshold", f"unexpected reason {events[0].reason}")
        _check(events[0].footprint == _mb(100), "the tick's own footprint should be recorded as-is")
        _check(events[0].interval_max == _mb(2000), "the interval max should be what tripped it")
        _check(not detector.in_spike, "the spike should have been released once the peak fell away")

    def rise_trigger() -> None:
        # Threshold deliberately above the peak: only the baseline rise can fire.
        detector = _detector(threshold_mb=4096, rise_mb=512, rearm_mb=512)
        events = _drive(detector, [100, 100, 100, 700, 100, 100])
        _check(len(events) == 1, f"expected exactly one capture, got {len(events)}")
        _check(events[0].reason == "rise", f"unexpected reason {events[0].reason}")
        _check(events[0].baseline == _mb(100), "baseline should be the window minimum")
        _check(not detector.in_spike, "a rise spike should release once it falls back")

    def high_trough_rearms() -> None:
        # The incident shape: a daemon idling at 990 MB against a 1024 MB
        # threshold. RELEASE_FRACTION alone can never fire here (0.75 * 1024 is
        # 768, and the trough never goes there), so under that rule alone the
        # detector would enter the first spike and stay in it for good, and the
        # 6, 7 and 8 GB spikes that follow would capture nothing.
        detector = _detector(threshold_mb=1024, rise_mb=512, rearm_mb=512)
        events = _drive(
            detector, [900, 900, 900, 5000, 900, 6000, 900, 7000, 900, 8000, 900]
        )
        reasons = [event.reason for event in events]
        _check(
            reasons == ["threshold"] * 4,
            f"expected four re-armed onset captures, got {reasons}",
        )
        _check(not detector.in_spike, "the last spike should have released at the trough")

    def sustained_plateau_does_not_refire() -> None:
        # A plateau held for longer than the baseline window drags the rolling
        # minimum up to meet it, so the rise-based release rule fires and the
        # spike ends. Nothing re-fires afterwards: the threshold onset is edge
        # triggered and the peak never leaves the plateau again. The old design
        # kept this open as one unending spike instead, which is what let a daemon
        # sitting above the threshold latch the detector for the whole night.
        detector = _detector(threshold_mb=1024, rise_mb=512, rearm_mb=512)
        ticks = int(DEFAULT_BASELINE_WINDOW) + 100
        events = _drive(detector, [100, 100, 100] + [5000] * ticks)
        reasons = [event.reason for event in events]
        _check(
            len(events) <= MAX_CAPTURES_PER_SPIKE,
            f"a plateau must not capture more than the per-spike cap; got {reasons}",
        )
        _check(
            reasons == ["threshold"],
            f"a flat plateau earns the onset capture and nothing else; got {reasons}",
        )
        # Expectation re-derived for the edge-triggered rules: the plateau is no
        # longer held open as a spike, because a level held for a whole baseline
        # window is the new normal rather than an ongoing event.
        _check(
            not detector.in_spike,
            "a plateau should release once its own baseline catches up with it",
        )

    def high_baseline_rise_releases() -> None:
        # A rise-triggered spike whose baseline is more than three times the
        # rise: 0.75 * (2000 + 512) is 1884, below the trough, so only the
        # rise-based release rule can end it.
        detector = _detector(threshold_mb=4096, rise_mb=512, rearm_mb=512)
        events = _drive(detector, [2000, 2000, 2000, 2600, 2000, 2000])
        _check(len(events) == 1, f"expected exactly one capture, got {len(events)}")
        _check(events[0].reason == "rise", f"unexpected reason {events[0].reason}")
        _check(not detector.in_spike, "the spike should release back at the trough")

    def steady_state_above_threshold() -> None:
        # The shape that latched the old detector: a daemon idling at 1100 MB
        # against the 1024 MB default. Level-triggered, the threshold fired at
        # t0 and never released, so every real excursion afterwards was already
        # "in spike" and captured nothing. Edge-triggered, t0 earns the one
        # capture that starting a watch mid-spike deserves, the plateau earns
        # nothing more, and each 8 GB excursion is caught by the rise rule
        # against the 1100 MB baseline.
        detector = _detector(threshold_mb=1024, rise_mb=512, rearm_mb=512, baseline_window=10_000)
        series = (
            [1100] * 5 + [8000] + [1100] * 20 + [8000] + [1100] * 20 + [8000] + [1100] * 5
        )
        events = _drive(detector, series)
        reasons = [event.reason for event in events]
        _check(
            reasons == ["threshold", "rise", "rise", "rise"],
            f"expected one onset at t0 and one rise per excursion; got {reasons}",
        )
        _check(
            events[0].when == 1000.0,
            f"the threshold capture should be the first tick, got {events[0].when}",
        )
        _check(
            [event.peak for event in events[1:]] == [_mb(8000)] * 3,
            "each rise capture should be taken at the excursion's peak",
        )
        _check(not detector.in_spike, "the run should end back at its idle plateau, not in a spike")

    def plateau_then_further_climb() -> None:
        # A daemon already over the threshold when the watch starts, holding
        # 5 GB for longer than the baseline window, then stepping to 8 GB. The
        # old rules held the whole plateau open as one spike and so could never
        # see the step; the new ones close the plateau once the baseline catches
        # up and the step is a rise above that plateau baseline.
        detector = _detector(threshold_mb=1024, rise_mb=512, rearm_mb=512)
        plateau = int(DEFAULT_BASELINE_WINDOW) + 50
        events = _drive(detector, [5000] * plateau + [8000] * 3)
        reasons = [event.reason for event in events]
        _check(
            reasons == ["threshold", "rise"],
            f"expected the t0 onset and one rise at the step; got {reasons}",
        )
        _check(
            events[0].when == 1000.0 and events[0].peak == _mb(5000),
            "the onset capture belongs to the first tick of the plateau",
        )
        _check(
            events[1].when == 1000.0 + plateau,
            f"the rise capture belongs to the step, got {events[1].when}",
        )
        _check(
            events[1].baseline == _mb(5000),
            f"the step should be measured against the plateau, got {events[1].baseline}",
        )
        _check(detector.in_spike, "the step off the plateau is still in progress at the end")

    def withdrawn_capture_is_reissued() -> None:
        # The runner takes one capture at a time. When it refuses, the slot has
        # to go back: a spike gets two, and a spike whose second one is refused
        # while the first is still running would otherwise never sample its own
        # peak.
        detector = _detector(threshold_mb=1024, rise_mb=0, rearm_mb=512)
        onset = _drive(detector, [100, 100, 1100])
        _check([event.reason for event in onset] == ["threshold"], "expected the onset capture")

        refused = detector.observe(1003.0, _mb(1700), _mb(1700))
        _check(
            [event.reason for event in refused] == ["highwater"],
            f"expected a high-water capture at 1700 MB; got {refused}",
        )
        detector.withdraw(refused[0])

        again = detector.observe(1004.0, _mb(1700), _mb(1700))
        _check(
            [event.reason for event in again] == ["highwater"],
            "a withdrawn high-water should be re-issued at the same peak",
        )
        _check(again[0].peak == _mb(1700), "the re-issued capture should carry the same peak")
        _check(detector.in_spike, "withdrawing a capture must not end the spike")

    def withdrawn_onset_is_reissued() -> None:
        # A refused onset used to leave the rearm bar parked at the peak it was
        # refused at, because only a high-water gave `_last_capture_value` back.
        # A spike that opens at 1500 MB and holds there then took no captures at
        # all: the onset was refused, the bar said 1500 MB, and no tick could
        # clear 1500 plus a rearm for as long as the spike lasted.
        detector = _detector(threshold_mb=1024, rise_mb=0, rearm_mb=512)
        onset = _drive(detector, [100, 100, 1500])
        _check([event.reason for event in onset] == ["threshold"], "expected the onset capture")
        detector.withdraw(onset[0])
        _check(detector.in_spike, "withdrawing an onset must not end the spike")

        again = detector.observe(1003.0, _mb(1500), _mb(1500))
        _check(
            [event.reason for event in again] == ["highwater"],
            f"a refused onset should re-issue on the next tick at the same peak; got {again}",
        )
        _check(again[0].peak == _mb(1500), "the re-issued capture should carry the same peak")
        _check(detector.in_spike, "the spike is still open after the re-issued capture")

    def warmup_rise_is_suppressed() -> None:
        # A daemon that has just restarted climbs from nothing to its working
        # set. Against a floor of 20 MB that climb is a 630 MB rise, so a fresh
        # detector fires on it, and then holds the spike open for a whole
        # baseline window with every real spike folded into it.
        detector = _detector(
            threshold_mb=4096, rise_mb=512, rearm_mb=512, rise_suppressed_until=2000.0
        )
        events = _drive(detector, [20, 80, 200, 400, 650])
        _check(
            not events,
            f"a warmup climb under suppression should capture nothing; got {events}",
        )
        _check(not detector.in_spike, "suppression should leave the detector out of a spike")

    def warmup_rise_fires_once_suppression_expires() -> None:
        # The same series against a suppression instant already in the past.
        # Suppression must be a window, not an off switch: a daemon that has
        # been up for hours is acquired unsuppressed and a rise in the first
        # minutes of the watch is still caught.
        detector = _detector(
            threshold_mb=4096, rise_mb=512, rearm_mb=512, rise_suppressed_until=999.0
        )
        events = _drive(detector, [20, 80, 200, 400, 650])
        reasons = [event.reason for event in events]
        _check(reasons == ["rise"], f"expected exactly one rise capture; got {reasons}")
        _check(
            events[0].baseline == _mb(20),
            f"the rise is measured against the warmup floor; got {events[0].baseline}",
        )

    def threshold_fires_during_suppression() -> None:
        # Suppression holds off the rise rule alone. A young daemon crossing an
        # absolute gigabyte is a real event whatever its age, and suppressing
        # that too would blind the watch during exactly the window a restarted
        # daemon is most likely to misbehave in.
        detector = _detector(
            threshold_mb=1024, rise_mb=512, rearm_mb=512, rise_suppressed_until=2000.0
        )
        events = _drive(detector, [20, 80, 2000])
        reasons = [event.reason for event in events]
        _check(
            reasons == ["threshold"],
            f"the threshold rule must survive suppression; got {reasons}",
        )
        _check(events[0].peak == _mb(2000), "the capture belongs to the crossing tick")

    def log_windows_partition() -> None:
        # The two windows the report asks about per spike have to partition the
        # log. With both ends inclusive the row logged exactly at onset landed
        # in the before window and the during window, and every report counted
        # it twice, in the one place a reader is looking hardest for the row
        # that explains the onset.
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "daemon-log.txt"
            onset = 1_700_000_100.0
            path.write_text(
                _synthetic_log_line(onset - 5, "early")
                + _synthetic_log_line(onset, "boundary")
                + _synthetic_log_line(onset + 5, "inside"),
                encoding="utf-8",
            )
            scanned = log_windows(
                path,
                [
                    ("1:before", onset - 60, onset, False),
                    ("1:during", onset, onset + 10, True),
                ],
            )
            before, _ = scanned["1:before"]
            during, _ = scanned["1:during"]
            _check(
                before["com.tbd.daemon:early"] == 1,
                f"the earlier row belongs to the before window; got {before}",
            )
            _check(
                before["com.tbd.daemon:boundary"] == 0,
                f"the onset row must not also be counted before onset; got {before}",
            )
            _check(
                during["com.tbd.daemon:boundary"] == 1,
                f"the onset row belongs to the spike; got {during}",
            )
            _check(
                during["com.tbd.daemon:inside"] == 1,
                f"a row inside the spike should be counted once; got {during}",
            )

    def report_honours_recorded_suppression() -> None:
        # The warmup series again, this time through the report. A replay that
        # ignores the run's own `rise_suppressed` marker prints the spike the
        # live detector was told to ignore, so the operator reading the run at
        # 3am sees a spike that was never captured and never happened.
        with tempfile.TemporaryDirectory() as raw:
            run_dir = Path(raw)
            base = 1_700_000_000.0
            series = [20, 80, 200, 400, 650, 650]
            run_args = {
                "threshold_mb": 4096,
                "rise_mb": 100,
                "rearm_mb": 512,
                "baseline_window": DEFAULT_BASELINE_WINDOW,
            }
            # Written as the live watch writes them: the acquire first, then the
            # suppression it decided on, both stamped with the acquiring tick.
            # The replay has to pair the two, because the acquire resets the
            # detector and a suppression applied to the detector it replaced is
            # no suppression at all.
            acquired = {
                "event": "target_acquired",
                "epoch": base,
                "ts": iso(base),
                "pid": 4242,
                "target_age_s": 0.1,
            }
            marker = {
                "event": "rise_suppressed",
                "epoch": base,
                "ts": iso(base),
                "pid": 4242,
                "until": base + DEFAULT_BASELINE_WINDOW,
                "until_iso": iso(base + DEFAULT_BASELINE_WINDOW),
                "target_age_s": 0.1,
            }

            _write_synthetic_run(run_dir, base, series, run_args, [], [acquired, marker])
            buffer = io.StringIO()
            _check(report(run_dir, None, out=buffer) == 0, "report should succeed")
            text = buffer.getvalue()
            _check(
                "no spike in this run" in text,
                f"a suppressed warmup must not be reported as a spike; got:\n{text}",
            )

            _write_synthetic_run(run_dir, base, series, run_args, [])
            buffer = io.StringIO()
            _check(report(run_dir, None, out=buffer) == 0, "report should succeed")
            control = buffer.getvalue()
            _check(
                "SPIKES (1)" in control and "reason rise" in control,
                "without the marker the same series is a rise spike, which is what "
                f"makes the case above discriminate; got:\n{control}",
            )

    def report_resets_across_a_target_change() -> None:
        # A daemon restart mid-run. The live watch built a fresh detector for
        # process B; a replay that drove one detector across both handed B's
        # first sample A's history, and the edge-triggered threshold saw no
        # crossing because A's previous peak was already above it. B's spike
        # went unreported and the capture the live run took under it belonged
        # to no spike at all.
        with tempfile.TemporaryDirectory() as raw:
            run_dir = Path(raw)
            base = 1_700_000_000.0
            gap = 60.0
            first_pid, second_pid = 4242, 5150

            def sample_line(epoch: float, pid: int, mb: float) -> str:
                return json.dumps(
                    {
                        "epoch": epoch,
                        "ts": iso(epoch),
                        "pid": pid,
                        "phys_footprint": _mb(mb),
                        "interval_max_phys_footprint": _mb(mb),
                        "lifetime_max_phys_footprint": _mb(mb),
                        "resident_size": _mb(60),
                        "user_time_ns": 0,
                        "system_time_ns": 0,
                        "pageins": 0,
                        "cpu_pct": 0.0,
                    }
                )

            def marker_line(epoch: float, **fields) -> str:
                return json.dumps(dict(epoch=epoch, ts=iso(epoch), **fields))

            lines = [marker_line(base, event="target_acquired", pid=first_pid, target_age_s=9000.0)]
            lines += [sample_line(base + step, first_pid, 6000) for step in range(5)]
            lost_at = base + 5
            lines.append(marker_line(lost_at, event="target_lost", pid=first_pid))
            acquired_at = lost_at + gap
            lines.append(
                marker_line(
                    acquired_at, event="target_acquired", pid=second_pid, target_age_s=9000.0
                )
            )
            lines += [sample_line(acquired_at + step, second_pid, 2000) for step in range(5)]
            capture_at = acquired_at + 1
            lines.append(
                marker_line(capture_at, event="capture", dir="20260903-b", reason="threshold")
            )
            (run_dir / "samples.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
            run_args = {
                "threshold_mb": 1024,
                "rise_mb": 512,
                "rearm_mb": 512,
                "baseline_window": DEFAULT_BASELINE_WINDOW,
            }
            (run_dir / "run.json").write_text(json.dumps({"args": run_args}), encoding="utf-8")

            samples, events, _ = load_run(run_dir)
            spikes = find_spikes(
                samples, _detector(threshold_mb=1024, rise_mb=512, rearm_mb=512), events
            )
            _check(len(spikes) == 2, f"expected one spike per target, got {len(spikes)}")
            _check(
                spikes[0].onset == base and spikes[0].peak == _mb(6000),
                f"the first spike belongs to the first target; got {spikes[0]}",
            )
            _check(
                spikes[1].onset == acquired_at and spikes[1].peak == _mb(2000),
                f"the second target should earn an onset of its own; got {spikes[1]}",
            )
            _check(
                spikes[0].end <= lost_at,
                f"a lost target closes its spike at that instant; got {spikes[0].end}",
            )

            attach_captures(spikes, events, slack=max(median_interval(samples), 1.0) * 2)
            _check(
                spikes[1].captures == ["20260903-b (threshold)"],
                f"the capture belongs to the second target's spike; got {spikes[1].captures}",
            )
            _check(
                spikes[0].captures == [],
                f"nothing was captured under the first target; got {spikes[0].captures}",
            )

            buffer = io.StringIO()
            _check(report(run_dir, None, out=buffer) == 0, "report should succeed")
            text = buffer.getvalue()
            _check("SPIKES (2)" in text, f"the report should print both spikes; got:\n{text}")

    def busy_runner_notes_one_refusal_per_episode() -> None:
        # A refused capture is re-issued on the next tick, so a `sample` that
        # runs for a minute is refused once a second. One marker per busy
        # episode, not one per tick: the re-issue is what gets the capture taken
        # as soon as the runner is free and must not be paid for in noise.
        # Driven with a plain thread rather than a real capture, because a real
        # one shells out to macOS-only tools.
        with tempfile.TemporaryDirectory() as raw:
            emitted: list[dict] = []
            runner = CaptureRunner(Path(raw), emitted.append, want_sample=False)
            request = CaptureRequest(
                when=1000.0,
                reason="highwater",
                footprint=_mb(1500),
                interval_max=_mb(1500),
                peak=_mb(1500),
                baseline=_mb(100),
            )

            def episode() -> None:
                release = threading.Event()
                blocked = threading.Thread(target=release.wait, daemon=True)
                # Stands in for the capture thread `start` would have created.
                runner._thread = blocked
                blocked.start()
                for _ in range(5):
                    _check(runner.start(4242, request) is None, "a busy runner must refuse")
                release.set()
                blocked.join(5)
                _check(not blocked.is_alive(), "the stand-in capture should have finished")

            episode()
            skipped = [event for event in emitted if event.get("event") == "capture_skipped"]
            _check(
                len(skipped) == 1,
                f"five refusals in one busy episode are one marker; got {len(skipped)}",
            )
            _check(
                skipped[0].get("reason") == "highwater",
                f"the marker should name the refused capture; got {skipped[0]}",
            )

            # The runner is observed idle, which ends the episode, and the next
            # one is announced again rather than being swallowed as a repeat.
            _check(not runner.busy(), "the runner should be idle between episodes")
            episode()
            skipped = [event for event in emitted if event.get("event") == "capture_skipped"]
            _check(
                len(skipped) == 2,
                f"a second busy episode earns a second marker; got {len(skipped)}",
            )

    def lock_status_is_unambiguous() -> None:
        # `take_lock` used to answer None for "acquired" and None again for
        # "gave up after two attempts", and the caller read both as success: a
        # watch could believe it held a lock it had never created. Driven
        # against `Watch.take_lock` with a stand-in for `self`, because building
        # a Watch binds libproc and this test has to run where there is none.
        class Standin:
            def __init__(self) -> None:
                self._lock_path = None

        previous_home = os.environ.get("TBD_HOME")
        with tempfile.TemporaryDirectory() as raw:
            os.environ["TBD_HOME"] = raw
            try:
                target = 4242
                path = watch_lock_path(target)

                first = Standin()
                _check(
                    Watch.take_lock(first, target) == ("acquired", None),
                    "an unheld lock should be acquired",
                )
                _check(first._lock_path == path, "an acquired lock should be remembered")

                # A live holder that is not us. The parent process is both.
                path.write_text(f"{os.getppid()}\n", encoding="utf-8")
                _check(
                    Watch.take_lock(Standin(), target) == ("conflict", os.getppid()),
                    "a live holder is a conflict, and is named",
                )

                dead = next(
                    (pid for pid in range(99_990, 99_000, -1) if not holder_is_alive(pid)), None
                )
                _check(dead is not None, "the machine has no free pid to stand in for a dead one")
                path.write_text(f"{dead}\n", encoding="utf-8")
                second = Standin()
                _check(
                    Watch.take_lock(second, target) == ("acquired", None),
                    "a dead holder's lock is stale and is retaken",
                )
                _check(read_lock(path)[0] == os.getpid(), "the retaken lock should name us")

                # Somebody recreating the file as fast as it is reclaimed. Both
                # attempts reach a holder that reads as dead, both unlinks
                # succeed, and the file is still not ours at the end of it.
                real_open = os.open

                def contested(target_path, flags, *rest):
                    if str(target_path) == str(path):
                        handle = real_open(
                            str(path), os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644
                        )
                        os.write(handle, f"{dead}\n".encode("utf-8"))
                        os.close(handle)
                        raise FileExistsError(str(path))
                    return real_open(target_path, flags, *rest)

                path.unlink()
                third = Standin()
                os.open = contested
                try:
                    exhausted = Watch.take_lock(third, target)
                finally:
                    os.open = real_open
                _check(
                    exhausted == ("conflict", None),
                    f"an exhausted retry is a conflict, never success; got {exhausted}",
                )
                _check(
                    third._lock_path is None,
                    "a lock that was never created must not be remembered as ours",
                )

                unwritable = Path(raw) / "not-a-directory"
                unwritable.write_text("", encoding="utf-8")
                os.environ["TBD_HOME"] = str(unwritable / "tbd")
                _check(
                    Watch.take_lock(Standin(), target) == ("unlocked", None),
                    "a lock directory that cannot exist leaves the watch unlocked",
                )
            finally:
                if previous_home is None:
                    os.environ.pop("TBD_HOME", None)
                else:
                    os.environ["TBD_HOME"] = previous_home

    def a_reused_holder_pid_does_not_hold_the_lock() -> None:
        # The lock used to store a pid and nothing else, so a watcher killed
        # with SIGKILL whose number was later handed to an unrelated process
        # read as a live holder for as long as that process ran: the target
        # could never be watched again and no sweep covers the file. Identity is
        # injected as a function returning (live, start stamp), so this leg runs
        # on a machine with no libproc.
        class Standin:
            def __init__(self) -> None:
                self._lock_path = None

        target = 4242
        other = 31337
        stamps = {os.getpid(): (True, 900), other: (True, 700)}

        def identity(pid: int) -> tuple[bool, int | None]:
            return stamps.get(pid, (False, None))

        previous_home = os.environ.get("TBD_HOME")
        with tempfile.TemporaryDirectory() as raw:
            os.environ["TBD_HOME"] = raw
            try:
                path = watch_lock_path(target)
                path.parent.mkdir(parents=True, exist_ok=True)

                path.write_text(
                    json.dumps({"pid": other, "start_abstime": 700}) + "\n", encoding="utf-8"
                )
                _check(
                    Watch.take_lock(Standin(), target, identity) == ("conflict", other),
                    "a holder whose stamp still matches is a live watcher",
                )

                # The same pid, alive, but not the process that took the lock.
                path.write_text(
                    json.dumps({"pid": other, "start_abstime": 123}) + "\n", encoding="utf-8"
                )
                reclaimed = Standin()
                _check(
                    Watch.take_lock(reclaimed, target, identity) == ("acquired", None),
                    "a lock whose holder pid was reused is stale and is reclaimed",
                )
                _check(
                    read_lock(path) == (os.getpid(), 900),
                    f"the retaken lock should carry our pid and stamp; got {read_lock(path)}",
                )
                _check(
                    isinstance(json.loads(path.read_text(encoding="utf-8")), dict),
                    "a lock is written as a JSON object",
                )

                # A legacy plain-pid lock, which carries no stamp at all: live
                # pid keeps it, dead pid reclaims it. Fail-safe, because the
                # only thing an absent stamp can mean is "cannot tell".
                path.write_text(f"{other}\n", encoding="utf-8")
                _check(
                    Watch.take_lock(Standin(), target, identity) == ("conflict", other),
                    "a legacy lock held by a live pid is left alone",
                )
                path.write_text("99999\n", encoding="utf-8")
                _check(
                    Watch.take_lock(Standin(), target, identity) == ("acquired", None),
                    "a legacy lock whose pid is dead is still reclaimable",
                )

                _check(
                    holder_is_alive(other, None, identity),
                    "no recorded stamp falls back to liveness alone",
                )
                _check(
                    not holder_is_alive(other, 123, identity),
                    "a stamp the running process does not match is a reused pid",
                )
                _check(
                    holder_is_alive(other, 700, identity),
                    "a matching stamp is the holder itself",
                )
            finally:
                if previous_home is None:
                    os.environ.pop("TBD_HOME", None)
                else:
                    os.environ["TBD_HOME"] = previous_home

    def restart_onto_the_same_pid_is_noticed() -> None:
        # `tick` read the pid it had acquired and never asked again whose pid it
        # was, so a daemon that died and came back onto the same number was
        # sampled straight through: the new process inherited the dead one's
        # baseline, in-spike state, previous peak and CPU counters, and the
        # record said nothing had happened. Driven through a stand-in libproc
        # whose start stamp changes between ticks, which is the one thing that
        # cannot be arranged for real - a pid cannot be made to come round.
        _check(not identity_changed(None, 111), "an unknown recorded stamp changes nothing")
        _check(not identity_changed(111, None), "an unreadable current stamp changes nothing")
        _check(not identity_changed(111, 111), "the same process is not a change")
        _check(identity_changed(111, 222), "a different stamp is a different process")

        class FakeUsage:
            def __init__(self, start: int) -> None:
                self.ri_proc_start_abstime = start
                self.ri_phys_footprint = _mb(100)
                self.ri_interval_max_phys_footprint = _mb(100)
                self.ri_lifetime_max_phys_footprint = _mb(120)
                self.ri_resident_size = _mb(60)
                self.ri_user_time = 0
                self.ri_system_time = 0
                self.ri_pageins = 0

        class FakeLibProc:
            """Enough of `LibProc` for the sampler, with a settable identity."""

            timebase_numer = 1
            timebase_denom = 1
            timebase_ok = True

            def __init__(self) -> None:
                self.start = 111

            def rusage(self, pid: int) -> FakeUsage:
                return FakeUsage(self.start)

            def cpu_times_ns(self, usage) -> tuple[int, int]:
                return 0, 0

            def reset_footprint_interval(self, pid: int) -> bool:
                return True

        previous_home = os.environ.get("TBD_HOME")
        with tempfile.TemporaryDirectory() as raw:
            os.environ["TBD_HOME"] = raw
            try:
                args = build_parser().parse_args(["--no-log-stream", "--no-sample"])
                args.threshold_mb = 4096
                args.rise_mb = 0
                args.rearm_mb = 512
                args.baseline_window = DEFAULT_BASELINE_WINDOW
                libproc = FakeLibProc()
                watch = Watch(args, Path(raw) / "run", libproc=libproc)
                watch._samples = io.StringIO()
                # The pid file is not what this leg is about, and reading one
                # would drag `ps` into it.
                watch.resolve_pid = lambda: 4242

                watch.tick(1000.0)
                watch.tick(1001.0)
                libproc.start = 222  # the daemon restarted onto its own pid
                watch.tick(1002.0)

                records = [
                    json.loads(line)
                    for line in watch._samples.getvalue().splitlines()
                    if line.strip()
                ]
                lifecycle = [
                    record.get("event")
                    for record in records
                    if record.get("event") in ("target_acquired", "target_lost")
                ]
                _check(
                    lifecycle == ["target_acquired", "target_lost", "target_acquired"],
                    f"a restart onto the same pid should be lost and re-acquired; got {lifecycle}",
                )
                acquired = [r for r in records if r.get("event") == "target_acquired"]
                _check(
                    [r.get("start_abstime") for r in acquired] == [111, 222],
                    "each acquisition should record the stamp of the process it took; "
                    f"got {[r.get('start_abstime') for r in acquired]}",
                )
                _check(
                    [r.get("epoch") for r in acquired] == [1000.0, 1002.0],
                    "the re-acquisition belongs to the tick that noticed the change",
                )
                measured = [r for r in records if "phys_footprint" in r and not r.get("event")]
                _check(
                    len(measured) == 3,
                    f"every tick should still record a sample; got {len(measured)}",
                )
                _check(
                    watch.pid == 4242 and not watch.stop_event.is_set(),
                    "the pid-file path re-acquires and keeps watching",
                )

                # The same change under an explicit --pid, which names one
                # process and has no replacement to move to.
                args.pid = 4242
                libproc.start = 111
                named = Watch(args, Path(raw) / "run-pid", libproc=libproc)
                named._samples = io.StringIO()
                named.resolve_pid = lambda: 4242
                named.tick(2000.0)
                libproc.start = 333
                # Captured, because the operator being told is part of what is
                # under test and a self-test that prints it is a self-test
                # nobody reads.
                complaint = io.StringIO()
                with contextlib.redirect_stderr(complaint):
                    named.tick(2001.0)
                _check(
                    "different process" in complaint.getvalue(),
                    f"--pid should say why it stopped; got {complaint.getvalue()!r}",
                )
                _check(
                    named.exit_code == 3 and named.stop_event.is_set(),
                    f"--pid should stop with the target-gone code; got {named.exit_code}",
                )
                events = [
                    json.loads(line).get("event")
                    for line in named._samples.getvalue().splitlines()
                    if line.strip()
                ]
                _check(
                    "target_lost" in events,
                    f"the loss should be in the record before it stops; got {events}",
                )
            finally:
                if previous_home is None:
                    os.environ.pop("TBD_HOME", None)
                else:
                    os.environ["TBD_HOME"] = previous_home

    def sweep_reclaims_forgotten_runs() -> None:
        # The reconciler for run directories. Everything about it is driven
        # through the injected clock and the injected identity seam, so it runs
        # on a machine with no libproc and cannot depend on which pids happen to
        # exist here.
        now = time.time()
        live, dead = 4242, 5150

        def identity(pid: int) -> tuple[bool, int | None]:
            return (True, 900) if pid == live else (False, None)

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            old_dead = _seed_swept_run(root, "old-dead", now, 40, watcher=(dead, 700))
            old_live = _seed_swept_run(root, "old-live", now, 40, watcher=(live, 900))
            young = _seed_swept_run(root, "young", now, 1, watcher=(dead, 700))
            bare = _seed_swept_run(root, "old-bare", now, 40, run_json=False)
            broken = _seed_swept_run(root, "old-broken", now, 40)
            (broken / "run.json").write_text("{not json", encoding="utf-8")
            current = _seed_swept_run(root, "old-current", now, 40, watcher=(dead, 700))
            for path in (broken / "run.json", broken):
                os.utime(str(path), (now - 40 * SECONDS_PER_DAY,) * 2)

            result = sweep_footprint_root(
                root=root, keep_days=14, now=now, identity=identity, skip=current
            )
            _check(
                sorted(result.removed) == ["old-bare", "old-broken", "old-dead"],
                f"expected the three unclaimed old runs to go; got {sorted(result.removed)}",
            )
            _check(not old_dead.exists(), "an old run whose watcher is dead should be removed")
            _check(
                old_live.exists() and result.kept_live == 1,
                f"a live watcher's run is kept however old it is; got {result}",
            )
            _check(young.exists(), "a run inside the keep window is never touched")
            _check(
                not bare.exists() and not broken.exists(),
                "a run with no readable run.json goes by age alone",
            )
            _check(current.exists(), "the caller's own run directory is never swept")

            # The same directory, the same age, and a watcher pid that is alive
            # but is no longer the process that wrote the run. Without this leg
            # the case above would pass on liveness alone and the start stamp
            # would be decorative.
            def reused(pid: int) -> tuple[bool, int | None]:
                return (True, 111) if pid == live else (False, None)

            again = sweep_footprint_root(
                root=root, keep_days=14, now=now, identity=reused, skip=current
            )
            _check(
                again.removed == ["old-live"] and again.kept_live == 0,
                f"a watcher pid handed on to another process holds nothing; got {again}",
            )
            _check(not old_live.exists(), "the reclaimed run should be gone from disk")

    def sweep_reclaims_stale_locks_only() -> None:
        # Locks go by holder liveness, never by age: these three are minutes
        # old and two of them are still removed. A lock outlives the watcher
        # that was SIGKILLed, and until something removes it that target can
        # never be watched again.
        now = time.time()
        live, dead = 4242, 5150

        def identity(pid: int) -> tuple[bool, int | None]:
            return (True, 900) if pid == live else (False, None)

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            stale = root / f".watch-{dead}.lock"
            stale.write_text(_lock_text(dead, 700), encoding="utf-8")
            held = root / f".watch-{live}.lock"
            held.write_text(_lock_text(live, 900), encoding="utf-8")
            reused = root / ".watch-777.lock"
            reused.write_text(_lock_text(live, 123), encoding="utf-8")
            unreadable = root / ".watch-888.lock"
            unreadable.write_text("not a lock at all", encoding="utf-8")

            result = sweep_footprint_root(root=root, keep_days=14, now=now, identity=identity)
            _check(
                sorted(result.removed_locks) == [f".watch-{dead}.lock", ".watch-777.lock"],
                f"expected the dead and the reused holder to go; got {result.removed_locks}",
            )
            _check(held.exists(), "a lock whose holder is alive at its own stamp is kept")
            _check(not stale.exists() and not reused.exists(), "the stale locks should be gone")
            _check(
                unreadable.exists(),
                "a lock naming no readable holder is left for take_lock to reclaim",
            )
            _check(result.removed == [], f"no run directories here to remove; got {result.removed}")

    def sweep_does_not_follow_symlinks() -> None:
        # A symlink must contribute its own mtime and never its target's, or a
        # link into a directory somebody else is writing keeps a dead run alive
        # for good, and rmtree must not reach through one.
        #
        # The sweep's clock is put 40 days ahead of the real one, so everything
        # this case creates is already past the cutoff without any mtime being
        # set, and the single file that has to read as fresh is stamped
        # explicitly. That is what lets the case turn on the link's own mtime
        # rather than on a lutimes call the platform may not offer.
        now = time.time() + 40 * SECONDS_PER_DAY

        def identity(_pid: int) -> tuple[bool, int | None]:
            return False, None

        with tempfile.TemporaryDirectory() as raw:
            base = Path(raw)
            root = base / "daemon-footprint"
            root.mkdir()
            outside = base / "outside"
            outside.mkdir()
            keeper = outside / "keeper.txt"
            keeper.write_text("not this tree's to remove\n", encoding="utf-8")
            os.utime(str(keeper), (now, now))

            old = _seed_swept_run(root, "old-linked", now, 40, watcher=(5150, 700))
            (old / "link").symlink_to(keeper)
            top = root / "linked-elsewhere"
            top.symlink_to(outside)

            result = sweep_footprint_root(root=root, keep_days=14, now=now, identity=identity)
            _check(
                result.removed == ["old-linked"],
                f"the link's fresh target must not keep a dead run alive; got {result.removed}",
            )
            _check(not old.exists(), "the old run should be gone")
            _check(keeper.exists(), "a file outside the tree must survive a run being removed")
            _check(outside.exists(), "a directory outside the tree must survive")
            _check(top.is_symlink(), "a symlinked entry at the top level is left alone")

    def sweep_is_disabled_by_zero_keep_days() -> None:
        # `--keep-days 0` is the off switch, and it has to be complete: an
        # operator who wants a tree kept must not have to trust that nothing in
        # it looks reclaimable.
        now = time.time()

        def identity(_pid: int) -> tuple[bool, int | None]:
            return False, None

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            old = _seed_swept_run(root, "old-dead", now, 400, watcher=(5150, 700))
            stale = root / ".watch-5150.lock"
            stale.write_text(_lock_text(5150, 700), encoding="utf-8")

            off = sweep_footprint_root(root=root, keep_days=0, now=now, identity=identity)
            _check(
                off.removed == [] and off.removed_locks == [] and off.kept_live == 0,
                f"keep-days 0 must remove nothing; got {off}",
            )
            _check(old.exists() and stale.exists(), "nothing should have been removed from disk")

            # The same tree with the sweep armed, so the case above cannot pass
            # because there was nothing to remove in the first place.
            armed = sweep_footprint_root(root=root, keep_days=14, now=now, identity=identity)
            _check(
                armed.removed == ["old-dead"] and armed.removed_locks == [".watch-5150.lock"],
                f"the same tree is reclaimable with the sweep armed; got {armed}",
            )

    def libproc_glue_reads_this_process() -> None:
        # The one leg that exercises the ctypes glue itself: the struct layout,
        # the two libproc calls and the mach timebase scaling, all against this
        # process, where the answers are known. A transcription error in
        # `RusageInfoV4` does not fail loudly, it hands back a plausible number
        # from the neighbouring field, and every other leg here feeds the
        # detector numbers by hand and would never notice.
        if sys.platform != "darwin":
            raise _Skipped("libproc and mach_timebase_info are macOS only")

        lib = LibProc()
        me = os.getpid()
        usage = lib.rusage(me)
        _check(usage is not None, "libproc should read our own rusage")
        footprint = int(usage.ri_phys_footprint)
        lifetime = int(usage.ri_lifetime_max_phys_footprint)
        _check(footprint > 0, f"a running process has a footprint; got {footprint}")
        _check(
            lifetime >= footprint,
            f"the lifetime peak cannot sit below the current footprint; "
            f"got {lifetime} < {footprint}",
        )

        # 64 MB touched page by page and then unmapped. The current footprint
        # goes back down; the interval max is not allowed to, which is the whole
        # premise of the sampler.
        size = 64 * MB
        _check(lib.reset_footprint_interval(me), "resetting our own interval should succeed")
        block = mmap.mmap(-1, size)
        try:
            for offset in range(0, size, 4096):
                block[offset] = 1
        finally:
            block.close()
        after = lib.rusage(me)
        _check(after is not None, "libproc should still read us after the mapping is gone")
        released = int(after.ri_phys_footprint)
        interval_max = int(after.ri_interval_max_phys_footprint)
        _check(
            interval_max - released > size // 2,
            f"the interval max should remember the unmapped {size // MB} MB; "
            f"got {fmt_bytes(interval_max)} against {fmt_bytes(released)}",
        )

        _check(lib.reset_footprint_interval(me), "a second reset should succeed")
        settled = lib.rusage(me)
        _check(settled is not None, "libproc should read us after the reset")
        settled_max = int(settled.ri_interval_max_phys_footprint)
        _check(
            settled_max < interval_max,
            f"a reset should drop the interval max back; got {fmt_bytes(settled_max)}",
        )
        _check(
            abs(settled_max - int(settled.ri_phys_footprint)) < 8 * MB,
            "after a reset the interval max is the current footprint; got "
            f"{fmt_bytes(settled_max)} against {fmt_bytes(int(settled.ri_phys_footprint))}",
        )

        # The timebase scaling, against a CPU burn of a known size. Unscaled,
        # these counters understate CPU by about 41.7 on Apple silicon.
        started = time.process_time()
        user0, system0 = lib.cpu_times_ns(lib.rusage(me))
        while time.process_time() - started < 0.2:
            pass
        user1, system1 = lib.cpu_times_ns(lib.rusage(me))
        elapsed_cpu = time.process_time() - started
        burned = (user1 - user0) + (system1 - system0)
        _check(elapsed_cpu > 0, "the burn should have taken measurable CPU")
        ratio = burned / 1e9 / elapsed_cpu
        _check(
            0.5 <= ratio <= 1.5,
            f"mach-scaled CPU should agree with process_time within 50%; got {ratio:.2f}",
        )

    def report_replay() -> None:
        with tempfile.TemporaryDirectory() as raw:
            run_dir = Path(raw)
            base = 1_700_000_000.0
            series = [200, 200, 1500, 3000, 2000, 200, 200]
            run_args = {
                "threshold_mb": 1024,
                "rise_mb": DEFAULT_RISE_MB,
                "rearm_mb": DEFAULT_REARM_MB,
                "baseline_window": DEFAULT_BASELINE_WINDOW,
            }
            _write_synthetic_run(
                run_dir, base, series, run_args, [(base + 2, "synthetic-threshold", "threshold")]
            )

            samples, events, config = load_run(run_dir)
            _check(
                len(samples) == len(series),
                f"expected {len(series)} samples, got {len(samples)}",
            )
            _check(len(events) == 1, f"expected 1 event, got {len(events)}")
            _check(config["args"]["threshold_mb"] == 1024, "run.json threshold not read back")

            spikes = find_spikes(samples, _detector(threshold_mb=1024, rise_mb=DEFAULT_RISE_MB))
            _check(len(spikes) == 1, f"expected 1 spike, got {len(spikes)}")
            spike = spikes[0]
            _check(
                spike.onset == base + 2,
                f"onset should be the tick that entered the spike, got {spike.onset}",
            )
            _check(spike.reason == "threshold", f"unexpected reason {spike.reason}")
            _check(spike.peak == _mb(3000), f"peak should be 3000 MB, got {spike.peak}")
            _check(spike.peak_at == base + 3, "peak time should be the sample that held it")
            # The releasing tick closes the interval, so the spike ends one tick
            # later than a bare threshold test would have said.
            _check(spike.end == base + 5, f"end should be the releasing tick, got {spike.end}")

            attach_captures(spikes, events, slack=2.0)
            _check(
                spike.captures == ["synthetic-threshold (threshold)"],
                f"capture not attached to its spike: {spike.captures}",
            )

            buffer = io.StringIO()
            _check(report(run_dir, None, out=buffer) == 0, "report should succeed")
            text = buffer.getvalue()
            _check("spike 1" in text, "report should name the spike")
            _check("2.93 GB" in text, f"report should print the peak; got:\n{text}")

    def report_sees_rise_spike() -> None:
        # Nothing in this run comes near the absolute threshold, so a report
        # that only re-tested the threshold reported a quiet run while the live
        # detector had captured a rise spike. Replaying the detector is what
        # makes the two agree.
        with tempfile.TemporaryDirectory() as raw:
            run_dir = Path(raw)
            base = 1_700_000_000.0
            series = [2000, 2000, 2000, 2600, 2000, 2000]
            run_args = {
                "threshold_mb": 4096,
                "rise_mb": 512,
                "rearm_mb": 512,
                "baseline_window": DEFAULT_BASELINE_WINDOW,
            }
            _write_synthetic_run(
                run_dir, base, series, run_args, [(base + 3, "synthetic-rise", "rise")]
            )

            buffer = io.StringIO()
            _check(report(run_dir, None, out=buffer) == 0, "report should succeed")
            text = buffer.getvalue()
            _check(
                "SPIKES (1)" in text,
                f"report should find the rise spike below the threshold; got:\n{text}",
            )
            _check("reason rise" in text, f"report should name the rule that fired; got:\n{text}")
            _check(
                "synthetic-rise (rise)" in text,
                f"report should attach the rise capture; got:\n{text}",
            )
            _check(
                "rise 512 MB" in text,
                f"report header should say which rules it applied; got:\n{text}",
            )

    case("threshold balloon captures onset, high-water, then re-arms", balloon)
    case("sub-tick spike is caught by the interval max", subtick_spike)
    case("baseline rise fires when the threshold is out of reach", rise_trigger)
    case("a trough above 75% of the threshold still re-arms", high_trough_rearms)
    case("a plateau past the baseline window does not re-fire", sustained_plateau_does_not_refire)
    case("a rise spike over a high baseline releases", high_baseline_rise_releases)
    case("an idle plateau above the threshold does not latch", steady_state_above_threshold)
    case("a climb off a released plateau is still caught", plateau_then_further_climb)
    case("a capture the runner refused is re-issued", withdrawn_capture_is_reissued)
    case("an onset the runner refused is re-issued on the next tick", withdrawn_onset_is_reissued)
    case("a warmup climb under suppression captures nothing", warmup_rise_is_suppressed)
    case(
        "the same climb captures once suppression has expired",
        warmup_rise_fires_once_suppression_expires,
    )
    case("the threshold rule still fires during suppression", threshold_fires_during_suppression)
    case("the before and during log windows partition the log", log_windows_partition)
    case("report honours a run's own rise suppression", report_honours_recorded_suppression)
    case("report starts a new detector at a target change", report_resets_across_a_target_change)
    case("a busy runner is marked once per episode", busy_runner_notes_one_refusal_per_episode)
    case("take_lock names acquired, conflict and unlocked apart", lock_status_is_unambiguous)
    case("a lock held by a reused pid is reclaimed", a_reused_holder_pid_does_not_hold_the_lock)
    case(
        "a restart onto the same pid is lost and re-acquired",
        restart_onto_the_same_pid_is_noticed,
    )
    case("the sweep reclaims forgotten runs and keeps held ones", sweep_reclaims_forgotten_runs)
    case("the sweep removes stale locks and keeps held ones", sweep_reclaims_stale_locks_only)
    case("the sweep never follows a symlink out of the tree", sweep_does_not_follow_symlinks)
    case("keep-days 0 disables the sweep entirely", sweep_is_disabled_by_zero_keep_days)
    case("the libproc glue reads this process correctly", libproc_glue_reads_this_process)
    case("report replays a synthetic run and finds its spike", report_replay)
    case("report finds a rise spike below the threshold", report_sees_rise_spike)

    if failures:
        print(f"\n{len(failures)} self-test failure(s):")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("\nself-test passed")
    return 0


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------


def default_out_dir() -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return tbd_home() / "diag" / "daemon-footprint" / stamp


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Sample TBDDaemon's phys_footprint continuously and capture a spike "
        "in the act, without suspending it.",
        epilog="Run directories are reclaimed by the startup sweep every watch runs, "
        "and by --prune; see --keep-days. No daemon-side sweep covers them.",
    )
    parser.add_argument("--pid", type=int, help="target pid; defaults to $TBD_HOME/tbdd.pid")
    parser.add_argument(
        "--interval", type=float, default=DEFAULT_INTERVAL, help="seconds between samples"
    )
    parser.add_argument(
        "--threshold-mb",
        type=float,
        default=None,
        help=f"absolute footprint that trips a capture (default {DEFAULT_THRESHOLD_MB}); "
        "in --report mode, overrides the run's own threshold",
    )
    parser.add_argument(
        "--rise-mb",
        type=float,
        default=None,
        help=f"rise above the rolling baseline that trips a capture (default {DEFAULT_RISE_MB}); "
        "the same value sets the release band, because a spike releases once it is back "
        "within half a rise of its baseline, so 0 is how the rise rule is disabled and a "
        "huge value is not; in --report mode, overrides the run's own rise",
    )
    parser.add_argument(
        "--rearm-mb",
        type=float,
        default=None,
        help="further rise within one spike that earns a second capture "
        f"(default {DEFAULT_REARM_MB}); in --report mode, overrides the run's own rearm",
    )
    parser.add_argument(
        "--baseline-window",
        type=float,
        default=None,
        help="seconds the rolling baseline minimum looks back "
        f"(default {DEFAULT_BASELINE_WINDOW:g}); in --report mode, overrides the run's own window",
    )
    parser.add_argument(
        "--out", help="run directory (default $TBD_HOME/diag/daemon-footprint/<ts>)"
    )
    parser.add_argument(
        "--vmmap",
        action="store_true",
        help="add `vmmap -summary` to each capture. Off by default: it briefly holds the "
        "task and took 5.9 s on a 26 MB process, and longer at gigabytes",
    )
    parser.add_argument("--no-sample", action="store_true", help="skip the `sample` call graph")
    parser.add_argument(
        "--no-log-stream", action="store_true", help="do not run the `log stream` sidecar"
    )
    parser.add_argument(
        "--keep-days",
        type=float,
        default=DEFAULT_KEEP_DAYS,
        help="age in days past which a run directory nobody is watching is removed by the "
        f"startup sweep and by --prune (default {DEFAULT_KEEP_DAYS:g}); 0 disables the "
        "sweep entirely",
    )
    parser.add_argument(
        "--prune",
        action="store_true",
        help="run the startup sweep on its own, print what it removed, and exit; "
        "reclaims without starting a watch",
    )
    parser.add_argument("--report", metavar="RUN_DIR", help="replay a run directory and exit")
    parser.add_argument(
        "--self-test", action="store_true", help="test the detector and the report, then exit"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.self_test:
        return self_test()
    if args.prune:
        return prune(args.keep_days)
    if args.report:
        # All four detector settings are replay overrides here: unset means the
        # run's own value, so a bare --report always replays the run's rules.
        return report(
            Path(args.report).expanduser(),
            args.threshold_mb,
            args.rise_mb,
            args.rearm_mb,
            args.baseline_window,
        )

    # Live mode: the same four arguments take the built-in defaults when unset.
    if args.threshold_mb is None:
        args.threshold_mb = DEFAULT_THRESHOLD_MB
    if args.rise_mb is None:
        args.rise_mb = DEFAULT_RISE_MB
    if args.rearm_mb is None:
        args.rearm_mb = DEFAULT_REARM_MB
    if args.baseline_window is None:
        args.baseline_window = DEFAULT_BASELINE_WINDOW
    if args.interval <= 0:
        print("--interval must be positive", file=sys.stderr)
        return 2

    out_dir = Path(args.out).expanduser() if args.out else default_out_dir()
    # Refuse to append to an earlier run rather than interleaving two runs in
    # one samples.jsonl, where the seam between them reads as target behaviour.
    for existing in ("samples.jsonl", "run.json"):
        if (out_dir / existing).exists():
            print(
                f"{out_dir} already holds {existing} from an earlier run.\n"
                "Pass a fresh --out directory: two runs in one samples.jsonl cannot be "
                "told apart on replay.",
                file=sys.stderr,
            )
            return 2

    watch = Watch(args, out_dir)

    def handle(_signum, _frame) -> None:
        # First signal stops the loop; a second one, which is what an operator
        # sends when the shutdown wait looks like a hang, also gives up on the
        # in-flight capture. The sidecar is still stopped and the samples file
        # still closed on the way out, so this never trades a stuck wait for an
        # orphaned `log stream` child.
        watch.signal_count += 1
        if watch.signal_count > 1:
            watch.abandon_event.set()
        watch.stop_event.set()

    signal.signal(signal.SIGINT, handle)
    signal.signal(signal.SIGTERM, handle)
    return watch.run()


if __name__ == "__main__":
    sys.exit(main())
