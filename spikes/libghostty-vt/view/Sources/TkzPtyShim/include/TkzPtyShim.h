// Adapted from tkzmux c961533 (MIT, see third_party/tkzmux).
// TkzPtyShim — the only C code that runs in the forked child (no Swift runtime after fork()).
// Everything between fork() and execve() is async-signal-safe by construction: no malloc,
// no Objective-C, no Swift, no locks that the parent could hold at fork time.
//
// Contract:
//   openpty(&master, &slave, NULL, NULL, &ws)   with the initial winsize
//   → pipe2-style FD_CLOEXEC error pipe
//   → fork()
//     child : setsid(), ioctl(slave, TIOCSCTTY, 0), dup2(slave, 0/1/2), close spare fds,
//             empty signal mask, all handlers back to SIG_DFL, chdir(cwd), execve(...)
//             On exec failure the child writes errno to the pipe and _exit(127)s.
//     parent: close(slave), O_NONBLOCK|FD_CLOEXEC on master, read the error pipe
//             (EOF = exec succeeded; a payload = exec failed with that errno).
//
// posix_spawn cannot do the tty setup (setsid + TIOCSCTTY must happen in the child between
// fork and exec), which is why this is a hand-rolled fork/exec.
#pragma once

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Shim ABI version. Bumped when the spawn contract changes.
/// 1 = M0.1 stub, 2 = M1.2 spawn/resize/proc-info contract.
int32_t tkz_pty_shim_version(void);

/// What to launch. All pointers are borrowed for the duration of the call only.
typedef struct {
    /// Absolute path of the executable handed to execve(). Required.
    const char *path;
    /// NULL-terminated argv, including argv[0] (which may differ from `path`, e.g. "-zsh"). Required.
    char *const *argv;
    /// NULL-terminated "KEY=VALUE" environment handed to execve(). Required (never inherited implicitly).
    char *const *envp;
    /// Working directory for the child. May be NULL (child keeps the parent's cwd).
    /// If chdir() fails the child still execs, from the inherited cwd.
    const char *cwd;
    /// Initial terminal size. Cells, then the cell size in pixels (0 = unknown).
    uint16_t rows;
    uint16_t cols;
    uint16_t cell_width_px;
    uint16_t cell_height_px;
} tkz_pty_spawn_options;

/// Result of a successful spawn.
typedef struct {
    /// Pty master, already O_NONBLOCK|FD_CLOEXEC. The caller owns it and must close() it.
    int master_fd;
    /// Child pid. The caller must waitpid() it.
    pid_t pid;
} tkz_pty_spawn_result;

/// Spawn `opts.path` on a fresh pty with the child as session leader of a new session whose
/// controlling terminal is the pty slave (i.e. job control works).
///
/// Returns 0 on success (`out` filled in), otherwise a positive errno-style code. On failure no
/// fd is leaked and no zombie is left behind: a child that failed to exec is reaped here.
/// Thread-safe: serialized internally so a concurrent fork cannot inherit another spawn's fds.
int32_t tkz_pty_spawn(const tkz_pty_spawn_options *opts, tkz_pty_spawn_result *out);

/// TIOCSWINSZ on the master. `px_w`/`px_h` are the *total* pixel size (cols*cellW, rows*cellH),
/// 0 when unknown. Returns 0 or an errno.
int32_t tkz_pty_set_size(int master_fd, uint16_t rows, uint16_t cols, uint16_t px_w, uint16_t px_h);

/// tcgetpgrp(master): the process group currently in the foreground of the pty.
/// Returns the pgid (> 0) or -1 (errno set) when there is none.
pid_t tkz_pty_foreground_pgid(int master_fd);

/// proc_pidpath(): absolute executable path of `pid` into `buf`.
/// Returns the byte length written (> 0) or 0 on failure. `len` should be >= 4096 (PROC_PIDPATHINFO_MAXSIZE).
int32_t tkz_proc_path(pid_t pid, char *buf, uint32_t len);

/// proc_pidinfo(PROC_PIDVNODEPATHINFO).pvi_cdir.vip_path: current directory of `pid` into `buf`.
/// Returns the byte length written (> 0) or 0 on failure (including EPERM for foreign-uid processes).
int32_t tkz_proc_cwd(pid_t pid, char *buf, uint32_t len);

#ifdef __cplusplus
}
#endif
