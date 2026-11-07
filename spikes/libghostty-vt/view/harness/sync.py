#!/usr/bin/env python3
# DEC 2026: rows change every 50 ms inside a hold. Presented frames must stay flat until it ends.
# The second hold never ends: the 1 s watchdog must break it.
import sys, time
w = sys.stdout.write
w("BEFORE-SYNC\r\n"); sys.stdout.flush(); time.sleep(2.0)
w("\x1b[?2026h"); sys.stdout.flush()
for i in range(12):
    w(f"held row {i}\r\n"); sys.stdout.flush(); time.sleep(0.05)
w("\x1b[?2026l"); sys.stdout.flush(); time.sleep(1.5)
w("\x1b[?2026h"); sys.stdout.flush()
for i in range(50):
    w(f"unterminated {i}\r\n"); sys.stdout.flush(); time.sleep(0.05)
time.sleep(5)
