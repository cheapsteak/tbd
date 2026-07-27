#!/usr/bin/env python3
"""Drive a `tmux -CC` control-mode client over a real pty and dump the transcript.

Used by scripts/nightly-tmux-probes.sh for probes P6/P7/P8. It exists as a
separate file for one reason: **control mode requires a tty.** Feeding
`tmux -CC attach` from a pipe or a fifo dies immediately with

    tcgetattr failed: Operation not supported on socket

and macOS `script -q /dev/null` does not rescue it (it fails the same way on its
own stdin). A pty has to be allocated explicitly, which shell cannot do.

Writes the raw transcript to stdout with `@@MARK <label>` lines separating
phases and a final `@@EXIT <status>` line. It asserts nothing — every claim is
checked by the shell harness, so the probe definitions all live in one file.

Usage: nightly-tmux-cc-probe.py <socket-name> <session-name>
"""

import os
import pty
import select
import subprocess
import sys
import termios
import time

# Each phase gets a fixed drain window. These are transcript-collection budgets,
# not synchronisation primitives: the shell harness asserts on what the
# transcript contains, so a slow runner yields a late line, never a wrong verdict.
ATTACH_DRAIN = 2.0
COMMAND_DRAIN = 1.5
DETACH_DRAIN = 2.5
EXIT_WAIT = 3.0


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: nightly-tmux-cc-probe.py <socket> <session>\n")
        return 2
    socket_name, session = sys.argv[1], sys.argv[2]

    master, slave = pty.openpty()
    # Turn off echo and canonical mode on the slave: with echo on, everything we
    # write comes back in the transcript and a "%begin block count" probe would
    # be counting its own input.
    attrs = termios.tcgetattr(slave)
    attrs[3] &= ~(termios.ECHO | termios.ICANON)
    termios.tcsetattr(slave, termios.TCSANOW, attrs)

    proc = subprocess.Popen(
        ["tmux", "-L", socket_name, "-CC", "attach", "-t", session],
        stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
    )
    os.close(slave)

    chunks: list[str] = []

    def drain(seconds: float) -> None:
        end = time.time() + seconds
        while True:
            remaining = end - time.time()
            if remaining <= 0:
                return
            readable, _, _ = select.select([master], [], [], remaining)
            if not readable:
                return
            try:
                data = os.read(master, 65536)
            except OSError:
                return
            if not data:
                return
            chunks.append(data.decode("utf-8", "replace"))

    def mark(label: str) -> None:
        chunks.append("\n@@MARK %s\n" % label)

    def send(text: str) -> None:
        os.write(master, text.encode())

    try:
        drain(ATTACH_DRAIN)
        mark("attached")

        send("display-message -p CCPROBE_OK\n")
        drain(COMMAND_DRAIN)
        mark("after-good-command")

        send("this-is-not-a-command\n")
        drain(COMMAND_DRAIN)
        mark("after-bad-command")

        # Whitespace-only line: claimed to produce no command blocks at all.
        send("   \n")
        drain(COMMAND_DRAIN)
        mark("after-whitespace-line")

        # Blank line: claimed to detach the client.
        send("\n")
        drain(DETACH_DRAIN)
        mark("after-blank-line")

        try:
            status = str(proc.wait(timeout=EXIT_WAIT))
        except subprocess.TimeoutExpired:
            status = "alive"
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        os.close(master)

    chunks.append("\n@@EXIT %s\n" % status)
    sys.stdout.write("".join(chunks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
