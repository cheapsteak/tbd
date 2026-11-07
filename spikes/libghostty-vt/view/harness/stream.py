#!/usr/bin/env python3
# Numbered, coloured lines with a checkable tail so garbage after resize can be found by script.
# argv: lines-per-second (0 = flat out), seconds.
import sys, time, os, signal
rate = float(sys.argv[1]) if len(sys.argv) > 1 else 200
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 20
body = "abcdefghijklmnopqrstuvwxyz0123456789" * 3
end = time.monotonic() + secs
n = 0
signal.signal(signal.SIGHUP, lambda *_: os._exit(0))
while time.monotonic() < end:
    n += 1
    colour = 31 + n % 7
    line = f"\x1b[{colour}m{n:08d}\x1b[0m |{body}| {n:08d}\r\n"
    try:
        os.write(1, line.encode())
    except OSError:
        break
    if rate: time.sleep(1 / rate)
os.write(1, f"STREAM-DONE {n}\r\n".encode())
time.sleep(60)
