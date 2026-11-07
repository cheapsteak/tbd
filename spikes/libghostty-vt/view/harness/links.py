#!/usr/bin/env python3
# OSC 8 hover and click targets: https on row 0, file on row 1, refused scheme on row 2.
import sys, time
def link(uri, text): return f"\x1b]8;;{uri}\x1b\\{text}\x1b]8;;\x1b\\"
sys.stdout.write(link("https://example.com/a", "https-link") + " tail\r\n")
sys.stdout.write(link("file:///tmp/x.txt", "file-link") + " tail\r\n")
sys.stdout.write(link("javascript:alert(1)", "bad-scheme") + " tail\r\n")
sys.stdout.flush()
time.sleep(30)
