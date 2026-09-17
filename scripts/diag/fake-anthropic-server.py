#!/usr/bin/env python3
"""Deterministic fake Anthropic /v1/messages SSE server for TBD render benchmarking.

Emits a scripted assistant stream at a controlled rate so Claude Code's real TUI
becomes the byte producer. Knobs (env):
  FA_PORT      listen port                       (default 8787)
  FA_DELTAS    number of text_delta events       (default 400)
  FA_RATE      deltas per second                 (default 50)
  FA_TEXT      characters per delta              (default 24)
  FA_NEWLINE   insert '\n' every N deltas, 0=off (default 8)
"""
import json, os, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT   = int(os.environ.get("FA_PORT", "8787"))
DELTAS = int(os.environ.get("FA_DELTAS", "400"))
RATE   = float(os.environ.get("FA_RATE", "50"))
TEXTN  = int(os.environ.get("FA_TEXT", "24"))
NLEVERY= int(os.environ.get("FA_NEWLINE", "8"))

def sse(w, ev, obj):
    w.write(f"event: {ev}\ndata: {json.dumps(obj)}\n\n".encode())
    w.flush()

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *a):
        sys.stderr.write("[fake] %s %s\n" % (self.command, self.path))

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_POST(self):
        body = self._read_body()
        if self.path.startswith("/v1/messages/count_tokens"):
            return self._json({"input_tokens": 42})
        if self.path.startswith("/v1/messages"):
            try: req = json.loads(body or b"{}")
            except Exception: req = {}
            if req.get("stream"): return self._stream(req)
            return self._json({"id":"msg_fake","type":"message","role":"assistant",
                "model":req.get("model","claude-opus-5"),
                "content":[{"type":"text","text":"ok"}],
                "stop_reason":"end_turn","stop_sequence":None,
                "usage":{"input_tokens":10,"output_tokens":5}})
        return self._json({"ok": True})

    def do_GET(self):
        return self._json({"ok": True, "fake": True})

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length","0")
        self.end_headers()

    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(b)))
        self.end_headers(); self.wfile.write(b); self.wfile.flush()

    def _stream(self, req):
        model = req.get("model","claude-opus-5")
        self.send_response(200)
        self.send_header("Content-Type","text/event-stream")
        self.send_header("Cache-Control","no-cache")
        self.send_header("Connection","close")
        self.end_headers()
        self.close_connection = True
        w = self.wfile
        mid = "msg_fake_%d" % int(time.time()*1000)
        sse(w,"message_start",{"type":"message_start","message":{"id":mid,"type":"message",
            "role":"assistant","model":model,"content":[],"stop_reason":None,
            "stop_sequence":None,"usage":{"input_tokens":10,"output_tokens":1}}})
        sse(w,"content_block_start",{"type":"content_block_start","index":0,
            "content_block":{"type":"text","text":""}})
        per = 1.0/RATE if RATE>0 else 0
        t0 = time.time()
        for i in range(DELTAS):
            txt = ("w%04d " % i) + "abcdefghijklmnopqrstuvwxyz"[:max(0,TEXTN-6)]
            if NLEVERY and i % NLEVERY == NLEVERY-1: txt += "\n"
            sse(w,"content_block_delta",{"type":"content_block_delta","index":0,
                "delta":{"type":"text_delta","text":txt}})
            if per:
                d = t0 + (i+1)*per - time.time()
                if d>0: time.sleep(d)
        sse(w,"content_block_stop",{"type":"content_block_stop","index":0})
        sse(w,"message_delta",{"type":"message_delta",
            "delta":{"stop_reason":"end_turn","stop_sequence":None},
            "usage":{"output_tokens":DELTAS}})
        sse(w,"message_stop",{"type":"message_stop"})

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    sys.stderr.write("[fake] listening on 127.0.0.1:%d deltas=%d rate=%.0f/s\n"%(PORT,DELTAS,RATE))
    srv.serve_forever()
