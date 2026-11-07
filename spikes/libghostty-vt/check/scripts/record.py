#!/usr/bin/env python3
"""Records real TUI output through a pty at a fixed size.

kinds: claude (the real CLI against scripts/claude-stub.py, zero tokens, its default
fullscreen renderer on the alternate screen), claude-classic (the same with
CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1, so it draws on the primary screen with
scrollback), vim, less.
Only what the program wrote to the terminal is stored. Run with python3 -I.
"""
import argparse
import fcntl
import json
import os
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time


# TBD's reply. --ghostty-probe-reply swaps in the one libghostty-vt sends.
PROBE_REPLY = b"\x1b]7501;?\x07"
GHOSTTY_PROBE_REPLY = b"\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x1b\\"


class Session:
    def __init__(self, argv, cols, rows, env, cwd):
        self.master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

        def own_tty():
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(
            argv, stdin=slave, stdout=slave, stderr=slave, cwd=cwd, env=env,
            start_new_session=True, preexec_fn=own_tty, close_fds=True)
        os.close(slave)
        self.out = bytearray()
        self.scanned = 0

    def answer_queries(self):
        """Answers the probes a terminal would, so the program takes its normal path."""
        fresh = bytes(self.out[self.scanned:])
        self.scanned = len(self.out)
        for m in re.finditer(rb"\x1b\]7501;\?(?:\x07|\x1b\\)|\x1b\[0?c|\x1b\[\?(\d+)\$p", fresh):
            s = m.group(0)
            if s.startswith(b"\x1b]"):
                os.write(self.master, PROBE_REPLY)
            elif m.group(1):
                os.write(self.master, b"\x1b[?%s;2$y" % m.group(1))   # known, currently reset
            else:
                os.write(self.master, b"\x1b[?62;22c")

    def pump(self, quiet, limit, until=None):
        """Reads until `quiet` seconds of silence, `until` appears, the child exits, or `limit`."""
        start = last = time.monotonic()
        while True:
            now = time.monotonic()
            if now - start > limit or now - last > quiet:
                return
            if until and until in self.out:
                return
            r, _, _ = select.select([self.master], [], [], 0.1)
            if r:
                try:
                    d = os.read(self.master, 65536)
                except OSError:
                    return
                if not d:
                    return
                self.out += d
                last = time.monotonic()
                self.answer_queries()
            elif self.proc.poll() is not None:
                return

    def type(self, text, delay=0.03):
        for ch in text:
            os.write(self.master, ch.encode())
            self.pump(delay, delay)

    def finish(self, limit=20):
        self.pump(2, limit)
        for sig in (signal.SIGTERM, signal.SIGKILL):
            if self.proc.poll() is not None:
                break
            try:
                os.killpg(self.proc.pid, sig)
            except PermissionError:   # the leader has exited and is a zombie: poll reaps it
                pass
            time.sleep(0.5)
        self.proc.wait(timeout=5)


def base_env():
    env = {"PATH": os.environ["PATH"], "TERM": "xterm-256color", "COLORTERM": "truecolor",
           "LANG": "en_US.UTF-8", "HOME": os.environ["HOME"]}
    return env


