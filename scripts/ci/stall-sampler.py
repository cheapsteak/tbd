#!/usr/bin/env python3
"""THROWAWAY CI DIAGNOSTIC: never merge this file.

Follows one fast test pass's log and, whenever no Swift Testing progress line
has arrived for --quiet-seconds, captures stacks of the test process
(`swiftpm-testing-helper`) and of SwiftPM's driver (its parent), plus a
snapshot of the machine. A per-second metrics table and a heartbeat process
outside the test process run alongside it.

  python3 -I scripts/ci/stall-sampler.py --log <pass log> --pipeline-pid <pid>
      --out-dir <dir> --name <pass> [--quiet-seconds 1.0] [--sample-seconds 2]
      [--max-captures 12]

Files written under --out-dir, all prefixed with <name>-:
  metrics.tsv          one row per second (header row names the columns)
  captures.jsonl       one object per capture
  stall-<i>-helper.txt / stall-<i>-driver.txt   `sample` output
  stall-<i>-helper.status / -driver.status      `sample`'s own stdout
  stall-<i>-sys.txt    ps -M, top processes, vm_stat, sysctl at the trigger
  processes.txt        the pipeline's descendants with argv, once found
  heartbeat.tsv        heartbeat ticks that overshot, plus a summary line
  sampler.log          lifecycle events
  sampler.err          the sampler's own errors

The test process is found by LINEAGE from --pipeline-pid and then by argv,
never by name alone (see scripts/ci/watched-test-pass.sh, WHY LINEAGE).

It never fails the pass: every error is logged to sampler.err and the process
always exits 0.
"""

import argparse
import ctypes
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import traceback
from datetime import datetime, timezone

# Swift Testing event lines: started, passed, failed, known issue.
PROGRESS_GLYPHS = ("◇", "✔", "✘", "━")  # ◇ ✔ ✘ ━
RUN_STARTED = re.compile(r"^\S+ Test run started\.")
RUN_FINISHED = re.compile(r"^\S+ Test run with \d+ tests?\b")
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")

POLL_SECONDS = 0.1
MIN_SECONDS_AFTER_CAPTURE = 5.0
# After SIGTERM: how long an in-flight capture may still finish. The caller
# sends SIGKILL 5 s after SIGTERM.
TERM_GRACE_SECONDS = 3.0
# After the run finishes on its own: how long an in-flight capture may finish.
FINISH_WAIT_SECONDS = 90.0
HEARTBEAT_TICK = 0.1
HEARTBEAT_REPORT_OVERSHOOT = 0.25


def utc(ts=None):
    if ts is None:
        ts = time.time()
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


class AppendLog(object):
    """Thread-safe append-only text file. Repeated error contexts are
    rate-limited so a command that fails every second cannot flood it."""

    def __init__(self, path, rate_limit=False):
        self.path = path
        self.rate_limit = rate_limit
        self.lock = threading.Lock()
        self.counts = {}

    def __call__(self, context, detail=None):
        try:
            with self.lock:
                n = self.counts.get(context, 0) + 1
                self.counts[context] = n
                if self.rate_limit and n > 5 and n % 100 != 0:
                    return
                text = "%s %s" % (utc(), context)
                if self.rate_limit:
                    text += " (occurrence %d)" % n
                if detail:
                    text += "\n" + detail.rstrip()
                with open(self.path, "a") as f:
                    f.write(text + "\n")
        except Exception:
            pass

    def exc(self, context):
        self(context, traceback.format_exc())


def run(cmd, timeout=15):
    """Runs a command; never raises. Returns (exit code or description, output)."""
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as e:
        out = e.output.decode("utf-8", "replace") if e.output else ""
        return "timeout after %ss" % timeout, out
    except Exception as e:
        return "error: %r" % (e,), ""


def alive(pid):
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Per-process counters without a fork: proc_pidinfo(PROC_PIDTASKINFO).


class TaskInfo(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint64) for n in (
        "virtual_size", "resident_size", "total_user", "total_system",
        "threads_user", "threads_system")] + [(n, ctypes.c_int32) for n in (
            "policy", "faults", "pageins", "cow_faults", "messages_sent",
            "messages_received", "syscalls_mach", "syscalls_unix", "csw",
            "threadnum", "numrunning", "priority")]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


