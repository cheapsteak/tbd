#!/usr/bin/env python3
"""Sends the queries TUIs use and logs each reply, with what the terminal does with the signals."""
import os, select, sys, termios, time, tty
log = open(sys.argv[1], "w", buffering=1)
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
tty.setraw(fd)
QUERIES = [
    ("DA1", b"\x1b[c"), ("DA2", b"\x1b[>c"), ("DA3", b"\x1b[=c"), ("XTVERSION", b"\x1b[>q"), ("DSR", b"\x1b[5n"), ("CPR", b"\x1b[6n"),
    ("DECXCPR", b"\x1b[?6n"), ("win size px 14t", b"\x1b[14t"), ("cell px 16t", b"\x1b[16t"), ("win size chars 18t", b"\x1b[18t"),
    ("OSC10 fg", b"\x1b]10;?\x1b\\"), ("OSC11 bg", b"\x1b]11;?\x1b\\"), ("OSC12 cursor", b"\x1b]12;?\x1b\\"), ("OSC4 color1", b"\x1b]4;1;?\x1b\\"),
    ("colour scheme 996", b"\x1b[?996n"), ("DECRQM 2026", b"\x1b[?2026$p"), ("DECRQM 2027", b"\x1b[?2027$p"), ("DECRQM 2031", b"\x1b[?2031$p"),
    ("kitty flags", b"\x1b[?u"), ("XTGETTCAP TN", b"\x1bP+q544e\x1b\\"), ("XTGETTCAP Co", b"\x1bP+q436f\x1b\\"),
    ("kitty gfx query", b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"),
    ("OSC52 read", b"\x1b]52;c;?\x1b\\"),
    ("title report 21t", b"\x1b[21t"),
]
def ask(label, seq):
    os.write(1, seq)
    got = b""
    end = time.time() + 0.25
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r: got += os.read(fd, 4096)
    log.write(f"{label}: {got!r}\n")
try:
    time.sleep(0.2)
    for label, seq in QUERIES: ask(label, seq)
    os.write(1, b"\x1b]0;title via OSC0\x07\x07\x1b]7;file://acme-host/tmp/acme\x07\x1b]9;osc nine body\x1b\\\x1b]777;notify;t;b\x1b\\\x1b]9;4;1;40\x1b\\\x1b]52;c;aGVsbG8gb3NjNTI=\x1b\\")
    time.sleep(0.4)
    os.write(1, b"\x1b[2J\x1b[Hqueries done\r\n")
    time.sleep(0.3)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, saved)
