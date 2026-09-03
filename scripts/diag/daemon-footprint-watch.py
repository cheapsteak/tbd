#!/usr/bin/env python3
"""Catch a TBDDaemon memory spike in the act, on a live daemon, without suspending it.

    daemon-footprint-watch.py [--pid N] [--interval 1.0] [--threshold-mb 1024] [--out DIR]
    daemon-footprint-watch.py --report <run dir>
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
  ri_user_time, ri_system_time     CPU, in nanoseconds, differenced per tick.
  ri_pageins                       compressor and swap activity.

After each read the script calls `proc_reset_footprint_interval(pid)`, so the
next tick's interval max is the peak reached *since this tick*. That is the part
that makes a spike shorter than the sampling interval impossible to miss: the
current footprint can be back down by the time we look, but the interval max
cannot hide. Both calls are declared in <libproc.h>.

The interval is reset once more, at acquire, before the very first sample is
read. Until somebody resets it the kernel reports the peak since process start,
so an un-reset first read hands back a lifetime peak as if it had just happened:
on the incident daemon that is 7.4 GB, which would fire a capture at t0 on a
process that is merely old and would then dominate `--report`. If that reset
ever fails the run records one `interval_reset_failed` marker for the target, so
an interval max that only ever climbs is diagnosable from the record instead of
being read as a real spike.

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
3. A `log stream` sidecar, so there is something to correlate the spike against.

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
`~/tbd`). The run directory holds `run.json`, `samples.jsonl`, `daemon-log.txt`
and `captures/`. These files outlive the run and no reconciler covers them: this
is operator scratch, and the operator who started the watch deletes it. Nothing
here writes to the database, signals the daemon, or restarts anything; the only
state it changes in the target is the footprint interval counter it resets.

A run directory is written once and never reused. If `--out` already holds a
`samples.jsonl` or a `run.json` the watch refuses to start and exits 2, because
appending a second run to the first one's sample stream produces a file whose
gaps and pid changes read as the target's behaviour rather than as two runs.

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
import ctypes
import io
import json
import os
import re
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

# Python 3.9 floor: this must run on the stock /usr/bin/python3, so no `match`,
# no `dataclass(slots=True)`, and the `__future__` import above is what keeps
# 3.10-style `X | None` annotations from being evaluated at definition time.

SCRIPT_VERSION = "1"

DEFAULT_INTERVAL = 1.0
DEFAULT_THRESHOLD_MB = 1024
DEFAULT_RISE_MB = 512
DEFAULT_REARM_MB = 512
DEFAULT_BASELINE_WINDOW = 300.0

MB = 1024 * 1024

# A spike is considered over, and the onset trigger re-armed, once the footprint
# falls this far below the level that fired it. Hysteresis: without it a
# footprint hovering at the threshold captures on every tick.
RELEASE_FRACTION = 0.75

# The second release rule: back within this fraction of a rise of the rolling
# trough. RELEASE_FRACTION alone can never fire when the trough itself sits
# above it, and the incident daemon idled at 990 MB against a 1024 MB threshold,
# so it would have stayed "in spike" for the rest of the night and the 7 GB and
# 8 GB spikes that followed would have captured nothing.
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


class LibProc:
    """The two libproc entry points this script needs, bound once."""

    def __init__(self) -> None:
        self._lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        self._lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self._lib.proc_pid_rusage.restype = ctypes.c_int
        self._lib.proc_reset_footprint_interval.argtypes = [ctypes.c_int]
        self._lib.proc_reset_footprint_interval.restype = ctypes.c_int

    def rusage(self, pid: int) -> RusageInfoV4 | None:
        """Kernel counters for `pid`, or None if it is gone or not ours."""
        buf = RusageInfoV4()
        if self._lib.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(buf)) != 0:
            return None
        return buf

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
    ) -> None:
        self.threshold_bytes = threshold_bytes
        self.rise_bytes = rise_bytes
        self.rearm_bytes = rearm_bytes
        self.baseline_window = baseline_window
        self.release_fraction = release_fraction
        self.release_rise_fraction = release_rise_fraction
        self.max_captures_per_spike = max_captures_per_spike
        self._window: deque[tuple[float, int]] = deque()
        self._in_spike = False
        self._trigger_level = 0
        self._last_capture_value = 0
        self._captures_this_spike = 0

    @property
    def in_spike(self) -> bool:
        return self._in_spike

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
        actions: list[CaptureRequest] = []

        if not self._in_spike:
            reason, level = self._trigger_for(peak, baseline)
            if reason is not None:
                self._in_spike = True
                self._trigger_level = level
                self._last_capture_value = peak
                self._captures_this_spike = 1
                actions.append(CaptureRequest(now, reason, footprint, interval_max, peak, baseline))
            return actions

        if self._releases(peak, baseline):
            # Fallen far enough below what fired it. The spike is over and the
            # onset trigger is armed again; no capture on the way down.
            self._in_spike = False
            self._trigger_level = 0
            self._last_capture_value = 0
            self._captures_this_spike = 0
            return actions

        if (
            self._captures_this_spike < self.max_captures_per_spike
            and peak >= self._last_capture_value + self.rearm_bytes
        ):
            self._captures_this_spike += 1
            self._last_capture_value = peak
            actions.append(
                CaptureRequest(now, "highwater", footprint, interval_max, peak, baseline)
            )
        return actions

    def _releases(self, peak: int, baseline: int) -> bool:
        """Whether this tick ends the spike. Either rule is enough.

        (a) The original hysteresis: the peak has fallen well below the level
        that fired the spike. It is the only rule that can end a spike which is
        still above the absolute threshold, and it cannot fire at all when the
        trough sits above `release_fraction` of that level.

        (b) Back within half a rise of the rolling trough, and below the
        absolute threshold. This is the case (a) cannot reach: a daemon idling
        at 990 MB against a 1024 MB threshold, or a rise-triggered spike whose
        baseline is more than three times the rise. The `peak < threshold` guard
        is what stops (b) from turning a sustained plateau into a capture on
        every tick: hold a plateau for longer than the baseline window and the
        rolling minimum climbs up to meet it, so `peak - baseline` goes to zero
        and (b) would release, re-arm, and fire a fresh onset capture the very
        next tick, forever. Above the threshold the plateau stays one spike.
        """
        if peak < self._trigger_level * self.release_fraction:
            return True
        below_threshold = self.threshold_bytes <= 0 or peak < self.threshold_bytes
        return below_threshold and peak - baseline < self.rise_bytes * self.release_rise_fraction

    def _trigger_for(self, peak: int, baseline: int) -> tuple[str | None, int]:
        """Which rule fires on this peak, and the level to release against."""
        if self.threshold_bytes > 0 and peak >= self.threshold_bytes:
            return "threshold", self.threshold_bytes
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

    def busy(self) -> bool:
        with self._lock:
            return self._thread is not None and self._thread.is_alive()

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
        """Kick off a capture, returning its directory name, or None if busy."""
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
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
        if label == "footprint":
            (target / "footprint.txt").write_text(done.stdout, encoding="utf-8")
        elif label == "vmmap":
            (target / "vmmap.txt").write_text(done.stdout, encoding="utf-8")


# ----------------------------------------------------------------------------
# LOG SIDECAR
# ----------------------------------------------------------------------------


class LogSidecar:
    """A `log stream` child whose output is the only correlatable record.

    Held by pid and terminated by pid on every exit path. Nothing here ever
    signals a process it did not spawn.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self.process: subprocess.Popen | None = None
        self._handle = None

    def start(self) -> int | None:
        self._handle = self.path.open("a", encoding="utf-8")
        self.process = subprocess.Popen(
            [
                "/usr/bin/log",
                "stream",
                "--level",
                "debug",
                "--style",
                "compact",
                "--predicate",
                'subsystem BEGINSWITH "com.tbd"',
            ],
            stdout=self._handle,
            stderr=subprocess.STDOUT,
        )
        return self.process.pid

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            try:
                os.kill(self.process.pid, signal.SIGTERM)
            except OSError:
                pass
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.kill(self.process.pid, signal.SIGKILL)
                except OSError:
                    pass
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

    def __init__(self, args: argparse.Namespace, out_dir: Path) -> None:
        self.args = args
        self.out_dir = out_dir
        self.captures_dir = out_dir / "captures"
        self.samples_path = out_dir / "samples.jsonl"
        self.log_path = out_dir / "daemon-log.txt"
        self.stop_event = threading.Event()
        self.libproc = LibProc()
        self.detector = SpikeDetector(
            threshold_bytes=int(args.threshold_mb * MB),
            rise_bytes=int(args.rise_mb * MB),
            rearm_bytes=int(args.rearm_mb * MB),
            baseline_window=args.baseline_window,
        )
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
        self._prev_cpu: tuple[float, int, int] | None = None
        self._reset_failure_noted = False

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

    def acquire(self, pid: int) -> None:
        self.pid = pid
        self._prev_cpu = None
        self._reset_failure_noted = False
        # Reset before the first read, not just after it. Nobody has reset this
        # counter since the target launched, so an un-reset first sample reports
        # the peak since process start: 7.4 GB on the incident daemon, which
        # would fire a capture at t0 and then dominate every report of the run.
        reset_ok = self.libproc.reset_footprint_interval(pid)
        self.emit(
            {
                "event": "target_acquired",
                "pid": pid,
                "start_time": process_start_time(pid),
            }
        )
        if not reset_ok:
            self.note_reset_failure()

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

    def lose(self) -> None:
        if self.pid is not None:
            self.emit({"event": "target_lost", "pid": self.pid})
        self.pid = None
        self._prev_cpu = None

    def resolve_pid(self) -> int | None:
        if self.args.pid is not None:
            candidate = self.args.pid
        else:
            candidate = read_pid_file(pid_file_path())
        if candidate is None:
            return None
        # Only accept a pid we can actually read, so a stale pid file does not
        # look like an acquired target.
        return candidate if self.libproc.rusage(candidate) is not None else None

    # -- loop --------------------------------------------------------------

    def run(self) -> int:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.captures_dir.mkdir(parents=True, exist_ok=True)
        self._samples = self.samples_path.open("a", encoding="utf-8")

        initial_pid = self.resolve_pid()
        sidecar_pid = None
        if not self.args.no_log_stream:
            self.sidecar = LogSidecar(self.log_path)
            sidecar_pid = self.sidecar.start()

        (self.out_dir / "run.json").write_text(
            json.dumps(
                {
                    "script_version": SCRIPT_VERSION,
                    "started_at": iso(time.time()),
                    "started_epoch": time.time(),
                    "target_pid": initial_pid,
                    "target_start_time": process_start_time(initial_pid) if initial_pid else None,
                    "log_stream_pid": sidecar_pid,
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
                        "out": str(self.out_dir),
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        print(f"watching -> {self.out_dir}")
        if initial_pid is None:
            print("no target yet; will keep looking at the pid file every tick")
        else:
            print(f"target pid {initial_pid}")
        if sidecar_pid is not None:
            print(f"log sidecar pid {sidecar_pid} -> {self.log_path.name}")
        print("Ctrl-C to stop")

        if initial_pid is not None:
            self.acquire(initial_pid)

        try:
            while not self.stop_event.is_set():
                tick_started = time.time()
                self.tick(tick_started)
                remaining = self.args.interval - (time.time() - tick_started)
                if remaining > 0:
                    self.stop_event.wait(remaining)
        finally:
            self.shutdown()
        return 0

    def tick(self, now: float) -> None:
        if self.pid is None:
            found = self.resolve_pid()
            if found is None:
                return
            self.acquire(found)

        assert self.pid is not None
        usage = self.libproc.rusage(self.pid)
        if usage is None:
            self.lose()
            return

        # Reset immediately after the read, so the next tick's interval max is
        # exactly the peak reached between these two ticks.
        if not self.libproc.reset_footprint_interval(self.pid):
            self.note_reset_failure()

        cpu_pct = None
        if self._prev_cpu is not None:
            prev_when, prev_user, prev_system = self._prev_cpu
            elapsed = now - prev_when
            if elapsed > 0:
                busy_ns = (usage.ri_user_time - prev_user) + (usage.ri_system_time - prev_system)
                cpu_pct = round(busy_ns / 1e9 / elapsed * 100, 2)
        self._prev_cpu = (now, usage.ri_user_time, usage.ri_system_time)

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
                "user_time_ns": int(usage.ri_user_time),
                "system_time_ns": int(usage.ri_system_time),
                "pageins": int(usage.ri_pageins),
                "cpu_pct": cpu_pct,
            }
        )

        for request in self.detector.observe(now, footprint, interval_max):
            name = self.capture_runner.start(self.pid, request)
            if name is not None:
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
        # spawned and it holds nothing the target needs.
        self.capture_runner.join(timeout=self.capture_runner.worst_case_seconds())
        if self.sidecar is not None:
            self.sidecar.stop()
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


def find_spikes(samples: list[dict], detector: SpikeDetector) -> list[Spike]:
    """Replay the live detector over recorded samples and bracket its spikes.

    The report used to re-test `value >= threshold` on its own, which could not
    see a rise-triggered spike at all and disagreed with the live run about
    where a spike ended. Driving the same pure detector makes the two agree by
    construction: a spike is the interval from the tick that put the detector
    into `in_spike` to the tick that took it out again, or to the last sample if
    the run ended mid-spike, and its reason is whichever rule fired at onset.
    """
    spikes: list[Spike] = []
    current: Spike | None = None
    for sample in samples:
        when = sample.get("epoch", 0.0)
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
    path: Path, windows: list[tuple[str, float, float]]
) -> dict[str, tuple[Counter, list[tuple[float, str]]]]:
    """Category counts and `rpc in-flight high` lines for every window at once.

    One pass over `daemon-log.txt`, bucketing each line into whichever of the
    requested windows contain it. A `log stream` sidecar left running overnight
    produces a large file, and the report wants two windows per spike: scanning
    it once per window meant rereading gigabytes to answer questions that one
    read already had the data for.
    """
    results: dict[str, tuple[Counter, list[tuple[float, str]]]] = {
        key: (Counter(), []) for key, _, _ in windows
    }
    if not windows or not path.exists():
        return results
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
            matched = [key for key, start, end in windows if start <= epoch <= end]
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