class LibProc(object):
    PROC_PIDTASKINFO = 4

    def __init__(self, err):
        self.lib = None
        self.ticks_to_seconds = None
        try:
            lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            tb = Timebase()
            lib.mach_timebase_info(ctypes.byref(tb))
            # pti_total_user/system are mach absolute time units on arm64
            # (nanoseconds on x86_64, where the timebase is 1/1).
            self.ticks_to_seconds = float(tb.numer) / float(tb.denom) / 1e9
            lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                         ctypes.POINTER(TaskInfo), ctypes.c_int]
            lib.proc_pidinfo.restype = ctypes.c_int
            self.lib = lib
        except Exception:
            err.exc("libproc unavailable")

    def task_info(self, pid):
        if self.lib is None or pid is None:
            return None
        ti = TaskInfo()
        n = self.lib.proc_pidinfo(pid, self.PROC_PIDTASKINFO, 0, ctypes.byref(ti),
                                  ctypes.sizeof(ti))
        if n != ctypes.sizeof(ti):
            return None
        return {
            "cpu_s": (ti.total_user + ti.total_system) * self.ticks_to_seconds,
            "threads": ti.threadnum,
            "running": ti.numrunning,
            "faults": ti.faults,
            "pageins": ti.pageins,
            "csw": ti.csw,
        }


# ---------------------------------------------------------------------------
# Shared state. The follower (main thread) owns the log fields, the metrics
# thread owns helper/driver discovery; each reads the other's fields only.


class State(object):
    def __init__(self):
        self.stop = False
        self.stop_mono = None
        self.stop_reason = None
        self.metrics_stop = False
        self.run_started = False
        self.run_finished = False
        self.last_progress_mono = None
        self.last_progress_wall = None
        self.progress_total = 0
        self.consumed = 0
        self.helper_pid = None
        self.helper_cmd = None
        self.driver_pid = None
        self.driver_cmd = None
        self.capturing = False
        self.captures_started = 0


def process_table():
    rc, out = run(["ps", "-axww", "-o", "pid=,ppid=,command="], timeout=10)
    procs = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        procs[pid] = (ppid, parts[2] if len(parts) > 2 else "")
    return procs


def walk(procs, root):
    """Preorder descendants of root as (pid, depth)."""
    children = {}
    for pid, (ppid, _) in procs.items():
        children.setdefault(ppid, []).append(pid)
    result, seen = [], set()
    stack = [(c, 1) for c in sorted(children.get(root, []), reverse=True)]
    while stack:
        pid, depth = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        result.append((pid, depth))
        for c in sorted(children.get(pid, []), reverse=True):
            stack.append((c, depth + 1))
    return result


def discover(args, st, paths, ev):
    procs = process_table()
    if not procs:
        return
    tree = walk(procs, args.pipeline_pid)
    matches = [pid for pid, _ in tree
               if "swiftpm-testing-helper" in procs[pid][1] and "swift-testing" in procs[pid][1]]
    if not matches:
        return
    helper = matches[-1]
    driver = procs[helper][0]
    st.driver_cmd = procs.get(driver, (None, ""))[1]
    st.driver_pid = driver if driver in procs else None
    st.helper_cmd = procs[helper][1]
    st.helper_pid = helper
    ev("helper found: pid %d (driver pid %s); %d descendants, %d argv matches"
       % (helper, st.driver_pid, len(tree), len(matches)))
    with open(paths["processes"], "a") as f:
        f.write("=== descendants of pipeline pid %d at %s ===\n" % (args.pipeline_pid, utc()))
        for pid, depth in tree:
            ppid, cmd = procs[pid]
            mark = ""
            if pid == helper:
                mark = "  <-- HELPER"
            elif pid == driver:
                mark = "  <-- DRIVER"
            f.write("%s%d (ppid %d)%s\n%s    %s\n" % ("  " * (depth - 1), pid, ppid, mark,
                                                   "  " * (depth - 1), cmd))
        f.write("\nhelper pid %d argv:\n%s\n\ndriver pid %s argv:\n%s\n\n"
                % (helper, st.helper_cmd, st.driver_pid, st.driver_cmd))


# ---------------------------------------------------------------------------
# Metrics: one row per second, on its own thread so a slow `ps` or `vm_stat`
# can never delay the log follower's timestamps.