def turn_script(a):
    """Three scripted answers: a long list, rich markdown with wide text, long wrapping lines."""
    numbered = "\n".join(f"{i}. stub answer line {i} of {a.lines} \u2014 filler so the answer scrolls." for i in range(1, a.lines + 1))
    rich = "\n".join([
        "# Heading one", "", "Some **bold**, *italic* and `code` text with \u6f22\u5b57, caf\u00e9, \U0001F600 and \U0001F469\u200D\U0001F4BB.", "",
        "```swift", "let answer = 42 // a comment", "func f(x: Int) -> Int { x + 1 }", "```", "",
        "| name | value |", "|------|-------|", "| a | 1 |", "| \u6f22\u5b57 | 2 |", "",
        "- one", "- two", "  - nested", "", "> quoted text", ""] * 12)
    wrapped = "\n\n".join(f"Paragraph {i}: " + "several words that run on and on " * 12 for i in range(30))
    turns = [{"text": numbered + "\n\nEND-OF-TURN-1"}, {"text": rich + "\n\nEND-OF-TURN-2"}, {"text": wrapped + "\n\nEND-OF-TURN-3"}]
    path = os.path.join(a.scratch, "turns.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(turns, f)
    return path


def claude(a, classic=False):
    work = os.path.join(a.scratch, "claude-run")
    os.makedirs(work, exist_ok=True)
    sandbox = os.path.join(a.scratch, "claude-sandbox-classic" if classic else "claude-sandbox")
    env = base_env()
    argv = [sys.executable, os.path.join(a.repo, "scripts/claude-stub.py"), "--turns", turn_script(a), "--sandbox", sandbox]
    if classic:
        argv += ["--env", "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1"]
    argv += ["--"]
    s = Session(argv, a.cols, a.rows, env, work)
    s.pump(4, 45)
    for n, prompt in enumerate(["say something long", "now some markdown", "now long paragraphs"], 1):
        s.type(prompt + "\r")
        s.pump(8, 60, until=b"END-OF-TURN-%d" % n)
        s.pump(3, 10)
    s.type("/exit\r")
    s.finish()
    return s


def text_file(a):
    path = os.path.join(a.scratch, "pager-input.txt")
    with open(path, "w", encoding="utf-8") as f:
        for i in range(600):
            f.write(f"{i:04d} the quick brown fox jumps over the lazy dog 漢字 ✓ café {'x' * (i % 90)}\n")
    return path


def vim(a):
    env = base_env()
    s = Session(["/usr/bin/vim", "-u", "NONE", "-i", "NONE", "-N", "-n", text_file(a)], a.cols, a.rows, env, a.scratch)
    s.pump(1.5, 10)
    for keys in [":set number\r", ":set hlsearch\r", ":syntax on\r", "G", "gg", "/quick\r", "n", "n",
                 ":vsplit\r", "\x17l", ":split\r", ":q\r", ":q\r", "50%", "ohello from a recording\x1b",
                 "\x06", "\x06", "\x02", "u", ":q!\r"]:
        s.type(keys)
        s.pump(0.4, 2)
    s.finish(5)
    return s


def less(a):
    env = base_env()
    env["LESS"] = ""
    s = Session(["/usr/bin/less", "-R", text_file(a)], a.cols, a.rows, env, a.scratch)
    s.pump(1, 5)
    for keys in [" ", " ", "b", "G", "g", "/fox\r", "n", "n", "\x06", "\x02", "q"]:
        s.type(keys)
        s.pump(0.3, 2)
    s.finish(5)
    return s


def main():
    p = argparse.ArgumentParser()
    p.add_argument("kind", choices=["claude", "claude-classic", "vim", "less"])
    p.add_argument("--out", required=True)
    p.add_argument("--cols", type=int, default=120)
    p.add_argument("--rows", type=int, default=40)
    p.add_argument("--lines", type=int, default=120)
    p.add_argument("--scratch", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--ghostty-probe-reply", action="store_true")
    p.add_argument("--no-probe-reply", action="store_true")
    a = p.parse_args()
    global PROBE_REPLY
    if a.ghostty_probe_reply:
        PROBE_REPLY = GHOSTTY_PROBE_REPLY
    if a.no_probe_reply:
        PROBE_REPLY = b""
    os.makedirs(a.scratch, exist_ok=True)
    s = {"claude": claude, "claude-classic": lambda x: claude(x, True), "vim": vim, "less": less}[a.kind](a)
    with open(a.out, "wb") as f:
        f.write(bytes(s.out))
    print(f"{a.kind}: {len(s.out)} bytes, exit {s.proc.returncode}")


main()
