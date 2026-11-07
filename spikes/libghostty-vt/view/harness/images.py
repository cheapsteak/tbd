#!/usr/bin/env python3
# Three image protocols, each between two text markers, then the replies that came back.
import base64, os, select, sys, termios, time, tty
fd = 0
tty.setraw(fd)
def out(s): os.write(1, s.encode())
rgb = bytes([255, 0, 0] * 16 + [0, 255, 0] * 16 + [0, 0, 255] * 16 + [255, 255, 0] * 16)  # 8x8 pixels, 192 bytes
png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAgAAAAIAQMAAAD+wSzIAAAABlBMVEX/AAD///9BHTQRAAAADklEQVQI12P4f4ABAQA+AAv/0F0tdwAAAABJRU5ErkJggg==")
out("SIXEL-BEFORE\r\n")
out("\x1bPq#0;2;100;0;0#1;2;0;100;0#0!40~-#1!40~-#0!40~\x1b\\")
out("SIXEL-AFTER\r\n\r\n")
out("ITERM2-BEFORE\r\n")
out("\x1b]1337;File=inline=1;width=8;height=2;preserveAspectRatio=0:" + base64.b64encode(png).decode() + "\x07")
out("ITERM2-AFTER\r\n\r\n")
out("KITTY-BEFORE\r\n")
out("\x1b_Gf=24,s=8,v=8,a=T,i=7,c=8,r=2;" + base64.b64encode(rgb).decode() + "\x1b\\")
out("KITTY-AFTER\r\n\r\n")
time.sleep(0.5)
got = b""
while select.select([fd], [], [], 0.2)[0]:
    got += os.read(fd, 4096)
out("REPLIES " + repr(got) + "\r\n")
out("DA1-CHECK\x1b[c")
time.sleep(0.3)
got = b""
while select.select([fd], [], [], 0.2)[0]:
    got += os.read(fd, 4096)
out("\r\nDA1 " + repr(got) + "\r\n")
time.sleep(20)
