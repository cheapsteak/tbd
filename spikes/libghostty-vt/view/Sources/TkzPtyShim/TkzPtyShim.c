// Adapted from tkzmux c961533 (MIT, see third_party/tkzmux).
#include "TkzPtyShim.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int32_t tkz_pty_shim_version(void) { return 2; }

// Spawning is serialized: fork() duplicates the *whole* fd table, so a spawn running on another
// thread between openpty()/pipe() and the fcntl() that marks those fds FD_CLOEXEC would leak them
// into this child (a leaked error-pipe write end means the other spawn never sees EOF and hangs).
static pthread_mutex_t tkz_spawn_lock = PTHREAD_MUTEX_INITIALIZER;

static int tkz_set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

// Everything below runs in the forked child: async-signal-safe calls only, and it must never
// return — either execve() replaces the image or we _exit() after reporting errno.
__attribute__((noreturn))
static void tkz_child_exec(const tkz_pty_spawn_options *opts, int slave, int master, int err_w) {
    int failure = 0;

    if (setsid() < 0) failure = errno;
    if (!failure && ioctl(slave, TIOCSCTTY, (int)0) < 0) failure = errno;

    if (!failure) {
        if (dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 ||
            dup2(slave, STDERR_FILENO) < 0) {
            failure = errno;
        }
    }

    if (!failure) {
        if (slave > STDERR_FILENO) close(slave);
        close(master);

        // A pristine signal environment: no inherited mask, no inherited handlers.
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SIG_DFL;
        sigemptyset(&sa.sa_mask);
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig == SIGKILL || sig == SIGSTOP) continue;
            sigaction(sig, &sa, NULL);
        }

        // A stale worktree must not make the session unlaunchable: keep the inherited cwd instead.
        if (opts->cwd != NULL) (void)chdir(opts->cwd);

        execve(opts->path, opts->argv, opts->envp);
        failure = errno;
    }

    if (failure == 0) failure = ENOEXEC;
    ssize_t ignored = write(err_w, &failure, sizeof(failure));
    (void)ignored;
    _exit(127);
}

int32_t tkz_pty_spawn(const tkz_pty_spawn_options *opts, tkz_pty_spawn_result *out) {
    if (opts == NULL || out == NULL || opts->path == NULL || opts->argv == NULL ||
        opts->envp == NULL) {
        return EINVAL;
    }

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = opts->rows;
    ws.ws_col = opts->cols;
    ws.ws_xpixel = (unsigned short)(opts->cols * opts->cell_width_px);
    ws.ws_ypixel = (unsigned short)(opts->rows * opts->cell_height_px);

    pthread_mutex_lock(&tkz_spawn_lock);

    int master = -1, slave = -1;
    if (openpty(&master, &slave, NULL, NULL, &ws) < 0) {
        int32_t err = errno ? errno : EIO;
        pthread_mutex_unlock(&tkz_spawn_lock);
        return err;
    }

    int err_pipe[2] = {-1, -1};
    if (pipe(err_pipe) < 0) {
        int32_t err = errno ? errno : EIO;
        close(master);
        close(slave);
        pthread_mutex_unlock(&tkz_spawn_lock);
        return err;
    }

    // Mark everything CLOEXEC *before* forking. The child clears what it needs explicitly.
    if (tkz_set_cloexec(master) < 0 || tkz_set_cloexec(err_pipe[0]) < 0 ||
        tkz_set_cloexec(err_pipe[1]) < 0) {
        int32_t err = errno ? errno : EIO;
        close(master);
        close(slave);
        close(err_pipe[0]);
        close(err_pipe[1]);
        pthread_mutex_unlock(&tkz_spawn_lock);
        return err;
    }

    pid_t pid = fork();
    if (pid < 0) {
        int32_t err = errno ? errno : EAGAIN;
        close(master);
        close(slave);
        close(err_pipe[0]);
        close(err_pipe[1]);
        pthread_mutex_unlock(&tkz_spawn_lock);
        return err;
    }

    if (pid == 0) {
        close(err_pipe[0]);
        tkz_child_exec(opts, slave, master, err_pipe[1]);
        // unreachable
    }

    close(slave);
    close(err_pipe[1]);
    pthread_mutex_unlock(&tkz_spawn_lock);

    // EOF = the child reached execve(); a payload = it failed, with that errno.
    int child_errno = 0;
    for (;;) {
        ssize_t n = read(err_pipe[0], &child_errno, sizeof(child_errno));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) child_errno = 0;
        break;
    }
    close(err_pipe[0]);

    if (child_errno != 0) {
        // Reap the failed child here so the caller never sees a zombie for a spawn that failed.
        int status = 0;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        close(master);
        return child_errno;
    }

    int flags = fcntl(master, F_GETFL);
    if (flags >= 0) (void)fcntl(master, F_SETFL, flags | O_NONBLOCK);

    out->master_fd = master;
    out->pid = pid;
    return 0;
}

int32_t tkz_pty_set_size(int master_fd, uint16_t rows, uint16_t cols, uint16_t px_w, uint16_t px_h) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = px_w;
    ws.ws_ypixel = px_h;
    if (ioctl(master_fd, TIOCSWINSZ, &ws) < 0) return errno ? errno : EIO;
    return 0;
}

pid_t tkz_pty_foreground_pgid(int master_fd) { return tcgetpgrp(master_fd); }

int32_t tkz_proc_path(pid_t pid, char *buf, uint32_t len) {
    if (buf == NULL || len == 0) return 0;
    buf[0] = '\0';
    int n = proc_pidpath(pid, buf, len);
    if (n <= 0) return 0;
    return (int32_t)n;
}

int32_t tkz_proc_cwd(pid_t pid, char *buf, uint32_t len) {
    if (buf == NULL || len == 0) return 0;
    buf[0] = '\0';
    struct proc_vnodepathinfo vpi;
    memset(&vpi, 0, sizeof(vpi));
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (n < (int)sizeof(vpi)) return 0;
    size_t path_len = strnlen(vpi.pvi_cdir.vip_path, sizeof(vpi.pvi_cdir.vip_path));
    if (path_len == 0 || path_len >= (size_t)len) return 0;
    memcpy(buf, vpi.pvi_cdir.vip_path, path_len);
    buf[path_len] = '\0';
    return (int32_t)path_len;
}