VM_KEYS = [
    ("pageins", "Pageins"), ("pageouts", "Pageouts"), ("swapins", "Swapins"),
    ("swapouts", "Swapouts"), ("compressions", "Compressions"),
    ("decompressions", "Decompressions"), ("free_pages", "Pages free"),
    ("compressor_pages", "Pages occupied by compressor"),
]

METRIC_COLUMNS = (
    ["utc", "phase", "quiet_s", "progress_lines_last_interval", "interval_s", "log_bytes",
     "loadavg1", "helper_pid", "helper_rss_kb", "helper_pcpu", "helper_threads",
     "helper_running_threads", "helper_cpu_cores", "helper_faults_delta",
     "helper_pageins_delta", "helper_csw_delta", "driver_pid", "driver_pcpu",
     "driver_cpu_cores"]
    + [k for k, _ in VM_KEYS]
    + ["swap_used_mb", "capturing", "captures_started"])


def parse_vm_stat(out):
    values = {}
    for line in out.splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip().strip('"')
        value = value.strip().rstrip(".")
        if value.isdigit():
            values[key] = value
    return {k: values.get(label, "") for k, label in VM_KEYS}


def parse_swap_used(out):
    m = re.search(r"used = ([0-9.]+)M", out)
    return m.group(1) if m else ""


def fmt(v, digits=2):
    if v is None:
        return ""
    if isinstance(v, float):
        return ("%." + str(digits) + "f") % v
    return str(v)


def metrics_worker(args, st, paths, err, ev):
    libproc = LibProc(err)
    prev = {}  # pid -> (mono, task info)
    last_total = 0
    last_mono = time.monotonic()
    next_tick = last_mono
    try:
        with open(paths["metrics"], "a") as f:
            f.write("\t".join(METRIC_COLUMNS) + "\n")
    except Exception:
        err.exc("metrics header")
    while not st.metrics_stop:
        try:
            if st.helper_pid is None or (not st.run_started and not alive(st.helper_pid)):
                if st.helper_pid is not None:
                    ev("helper pid %d exited before the run started; searching again" % st.helper_pid)
                    st.helper_pid = None
                    st.driver_pid = None
                discover(args, st, paths, ev)
        except Exception:
            err.exc("discover")
        try:
            now = time.monotonic()
            interval = now - last_mono
            total = st.progress_total
            helper, driver = st.helper_pid, st.driver_pid
            if st.run_finished:
                phase = "finished"
            elif st.run_started:
                phase = "running"
            else:
                phase = "waiting"
            quiet = None
            if st.run_started and st.last_progress_mono is not None:
                quiet = now - st.last_progress_mono
            row = {
                "utc": utc(), "phase": phase, "quiet_s": fmt(quiet),
                "progress_lines_last_interval": str(total - last_total),
                "interval_s": fmt(interval, 3), "log_bytes": str(st.consumed),
                "helper_pid": fmt(helper), "driver_pid": fmt(driver),
                "capturing": "1" if st.capturing else "0",
                "captures_started": str(st.captures_started),
            }
            last_total, last_mono = total, now
            try:
                row["loadavg1"] = "%.2f" % os.getloadavg()[0]
            except Exception:
                err.exc("loadavg")
            pids = [p for p in (helper, driver) if p is not None]
            if pids:
                rc, out = run(["ps", "-o", "pid=,rss=,%cpu=", "-p", ",".join(str(p) for p in pids)], 10)
                for line in out.splitlines():
                    parts = line.split()
                    if len(parts) != 3:
                        continue
                    if parts[0] == str(helper):
                        row["helper_rss_kb"], row["helper_pcpu"] = parts[1], parts[2]
                    if parts[0] == str(driver):
                        row["driver_pcpu"] = parts[2]
            for role, pid in (("helper", helper), ("driver", driver)):
                ti = libproc.task_info(pid)
                if ti is None:
                    continue
                t = time.monotonic()
                before = prev.get(pid)
                prev[pid] = (t, ti)
                if role == "helper":
                    row["helper_threads"] = str(ti["threads"])
                    row["helper_running_threads"] = str(ti["running"])
                if before is None:
                    continue
                dt = t - before[0]
                if dt > 0:
                    row[role + "_cpu_cores"] = "%.3f" % ((ti["cpu_s"] - before[1]["cpu_s"]) / dt)
                if role == "helper":
                    for key in ("faults", "pageins", "csw"):
                        row["helper_%s_delta" % key] = str(ti[key] - before[1][key])
            rc, out = run(["vm_stat"], 10)
            row.update(parse_vm_stat(out))
            rc, out = run(["sysctl", "-n", "vm.swapusage"], 10)
            row["swap_used_mb"] = parse_swap_used(out)
            with open(paths["metrics"], "a") as f:
                f.write("\t".join(row.get(c, "") for c in METRIC_COLUMNS) + "\n")
        except Exception:
            err.exc("metrics row")
        next_tick += 1.0
        delay = next_tick - time.monotonic()
        if delay < 0:
            next_tick = time.monotonic()
            delay = 0
        time.sleep(delay)