def report(run_dir: Path, threshold_override_mb: float | None, out=sys.stdout) -> int:
    samples, events, config = load_run(run_dir)
    if not samples:
        print(f"no samples in {run_dir / 'samples.jsonl'}", file=out)
        return 1

    run_args = config.get("args") or {}

    def setting(name: str, fallback: float) -> float:
        value = run_args.get(name)
        return float(value) if value is not None else float(fallback)

    configured = run_args.get("threshold_mb")
    threshold_mb = (
        threshold_override_mb
        if threshold_override_mb is not None
        else (configured if configured is not None else DEFAULT_THRESHOLD_MB)
    )
    source = "override" if threshold_override_mb is not None else (
        "run.json" if configured is not None else "built-in default"
    )
    rise_mb = setting("rise_mb", DEFAULT_RISE_MB)
    rearm_mb = setting("rearm_mb", DEFAULT_REARM_MB)
    baseline_window = setting("baseline_window", DEFAULT_BASELINE_WINDOW)

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
    print(
        f"rise rule       {rise_mb:g} MB above a {baseline_window:g} s rolling baseline "
        f"(rearm {rearm_mb:g} MB)",
        file=out,
    )
    print(f"highest sample  {fmt_bytes(highest)}", file=out)
    print(f"lifetime peak   {fmt_bytes(lifetime)}", file=out)
    print(file=out)

    markers = [
        e
        for e in events
        if e.get("event") in ("target_acquired", "target_lost", "interval_reset_failed")
    ]
    if markers:
        print(f"MARKERS ({len(markers)})", file=out)
        for event in markers:
            detail = f"pid {event.get('pid')}"
            if event.get("start_time"):
                detail += f"  started {event['start_time']}"
            print(f"  {hhmmss(event.get('epoch', 0.0)):<14}{event['event']:<24}{detail}", file=out)
        print(file=out)

    failures = [e for e in events if str(e.get("event", "")).startswith("capture_")]
    if failures:
        print(f"CAPTURE PROBLEMS ({len(failures)})", file=out)
        for event in failures:
            print(
                f"  {hhmmss(event.get('epoch', 0.0)):<14}{event['event']:<22}"
                f"{event.get('error') or event.get('why') or ''}",
                file=out,
            )
        print(file=out)

    detector = SpikeDetector(
        threshold_bytes=int(threshold_mb * MB),
        rise_bytes=int(rise_mb * MB),
        rearm_bytes=int(rearm_mb * MB),
        baseline_window=baseline_window,
    )
    spikes = find_spikes(samples, detector)
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
    windows: list[tuple[str, float, float]] = []
    for index, spike in enumerate(spikes, start=1):
        windows.append((f"{index}:before", spike.onset - 60, spike.onset))
        windows.append((f"{index}:during", spike.onset, spike.end))
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
            for key, count in counts.most_common(10):
                print(f"        {count:>7}  {key}", file=out)
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


