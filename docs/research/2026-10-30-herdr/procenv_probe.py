"""Read-only probe: can we read another process's environment on macOS?

Uses sysctl(CTL_KERN, KERN_PROCARGS2, pid), the same call herdr uses in
src/platform/macos.rs (kern_procargs2 / procargs2_env).

Prints only: errno on failure, argc, number of env entries, the env *names*
(when --names), and the *values* of an allowlist of identity variables. It
never prints any other value, so secrets in env do not reach the terminal.

Usage:
  python3 -I procenv_probe.py PID [PID ...] [--names]
  python3 -I procenv_probe.py --scan [--want VAR]   # every pid, timed
"""
import ctypes
import ctypes.util
import os
import sys
import time

CTL_KERN = 1
KERN_PROCARGS2 = 49
KERN_ARGMAX = 8

SHOW_VALUES = {
    "HERDR_PROBE", "HERDR_PANE_ID", "HERDR_ENV", "HERDR_AGENT",
    "TBD_WORKTREE_ID", "TBD_TERMINAL_ID", "LATE_SETENV",
}

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)


def argmax():
    mib = (ctypes.c_int * 2)(CTL_KERN, KERN_ARGMAX)
    val = ctypes.c_int(0)
    size = ctypes.c_size_t(ctypes.sizeof(val))
    if libc.sysctl(mib, 2, ctypes.byref(val), ctypes.byref(size), None, 0) != 0:
        return 1 << 20
    return val.value


ARGMAX = argmax()


def procargs2(pid):
    """Return (bytes, None) or (None, errno)."""
    mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
    buf = ctypes.create_string_buffer(ARGMAX)
    size = ctypes.c_size_t(ARGMAX)
    rc = libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0)
    if rc != 0:
        return None, ctypes.get_errno()
    return buf.raw[: size.value], None


def parse(raw):
    argc = int.from_bytes(raw[:4], sys.byteorder)
    rest = raw[4:]
    end = rest.find(b"\0")
    exec_path = rest[:end].decode(errors="replace")
    pos = end
    # The NUL padding after exec_path cannot be told apart from an empty
    # argv[0], so a process with one parses with argv shifted by one entry.
    # Nothing prints argv for that reason; only allowlisted env values print.
    while pos < len(rest) and rest[pos] == 0:
        pos += 1
    argv = []
    for _ in range(argc):
        e = rest.find(b"\0", pos)
        if e < 0:
            break
        argv.append(rest[pos:e].decode(errors="replace"))
        pos = e + 1
    env = []
    while pos < len(rest):
        e = rest.find(b"\0", pos)
        if e < 0 or e == pos:
            break
        env.append(rest[pos:e].decode(errors="replace"))
        pos = e + 1
    return argc, exec_path, argv, env


def describe(pid, names):
    raw, err = procargs2(pid)
    if raw is None:
        print(f"pid {pid}: sysctl(KERN_PROCARGS2) failed errno={err} ({os.strerror(err)})")
        return
    argc, exec_path, argv, env = parse(raw)
    keys = [kv.split("=", 1)[0] for kv in env]
    shown = {k: v for k, v in (kv.split("=", 1) for kv in env if "=" in kv) if k in SHOW_VALUES}
    print(f"pid {pid}: OK exec={exec_path} argc={argc} env_entries={len(env)}")
    for k, v in sorted(shown.items()):
        print(f"    {k}={v}")
    if names:
        print("    env names:", " ".join(sorted(keys)))


def all_pids():
    n = libproc.proc_listallpids(None, 0)
    cap = n + 256
    arr = (ctypes.c_int * cap)()
    got = libproc.proc_listallpids(arr, ctypes.sizeof(arr))
    return [p for p in arr[:got] if p > 0]


def scan(want):
    pids = all_pids()
    t0 = time.perf_counter()
    ok = 0
    errs = {}
    hits = []
    total_bytes = 0
    for pid in pids:
        raw, err = procargs2(pid)
        if raw is None:
            errs[err] = errs.get(err, 0) + 1
            continue
        ok += 1
        total_bytes += len(raw)
        if want:
            _, exec_path, argv, env = parse(raw)
            for kv in env:
                if kv.startswith(want + "="):
                    hits.append((pid, exec_path, kv))
    dt = time.perf_counter() - t0
    my_uid = os.getuid()
    print(f"pids={len(pids)} readable={ok} total_bytes={total_bytes} elapsed_ms={dt*1000:.1f} (uid {my_uid})")
    for e, c in sorted(errs.items()):
        print(f"  errno {e} ({os.strerror(e)}): {c} pids")
    if want:
        print(f"  pids carrying {want}= : {len(hits)}")
        for pid, exe, kv in hits[:40]:
            shown = kv if want in SHOW_VALUES else f"{want}=<value not in allowlist>"
            print(f"    {pid} {exe} {shown}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--scan" in args:
        want = None
        if "--want" in args:
            want = args[args.index("--want") + 1]
        scan(want)
    else:
        names = "--names" in args
        for a in args:
            if a.isdigit():
                describe(int(a), names)