# ---------------------------------------------------------------------------
# Capture: per-thread state, two concurrent `sample` runs, a system snapshot.


def section(f, label, cmd, head=None):
    started = utc()
    rc, out = run(cmd, timeout=20)
    if head is not None:
        out = "\n".join(out.splitlines()[:head]) + "\n"
    f.write("\n=== %s (started %s, exit %s) ===\n$ %s\n%s" % (label, started, rc, " ".join(cmd), out))
    f.flush()


def launch_sampler(args, role, pid, base, err):
    info = {
        "role": role, "pid": pid, "file": "%s-%s.txt" % (base, role),
        "status_file": "%s-%s.status" % (base, role),
        "launch_utc": utc(), "launch_mono": time.monotonic(),
        "sampling_start_utc": None, "sampling_start_mono": None,
        "sampling_end_utc": None, "sampling_end_mono": None,
        "exit_utc": None, "exit_mono": None, "exit_code": None, "status_lines": [],
    }
    try:
        with open(info["status_file"], "wb") as status:
            proc = subprocess.Popen(
                ["sample", str(pid), str(args.sample_seconds), "10", "-mayDie", "-file", info["file"]],
                stdin=subprocess.DEVNULL, stdout=status, stderr=subprocess.STDOUT)
    except Exception as e:
        info["exit_code"] = "launch failed: %r" % (e,)
        err.exc("launch sample %s" % role)
        return info, None
    return info, proc


def watch_sampler(info, proc, timeout, err):
    """Polls the sampler's status file (its stdout) for the lines that mark
    the start and end of the sampling proper, then records its exit."""
    seen = 0
    deadline = time.monotonic() + timeout
    try:
        while True:
            finished = proc.poll() is not None
            try:
                with open(info["status_file"], "rb") as f:
                    data = f.read()
            except Exception:
                data = b""
            if len(data) > seen:
                now_m, now_w = time.monotonic(), time.time()
                complete = data[:data.rfind(b"\n") + 1] if finished is False else data
                for raw in complete[seen:].splitlines():
                    line = raw.decode("utf-8", "replace").rstrip()
                    if not line:
                        continue
                    if len(info["status_lines"]) < 40:
                        info["status_lines"].append([utc(now_w), line[:400]])
                    if line.startswith("Sampling process") and info["sampling_start_mono"] is None:
                        info["sampling_start_mono"], info["sampling_start_utc"] = now_m, utc(now_w)
                    elif line.startswith("Sampling completed") and info["sampling_end_mono"] is None:
                        info["sampling_end_mono"], info["sampling_end_utc"] = now_m, utc(now_w)
                seen = len(complete)
            if finished:
                info["exit_code"] = proc.returncode
                info["exit_utc"] = utc()
                info["exit_mono"] = time.monotonic()
                return
            if time.monotonic() > deadline:
                proc.kill()
                try:
                    proc.wait(5)
                except Exception:
                    pass
                info["exit_code"] = "killed after %ss" % timeout
                info["exit_utc"] = utc()
                info["exit_mono"] = time.monotonic()
                return
            time.sleep(0.05)
    except Exception:
        err.exc("watch sample %s" % info["role"])