def _detector(threshold_mb: float, rise_mb: float, rearm_mb: float = 512) -> SpikeDetector:
    return SpikeDetector(
        threshold_bytes=_mb(threshold_mb),
        rise_bytes=_mb(rise_mb),
        rearm_bytes=_mb(rearm_mb),
        baseline_window=DEFAULT_BASELINE_WINDOW,
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


def _write_synthetic_run(
    run_dir: Path,
    base: float,
    series: list[float],
    run_args: dict,
    captures: list[tuple[float, str, str]],
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
    (run_dir / "samples.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (run_dir / "run.json").write_text(json.dumps({"args": run_args}), encoding="utf-8")


def self_test() -> int:
    """Drive the detector and the report over synthetic series, no daemon needed."""
    failures: list[str] = []

    def case(name: str, body) -> None:
        try:
            body()
            print(f"ok    {name}")
        except AssertionError as exc:
            failures.append(f"{name}: {exc}")
            print(f"FAIL  {name}: {exc}")

    def balloon() -> None:
        # rise is set out of reach so this case exercises the absolute threshold
        # rule alone; the rise rule has its own case.
        detector = _detector(threshold_mb=1024, rise_mb=1_000_000, rearm_mb=512)
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
        detector = _detector(threshold_mb=1024, rise_mb=1_000_000, rearm_mb=512)
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
        # minimum up to meet it, so the rise-based release rule would fire on
        # every tick if it were not guarded by the absolute threshold. The cap
        # on captures per spike only helps while it is still the same spike.
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
        _check(detector.in_spike, "a plateau above the threshold is still one spike")

    def high_baseline_rise_releases() -> None:
        # A rise-triggered spike whose baseline is more than three times the
        # rise: 0.75 * (2000 + 512) is 1884, below the trough, so only the
        # rise-based release rule can end it.
        detector = _detector(threshold_mb=4096, rise_mb=512, rearm_mb=512)
        events = _drive(detector, [2000, 2000, 2000, 2600, 2000, 2000])
        _check(len(events) == 1, f"expected exactly one capture, got {len(events)}")
        _check(events[0].reason == "rise", f"unexpected reason {events[0].reason}")
        _check(not detector.in_spike, "the spike should release back at the trough")

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
        epilog="Files under --out are operator scratch: no sweep reclaims them.",
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
        default=DEFAULT_RISE_MB,
        help=f"rise above the rolling baseline that trips a capture (default {DEFAULT_RISE_MB})",
    )
    parser.add_argument(
        "--rearm-mb",
        type=float,
        default=DEFAULT_REARM_MB,
        help="further rise within one spike that earns a second capture "
        f"(default {DEFAULT_REARM_MB})",
    )
    parser.add_argument(
        "--baseline-window",
        type=float,
        default=DEFAULT_BASELINE_WINDOW,
        help="seconds the rolling baseline minimum looks back "
        f"(default {DEFAULT_BASELINE_WINDOW:g})",
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
    parser.add_argument("--report", metavar="RUN_DIR", help="replay a run directory and exit")
    parser.add_argument(
        "--self-test", action="store_true", help="test the detector and the report, then exit"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.self_test:
        return self_test()
    if args.report:
        return report(Path(args.report).expanduser(), args.threshold_mb)

    if args.threshold_mb is None:
        args.threshold_mb = DEFAULT_THRESHOLD_MB
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
        watch.stop_event.set()

    signal.signal(signal.SIGINT, handle)
    signal.signal(signal.SIGTERM, handle)
    return watch.run()


if __name__ == "__main__":
    sys.exit(main())
