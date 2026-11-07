#!/usr/bin/env python3
"""Raw-mode probe: enables the modes named on argv, then logs every byte the terminal sends.

  probe.py LOG [--seq ESC-SEQUENCE ...] [--seconds N]

Each read is one line in LOG, so a wrong encoding is evidence rather than a guess.
"""
import os, select, sys, termios, time, tty

log = open(sys.argv[1], "w", buffering=1)
args = sys.argv[2:]
seconds = 20.0
sequences = []
i = 0
while i < len(args):
    if args[i] == "--seconds":
        seconds = float(args[i + 1]); i += 2
    elif args[i] == "--seq":
        sequences.append(args[i + 1].encode().decode("unicode_escape")); i += 2
    else:
        i += 1
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    for sequence in sequences:
        os.write(1, sequence.encode())
    os.write(1, b"probe ready\r\n")
    deadline = time.time() + seconds
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            continue
        data = os.read(fd, 4096)
        if not data:
            break
        log.write(repr(data) + "\n")
        os.write(1, (repr(data) + "\r\n").encode())
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, saved)