def capture_worker(args, rec, paths, err):
    try:
        idx = rec["index"]
        base = os.path.join(args.out_dir, "%s-stall-%d" % (args.name, idx))
        helper, driver = rec["helper_pid"], rec["driver_pid"]
        watchers = []
        with open(base + "-sys.txt", "w") as f:
            f.write("=== stall capture %d of pass %s: triggered %s after %.2f s without a progress line ===\n"
                    "helper pid %s, driver pid %s, log byte offset %d\n"
                    % (idx, args.name, rec["trigger_utc"], rec["quiet_seconds_at_trigger"],
                       helper, driver, rec["log_byte_offset"]))
            # Per-thread state first, before `sample` attaches and perturbs it.
            section(f, "per-thread state of the helper", ["ps", "-M", "-p", str(helper)])
            for role, pid in (("helper", helper), ("driver", driver)):
                if pid is None:
                    continue
                info, proc = launch_sampler(args, role, pid, base, err)
                rec["samplers"][role] = info
                if proc is not None:
                    t = threading.Thread(target=watch_sampler,
                                         args=(info, proc, args.sample_seconds + 120, err))
                    t.daemon = True
                    t.start()
                    watchers.append(t)
            if driver is not None:
                section(f, "per-thread state of the driver", ["ps", "-M", "-p", str(driver)])
            section(f, "top 25 processes by CPU",
                    ["ps", "-axww", "-o", "pid,ppid,%cpu,rss,state,etime,comm", "-r"], head=26)
            section(f, "vm_stat", ["vm_stat"])
            section(f, "sysctl", ["sysctl", "vm.swapusage", "vm.loadavg"])
        for t in watchers:
            t.join()
    except Exception:
        err.exc("capture %s" % rec.get("index"))
    finally:
        rec["end_mono"] = time.monotonic()
        rec["end_utc"] = utc()
        rec["done"] = True


def capture_record(rec, events, complete):
    """The jsonl object for one capture. `events` holds (mono, wall) arrival
    times of every progress line; those after rec['events_index'] arrived
    after the trigger."""
    after = events[rec["events_index"]:]
    helper = dict(rec["samplers"].get("helper") or {})
    ws = helper.get("sampling_start_mono")
    we = helper.get("sampling_end_mono")
    source = "sample status lines"
    if ws is None:
        source = "estimate: start is the sampler launch, end start + sample-seconds"
        ws = helper.get("launch_mono") or rec["trigger_mono"]
        we = None
    if we is None:
        if source == "sample status lines":
            source = "estimate: start from status lines, end start + sample-seconds"
        we = ws + rec["sample_seconds"]
    during = [e for e in after if ws <= e[0] <= we]
    before_window = [e for e in after if e[0] < ws]
    first_after = after[0] if after else None
    samplers = {}
    # dict()/list() copies: on a partial record the capture threads may still
    # be writing these.
    for role, info in list(rec["samplers"].items()):
        info = dict(info)
        samplers[role] = {k: v for k, v in info.items() if not k.endswith("_mono")}
        samplers[role]["status_lines"] = list(info.get("status_lines") or [])
        if info.get("sampling_start_mono") is not None:
            samplers[role]["launch_to_sampling_start_s"] = round(
                info["sampling_start_mono"] - info["launch_mono"], 3)
    return {
        "index": rec["index"],
        "complete": complete,
        "trigger_utc": rec["trigger_utc"],
        "quiet_seconds_at_trigger": round(rec["quiet_seconds_at_trigger"], 3),
        "last_progress_before_trigger_utc": rec["last_progress_utc"],
        "log_byte_offset": rec["log_byte_offset"],
        "helper_pid": rec["helper_pid"],
        "driver_pid": rec["driver_pid"],
        "sample_window_start_utc": utc(rec["trigger_wall"] + (ws - rec["trigger_mono"])),
        "sample_window_end_utc": utc(rec["trigger_wall"] + (we - rec["trigger_mono"])),
        "sample_window_source": source,
        "progress_lines_during_sample": len(during),
        "first_progress_during_sample_utc": utc(during[0][1]) if during else None,
        "progress_lines_between_trigger_and_sample_start": len(before_window),
        "first_progress_after_trigger_utc": utc(first_after[1]) if first_after else None,
        "stall_seconds_observed": (round(first_after[0] - rec["last_progress_mono"], 3)
                                   if first_after else None),
        "capture_end_utc": rec.get("end_utc"),
        "samplers": samplers,
        "sys_file": os.path.basename(rec["sys_file"]),
        "progress_arrival_resolution_s": POLL_SECONDS,
    }


# ---------------------------------------------------------------------------
# Heartbeat: a separate process, so it shares no lock (not even the GIL) and
# no blocking call with the follower or the capture code.


def heartbeat_main(args):
    path = os.path.join(args.out_dir, "%s-heartbeat.tsv" % args.name)
    err = AppendLog(os.path.join(args.out_dir, "%s-sampler.err" % args.name), rate_limit=True)
    parent = args.parent_pid
    ticks = overshoots = 0
    max_mono = max_wall = 0.0
    max_mono_utc = max_wall_utc = None
    start_wall, start_mono = time.time(), time.monotonic()
    reason = "unknown"

    def on_term(signum, frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    f = open(path, "a", buffering=1)
    try:
        f.write("# heartbeat pid %d for pass %s, parent %d, started %s; rows are ticks of "
                "time.sleep(%.1f) that overshot by >= %.2f s on either clock\n"
                % (os.getpid(), args.name, parent, utc(start_wall), HEARTBEAT_TICK,
                   HEARTBEAT_REPORT_OVERSHOOT))
        f.write("utc_tick_end\texpected_s\tactual_monotonic_s\tactual_wall_s\t"
                "overshoot_monotonic_s\tovershoot_wall_s\n")
        while True:
            m0, w0 = time.monotonic(), time.time()
            time.sleep(HEARTBEAT_TICK)
            m1, w1 = time.monotonic(), time.time()
            ticks += 1
            om, ow = (m1 - m0) - HEARTBEAT_TICK, (w1 - w0) - HEARTBEAT_TICK
            if om > max_mono:
                max_mono, max_mono_utc = om, utc(w1)
            if ow > max_wall:
                max_wall, max_wall_utc = ow, utc(w1)
            if om >= HEARTBEAT_REPORT_OVERSHOOT or ow >= HEARTBEAT_REPORT_OVERSHOOT:
                overshoots += 1
                f.write("%s\t%.1f\t%.3f\t%.3f\t%.3f\t%.3f\n"
                        % (utc(w1), HEARTBEAT_TICK, m1 - m0, w1 - w0, om, ow))
            if os.getppid() != parent:
                reason = "parent exited"
                break
    except SystemExit:
        reason = "terminated"
    except Exception:
        reason = "error"
        err.exc("heartbeat")
    finally:
        try:
            elapsed = time.monotonic() - start_mono
            f.write("# summary\tstart %s\tend %s\telapsed_s %.3f\tticks %d\texpected_ticks_if_never_late %d"
                    "\tovershoots %d\tmax_overshoot_monotonic_s %.3f at %s\tmax_overshoot_wall_s %.3f at %s"
                    "\tstop %s\n"
                    % (utc(start_wall), utc(), elapsed, ticks, int(elapsed / HEARTBEAT_TICK),
                       overshoots, max_mono, max_mono_utc, max_wall, max_wall_utc, reason))
            f.close()
        except Exception:
            err.exc("heartbeat summary")


def start_heartbeat(args, err, ev):
    try:
        errf = open(os.path.join(args.out_dir, "%s-sampler.err" % args.name), "ab")
        proc = subprocess.Popen(
            [sys.executable, "-I", os.path.abspath(__file__), "--heartbeat-child",
             "--out-dir", args.out_dir, "--name", args.name, "--parent-pid", str(os.getpid())],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=errf)
        errf.close()
        ev("heartbeat started: pid %d" % proc.pid)
        return proc
    except Exception:
        err.exc("start heartbeat")
        return None


def stop_heartbeat(proc, err):
    if proc is None:
        return
    try:
        proc.terminate()
        proc.wait(2)
    except Exception:
        try:
            proc.kill()
        except Exception:
            err.exc("stop heartbeat")


# ---------------------------------------------------------------------------
# The follower: main thread.


def start_whole_sample(args, st, paths, err, ev):
    """--mode whole: ONE long `sample` of the helper, run through a detached
    shell wrapper (own session) so it outlives this sampler and finishes
    writing its report after the helper exits. The wrapper records sample's
    exit status in <name>-whole-helper.exit."""
    base = os.path.join(args.out_dir, "%s-whole-helper" % args.name)
    pid = st.helper_pid
    started = utc()
    rec = {"mode": "whole", "helper_pid": pid, "sample_start_utc": started,
           "sample_file": base + ".txt", "status_file": base + ".status",
           "exit_file": base + ".exit", "sample_seconds": 900,
           "sample_exit_status": None, "sample_exit_status_note": "see exit_file"}
    try:
        with open(base + ".status", "wb") as status:
            subprocess.Popen(
                ["sh", "-c", 'sample "$1" 900 10 -mayDie -file "$2"; echo $? > "$3"',
                 "sh", str(pid), base + ".txt", base + ".exit"],
                stdin=subprocess.DEVNULL, stdout=status, stderr=subprocess.STDOUT,
                start_new_session=True)
        ev("whole-pass sample started on helper pid %d" % pid)
    except Exception:
        rec["launch_error"] = True
        err.exc("launch whole sample")
    with open(paths["captures"], "a") as f:
        f.write(json.dumps(rec) + "\n")


def follow(args, st, paths, err, ev):
    whole_started = False
    fh, ino, buf = None, None, b""
    events = []  # (mono, wall) arrival of each progress line
    cap = None
    last_capture_end = None
    start_mono = time.monotonic()
    finishing_since = None
    while True:
        now, wall = time.monotonic(), time.time()
        try:
            if fh is None and os.path.exists(args.log):
                fh = open(args.log, "rb")
                ino = os.fstat(fh.fileno()).st_ino
                ev("log opened: %s" % args.log)
            if fh is not None:
                try:
                    cur_ino = os.stat(args.log).st_ino
                except OSError:
                    cur_ino = ino
                if cur_ino != ino:
                    fh.close()
                    fh = open(args.log, "rb")
                    ino = os.fstat(fh.fileno()).st_ino
                    buf, st.consumed = b"", 0
                    ev("log replaced; reading from its start")
                if os.fstat(fh.fileno()).st_size < st.consumed + len(buf):
                    fh.seek(0)
                    buf, st.consumed = b"", 0
                    ev("log truncated; reading from its start")
                chunk = fh.read()
                if chunk:
                    parts = (buf + chunk).split(b"\n")
                    buf = parts.pop()
                    for raw in parts:
                        st.consumed += len(raw) + 1
                        text = raw.decode("utf-8", "replace").replace("\r", "")
                        text = ANSI.sub("", text).lstrip("﻿ \t")
                        if not st.run_started:
                            if not RUN_STARTED.match(text):
                                continue
                            st.run_started = True
                            ev("run started at log byte %d" % st.consumed)
                        if text[:1] in PROGRESS_GLYPHS:
                            st.progress_total += 1
                            st.last_progress_mono, st.last_progress_wall = now, wall
                            events.append((now, wall))
                        if RUN_FINISHED.match(text) and not st.run_finished:
                            st.run_finished = True
                            ev("run finished at log byte %d: %s" % (st.consumed, text[:200]))
        except Exception:
            err.exc("follow log")

        try:
            if cap is not None and cap.get("done"):
                with open(paths["captures"], "a") as f:
                    f.write(json.dumps(capture_record(cap, events, True)) + "\n")
                last_capture_end = cap["end_mono"]
                ev("capture %d done" % cap["index"])
                cap = None
                st.capturing = False
        except Exception:
            err.exc("finish capture")
            cap = None
            st.capturing = False

        if (args.mode == "whole" and not whole_started and st.run_started
                and st.helper_pid is not None and alive(st.helper_pid)):
            whole_started = True
            try:
                start_whole_sample(args, st, paths, err, ev)
            except Exception:
                err.exc("whole sample")

        reason = None
        if st.stop:
            reason = st.stop_reason or "signal"
        elif st.run_finished:
            reason = "run finished"
        elif st.run_started and st.helper_pid is not None and not alive(st.helper_pid):
            reason = "helper exited"
        elif not alive(args.pipeline_pid):
            reason = "pipeline exited"
        elif os.getppid() == 1:
            reason = "parent exited"
        elif now - start_mono > args.max_runtime:
            reason = "max runtime"
        if reason is not None:
            if cap is None:
                st.stop_reason = reason
                return
            if finishing_since is None:
                finishing_since = now
                ev("stopping (%s); waiting for capture %d" % (reason, cap["index"]))
            if st.stop:
                waited, limit = now - (st.stop_mono or now), TERM_GRACE_SECONDS
            else:
                waited, limit = now - finishing_since, FINISH_WAIT_SECONDS
            if waited >= limit:
                try:
                    with open(paths["captures"], "a") as f:
                        f.write(json.dumps(capture_record(cap, events, False)) + "\n")
                except Exception:
                    err.exc("partial capture record")
                ev("gave up waiting for capture %d; its sample processes are left to finish"
                   % cap["index"])
                st.stop_reason = reason
                return
        elif (args.mode == "stall" and cap is None and st.run_started
              and st.captures_started < args.max_captures
              and st.helper_pid is not None and st.last_progress_mono is not None):
            quiet = now - st.last_progress_mono
            spaced = last_capture_end is None or (
                st.last_progress_mono > last_capture_end
                and now - last_capture_end >= MIN_SECONDS_AFTER_CAPTURE)
            if quiet >= args.quiet_seconds and spaced and alive(st.helper_pid):
                st.captures_started += 1
                cap = {
                    "index": st.captures_started, "done": False,
                    "trigger_mono": now, "trigger_wall": wall, "trigger_utc": utc(wall),
                    "quiet_seconds_at_trigger": quiet,
                    "last_progress_mono": st.last_progress_mono,
                    "last_progress_utc": utc(st.last_progress_wall),
                    "log_byte_offset": st.consumed, "events_index": len(events),
                    "helper_pid": st.helper_pid, "driver_pid": st.driver_pid,
                    "sample_seconds": float(args.sample_seconds), "samplers": {},
                    "sys_file": os.path.join(args.out_dir, "%s-stall-%d-sys.txt"
                                             % (args.name, st.captures_started)),
                }
                st.capturing = True
                ev("capture %d triggered after %.2f s quiet at log byte %d"
                   % (cap["index"], quiet, st.consumed))
                t = threading.Thread(target=capture_worker, args=(args, cap, paths, err))
                t.daemon = True
                t.start()
        time.sleep(POLL_SECONDS)


def sampler_main(args):
    def path(suffix):
        return os.path.join(args.out_dir, "%s-%s" % (args.name, suffix))

    paths = {k: path(v) for k, v in (
        ("metrics", "metrics.tsv"), ("captures", "captures.jsonl"),
        ("processes", "processes.txt"))}
    err = AppendLog(path("sampler.err"), rate_limit=True)
    ev = AppendLog(path("sampler.log"))
    st = State()

    def on_signal(signum, frame):
        if not st.stop:
            st.stop_mono = time.monotonic()
            st.stop_reason = "signal %d" % signum
            st.stop = True

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(sig, on_signal)
        except Exception:
            err.exc("signal %s" % sig)
    ev("sampler started: pid %d, python %s, args %r"
       % (os.getpid(), sys.version.split()[0], vars(args)))
    heartbeat = start_heartbeat(args, err, ev)
    metrics = threading.Thread(target=metrics_worker, args=(args, st, paths, err, ev))
    metrics.daemon = True
    metrics.start()
    try:
        follow(args, st, paths, err, ev)
    except Exception:
        err.exc("follow")
    finally:
        st.metrics_stop = True
        stop_heartbeat(heartbeat, err)
        metrics.join(1.0)
        ev("sampler exiting (%s): run_started=%s run_finished=%s progress_lines=%d captures=%d"
           % (st.stop_reason, st.run_started, st.run_finished, st.progress_total,
              st.captures_started))


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--log")
    p.add_argument("--pipeline-pid", type=int)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--quiet-seconds", type=float, default=1.0)
    p.add_argument("--sample-seconds", type=int, default=2)
    p.add_argument("--max-captures", type=int, default=12)
    p.add_argument("--max-runtime", type=float, default=1800.0)
    p.add_argument("--mode", choices=("stall", "whole"), default="stall")
    p.add_argument("--heartbeat-child", action="store_true")
    p.add_argument("--parent-pid", type=int)
    args = p.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    if args.heartbeat_child:
        heartbeat_main(args)
        return
    if not args.log or args.pipeline_pid is None:
        raise ValueError("--log and --pipeline-pid are required")
    sampler_main(args)


if __name__ == "__main__":
    try:
        main()
    except (SystemExit, KeyboardInterrupt):
        pass
    except BaseException:
        try:
            out_dir = name = None
            argv = sys.argv
            if "--out-dir" in argv:
                out_dir = argv[argv.index("--out-dir") + 1]
            if "--name" in argv:
                name = argv[argv.index("--name") + 1]
            target = os.path.join(out_dir or "/tmp", "%s-sampler.err" % (name or "stall-sampler"))
            with open(target, "a") as f:
                f.write("%s fatal\n%s\n" % (utc(), traceback.format_exc()))
        except BaseException:
            pass
    finally:
        os._exit(0)
